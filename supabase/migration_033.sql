-- =============================================================================
-- migration_033.sql — run ONCE after migration_032.sql
-- 1) Two kinds of provider profile ("groups"): night = bartender + ENT, spa = masseuse + spa. A profile belongs to ONE
--    group (MIXED_GROUPS otherwise); the group decides which personality tags exist. Spa profiles price by SESSION
--    ('@60' / '@90' / '@120' minutes + own rows) and may say where they work (service_mode: shop / outcall / both).
--    Display for customers is unchanged. (One account still has ONE profile.)
-- 2) update_my_location(): a provider moves her location (GPS) + district + nearby area at any time, free and without
--    approval; everything else stays locked behind edit requests.
-- =============================================================================

alter table public.workers add column if not exists grp text not null default 'night';
alter table public.workers add column if not exists service_mode text;
alter table public.worker_applications add column if not exists grp text not null default 'night';
alter table public.worker_applications add column if not exists service_mode text;
grant insert (service_mode) on public.worker_applications to authenticated;
grant update (service_mode) on public.worker_applications to authenticated;
update public.workers set grp = 'spa' where categories && array['masseuse', 'spa'] and not categories && array['bartender', 'ent'];
update public.worker_applications set grp = 'spa' where categories && array['masseuse', 'spa'] and not categories && array['bartender', 'ent'];

create or replace function public.normalize_worker_profile()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  e jsonb; v_out jsonb := '[]'::jsonb; v_label text; v_price numeric; v_n int := 0;
  v_tags text[]; v_moved boolean;
begin
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

create or replace function public.approve_worker(p_app uuid)
returns void language plpgsql security definer set search_path = public as $$
declare a public.worker_applications; v_first public.profile_photos;
begin
  select * into a from public.worker_applications where id = p_app and status = 'pending';
  if not found then raise exception 'NOT_FOUND'; end if;
  if a.agency_id is not null and a.agency_status is distinct from 'accepted' then raise exception 'AGENCY_NOT_CONFIRMED'; end if;
  if a.age_check_status <> 'verified' then raise exception 'AGE_NOT_VERIFIED'; end if;
  if not exists (select 1 from public.profile_photos where user_id = a.user_id and state = 'application') and a.original_path is null then
    raise exception 'NO_PHOTO';
  end if;
  update public.users set role = 'worker' where id = a.user_id;
  perform set_config('app.no_fuzz', 'on', true);
  insert into public.workers (user_id, display_name, categories, price, province, district, nearby,
                              profile_image, original_path, recruiter_id, recruiter_until, agency_id, agency_since,
                              gender, age, height_cm, weight_kg, measurements, tags, about, price_options,
                              loc_lat, loc_lng, loc_verified_at, start_rate, service_mode)
  values (a.user_id, a.display_name, a.categories, a.price, a.province, a.district, a.nearby,
          a.profile_image, a.original_path, a.recruiter_id,
          case when a.recruiter_id is not null then now() + make_interval(days => public.recruiter_window_days()) end,
          a.agency_id, case when a.agency_id is not null then now() end,
          a.gender, a.age, a.height_cm, a.weight_kg, a.measurements, a.tags, a.about, a.price_options,
          a.loc_lat, a.loc_lng, a.loc_verified_at, a.start_rate, a.service_mode)
  on conflict (user_id) do update
    set display_name = excluded.display_name, categories = excluded.categories, price = excluded.price,
        province = excluded.province, district = excluded.district, nearby = excluded.nearby,
        profile_image = coalesce(excluded.profile_image, public.workers.profile_image),
        original_path = coalesce(excluded.original_path, public.workers.original_path),
        agency_id = coalesce(excluded.agency_id, public.workers.agency_id),
        agency_since = case when excluded.agency_id is not null and excluded.agency_id is distinct from public.workers.agency_id
                            then now() else public.workers.agency_since end,
        gender = coalesce(excluded.gender, public.workers.gender), age = coalesce(excluded.age, public.workers.age),
        height_cm = coalesce(excluded.height_cm, public.workers.height_cm), weight_kg = coalesce(excluded.weight_kg, public.workers.weight_kg),
        measurements = coalesce(excluded.measurements, public.workers.measurements),
        tags = excluded.tags, about = coalesce(excluded.about, public.workers.about),
        price_options = case when jsonb_array_length(excluded.price_options) > 0 then excluded.price_options else public.workers.price_options end,
        loc_lat = coalesce(excluded.loc_lat, public.workers.loc_lat), loc_lng = coalesce(excluded.loc_lng, public.workers.loc_lng),
        loc_verified_at = coalesce(excluded.loc_verified_at, public.workers.loc_verified_at),
        start_rate = excluded.start_rate, service_mode = excluded.service_mode,
        deleted_at = null, delete_requested_at = null;

  -- the application's pictures become the live ones; picture no. 1 is the card photo
  if exists (select 1 from public.profile_photos where user_id = a.user_id and state = 'application') then
    delete from public.profile_photos where user_id = a.user_id and state = 'live';
    update public.profile_photos set state = 'live' where user_id = a.user_id and state = 'application';
    select * into v_first from public.profile_photos where user_id = a.user_id and state = 'live' order by sort_no limit 1;
    update public.workers set profile_image = v_first.public_url, original_path = v_first.original_path where user_id = a.user_id;
  end if;
  update public.worker_applications set status = 'approved' where id = p_app;
