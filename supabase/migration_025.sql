-- =============================================================================
-- migration_025.sql — run ONCE after migration_024.sql
-- Controlled provider profiles.
--  * Applying needs 1-5 photos attached to the application (profile_photos).
--  * Age: the admin must record HOW the age was checked before approving (photo / video call / in person / ID card).
--    If unsure the admin asks the applicant for an ID + selfie (private bucket id-docs), checks it and can delete it.
--  * After approval a provider can no longer change her profile directly (only is_online). Every change — details,
--    prices, location, photos (max 5) — is an EDIT REQUEST the admin approves; the live profile stays as it is until then.
--    The first approved edit is free, each later request costs 20 THB from the Wallet (refunded if rejected/cancelled).
--  * "Remove me": the profile is hidden at once and removed by the admin, or automatically after 24 hours.
-- =============================================================================

create or replace function public.profile_edit_fee()      returns numeric language sql immutable as $$ select 20::numeric $$;
create or replace function public.profile_max_photos()    returns int     language sql immutable as $$ select 5 $$;
create or replace function public.deletion_wait_hours()   returns int     language sql immutable as $$ select 24 $$;

-- ---------- tell a user something in her admin chat ---------------------------------------------------------------
create or replace function public.support_notify(p_user uuid, p_body text)
returns void language plpgsql security definer set search_path = public as $$
declare v_thread uuid;
begin
  insert into public.support_threads (user_id) values (p_user) on conflict (user_id) do nothing;
  select id into v_thread from public.support_threads where user_id = p_user;
  insert into public.support_messages (thread_id, sender_id, from_admin, kind, body)
  values (v_thread, coalesce(auth.uid(), p_user), true, 'system', left(p_body, 900));
  update public.support_threads set last_message_at = now(), admin_last_read = now() where id = v_thread;
end $$;
revoke all on function public.support_notify(uuid, text) from public, anon, authenticated;

-- ---------- Photos ---------------------------------------------------------------------------------------------------
alter table public.workers add column if not exists delete_requested_at timestamptz;
alter table public.workers add column if not exists deleted_at timestamptz;

create table if not exists public.profile_photos (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references public.users (id) on delete cascade,
  state         text not null check (state in ('application', 'live', 'pending_add')),
  request_id    uuid,
  sort_no      smallint not null default 1,
  public_url    text not null,             -- the mosaicked picture everybody may see
  original_path text not null,             -- private bucket worker-originals
  created_at    timestamptz not null default now()
);
create index if not exists profile_photos_user_idx on public.profile_photos (user_id, state, sort_no);
alter table public.profile_photos enable row level security;
revoke all on public.profile_photos from anon, authenticated;
grant select on public.profile_photos to authenticated;
drop policy if exists profile_photos_own on public.profile_photos;
create policy profile_photos_own on public.profile_photos for select to authenticated using (user_id = auth.uid());

-- providers that already have a single photo keep it as photo no. 1
insert into public.profile_photos (user_id, state, sort_no, public_url, original_path)
select w.user_id, 'live', 1, w.profile_image, w.original_path from public.workers w
 where w.profile_image is not null and w.original_path is not null
   and not exists (select 1 from public.profile_photos p where p.user_id = w.user_id and p.state = 'live');

-- Attach an already uploaded picture (the files are in worker-public / worker-originals under <user id>/).
create or replace function public.attach_photo(p_state text, p_public_url text, p_original_path text)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_id uuid; v_n int;
begin
  if auth.uid() is null then raise exception 'FORBIDDEN'; end if;
  if p_original_path is null or p_original_path not like auth.uid()::text || '/%' or p_public_url is null then raise exception 'BAD_INPUT'; end if;
  if p_state = 'application' then
    if not exists (select 1 from public.worker_applications where user_id = auth.uid() and status = 'pending') then raise exception 'NO_APPLICATION'; end if;
    select count(*) into v_n from public.profile_photos where user_id = auth.uid() and state = 'application';
  elsif p_state = 'pending_add' then
    if not exists (select 1 from public.workers where user_id = auth.uid() and deleted_at is null) then raise exception 'NOT_A_WORKER'; end if;
    if exists (select 1 from public.profile_edit_requests where user_id = auth.uid() and status = 'pending') then raise exception 'REQUEST_PENDING'; end if;
    -- additions are capped on their own; the final "live - removed + added <= 5" check happens when the request is submitted
    select count(*) into v_n from public.profile_photos where user_id = auth.uid() and state = 'pending_add';
  else
    raise exception 'BAD_INPUT';
  end if;
  if v_n >= public.profile_max_photos() then raise exception 'TOO_MANY_PHOTOS'; end if;
  insert into public.profile_photos (user_id, state, sort_no, public_url, original_path)
  values (auth.uid(), p_state, v_n + 1, p_public_url, p_original_path) returning id into v_id;
  return v_id;
