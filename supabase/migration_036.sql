-- =============================================================================
-- migration_036.sql — run ONCE after migration_035.sql
-- Profiles published by an admin ("managed" profiles):
--   * the admin fills the draft in, records how the age was verified and that the girl consented, and PUBLISHES it: the
--     profile is visible to customers at once, with a "waiting for confirmation" badge, but it cannot be booked or chatted
--     with (UNCLAIMED) until the girl confirms through the link.
--   * a placeholder account (auth.users + users row, line_user_id 'managed:<id>') owns it meanwhile.
--   * unclaimed profiles hide themselves 14 days after publishing (re-issuing the link adds 14 days).
--   * when the girl claims the link the profile moves to HER account (workers.user_id is re-keyed; the foreign keys get
--     ON UPDATE CASCADE) and the placeholder is deleted. She confirms her GPS location, chooses self / agency, accepts.
--   * cancelling the draft removes the profile.
-- =============================================================================

-- foreign keys to workers(user_id) must follow a re-key
do $$
declare r record;
begin
  for r in select conrelid::regclass as tbl, conname, pg_get_constraintdef(oid) as def
             from pg_constraint where confrelid = 'public.workers'::regclass and contype = 'f' and pg_get_constraintdef(oid) !~* 'on update cascade' loop
    execute format('alter table %s drop constraint %I', r.tbl, r.conname);
    execute format('alter table %s add constraint %I %s on update cascade', r.tbl, r.conname, r.def);
  end loop;
end $$;

alter table public.application_drafts
  add column if not exists managed_user_id uuid,
  add column if not exists published_at timestamptz,
  add column if not exists age_verified_method text,
  add column if not exists age_verified_by uuid,
  add column if not exists age_verified_at timestamptz,
  add column if not exists consent_note text;

create or replace function public.worker_listed(p_worker uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select not public.is_suspended(p_worker)
     and coalesce((select w.deleted_at is null and w.delete_requested_at is null and not w.admin_hidden and (w.claimed or w.claim_deadline > now())
                          and (w.agency_id is null or public.agency_active(w.agency_id))
                     from public.workers w where w.user_id = p_worker), false)
$$;

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
  distance_km numeric, loc_verified boolean, start_rate text, start_price numeric, grp text, service_mode text, claimed boolean
) language sql stable security definer set search_path = public as $$
  with tier as (select public.viewer_tier() as t)
  select w.user_id, w.display_name, r.category, w.categories, w.price, w.profile_image,
         case when v.ok then w.original_path end,
         w.is_online, r.is_boosted, r.rank, v.ok,
         w.province, w.district, w.nearby, ag.name, ag.logo_path,
         w.gender, w.age::int, w.height_cm::int, w.weight_kg::int, w.measurements, w.tags, w.about, w.price_options,
         null::numeric, (w.loc_verified_at is not null and w.loc_lat is not null), w.start_rate,
         case when w.start_rate = '1h' then w.price else (select (o->>'price')::numeric from jsonb_array_elements(w.price_options) o where o->>'label' = w.start_rate limit 1) end,
         w.grp, w.service_mode, w.claimed
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
  distance_km numeric, loc_verified boolean, start_rate text, start_price numeric, grp text, service_mode text, claimed boolean
) language sql stable security definer set search_path = public as $$
  select l.user_id, l.display_name, l.category, l.categories, l.price, l.profile_image, l.original_path,
         l.is_online, l.is_boosted, l.rank, l.can_view, l.province, l.district, l.nearby, l.agency_name, l.agency_logo,
         l.gender, l.age, l.height_cm, l.weight_kg, l.measurements, l.tags, l.about, l.price_options,
         greatest(1, ceil(public.geo_km(p_lat, p_lng, w.loc_lat, w.loc_lng)))::numeric, true, l.start_rate, l.start_price, l.grp, l.service_mode, l.claimed
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
  distance_km numeric, loc_verified boolean, start_rate text, start_price numeric, grp text, service_mode text, claimed boolean
) language sql stable security definer set search_path = public as $$
  select * from public.list_workers(null) l where l.user_id = p_worker order by l.rank limit 1