end $$;
revoke all on function public.approve_worker(uuid) from public, anon, authenticated;

create or replace function public.check_profile_changes(p_changes jsonb)
returns void language plpgsql immutable as $$
declare k text;
begin
  if jsonb_typeof(p_changes) <> 'object' then raise exception 'BAD_INPUT'; end if;
  for k in select jsonb_object_keys(p_changes) loop
    if k <> all (array['display_name','categories','gender','age','height_cm','weight_kg','measurements','tags','about',
                       'price','price_options','start_rate','service_mode','district','nearby','province','loc_lat','loc_lng']) then
      raise exception 'BAD_INPUT';
    end if;
  end loop;
  if p_changes ? 'age' and ((p_changes->>'age') is null or (p_changes->>'age')::int not between 20 and 70) then raise exception 'BAD_AGE'; end if;
  if p_changes ? 'gender' and (p_changes->>'gender') not in ('female', 'male', 'lgbt') then raise exception 'BAD_INPUT'; end if;
  if p_changes ? 'service_mode' and (p_changes->>'service_mode') is not null and (p_changes->>'service_mode') not in ('shop', 'outcall', 'both') then raise exception 'BAD_INPUT'; end if;
  if p_changes ? 'price' and ((p_changes->>'price') is null or (p_changes->>'price')::numeric < 0) then raise exception 'BAD_PRICE'; end if;
  if p_changes ? 'display_name' and char_length(btrim(p_changes->>'display_name')) not between 1 and 40 then raise exception 'BAD_INPUT'; end if;
  if p_changes ? 'categories' and (jsonb_typeof(p_changes->'categories') <> 'array' or jsonb_array_length(p_changes->'categories') = 0) then raise exception 'BAD_INPUT'; end if;
end $$;