end $$;

-- An applicant (or a provider with a not yet submitted addition) removes a picture she attached.
create or replace function public.delete_staged_photo(p_id uuid)
returns text language plpgsql security definer set search_path = public as $$
declare v_path text;
begin
  delete from public.profile_photos
   where id = p_id and user_id = auth.uid() and state in ('application', 'pending_add') and request_id is null
  returning original_path into v_path;
  if v_path is null then raise exception 'NOT_FOUND'; end if;
  return v_path;
end $$;

-- Photos of a provider for the details page. The private original is only returned to those allowed to see her clearly.
create or replace function public.worker_photos(p_worker uuid)
returns table (id uuid, sort_no smallint, public_url text, original_path text)
language sql stable security definer set search_path = public as $$
  select p.id, p.sort_no, p.public_url,
         case when p.user_id = auth.uid() or public.can_view_worker(p.user_id) then p.original_path end
    from public.profile_photos p
   where p.user_id = p_worker and p.state = 'live' and (public.worker_listed(p_worker) or p_worker = auth.uid())
   order by p.sort_no
$$;

create or replace function public.my_photos()
returns table (id uuid, state text, sort_no smallint, public_url text, original_path text, request_id uuid)
language sql stable security definer set search_path = public as $$
  select p.id, p.state, p.sort_no, p.public_url, p.original_path, p.request_id
    from public.profile_photos p where p.user_id = auth.uid() order by p.state, p.sort_no
$$;

-- ---------- Age check ----------------------------------------------------------------------------------------------------
alter table public.worker_applications
  add column if not exists age_check_status text not null default 'none' check (age_check_status in ('none', 'requested', 'submitted', 'verified')),
  add column if not exists age_verified_method text check (age_verified_method in ('photo', 'video_call', 'in_person', 'id_card')),
  add column if not exists age_verified_by uuid references public.users (id),
  add column if not exists age_verified_at timestamptz,
  add column if not exists age_check_note text,
  add column if not exists age_id_path text,
  add column if not exists age_selfie_path text;

create or replace function public.admin_request_age_proof(p_app uuid, p_note text default null)
returns void language plpgsql security definer set search_path = public as $$
declare a public.worker_applications;
begin
  perform public.assert_admin();
  select * into a from public.worker_applications where id = p_app and status = 'pending' for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  update public.worker_applications set age_check_status = 'requested', age_check_note = left(nullif(btrim(coalesce(p_note, '')), ''), 300)
   where id = p_app and age_check_status <> 'verified';
  perform public.support_notify(a.user_id,
    '🪪 แอดมินขอยืนยันอายุ: กรุณาแนบรูปบัตรประชาชน (ปิดเลขที่ไม่จำเป็นได้ แต่ต้องเห็นวันเกิดและรูปถ่าย) และรูปเซลฟี่ถือบัตร ที่หน้าสมัครงานในแอป'
    || coalesce(' — ' || left(nullif(btrim(coalesce(p_note, '')), ''), 300), ''));
end $$;