$$;
revoke all on function public.list_workers(text), public.list_workers_near(double precision, double precision, numeric, text), public.get_worker(uuid) from public, anon;
grant execute on function public.list_workers(text), public.list_workers_near(double precision, double precision, numeric, text), public.get_worker(uuid) to authenticated;

create or replace function public.open_thread(p_worker uuid)
returns uuid language plpgsql security definer set search_path = public as $$
declare v uuid;
begin
  if auth.uid() is null then raise exception 'FORBIDDEN'; end if;
  if p_worker = auth.uid() then raise exception 'SELF_CHAT'; end if;
  if public.viewer_tier() < 1 then raise exception 'MEMBERS_ONLY'; end if;
  if not public.can_view_worker(p_worker) then raise exception 'LOCKED'; end if;
  if exists (select 1 from public.workers w where w.user_id = p_worker and not w.claimed) then raise exception 'UNCLAIMED'; end if;
  insert into public.chat_threads (customer_id, worker_id) values (auth.uid(), p_worker)
  on conflict (customer_id, worker_id) do nothing;
  select id into v from public.chat_threads where customer_id = auth.uid() and worker_id = p_worker;
  return v;
end $$;

create or replace function public.draft_view(d public.application_drafts)
returns jsonb language sql stable security definer set search_path = public as $$
  select to_jsonb(d) - 'token' - 'province' - 'loc_lat' - 'loc_lng' - 'loc_verified_at'
         || jsonb_build_object(
              'token', case when d.status = 'approved' and d.link_expires_at > now() then d.token end,
              'link_active', d.status = 'approved' and d.link_expires_at > now(),
              'link_expired', d.status = 'expired' or (d.status = 'approved' and d.link_expires_at <= now()),
              'managed', d.managed_user_id is not null,
              'claim_deadline', (select w.claim_deadline from public.workers w where w.user_id = d.managed_user_id and not w.claimed),
              'agency_name', (select a.name from public.agencies a where a.user_id = d.agency_id),
              'creator_name', (select u.display_name from public.users u where u.id = d.created_by),
              'photos', coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'public_url', p.public_url, 'original_path', p.original_path) order by p.sort_no)
                                    from public.draft_photos p where p.draft_id = d.id), '[]'::jsonb))
$$;

-- keeps the published profile equal to its draft (text fields and photos) while it is unclaimed
create or replace function public.sync_managed_profile(p_draft uuid)
returns void language plpgsql security definer set search_path = public as $$
declare d public.application_drafts;
begin
  select * into d from public.application_drafts where id = p_draft;
  if not found or d.managed_user_id is null then return; end if;
  update public.workers set display_name = d.display_name, categories = d.categories, gender = d.gender, age = d.age, height_cm = d.height_cm,
         weight_kg = d.weight_kg, measurements = d.measurements, tags = d.tags, about = d.about, price_options = d.price_options,
         start_rate = d.start_rate, service_mode = d.service_mode, district = d.district, nearby = d.nearby,
         booking_phone = d.phone, booking_line_id = d.line_id
   where user_id = d.managed_user_id and not claimed;
  delete from public.profile_photos where user_id = d.managed_user_id and state = 'live';
  insert into public.profile_photos (user_id, state, sort_no, public_url, original_path)
    select d.managed_user_id, 'live', p.sort_no, p.public_url, p.original_path from public.draft_photos p where p.draft_id = p_draft order by p.sort_no;
  update public.workers w set profile_image = (select p.public_url from public.draft_photos p where p.draft_id = p_draft order by p.sort_no limit 1),
         original_path = (select p.original_path from public.draft_photos p where p.draft_id = p_draft order by p.sort_no limit 1)
   where w.user_id = d.managed_user_id;
end $$;
revoke all on function public.sync_managed_profile(uuid) from public, anon, authenticated;

create or replace function public.draft_save(p_id uuid, p_data jsonb)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  r public.application_drafts; d public.application_drafts; v_id uuid;
  v_admin boolean := public.is_admin(); v_agency uuid;
