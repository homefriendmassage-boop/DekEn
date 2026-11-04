-- =============================================================================
-- migration_076.sql — run ONCE after migration_075.sql
-- A PAID agency edits the pictures of its girls — add, delete, place the mosaic again — and sends them as a request that an admin approves
-- first, exactly like a girl's own edit request (same admin tab "แก้ไข/ลบโปรไฟล์", same approval; free of charge for the agency).
--   * staged pictures are rows of profile_photos with state 'agency_add'; a changed mosaic = a new public picture made from the same private original,
--     marked 'replaces' the old one (the old one is removed when the request is approved)
--   * one pending request per girl (shared with her own requests), only a paid agency, only its own girls
--   * the girl is told as usual; the agency gets a Flex when its request is approved / rejected
-- =============================================================================
alter table public.profile_edit_requests add column if not exists requested_by uuid;
alter table public.profile_photos add column if not exists replaces uuid;
alter table public.profile_photos drop constraint if exists profile_photos_state_check;
alter table public.profile_photos add constraint profile_photos_state_check check (state in ('application', 'live', 'pending_add', 'agency_add'));

-- her own list never shows what her agency staged
create or replace function public.my_photos()
returns table (id uuid, state text, sort_no smallint, public_url text, original_path text, request_id uuid)
language sql stable security definer set search_path = public as $$
  select p.id, p.state, p.sort_no, p.public_url, p.original_path, p.request_id
    from public.profile_photos p where p.user_id = auth.uid() and p.state <> 'agency_add' order by p.state, p.sort_no
$$;

create or replace function public.close_profile_edit(p_id uuid, p_status text, p_reason text)
returns void language plpgsql security definer set search_path = public as $$
declare r public.profile_edit_requests;
begin
  select * into r from public.profile_edit_requests where id = p_id and status = 'pending' for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  update public.profile_edit_requests set status = p_status, reject_reason = p_reason, reviewed_by = auth.uid(), reviewed_at = now() where id = p_id;
  delete from public.profile_photos where request_id = p_id and state in ('pending_add', 'agency_add');
  if r.fee > 0 then
    perform set_config('app.ledger_kind', 'profile_edit_refund', true);
    perform set_config('app.ledger_ref', p_id::text, true);
    update public.users set wallet_balance = wallet_balance + r.fee where id = r.user_id;
  end if;
end $$;
revoke all on function public.close_profile_edit(uuid, text, text) from public, anon, authenticated;

-- she cannot cancel a request her agency sent
create or replace function public.cancel_profile_edit()
returns void language plpgsql security definer set search_path = public as $$
declare v uuid;
begin
  select id into v from public.profile_edit_requests where user_id = auth.uid() and status = 'pending' and requested_by is null;
  if v is null then raise exception 'NOT_FOUND'; end if;
  perform public.close_profile_edit(v, 'cancelled', null);
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
  -- a re-mosaic takes the place of the picture it replaces (the card photo stays the card photo)
  update public.profile_photos n set sort_no = o.sort_no from public.profile_photos o where n.request_id = p_id and n.state = 'agency_add' and n.replaces = o.id;
  update public.profile_photos set sort_no = sort_no + 100 where request_id = p_id and state = 'agency_add' and replaces is null;     -- plain additions go to the end
  delete from public.profile_photos where state = 'live' and id = any (r.remove_photos) and user_id = r.user_id;
  update public.profile_photos set state = 'live', request_id = null, replaces = null where request_id = p_id and state in ('pending_add', 'agency_add');
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

drop function if exists public.admin_list_profile_edits(text);
create function public.admin_list_profile_edits(p_status text default 'pending')
returns table (id uuid, user_id uuid, user_name text, status text, created_at timestamptz, fee numeric, changes jsonb, current jsonb,
               add_photos jsonb, remove_photos jsonb, reject_reason text, by_agency text)
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
                       from public.profile_photos p where p.request_id = r.id and p.state in ('pending_add', 'agency_add')), '[]'::jsonb),
           coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'public_url', p.public_url) order by p.sort_no)
                       from public.profile_photos p where p.id = any (r.remove_photos)), '[]'::jsonb),
           r.reject_reason,
           (select a.name from public.agencies a where a.user_id = r.requested_by)
      from public.profile_edit_requests r
      join public.users u on u.id = r.user_id
      left join public.workers w on w.user_id = r.user_id
     where p_status is null or r.status = p_status
     order by r.created_at desc limit 100;
end $$;