create or replace function public.admin_review_profile_edit(p_id uuid, p_approve boolean, p_reason text default null)
returns void language plpgsql security definer set search_path = public as $$
declare r public.profile_edit_requests; c jsonb; rec public.workers; v_first public.profile_photos;
begin
  perform public.assert_admin();
  select * into r from public.profile_edit_requests where id = p_id and status = 'pending' for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if not p_approve then
    perform public.close_profile_edit(p_id, 'rejected', left(nullif(btrim(coalesce(p_reason, '')), ''), 300));
    perform public.support_notify(r.user_id, '❌ แอดมินไม่อนุมัติการแก้ไขโปรไฟล์' || coalesce(' — ' || left(nullif(btrim(coalesce(p_reason, '')), ''), 300), '') || (case when r.fee > 0 then ' (คืนค่าบริการให้ Wallet แล้ว)' else '' end));
    return;
  end if;
  c := r.changes;
  select * into rec from jsonb_populate_record(null::public.workers, c);
  update public.workers w set
      display_name = case when c ? 'display_name' then rec.display_name else w.display_name end,
      categories   = case when c ? 'categories'   then rec.categories   else w.categories end,
      gender       = case when c ? 'gender'       then rec.gender       else w.gender end,
      age          = case when c ? 'age'          then rec.age          else w.age end,
      height_cm    = case when c ? 'height_cm'    then rec.height_cm    else w.height_cm end,
      weight_kg    = case when c ? 'weight_kg'    then rec.weight_kg    else w.weight_kg end,
      measurements = case when c ? 'measurements' then rec.measurements else w.measurements end,
      tags         = case when c ? 'tags'         then coalesce(rec.tags, '{}') else w.tags end,
      about        = case when c ? 'about'        then rec.about        else w.about end,
      price        = case when c ? 'price'        then rec.price        else w.price end,
      price_options= case when c ? 'price_options' then coalesce(rec.price_options, '[]'::jsonb) else w.price_options end,
      start_rate   = case when c ? 'start_rate'   then coalesce(rec.start_rate, '1h') else w.start_rate end,
      service_mode = case when c ? 'service_mode' then rec.service_mode else w.service_mode end,
      district     = case when c ? 'district'     then rec.district     else w.district end,
      nearby       = case when c ? 'nearby'       then rec.nearby       else w.nearby end,
      province     = case when c ? 'province'     then rec.province     else w.province end,
      loc_lat      = case when c ? 'loc_lat'      then rec.loc_lat      else w.loc_lat end,
      loc_lng      = case when c ? 'loc_lng'      then rec.loc_lng      else w.loc_lng end
   where w.user_id = r.user_id;
  delete from public.profile_photos where state = 'live' and id = any (r.remove_photos) and user_id = r.user_id;
  update public.profile_photos set state = 'live', request_id = null where request_id = p_id and state = 'pending_add';
  -- renumber and refresh the card photo
  with n as (select id, row_number() over (order by sort_no, created_at) as rn from public.profile_photos where user_id = r.user_id and state = 'live')
  update public.profile_photos p set sort_no = n.rn from n where p.id = n.id;
  select * into v_first from public.profile_photos where user_id = r.user_id and state = 'live' order by sort_no limit 1;
  if v_first.id is not null then
    update public.workers set profile_image = v_first.public_url, original_path = v_first.original_path where user_id = r.user_id;
  end if;
  update public.profile_edit_requests set status = 'approved', reviewed_by = auth.uid(), reviewed_at = now() where id = p_id;
  perform public.support_notify(r.user_id, '✅ แอดมินอนุมัติการแก้ไขโปรไฟล์แล้ว ข้อมูลและรูปใหม่แสดงในระบบเรียบร้อย');
end $$;

create or replace function public.admin_list_profile_edits(p_status text default 'pending')
returns table (id uuid, user_id uuid, user_name text, status text, created_at timestamptz, fee numeric, changes jsonb, current jsonb,
               add_photos jsonb, remove_photos jsonb, reject_reason text)
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.assert_admin();
  return query
    select r.id, r.user_id, u.display_name, r.status, r.created_at, r.fee, r.changes,
           jsonb_build_object('display_name', w.display_name, 'categories', w.categories, 'gender', w.gender, 'age', w.age,
                              'height_cm', w.height_cm, 'weight_kg', w.weight_kg, 'measurements', w.measurements, 'tags', w.tags,
                              'about', w.about, 'price', w.price, 'price_options', w.price_options, 'start_rate', w.start_rate, 'service_mode', w.service_mode, 'district', w.district,
                              'nearby', w.nearby, 'province', w.province),
           coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'public_url', p.public_url, 'original_path', p.original_path) order by p.created_at)
                       from public.profile_photos p where p.request_id = r.id and p.state = 'pending_add'), '[]'::jsonb),
           coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'public_url', p.public_url) order by p.sort_no)
                       from public.profile_photos p where p.id = any (r.remove_photos)), '[]'::jsonb),
           r.reject_reason
      from public.profile_edit_requests r
      join public.users u on u.id = r.user_id
      left join public.workers w on w.user_id = r.user_id
     where p_status is null or r.status = p_status
     order by r.created_at desc limit 100;