begin
  if auth.uid() is null then raise exception 'FORBIDDEN'; end if;
  if not v_admin then
    select user_id into v_agency from public.agencies where user_id = auth.uid() and status = 'approved';
    if v_agency is null or not public.agency_active(v_agency) then raise exception 'PLAN_INACTIVE'; end if;
  end if;
  r := jsonb_populate_record(null::public.application_drafts, coalesce(p_data, '{}'::jsonb));
  if r.categories is null or coalesce(array_length(r.categories, 1), 0) = 0 or btrim(coalesce(r.display_name, '')) = '' then raise exception 'BAD_INPUT'; end if;

  if p_id is null then
    if (select count(*) from public.application_drafts where created_by = auth.uid() and status in ('draft', 'submitted', 'approved', 'rejected')) >= 40 then
      raise exception 'TOO_MANY_DRAFTS';
    end if;
    insert into public.application_drafts (created_by, source, agency_id, display_name, categories, gender, age, height_cm, weight_kg, measurements,
                                           tags, about, price, price_options, start_rate, service_mode, district, nearby, phone, line_id, note)
    values (auth.uid(), case when v_admin then 'admin' else 'agency' end, case when v_admin then null else v_agency end,
            r.display_name, r.categories, r.gender, r.age, r.height_cm, r.weight_kg, r.measurements,
            coalesce(r.tags, '{}'), r.about, coalesce(r.price, 0), coalesce(r.price_options, '[]'::jsonb), r.start_rate, r.service_mode,
            r.district, r.nearby, nullif(btrim(coalesce(r.phone, '')), ''), nullif(btrim(coalesce(r.line_id, '')), ''), left(r.note, 300))
    returning id into v_id;
    return v_id;
  end if;

  select * into d from public.application_drafts where id = p_id and created_by = auth.uid() for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if d.status not in ('draft', 'rejected', 'approved', 'expired') then raise exception 'LOCKED'; end if;
  update public.application_drafts set
    display_name = r.display_name, categories = r.categories, gender = r.gender, age = r.age, height_cm = r.height_cm, weight_kg = r.weight_kg,
    measurements = r.measurements, tags = coalesce(r.tags, '{}'), about = r.about, price = coalesce(r.price, 0),
    price_options = coalesce(r.price_options, '[]'::jsonb), start_rate = r.start_rate, service_mode = r.service_mode,
    district = r.district, nearby = r.nearby, phone = nullif(btrim(coalesce(r.phone, '')), ''), line_id = nullif(btrim(coalesce(r.line_id, '')), ''),
    note = left(r.note, 300), updated_at = now(),
    -- an agency's change after approval needs a new approval; an admin's own draft keeps its link
    status = case when v_admin then (case when d.status = 'expired' then 'draft' else d.status end) else 'draft' end,
    token = case when v_admin then d.token else null end,
    reject_reason = null
   where id = p_id;
  perform public.sync_managed_profile(p_id);
  return p_id;
end $$;

create or replace function public.draft_attach_photo(p_draft uuid, p_public_url text, p_original_path text)
returns uuid language plpgsql security definer set search_path = public as $$
declare d public.application_drafts; v_n int; v_id uuid;
begin
  select * into d from public.application_drafts where id = p_draft and created_by = auth.uid() for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if d.status not in ('draft', 'rejected', 'approved', 'expired') then raise exception 'LOCKED'; end if;
  if p_original_path is null or p_original_path not like p_draft::text || '/%' or p_public_url is null then raise exception 'BAD_INPUT'; end if;
  select count(*) into v_n from public.draft_photos where draft_id = p_draft;
  if v_n >= 5 then raise exception 'TOO_MANY_PHOTOS'; end if;
  insert into public.draft_photos (draft_id, sort_no, public_url, original_path) values (p_draft, v_n + 1, p_public_url, p_original_path) returning id into v_id;
  if d.source = 'agency' and d.status <> 'draft' then
    update public.application_drafts set status = 'draft', token = null, updated_at = now() where id = p_draft;
  end if;
  perform public.sync_managed_profile(p_draft);
  return v_id;
end $$;