create or replace function public.submit_age_proof(p_id_path text, p_selfie_path text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'FORBIDDEN'; end if;
  if p_id_path not like auth.uid()::text || '/%' or p_selfie_path not like auth.uid()::text || '/%' then raise exception 'BAD_INPUT'; end if;
  update public.worker_applications set age_check_status = 'submitted', age_id_path = p_id_path, age_selfie_path = p_selfie_path
   where user_id = auth.uid() and status = 'pending' and age_check_status = 'requested';
  if not found then raise exception 'NOT_REQUESTED'; end if;
end $$;

-- The admin records how the age was verified; approving is impossible without it.
create or replace function public.admin_verify_age(p_app uuid, p_method text, p_note text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public.assert_admin();
  if p_method not in ('photo', 'video_call', 'in_person', 'id_card') then raise exception 'BAD_INPUT'; end if;
  update public.worker_applications
     set age_check_status = 'verified', age_verified_method = p_method, age_verified_by = auth.uid(), age_verified_at = now(),
         age_check_note = left(nullif(btrim(coalesce(p_note, age_check_note, '')), ''), 300),
         age_id_path = null, age_selfie_path = null          -- the documents are not kept in the database either
   where id = p_app and status = 'pending';
  if not found then raise exception 'NOT_FOUND'; end if;
end $$;

-- private bucket for the documents: the applicant writes into her own folder while a request is open; only admins read/delete
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('id-docs', 'id-docs', false, 5242880, array['image/jpeg', 'image/png'])
on conflict (id) do nothing;
drop policy if exists "id-docs_insert" on storage.objects;
create policy "id-docs_insert" on storage.objects for insert to authenticated
  with check (bucket_id = 'id-docs' and (storage.foldername(name))[1] = auth.uid()::text
              and exists (select 1 from public.worker_applications a where a.user_id = auth.uid() and a.status = 'pending' and a.age_check_status = 'requested'));
drop policy if exists "id-docs_admin_select" on storage.objects;
create policy "id-docs_admin_select" on storage.objects for select to authenticated using (bucket_id = 'id-docs' and public.is_admin());
drop policy if exists "id-docs_admin_delete" on storage.objects;
create policy "id-docs_admin_delete" on storage.objects for delete to authenticated using (bucket_id = 'id-docs' and public.is_admin());

-- ---------- Approve: needs photos + a recorded age check; photos go live ---------------------------------------------------
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
                              loc_lat, loc_lng, loc_verified_at)
  values (a.user_id, a.display_name, a.categories, a.price, a.province, a.district, a.nearby,
          a.profile_image, a.original_path, a.recruiter_id,
          case when a.recruiter_id is not null then now() + make_interval(days => public.recruiter_window_days()) end,
          a.agency_id, case when a.agency_id is not null then now() end,
          a.gender, a.age, a.height_cm, a.weight_kg, a.measurements, a.tags, a.about, a.price_options,
          a.loc_lat, a.loc_lng, a.loc_verified_at)
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

-- ---------- Locked profile: only the online switch is a direct edit ------------------------------------------------------------
revoke update on public.workers from authenticated;
grant update (is_online) on public.workers to authenticated;

create table if not exists public.profile_edit_requests (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references public.users (id) on delete cascade,
  status        text not null default 'pending' check (status in ('pending', 'approved', 'rejected', 'cancelled')),
  changes       jsonb not null default '{}',
  remove_photos uuid[] not null default '{}',
  fee           numeric(12,2) not null default 0,
  reject_reason text,
  created_at    timestamptz not null default now(),
  reviewed_by   uuid references public.users (id),
  reviewed_at   timestamptz
);
create unique index if not exists profile_edit_one_pending on public.profile_edit_requests (user_id) where status = 'pending';
alter table public.profile_edit_requests enable row level security;
revoke all on public.profile_edit_requests from anon, authenticated;
grant select on public.profile_edit_requests to authenticated;
drop policy if exists profile_edit_own on public.profile_edit_requests;
create policy profile_edit_own on public.profile_edit_requests for select to authenticated using (user_id = auth.uid());

-- Which keys a request may change, and basic sanity (the normalising trigger of migration_022/023 cleans the rest).
create or replace function public.check_profile_changes(p_changes jsonb)
returns void language plpgsql immutable as $$
declare k text;
begin
  if jsonb_typeof(p_changes) <> 'object' then raise exception 'BAD_INPUT'; end if;
  for k in select jsonb_object_keys(p_changes) loop
    if k <> all (array['display_name','categories','gender','age','height_cm','weight_kg','measurements','tags','about',
                       'price','price_options','district','nearby','province','loc_lat','loc_lng']) then
      raise exception 'BAD_INPUT';
    end if;
  end loop;
  if p_changes ? 'age' and ((p_changes->>'age') is null or (p_changes->>'age')::int not between 20 and 70) then raise exception 'BAD_AGE'; end if;
  if p_changes ? 'gender' and (p_changes->>'gender') not in ('female', 'male', 'lgbt') then raise exception 'BAD_INPUT'; end if;
  if p_changes ? 'price' and ((p_changes->>'price') is null or (p_changes->>'price')::numeric < 0) then raise exception 'BAD_PRICE'; end if;
  if p_changes ? 'display_name' and char_length(btrim(p_changes->>'display_name')) not between 1 and 40 then raise exception 'BAD_INPUT'; end if;
  if p_changes ? 'categories' and (jsonb_typeof(p_changes->'categories') <> 'array' or jsonb_array_length(p_changes->'categories') = 0) then raise exception 'BAD_INPUT'; end if;
end $$;

create or replace function public.submit_profile_edit(p_changes jsonb, p_remove uuid[] default '{}')
returns uuid language plpgsql security definer set search_path = public as $$
declare
  w public.workers; v_id uuid; v_fee numeric := 0; v_bal numeric; v_used int; v_adds int; v_live int; v_rm int;
begin
  if auth.uid() is null then raise exception 'FORBIDDEN'; end if;
  if public.is_suspended(auth.uid()) then raise exception 'SUSPENDED'; end if;
  select * into w from public.workers where user_id = auth.uid() and deleted_at is null and delete_requested_at is null for update;
  if not found then raise exception 'NOT_A_WORKER'; end if;
  if exists (select 1 from public.profile_edit_requests where user_id = auth.uid() and status = 'pending') then raise exception 'REQUEST_PENDING'; end if;
  perform public.check_profile_changes(coalesce(p_changes, '{}'::jsonb));
  select count(*) into v_adds from public.profile_photos where user_id = auth.uid() and state = 'pending_add' and request_id is null;
  select count(*) into v_rm from public.profile_photos where user_id = auth.uid() and state = 'live' and id = any (coalesce(p_remove, '{}'));
  select count(*) into v_live from public.profile_photos where user_id = auth.uid() and state = 'live';
  if coalesce(p_changes, '{}'::jsonb) = '{}'::jsonb and v_adds = 0 and v_rm = 0 then raise exception 'NOTHING_TO_CHANGE'; end if;
  if v_live - v_rm + v_adds > public.profile_max_photos() then raise exception 'TOO_MANY_PHOTOS'; end if;
  if v_live - v_rm + v_adds < 1 then raise exception 'NO_PHOTO'; end if;

  -- the first approved request is free; later ones cost money up front (returned if it is not approved)
  select count(*) into v_used from public.profile_edit_requests where user_id = auth.uid() and status in ('approved', 'pending');
  if v_used >= 1 then
    v_fee := public.profile_edit_fee();
    select wallet_balance into v_bal from public.users where id = auth.uid() for update;
    if v_bal < v_fee then raise exception 'INSUFFICIENT_BALANCE'; end if;
  end if;
  insert into public.profile_edit_requests (user_id, changes, remove_photos, fee)
  values (auth.uid(), coalesce(p_changes, '{}'::jsonb), coalesce(p_remove, '{}'), v_fee) returning id into v_id;
  if v_fee > 0 then
    perform set_config('app.ledger_kind', 'profile_edit_fee', true);
    perform set_config('app.ledger_ref', v_id::text, true);
    update public.users set wallet_balance = wallet_balance - v_fee where id = auth.uid();
  end if;
  update public.profile_photos set request_id = v_id where user_id = auth.uid() and state = 'pending_add' and request_id is null;
  return v_id;
end $$;

-- give back the fee and drop the staged pictures of a request that did not go through
create or replace function public.close_profile_edit(p_id uuid, p_status text, p_reason text)
returns void language plpgsql security definer set search_path = public as $$
declare r public.profile_edit_requests;
begin
  select * into r from public.profile_edit_requests where id = p_id and status = 'pending' for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  update public.profile_edit_requests set status = p_status, reject_reason = p_reason, reviewed_by = auth.uid(), reviewed_at = now() where id = p_id;
  delete from public.profile_photos where request_id = p_id and state = 'pending_add';
  if r.fee > 0 then
    perform set_config('app.ledger_kind', 'profile_edit_refund', true);
    perform set_config('app.ledger_ref', p_id::text, true);
    update public.users set wallet_balance = wallet_balance + r.fee where id = r.user_id;
  end if;
end $$;
revoke all on function public.close_profile_edit(uuid, text, text) from public, anon, authenticated;

create or replace function public.cancel_profile_edit()
returns void language plpgsql security definer set search_path = public as $$
declare v uuid;
begin
  select id into v from public.profile_edit_requests where user_id = auth.uid() and status = 'pending';
  if v is null then raise exception 'NOT_FOUND'; end if;
  perform public.close_profile_edit(v, 'cancelled', null);
end $$;

create or replace function public.my_edit_status()
returns table (pending_id uuid, pending_since timestamptz, free_left int, fee numeric, delete_requested_at timestamptz, delete_at timestamptz)
language sql stable security definer set search_path = public as $$
  select (select id from public.profile_edit_requests where user_id = auth.uid() and status = 'pending'),
         (select created_at from public.profile_edit_requests where user_id = auth.uid() and status = 'pending'),
         greatest(0, 1 - (select count(*)::int from public.profile_edit_requests where user_id = auth.uid() and status in ('approved', 'pending'))),
         public.profile_edit_fee(),
         w.delete_requested_at,
         w.delete_requested_at + make_interval(hours => public.deletion_wait_hours())
    from public.workers w where w.user_id = auth.uid()
$$;

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
                              'about', w.about, 'price', w.price, 'price_options', w.price_options, 'district', w.district,
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

-- ---------- Removing a profile -----------------------------------------------------------------------------------------------------
create or replace function public.worker_listed(p_worker uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select not public.is_suspended(p_worker)
     and coalesce((select w.deleted_at is null and w.delete_requested_at is null and (w.agency_id is null or public.agency_active(w.agency_id))
                     from public.workers w where w.user_id = p_worker), false)
$$;

create or replace function public.request_profile_deletion()
returns timestamptz language plpgsql security definer set search_path = public as $$
declare w public.workers;
begin
  select * into w from public.workers where user_id = auth.uid() and deleted_at is null for update;
  if not found then raise exception 'NOT_A_WORKER'; end if;
  if exists (select 1 from public.jobs j where j.worker_id = auth.uid() and j.status in ('pending', 'matched')) then raise exception 'HAS_ACTIVE_JOBS'; end if;
  update public.workers set delete_requested_at = coalesce(delete_requested_at, now()), is_online = false where user_id = auth.uid();
  update public.profile_edit_requests set status = 'cancelled', reviewed_at = now() where user_id = auth.uid() and status = 'pending';
  return coalesce(w.delete_requested_at, now()) + make_interval(hours => public.deletion_wait_hours());
end $$;

create or replace function public.cancel_profile_deletion()
returns void language plpgsql security definer set search_path = public as $$
begin
  update public.workers set delete_requested_at = null where user_id = auth.uid() and deleted_at is null and delete_requested_at is not null;
  if not found then raise exception 'NOT_FOUND'; end if;
end $$;

create or replace function public.finish_profile_deletion(p_user uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  update public.workers set deleted_at = now(), is_online = false, agency_id = null, agency_since = null,
         profile_image = null, original_path = null, about = null, tags = '{}', price_options = '[]'::jsonb,
         loc_lat = null, loc_lng = null, loc_verified_at = null
   where user_id = p_user and deleted_at is null;
  delete from public.profile_photos where user_id = p_user;
  update public.profile_edit_requests set status = 'cancelled', reviewed_at = now() where user_id = p_user and status = 'pending';
  update public.users set role = 'customer' where id = p_user and role = 'worker';
  perform public.support_notify(p_user, '🗑️ โปรไฟล์ผู้ให้บริการของคุณถูกลบออกจากระบบแล้ว สมัครใหม่ได้ทุกเมื่อ');
end $$;
revoke all on function public.finish_profile_deletion(uuid) from public, anon, authenticated;

-- runs every hour (pg_cron) and also when an admin opens the list: removes requests older than 24 h
create or replace function public.process_profile_deletions()
returns int language plpgsql security definer set search_path = public as $$
declare w record; n int := 0;
begin
  for w in select user_id from public.workers
            where deleted_at is null and delete_requested_at <= now() - make_interval(hours => public.deletion_wait_hours()) loop
    perform public.finish_profile_deletion(w.user_id);
    n := n + 1;
  end loop;
  return n;
end $$;
revoke all on function public.process_profile_deletions() from public, anon, authenticated;

create or replace function public.admin_list_deletions()
returns table (user_id uuid, user_name text, display_name text, requested_at timestamptz, delete_at timestamptz)
language plpgsql security definer set search_path = public as $$
begin
  perform public.assert_admin();
  perform public.process_profile_deletions();
  return query
    select w.user_id, u.display_name, w.display_name, w.delete_requested_at, w.delete_requested_at + make_interval(hours => public.deletion_wait_hours())
      from public.workers w join public.users u on u.id = w.user_id
     where w.deleted_at is null and w.delete_requested_at is not null order by w.delete_requested_at;
end $$;

create or replace function public.admin_review_deletion(p_user uuid, p_approve boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public.assert_admin();
  if p_approve then
    perform public.finish_profile_deletion(p_user);
  else
    update public.workers set delete_requested_at = null where user_id = p_user and deleted_at is null and delete_requested_at is not null;
    if not found then raise exception 'NOT_FOUND'; end if;
    perform public.support_notify(p_user, 'ℹ️ แอดมินไม่ลบโปรไฟล์ตามคำขอ โปรไฟล์ของคุณกลับมาแสดงตามปกติ ติดต่อแอดมินได้ถ้ามีข้อสงสัย');
  end if;
end $$;

-- ---------- Admin: applications with photos and the age check -----------------------------------------------------------------------
drop function if exists public.admin_list_applications(text);
create function public.admin_list_applications(p_status text default 'pending')
returns table (id uuid, user_id uuid, user_name text, display_name text, categories text[], price numeric,
               province text, district text, nearby text, phone text, line_id text, note text,
               profile_image text, original_path text, status text, reject_reason text, created_at timestamptz,
               agency_name text, agency_status text,
               gender text, age int, height_cm int, weight_kg int, measurements text, tags text[], about text,
               price_options jsonb, loc_verified boolean,
               age_check_status text, age_verified_method text, age_check_note text, age_id_path text, age_selfie_path text, photos jsonb)
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
                       from public.profile_photos p where p.user_id = a.user_id and p.state = 'application'), '[]'::jsonb)
      from public.worker_applications a join public.users u on u.id = a.user_id
      left join public.agencies ag on ag.user_id = a.agency_id
     where p_status is null or a.status = p_status
     order by a.created_at desc
     limit 100;
end $$;

revoke all on function public.attach_photo(text, text, text), public.delete_staged_photo(uuid), public.worker_photos(uuid),
  public.my_photos(), public.admin_request_age_proof(uuid, text), public.submit_age_proof(text, text), public.admin_verify_age(uuid, text, text),
  public.check_profile_changes(jsonb), public.submit_profile_edit(jsonb, uuid[]), public.cancel_profile_edit(), public.my_edit_status(),
  public.admin_list_profile_edits(text), public.admin_review_profile_edit(uuid, boolean, text),
  public.request_profile_deletion(), public.cancel_profile_deletion(), public.admin_list_deletions(), public.admin_review_deletion(uuid, boolean),
  public.admin_list_applications(text) from public, anon;
grant execute on function public.attach_photo(text, text, text), public.delete_staged_photo(uuid), public.worker_photos(uuid),
  public.my_photos(), public.admin_request_age_proof(uuid, text), public.submit_age_proof(text, text), public.admin_verify_age(uuid, text, text),
  public.submit_profile_edit(jsonb, uuid[]), public.cancel_profile_edit(), public.my_edit_status(),
  public.admin_list_profile_edits(text), public.admin_review_profile_edit(uuid, boolean, text),
  public.request_profile_deletion(), public.cancel_profile_deletion(), public.admin_list_deletions(), public.admin_review_deletion(uuid, boolean),
  public.admin_list_applications(text) to authenticated;

do $$ begin
  create extension if not exists pg_cron;
  perform cron.schedule('process-profile-deletions', '5 * * * *', 'select public.process_profile_deletions()');
exception when others then
  raise notice 'pg_cron is not enabled (%): deletions are processed whenever an admin opens the list', sqlerrm;
end $$;
-- =============================================================================