end $$;

drop function if exists public.admin_list_applications(text);
create function public.admin_list_applications(p_status text default 'pending')
returns table (id uuid, user_id uuid, user_name text, display_name text, categories text[], price numeric,
               province text, district text, nearby text, phone text, line_id text, note text,
               profile_image text, original_path text, status text, reject_reason text, created_at timestamptz,
               agency_name text, agency_status text,
               gender text, age int, height_cm int, weight_kg int, measurements text, tags text[], about text,
               price_options jsonb, loc_verified boolean,
               age_check_status text, age_verified_method text, age_check_note text, age_id_path text, age_selfie_path text, photos jsonb,
               start_rate text, grp text, service_mode text)
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.assert_admin();
  return query
    select a.id, a.user_id, u.display_name, a.display_name, a.categories, a.price,
           a.province, a.district, a.nearby, a.phone, a.line_id, a.note,
           a.profile_image, a.original_path, a.status, a.reject_reason, a.created_at,
           ag.name, a.agency_status,
           a.gender, a.age::int, a.height_cm::int, a.weight_kg::int, a.measurements, a.tags, a.about,
           a.price_options, a.loc_verified_at is not null,
           a.age_check_status, a.age_verified_method, a.age_check_note, a.age_id_path, a.age_selfie_path,
           coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'public_url', p.public_url, 'original_path', p.original_path) order by p.sort_no)
                       from public.profile_photos p where p.user_id = a.user_id and p.state = 'application'), '[]'::jsonb),
           a.start_rate, a.grp, a.service_mode
      from public.worker_applications a join public.users u on u.id = a.user_id
      left join public.agencies ag on ag.user_id = a.agency_id
     where p_status is null or a.status = p_status
     order by a.created_at desc
     limit 100;
end $$;

drop function if exists public.get_worker(uuid);
drop function if exists public.list_workers_near(double precision, double precision, numeric, text);
drop function if exists public.list_workers(text);
create function public.list_workers(p_category text default null)
returns table (
  user_id uuid, display_name text, category text, categories text[], price numeric,
  profile_image text, original_path text,
  is_online boolean, is_boosted boolean, rank int, can_view boolean,
  province text, district text, nearby text, agency_name text, agency_logo text,
  gender text, age int, height_cm int, weight_kg int, measurements text, tags text[], about text, price_options jsonb,
  distance_km numeric, loc_verified boolean, start_rate text, start_price numeric, grp text, service_mode text
) language sql stable security definer set search_path = public as $$
  with tier as (select public.viewer_tier() as t)
  select w.user_id, w.display_name, r.category, w.categories, w.price, w.profile_image,
         case when v.ok then w.original_path end,
         w.is_online, r.is_boosted, r.rank, v.ok,
         w.province, w.district, w.nearby, ag.name, ag.logo_path,
         w.gender, w.age::int, w.height_cm::int, w.weight_kg::int, w.measurements, w.tags, w.about, w.price_options,
         null::numeric, (w.loc_verified_at is not null and w.loc_lat is not null), w.start_rate,
         case when w.start_rate = '1h' then w.price else (select (o->>'price')::numeric from jsonb_array_elements(w.price_options) o where o->>'label' = w.start_rate limit 1) end,
         w.grp, w.service_mode
    from public.ranked_workers() r
    join public.workers w on w.user_id = r.user_id
    join tier on true
    cross join lateral (select public.can_view_category(r.category, r.free_rank, tier.t) as ok) v
    left join public.agencies ag on ag.user_id = w.agency_id
   where p_category is null or r.category = p_category
   order by r.category, r.rank
$$;
create function public.list_workers_near(p_lat double precision, p_lng double precision,
                                         p_radius_km numeric default 50, p_category text default null)