create or replace function public.draft_remove_photo(p_photo uuid)
returns text language plpgsql security definer set search_path = public as $$
declare v_path text; v_draft uuid; d public.application_drafts;
begin
  select dp.original_path, dp.draft_id into v_path, v_draft from public.draft_photos dp where dp.id = p_photo;
  select * into d from public.application_drafts where id = v_draft and created_by = auth.uid() and status in ('draft', 'rejected', 'approved', 'expired');
  if v_path is null or not found then raise exception 'NOT_FOUND'; end if;
  delete from public.draft_photos where id = p_photo;
  if d.source = 'agency' and d.status <> 'draft' then
    update public.application_drafts set status = 'draft', token = null, updated_at = now() where id = d.id;
  end if;
  perform public.sync_managed_profile(d.id);
  return v_path;
end $$;

create or replace function public.draft_issue_link(p_id uuid)
returns text language plpgsql security definer set search_path = public as $$
declare d public.application_drafts; v_tok text := public.draft_new_token(); v_admin boolean := public.is_admin();
begin
  select * into d from public.application_drafts where id = p_id and (created_by = auth.uid() or v_admin) for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if d.source = 'agency' and not v_admin then
    if d.status not in ('approved', 'expired') then raise exception 'NOT_APPROVED'; end if;
    if not public.agency_active(d.agency_id) then raise exception 'PLAN_INACTIVE'; end if;
  else
    if d.status not in ('draft', 'approved', 'expired') and not (v_admin and d.status = 'submitted') then raise exception 'LOCKED'; end if;
  end if;
  if not exists (select 1 from public.draft_photos where draft_id = p_id) then raise exception 'NO_PHOTO'; end if;
  update public.application_drafts set status = 'approved', token = v_tok, link_issued_at = now(), link_expires_at = now() + interval '3 days',
         reviewed_by = case when v_admin then auth.uid() else reviewed_by end, reviewed_at = case when v_admin then now() else reviewed_at end,
         updated_at = now() where id = p_id;
  -- an unclaimed published profile keeps showing for 14 more days from the moment a link is (re)issued
  update public.workers set claim_deadline = greatest(coalesce(claim_deadline, now()), now() + interval '14 days')
   where user_id = d.managed_user_id and not claimed;
  return v_tok;
end $$;

-- admin: publish the draft now (visible, not bookable until the girl confirms) and issue the link
create or replace function public.admin_publish_draft(p_id uuid, p_province text, p_age_method text, p_consent_note text)
returns text language plpgsql security definer set search_path = public as $$
declare d public.application_drafts; v_uid uuid := gen_random_uuid();
begin
  perform public.assert_admin();
  select * into d from public.application_drafts where id = p_id and source = 'admin' and status in ('draft', 'approved', 'expired') for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if d.managed_user_id is not null then return public.draft_issue_link(p_id); end if;
  if not exists (select 1 from public.draft_photos where draft_id = p_id) then raise exception 'NO_PHOTO'; end if;
  if not exists (select 1 from public.province_centroids where name = p_province) then raise exception 'BAD_PROVINCE'; end if;
  if p_age_method not in ('photo', 'video_call', 'in_person', 'id_card') then raise exception 'BAD_AGE_METHOD'; end if;
  if char_length(btrim(coalesce(p_consent_note, ''))) < 3 then raise exception 'CONSENT_REQUIRED'; end if;
  if coalesce(d.age, 0) < 20 then raise exception 'BAD_AGE'; end if;

  insert into auth.users (id, instance_id, aud, role, email, raw_user_meta_data, created_at, updated_at)
  values (v_uid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'managed-' || v_uid || '@managed.invalid',
          jsonb_build_object('line_user_id', 'managed:' || v_uid), now(), now());
  update public.users set role = 'worker', display_name = d.display_name where id = v_uid;

  insert into public.workers (user_id, display_name, categories, price, province, district, nearby, gender, age, height_cm, weight_kg, measurements,
                              tags, about, price_options, start_rate, service_mode, is_online, claimed, claim_deadline, booking_phone, booking_line_id,
                              profile_image, original_path)
  values (v_uid, d.display_name, d.categories, d.price, p_province, d.district, d.nearby, d.gender, d.age, d.height_cm, d.weight_kg, d.measurements,
          d.tags, d.about, d.price_options, d.start_rate, d.service_mode, true, false, now() + interval '14 days', d.phone, d.line_id,
          (select p.public_url from public.draft_photos p where p.draft_id = p_id order by p.sort_no limit 1),
          (select p.original_path from public.draft_photos p where p.draft_id = p_id order by p.sort_no limit 1));
  insert into public.profile_photos (user_id, state, sort_no, public_url, original_path)
    select v_uid, 'live', p.sort_no, p.public_url, p.original_path from public.draft_photos p where p.draft_id = p_id order by p.sort_no;
  insert into public.draft_owner_map (draft_id, user_id) values (p_id, v_uid) on conflict (draft_id) do update set user_id = excluded.user_id;
  update public.application_drafts set managed_user_id = v_uid, published_at = now(), province = p_province, age_verified_method = p_age_method,
         age_verified_by = auth.uid(), age_verified_at = now(), consent_note = left(btrim(p_consent_note), 300) where id = p_id;
  return public.draft_issue_link(p_id);