-- the agency hears the result
create or replace function public.trg_edit_agency_notify() returns trigger language plpgsql security definer set search_path = public as $$
declare v_name text;
begin
  if new.requested_by is null or new.status is not distinct from old.status or new.status not in ('approved', 'rejected') then return new; end if;
  select w.display_name into v_name from public.workers w where w.user_id = new.user_id;
  perform public.approval_notify('agency_photo', new.requested_by, new.status, left(concat_ws(': ', v_name, new.reject_reason), 120));
  return new;
end $$;
drop trigger if exists profile_edit_requests_agency_notify on public.profile_edit_requests;
create trigger profile_edit_requests_agency_notify after update of status on public.profile_edit_requests for each row execute function public.trg_edit_agency_notify();

-- ---------- the agency ---------------------------------------------------------------------------------------------------------------------
create or replace function public.agency_check_girl(p_worker uuid)
returns void language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'FORBIDDEN'; end if;
  if not exists (select 1 from public.workers w where w.user_id = p_worker and w.agency_id = auth.uid() and w.user_id <> auth.uid() and w.deleted_at is null) then raise exception 'NOT_FOUND'; end if;
  if not public.agency_active(auth.uid()) then raise exception 'PLAN_INACTIVE'; end if;
  if public.is_suspended(p_worker) then raise exception 'SUSPENDED'; end if;
end $$;
revoke all on function public.agency_check_girl(uuid) from public, anon, authenticated;

create or replace function public.agency_girl_photos(p_worker uuid)
returns table (id uuid, state text, sort_no smallint, public_url text, original_path text, request_id uuid, replaces uuid)
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.agency_check_girl(p_worker);
  return query
    select p.id, p.state, p.sort_no, p.public_url, p.original_path, p.request_id, p.replaces
      from public.profile_photos p
     where p.user_id = p_worker and (p.state = 'live' or (p.state = 'agency_add'))
     order by p.state, p.sort_no, p.created_at;
end $$;