returns table (
  user_id uuid, display_name text, category text, categories text[], price numeric,
  profile_image text, original_path text,
  is_online boolean, is_boosted boolean, rank int, can_view boolean,
  province text, district text, nearby text, agency_name text, agency_logo text,
  gender text, age int, height_cm int, weight_kg int, measurements text, tags text[], about text, price_options jsonb,
  distance_km numeric, loc_verified boolean, start_rate text, start_price numeric, grp text, service_mode text
) language sql stable security definer set search_path = public as $$
  select l.user_id, l.display_name, l.category, l.categories, l.price, l.profile_image, l.original_path,
         l.is_online, l.is_boosted, l.rank, l.can_view, l.province, l.district, l.nearby, l.agency_name, l.agency_logo,
         l.gender, l.age, l.height_cm, l.weight_kg, l.measurements, l.tags, l.about, l.price_options,
         greatest(1, ceil(public.geo_km(p_lat, p_lng, w.loc_lat, w.loc_lng)))::numeric, true, l.start_rate, l.start_price, l.grp, l.service_mode
    from public.list_workers(p_category) l
    join public.workers w on w.user_id = l.user_id
   where p_lat between 5.4 and 20.7 and p_lng between 97.2 and 105.8
     and w.loc_lat is not null and w.loc_verified_at is not null
     and public.geo_km(p_lat, p_lng, w.loc_lat, w.loc_lng) <= least(greatest(p_radius_km, 1), 100)
   order by 25, l.rank
$$;

create or replace function public.get_worker(p_worker uuid)
returns table (
  user_id uuid, display_name text, category text, categories text[], price numeric,
  profile_image text, original_path text,
  is_online boolean, is_boosted boolean, rank int, can_view boolean,
  province text, district text, nearby text, agency_name text, agency_logo text,
  gender text, age int, height_cm int, weight_kg int, measurements text, tags text[], about text, price_options jsonb,
  distance_km numeric, loc_verified boolean, start_rate text, start_price numeric, grp text, service_mode text
) language sql stable security definer set search_path = public as $$
  select * from public.list_workers(null) l where l.user_id = p_worker order by l.rank limit 1
$$;

-- ---------- free location change ----------------------------------------------------------
create table if not exists public.location_changes (id uuid primary key default gen_random_uuid(), user_id uuid not null, created_at timestamptz not null default now());
create index if not exists location_changes_idx on public.location_changes (user_id, created_at desc);
alter table public.location_changes enable row level security;
revoke all on public.location_changes from anon, authenticated;

create or replace function public.update_my_location(p_lat double precision, p_lng double precision, p_district text default null, p_nearby text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null or not exists (select 1 from public.workers where user_id = auth.uid()) then raise exception 'FORBIDDEN'; end if;
  if (select count(*) from public.location_changes where user_id = auth.uid() and created_at > now() - interval '24 hours') >= 10 then
    raise exception 'RATE_LIMIT';
  end if;
  insert into public.location_changes (user_id) values (auth.uid());
  -- the profile trigger blurs the point, sets the province from it and marks the location as GPS-verified
  update public.workers set loc_lat = p_lat, loc_lng = p_lng,
         district = left(nullif(btrim(coalesce(p_district, '')), ''), 60), nearby = left(nullif(btrim(coalesce(p_nearby, '')), ''), 120)
   where user_id = auth.uid();
end $$;

revoke all on function public.list_workers(text), public.list_workers_near(double precision, double precision, numeric, text),
  public.get_worker(uuid), public.admin_list_applications(text), public.check_profile_changes(jsonb),
  public.admin_review_profile_edit(uuid, boolean, text), public.admin_list_profile_edits(text), public.update_my_location(double precision, double precision, text, text) from public, anon;
grant execute on function public.list_workers(text), public.list_workers_near(double precision, double precision, numeric, text),
  public.get_worker(uuid), public.admin_list_applications(text), public.admin_review_profile_edit(uuid, boolean, text),
  public.admin_list_profile_edits(text), public.update_my_location(double precision, double precision, text, text) to authenticated;
-- =============================================================================