end $$;

-- cancelling a published draft takes the profile down
create or replace function public.draft_cancel(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare d public.application_drafts;
begin
  select * into d from public.application_drafts
   where id = p_id and (created_by = auth.uid() or public.is_admin()) and status in ('draft', 'submitted', 'approved', 'rejected', 'expired') for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  update public.application_drafts set status = 'cancelled', token = null, managed_user_id = null, updated_at = now() where id = p_id;
  if d.managed_user_id is not null then
    delete from public.draft_owner_map where draft_id = p_id;
    delete from auth.users where id = d.managed_user_id;      -- cascades to users, workers and photos
  end if;
end $$;

create or replace function public.claim_preview(p_token text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare d public.application_drafts;
begin
  if auth.uid() is null then raise exception 'FORBIDDEN'; end if;
  select * into d from public.application_drafts where token = p_token;
  if not found then raise exception 'NOT_FOUND'; end if;
  if d.status = 'claimed' then raise exception 'USED'; end if;
  if d.status <> 'approved' or d.link_expires_at <= now() then raise exception 'EXPIRED'; end if;
  return jsonb_build_object(
    'source', d.source, 'managed', d.managed_user_id is not null, 'grp', d.grp, 'display_name', d.display_name, 'categories', d.categories, 'gender', d.gender, 'age', d.age,
    'height_cm', d.height_cm, 'weight_kg', d.weight_kg, 'measurements', d.measurements, 'tags', d.tags, 'about', d.about,
    'price_options', d.price_options, 'start_rate', d.start_rate, 'service_mode', d.service_mode, 'district', d.district, 'nearby', d.nearby,
    'phone', d.phone, 'line_id', d.line_id, 'expires_at', d.link_expires_at,
    'agency_name', (select a.name from public.agencies a where a.user_id = d.agency_id),
    'agency_logo', (select a.logo_path from public.agencies a where a.user_id = d.agency_id),
    'photos', coalesce((select jsonb_agg(p.public_url order by p.sort_no) from public.draft_photos p where p.draft_id = d.id), '[]'::jsonb),
    'already_provider', exists (select 1 from public.workers w where w.user_id = auth.uid() and w.deleted_at is null)
                        or exists (select 1 from public.worker_applications x where x.user_id = auth.uid() and x.status = 'pending'));
end $$;

create or replace function public.claim_draft(p_token text, p_lat double precision, p_lng double precision, p_choice text default 'self',
                                              p_agency_code text default null, p_phone text default null, p_line_id text default null,
                                              p_adult boolean default false, p_consent boolean default false, p_terms boolean default false)
returns uuid language plpgsql security definer set search_path = public as $$
declare d public.application_drafts; v_code text; v_phone text; v_line text; v_app uuid;
begin
  if auth.uid() is null then raise exception 'FORBIDDEN'; end if;
  select * into d from public.application_drafts where token = p_token for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if d.status = 'claimed' then raise exception 'USED'; end if;
  if d.status <> 'approved' or d.link_expires_at <= now() then raise exception 'EXPIRED'; end if;
  if not (coalesce(p_adult, false) and coalesce(p_consent, false) and coalesce(p_terms, false)) then raise exception 'CONSENT_REQUIRED'; end if;
  if p_lat is null or p_lng is null then raise exception 'LOCATION_REQUIRED'; end if;
  if exists (select 1 from public.workers w where w.user_id = auth.uid() and w.deleted_at is null)
     or exists (select 1 from public.worker_applications x where x.user_id = auth.uid() and x.status = 'pending') then
    raise exception 'ALREADY_PROVIDER';
  end if;
  if d.source = 'agency' then
    select a.code into v_code from public.agencies a where a.user_id = d.agency_id;
  elsif p_choice = 'agency' then
    v_code := nullif(btrim(coalesce(p_agency_code, '')), '');
    if v_code is null then raise exception 'AGENCY_CODE_REQUIRED'; end if;
  end if;
  v_phone := coalesce(nullif(btrim(coalesce(p_phone, '')), ''), d.phone);
  v_line := coalesce(nullif(btrim(coalesce(p_line_id, '')), ''), d.line_id);
  if v_phone is null and v_line is null then raise exception 'CONTACT_REQUIRED'; end if;

  if d.managed_user_id is not null then
    -- the profile an admin published for her is hers now: it moves to her account and the placeholder disappears
    update public.workers set user_id = auth.uid() where user_id = d.managed_user_id;
    update public.profile_photos set user_id = auth.uid() where user_id = d.managed_user_id;
    update public.users set role = 'worker' where id = auth.uid();
    update public.workers set claimed = true, claim_deadline = null, is_online = false, booking_phone = v_phone, booking_line_id = v_line,
           loc_lat = p_lat, loc_lng = p_lng
     where user_id = auth.uid();
    delete from auth.users where id = d.managed_user_id;
    insert into public.draft_owner_map (draft_id, user_id) values (d.id, auth.uid()) on conflict (draft_id) do update set user_id = excluded.user_id;
    update public.application_drafts set status = 'claimed', claimed_by = auth.uid(), claimed_at = now(), token = null, managed_user_id = null, updated_at = now() where id = d.id;
    if p_choice = 'agency' then perform public.worker_join_agency(v_code); end if;
    return auth.uid();
  end if;

  insert into public.worker_applications (user_id, display_name, categories, price, price_options, start_rate, service_mode, district, nearby,
                                          phone, line_id, note, gender, age, height_cm, weight_kg, measurements, tags, about,
                                          loc_lat, loc_lng, accepted_terms, agency_code)
  values (auth.uid(), d.display_name, d.categories, d.price, d.price_options, d.start_rate, d.service_mode, d.district, d.nearby,
          v_phone, v_line, left(concat_ws(' ', d.note, '[แบบร่างจาก ' || case d.source when 'agency' then 'โมเดลลิ่ง' else 'แอดมิน' end || ']'), 300),
          d.gender, d.age, d.height_cm, d.weight_kg, d.measurements, d.tags, d.about, p_lat, p_lng, true, v_code)
  returning id into v_app;

  insert into public.profile_photos (user_id, state, sort_no, public_url, original_path)
    select auth.uid(), 'application', p.sort_no, p.public_url, p.original_path from public.draft_photos p where p.draft_id = d.id order by p.sort_no;
  insert into public.draft_owner_map (draft_id, user_id) values (d.id, auth.uid()) on conflict (draft_id) do update set user_id = excluded.user_id;
  update public.application_drafts set status = 'claimed', claimed_by = auth.uid(), claimed_at = now(), token = null, updated_at = now() where id = d.id;
  return v_app;
end $$;

revoke all on function public.draft_save(uuid, jsonb), public.draft_attach_photo(uuid, text, text), public.draft_remove_photo(uuid),
  public.draft_issue_link(uuid), public.admin_publish_draft(uuid, text, text, text), public.draft_cancel(uuid), public.claim_preview(text),
  public.claim_draft(text, double precision, double precision, text, text, text, text, boolean, boolean, boolean), public.open_thread(uuid) from public, anon;
grant execute on function public.draft_save(uuid, jsonb), public.draft_attach_photo(uuid, text, text), public.draft_remove_photo(uuid),
  public.draft_issue_link(uuid), public.admin_publish_draft(uuid, text, text, text), public.draft_cancel(uuid), public.claim_preview(text),
  public.claim_draft(text, double precision, double precision, text, text, text, text, boolean, boolean, boolean), public.open_thread(uuid) to authenticated;
-- =============================================================================