-- stage one picture: p_replaces = the live picture it replaces (a new mosaic of the same original)
create or replace function public.agency_stage_photo(p_worker uuid, p_public_url text, p_original_path text, p_replaces uuid default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_live int; v_adds int; v_id uuid; v_n int;
begin
  perform public.agency_check_girl(p_worker);
  if exists (select 1 from public.profile_edit_requests where user_id = p_worker and status = 'pending') then raise exception 'REQUEST_PENDING'; end if;
  if p_public_url is null or position('/storage/v1/object/public/worker-public/' || p_worker::text || '/' in p_public_url) = 0 then raise exception 'BAD_INPUT'; end if;
  if p_original_path is null or p_original_path not like p_worker::text || '/%' then raise exception 'BAD_INPUT'; end if;
  select count(*) into v_live from public.profile_photos where user_id = p_worker and state = 'live';
  select count(*) into v_adds from public.profile_photos where user_id = p_worker and state = 'agency_add' and request_id is null and replaces is null;
  if p_replaces is not null then
    if not exists (select 1 from public.profile_photos where id = p_replaces and user_id = p_worker and state = 'live') then raise exception 'NOT_FOUND'; end if;
    if exists (select 1 from public.profile_photos where replaces = p_replaces and state = 'agency_add' and request_id is null) then raise exception 'ALREADY_STAGED'; end if;
  elsif v_live + v_adds + 1 > public.profile_max_photos() then
    raise exception 'TOO_MANY_PHOTOS';
  end if;
  select count(*) into v_n from public.profile_photos where user_id = p_worker and state = 'agency_add' and request_id is null;
  insert into public.profile_photos (user_id, state, sort_no, public_url, original_path, replaces)
  values (p_worker, 'agency_add', v_n + 1, p_public_url, p_original_path, p_replaces) returning id into v_id;
  return v_id;
end $$;

-- take a staged picture back; returns the private original when nothing else uses it (so the app can delete the file)
create or replace function public.agency_unstage_photo(p_id uuid)
returns text language plpgsql security definer set search_path = public as $$
declare p public.profile_photos;
begin
  select * into p from public.profile_photos where id = p_id and state = 'agency_add' and request_id is null;
  if not found then raise exception 'NOT_FOUND'; end if;
  perform public.agency_check_girl(p.user_id);
  delete from public.profile_photos where id = p_id;
  if exists (select 1 from public.profile_photos x where x.original_path = p.original_path) then return null; end if;
  return p.original_path;
end $$;

-- send the staged pictures + the removals to the admin
create or replace function public.agency_submit_photo_edit(p_worker uuid, p_remove uuid[] default '{}')
returns uuid language plpgsql security definer set search_path = public as $$
declare v_id uuid; v_rm uuid[]; v_live int; v_rm_n int; v_staged int;
begin
  perform public.agency_check_girl(p_worker);
  if exists (select 1 from public.profile_edit_requests where user_id = p_worker and status = 'pending') then raise exception 'REQUEST_PENDING'; end if;
  select coalesce(array_agg(distinct x), '{}') into v_rm from (
    select unnest(coalesce(p_remove, '{}')) as x
    union select replaces from public.profile_photos where user_id = p_worker and state = 'agency_add' and request_id is null and replaces is not null) q
   where x in (select id from public.profile_photos where user_id = p_worker and state = 'live');
  select count(*) into v_live from public.profile_photos where user_id = p_worker and state = 'live';
  v_rm_n := coalesce(array_length(v_rm, 1), 0);
  select count(*) into v_staged from public.profile_photos where user_id = p_worker and state = 'agency_add' and request_id is null;
  if v_rm_n = 0 and v_staged = 0 then raise exception 'NOTHING_TO_CHANGE'; end if;
  if v_live - v_rm_n + v_staged > public.profile_max_photos() then raise exception 'TOO_MANY_PHOTOS'; end if;
  if v_live - v_rm_n + v_staged < 1 then raise exception 'NO_PHOTO'; end if;
  insert into public.profile_edit_requests (user_id, requested_by, changes, remove_photos, fee) values (p_worker, auth.uid(), '{}'::jsonb, v_rm, 0) returning id into v_id;
  update public.profile_photos set request_id = v_id where user_id = p_worker and state = 'agency_add' and request_id is null;
  return v_id;
end $$;

create or replace function public.agency_cancel_photo_edit(p_worker uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v uuid;
begin
  perform public.agency_check_girl(p_worker);
  select id into v from public.profile_edit_requests where user_id = p_worker and status = 'pending' and requested_by = auth.uid();
  if v is null then raise exception 'NOT_FOUND'; end if;
  perform public.close_profile_edit(v, 'cancelled', null);
end $$;

-- status of the agency's requests (pending, the last answers)
create or replace function public.agency_photo_requests()
returns table (worker_id uuid, display_name text, status text, reject_reason text, created_at timestamptz)
language sql stable security definer set search_path = public as $$
  select r.user_id, w.display_name, r.status, r.reject_reason, r.created_at
    from public.profile_edit_requests r join public.workers w on w.user_id = r.user_id
   where r.requested_by = auth.uid() and (r.status = 'pending' or r.created_at > now() - interval '14 days')
   order by r.created_at desc limit 50
$$;

-- the agency may write into the folder of its own girls (new pictures and the new public mosaic files)
do $$
declare b text;
begin
  foreach b in array array['worker-public', 'worker-originals'] loop
    execute format('drop policy if exists "%1$s_agency_insert" on storage.objects', b);
    execute format($p$create policy "%1$s_agency_insert" on storage.objects for insert to authenticated
      with check (bucket_id = %1$L and public.agency_active(auth.uid())
        and exists (select 1 from public.workers w where w.user_id::text = (storage.foldername(name))[1] and w.agency_id = auth.uid()))$p$, b);
    execute format('drop policy if exists "%1$s_agency_delete" on storage.objects', b);
    execute format($p$create policy "%1$s_agency_delete" on storage.objects for delete to authenticated
      using (bucket_id = %1$L and public.agency_active(auth.uid())
        and exists (select 1 from public.workers w where w.user_id::text = (storage.foldername(name))[1] and w.agency_id = auth.uid()))$p$, b);
  end loop;
end $$;

revoke all on function public.my_photos(), public.cancel_profile_edit(), public.agency_girl_photos(uuid), public.agency_stage_photo(uuid, text, text, uuid),
  public.agency_unstage_photo(uuid), public.agency_submit_photo_edit(uuid, uuid[]), public.agency_cancel_photo_edit(uuid), public.agency_photo_requests(),
  public.admin_review_profile_edit(uuid, boolean, text), public.admin_list_profile_edits(text) from public, anon;
grant execute on function public.my_photos(), public.cancel_profile_edit(), public.agency_girl_photos(uuid), public.agency_stage_photo(uuid, text, text, uuid),
  public.agency_unstage_photo(uuid), public.agency_submit_photo_edit(uuid, uuid[]), public.agency_cancel_photo_edit(uuid), public.agency_photo_requests(),
  public.admin_review_profile_edit(uuid, boolean, text), public.admin_list_profile_edits(text) to authenticated;
