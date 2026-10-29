-- =============================================================================
-- migration_049.sql — run ONCE after migration_048.sql
-- Fix: the admin button "ลบเลย" (and the 24-hour automatic removal) failed for every provider with a GPS-verified location
-- ("ทำรายการไม่สำเร็จ", BAD_LOCATION): blanking the location tripped the profile validation trigger. The wipe now runs with the
-- validation switched off for that one statement.
-- =============================================================================

create or replace function public.normalize_worker_profile()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  e jsonb; v_out jsonb := '[]'::jsonb; v_label text; v_price numeric; v_n int := 0;
  v_tags text[]; v_moved boolean;
begin
  -- finishing a profile deletion blanks the location / prices on purpose: no re-validation then
  if coalesce(current_setting('app.profile_wipe', true), '') = 'on' then return new; end if;
  if tg_table_name = 'worker_applications' and tg_op = 'INSERT' then
    if new.accepted_terms is not true then raise exception 'TERMS_REQUIRED'; end if;
    new.terms_accepted_at := now();
  end if;

  -- profile group: night (bartender / ENT) or spa (masseuse / spa); one profile never mixes the two
  new.grp := case when new.categories && array['bartender', 'ent'] then 'night' when new.categories && array['masseuse', 'spa'] then 'spa' else 'night' end;
  if new.categories && array['bartender', 'ent'] and new.categories && array['masseuse', 'spa']
     and (tg_op = 'INSERT' or new.categories is distinct from old.categories) then
    raise exception 'MIXED_GROUPS';
  end if;
  new.service_mode := case when new.grp = 'spa' and new.service_mode in ('shop', 'outcall', 'both') then new.service_mode else null end;

  select coalesce(array_agg(distinct x), '{}') into v_tags
    from unnest(coalesce(new.tags, '{}')) x
   where x = any (case when new.grp = 'spa'
                        then array['thai_massage', 'oil', 'foot', 'aroma', 'sports', 'scrub', 'polite', 'punctual', 'experienced']
                        else array['playful', 'fun_talk', 'not_picky', 'sing', 'dance', 'drinks', 'friendly'] end);
  new.tags := v_tags;
  new.about := nullif(btrim(coalesce(new.about, '')), '');
  new.measurements := nullif(btrim(coalesce(new.measurements, '')), '');
  -- contact details must not hide in the public profile text either (only checked when the text is new or changed)
  if tg_op = 'INSERT' or new.about is distinct from old.about or new.display_name is distinct from old.display_name
     or new.nearby is distinct from old.nearby or new.district is distinct from old.district then
    if public.contact_problem(concat_ws(' | ', new.display_name, new.about, new.nearby, new.district)) is not null then
      raise exception 'CONTACT_IN_PROFILE';
    end if;
  end if;

  if jsonb_typeof(coalesce(new.price_options, '[]'::jsonb)) <> 'array' then raise exception 'BAD_PRICE'; end if;
  for e in select * from jsonb_array_elements(coalesce(new.price_options, '[]'::jsonb)) loop
    exit when v_n >= 8;
    v_label := left(btrim(coalesce(e->>'label', '')), 30);
    begin v_price := (e->>'price')::numeric; exception when others then raise exception 'BAD_PRICE'; end;
    if v_label = '' then continue; end if;
    if v_price is null or v_price < 0 or v_price > 1000000 then raise exception 'BAD_PRICE'; end if;
    v_out := v_out || jsonb_build_object('label', v_label, 'price', round(v_price));
    v_n := v_n + 1;
  end loop;
  new.price_options := v_out;

  v_moved := (tg_op = 'INSERT' and new.loc_lat is not null)
             or (tg_op = 'UPDATE' and (new.loc_lat is distinct from old.loc_lat or new.loc_lng is distinct from old.loc_lng));
  if v_moved then
    if new.loc_lat is null or new.loc_lng is null or public.province_for(new.loc_lat, new.loc_lng) is null then
      raise exception 'BAD_LOCATION';
    end if;
    if coalesce(current_setting('app.no_fuzz', true), '') <> 'on' then
      new.loc_lat := round((new.loc_lat / 0.005)::numeric) * 0.005 + (random() - 0.5) * 0.004;
      new.loc_lng := round((new.loc_lng / 0.005)::numeric) * 0.005 + (random() - 0.5) * 0.004;
      new.loc_verified_at := now();
    end if;
    new.province := coalesce(public.province_for(new.loc_lat, new.loc_lng), new.province);
  elsif tg_op = 'UPDATE' and new.province is distinct from old.province
        and coalesce(current_setting('app.no_fuzz', true), '') <> 'on' then
    -- a province typed by hand replaces a GPS-confirmed one: the old point no longer applies, the profile is self-declared
    new.loc_lat := null; new.loc_lng := null; new.loc_verified_at := null;
  end if;
  -- Every rate lives in price_options ('1h', '@4h', '@6h' or her own rows); the starting rate must be one of them and
  -- `price` always mirrors it (bookings and the feed read that column). Legacy rows only had `price` = hourly.
  new.start_rate := nullif(btrim(coalesce(new.start_rate, '')), '');
  if (new.start_rate is null or new.start_rate = '1h') and coalesce(new.price, 0) > 0
     and not exists (select 1 from jsonb_array_elements(new.price_options) o where o->>'label' = '1h')
     and (new.start_rate = '1h' or jsonb_array_length(new.price_options) = 0) then
    new.price_options := new.price_options || jsonb_build_object('label', '1h', 'price', round(new.price));
    new.start_rate := '1h';
  end if;
  if new.start_rate is null then
    select o->>'label' into new.start_rate from jsonb_array_elements(new.price_options) o
     order by case o->>'label' when '@4h' then 1 when '@6h' then 2 when '@60' then 3 when '@90' then 4 when '@120' then 5 when '1h' then 6 else 7 end limit 1;
  end if;
  select (o->>'price')::numeric into v_price from jsonb_array_elements(new.price_options) o where o->>'label' = new.start_rate limit 1;
  if new.start_rate is null or v_price is null then raise exception 'BAD_START_RATE'; end if;
  new.price := v_price;
  return new;
end $$;

create or replace function public.finish_profile_deletion(p_user uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform set_config('app.profile_wipe', 'on', true);
  update public.workers set deleted_at = now(), is_online = false, agency_id = null, agency_since = null,
         profile_image = null, original_path = null, about = null, tags = '{}', price_options = '[]'::jsonb,
         loc_lat = null, loc_lng = null, loc_verified_at = null
   where user_id = p_user and deleted_at is null;
  perform set_config('app.profile_wipe', '', true);
  delete from public.profile_photos where user_id = p_user;
  update public.profile_edit_requests set status = 'cancelled', reviewed_at = now() where user_id = p_user and status = 'pending';
  update public.users set role = 'customer' where id = p_user and role = 'worker';
  perform public.support_notify(p_user, '🗑️ โปรไฟล์ผู้ให้บริการของคุณถูกลบออกจากระบบแล้ว สมัครใหม่ได้ทุกเมื่อ');
end $$;
revoke all on function public.finish_profile_deletion(uuid) from public, anon, authenticated;
