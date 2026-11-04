-- =============================================================================
-- migration_077.sql — run ONCE after migration_076.sql
-- Agency pictures, refined:
--   * ANY approved agency (paid or not) may add mosaic spots on top of the PUBLIC picture of its own girls, free and at once (no admin): it can only hide more.
--     Every such edit is logged with the old picture; the admin sees "สังกัดแก้โมเสกเอง" and can put the old picture back.
--   * add / delete pictures, and re-placing the mosaic from the private original, stay for PAID agencies and wait for an admin (migration_076)
--     — the first request per girl is free, later ones cost profile_edit_fee (20 THB) from the agency Wallet (refunded if it is rejected / cancelled)
--     — the free one is shared with the girl's own requests; mosaics placed on the public picture are not counted
-- =============================================================================

-- ---------- checks -------------------------------------------------------------------------------------------------------------------------
create or replace function public.agency_check_girl_basic(p_worker uuid)
returns void language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'FORBIDDEN'; end if;
  if not exists (select 1 from public.agencies a where a.user_id = auth.uid() and a.status = 'approved') then raise exception 'NOT_APPROVED'; end if;
  if not exists (select 1 from public.workers w where w.user_id = p_worker and w.agency_id = auth.uid() and w.user_id <> auth.uid() and w.deleted_at is null) then raise exception 'NOT_FOUND'; end if;
  if public.is_suspended(p_worker) then raise exception 'SUSPENDED'; end if;
end $$;
revoke all on function public.agency_check_girl_basic(uuid) from public, anon, authenticated;

-- an unpaid agency sees the public pictures of its girls (the private originals only when it is paid)
create or replace function public.agency_girl_photos(p_worker uuid)
returns table (id uuid, state text, sort_no smallint, public_url text, original_path text, request_id uuid, replaces uuid)
language plpgsql stable security definer set search_path = public as $$
declare v_paid boolean := public.agency_active(auth.uid());
begin
  perform public.agency_check_girl_basic(p_worker);
  return query
    select p.id, p.state, p.sort_no, p.public_url, case when v_paid then p.original_path end, p.request_id, p.replaces
      from public.profile_photos p
     where p.user_id = p_worker and p.state in ('live', 'agency_add')
     order by p.state, p.sort_no, p.created_at;
end $$;

-- ---------- storage: the PUBLIC bucket is open to any approved agency for its own girls (the originals stay paid-only) -------------------
drop policy if exists "worker-public_agency_insert" on storage.objects;
create policy "worker-public_agency_insert" on storage.objects for insert to authenticated
  with check (bucket_id = 'worker-public'
    and exists (select 1 from public.agencies a where a.user_id = auth.uid() and a.status = 'approved')
    and exists (select 1 from public.workers w where w.user_id::text = (storage.foldername(name))[1] and w.agency_id = auth.uid()));
drop policy if exists "worker-public_agency_delete" on storage.objects;
create policy "worker-public_agency_delete" on storage.objects for delete to authenticated
  using (bucket_id = 'worker-public'
    and exists (select 1 from public.agencies a where a.user_id = auth.uid() and a.status = 'approved')
    and exists (select 1 from public.workers w where w.user_id::text = (storage.foldername(name))[1] and w.agency_id = auth.uid()));

-- ---------- direct mosaic on the public picture ------------------------------------------------------------------------------------------
create table if not exists public.agency_mosaic_edits (
  id          uuid primary key default gen_random_uuid(),
  photo_id    uuid not null,
  worker_id   uuid not null,
  agency_id   uuid not null,
  old_url     text not null,
  new_url     text not null,
  at          timestamptz not null default now(),
  reverted_at timestamptz, reverted_by uuid
);
create index if not exists agency_mosaic_edits_photo on public.agency_mosaic_edits (photo_id, at desc);
alter table public.agency_mosaic_edits enable row level security;
revoke all on public.agency_mosaic_edits from anon, authenticated;

create or replace function public.agency_mosaic_direct(p_photo uuid, p_public_url text)
returns uuid language plpgsql security definer set search_path = public as $$
declare pp public.profile_photos; v_id uuid;
begin
  select * into pp from public.profile_photos where id = p_photo and state = 'live' for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  perform public.agency_check_girl_basic(pp.user_id);
  if p_public_url is null or position('/storage/v1/object/public/worker-public/' || pp.user_id::text || '/' in p_public_url) = 0 or p_public_url = pp.public_url then raise exception 'BAD_INPUT'; end if;
  if (select count(*) from public.agency_mosaic_edits e where e.worker_id = pp.user_id and e.at > now() - interval '1 day') >= 30 then raise exception 'TOO_MANY'; end if;
  insert into public.agency_mosaic_edits (photo_id, worker_id, agency_id, old_url, new_url) values (pp.id, pp.user_id, auth.uid(), pp.public_url, p_public_url) returning id into v_id;
  update public.profile_photos set public_url = p_public_url where id = pp.id;
  update public.workers set profile_image = p_public_url where user_id = pp.user_id and profile_image = pp.public_url;
  return v_id;
end $$;

-- the admin puts the picture back (only the latest edit of a picture can be undone)
create or replace function public.admin_mosaic_revert(p_edit uuid)
returns void language plpgsql security definer set search_path = public as $$
declare e public.agency_mosaic_edits; pp public.profile_photos;
begin
  perform public.assert_admin();
  select * into e from public.agency_mosaic_edits where id = p_edit and reverted_at is null for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  select * into pp from public.profile_photos where id = e.photo_id for update;
  if not found or pp.public_url <> e.new_url then raise exception 'NOT_LATEST'; end if;
  update public.profile_photos set public_url = e.old_url where id = pp.id;
  update public.workers set profile_image = e.old_url where user_id = pp.user_id and profile_image = e.new_url;
  update public.agency_mosaic_edits set reverted_at = now(), reverted_by = auth.uid() where id = e.id;
end $$;

-- the admin list now shows the latest agency edit of each picture
drop function if exists public.admin_teaser_list(text, boolean, int, int);
create function public.admin_teaser_list(p_q text default null, p_flagged boolean default false, p_limit int default 30, p_offset int default 0)
returns table (worker_id uuid, display_name text, agency_name text, photo_id uuid, sort_no int, public_url text, original_path text,
               is_cover boolean, flag_note text, flagged_at timestamptz, rn int, agency_edit_id uuid, agency_edit_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.assert_admin();
  return query
  with ws as (
    select w.user_id, w.display_name, w.agency_id, w.profile_image, f.note, f.created_at as fat,
           (row_number() over (order by (f.id is not null) desc, w.created_at desc, w.user_id))::int as rn
      from public.workers w
      left join public.teaser_flags f on f.worker_id = w.user_id and f.resolved_at is null
     where w.deleted_at is null
       and (p_q is null or btrim(p_q) = '' or w.display_name ilike '%' || btrim(p_q) || '%')
       and (not coalesce(p_flagged, false) or f.id is not null)
     order by 6
     limit least(greatest(coalesce(p_limit, 30), 1), 100) offset greatest(coalesce(p_offset, 0), 0)
  )
  select ws.user_id, ws.display_name, a.name, pp.id, pp.sort_no::int, pp.public_url, pp.original_path,
         (pp.public_url = ws.profile_image), ws.note, ws.fat, ws.rn, ae.id, ae.at
    from ws
    join public.profile_photos pp on pp.user_id = ws.user_id and pp.state = 'live'
    left join public.agencies a on a.user_id = ws.agency_id
    left join lateral (select e.id, e.at from public.agency_mosaic_edits e where e.photo_id = pp.id and e.reverted_at is null order by e.at desc limit 1) ae on true
   order by ws.rn, pp.sort_no;
end $$;

-- ---------- the fee of an edit request ---------------------------------------------------------------------------------------------------
create or replace function public.agency_photo_fee(p_worker uuid)
returns table (fee numeric, wallet numeric, is_free boolean)
language plpgsql stable security definer set search_path = public as $$
declare v_used int;
begin
  perform public.agency_check_girl_basic(p_worker);
  select count(*) into v_used from public.profile_edit_requests where user_id = p_worker and status in ('approved', 'pending');
  return query select case when v_used >= 1 then public.profile_edit_fee() else 0::numeric end, (select u.wallet_balance from public.users u where u.id = auth.uid()), v_used < 1;
end $$;

-- a rejected / cancelled request gives the fee back to whoever paid it (the agency for its own requests)
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
    update public.users set wallet_balance = wallet_balance + r.fee where id = coalesce(r.requested_by, r.user_id);
  end if;
end $$;
revoke all on function public.close_profile_edit(uuid, text, text) from public, anon, authenticated;

-- add / delete / re-place from the original: paid agencies only, free once per girl, then the fee
create or replace function public.agency_submit_photo_edit(p_worker uuid, p_remove uuid[] default '{}')
returns uuid language plpgsql security definer set search_path = public as $$
declare v_id uuid; v_rm uuid[]; v_live int; v_rm_n int; v_staged int; v_used int; v_fee numeric := 0; v_bal numeric;
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
  select count(*) into v_used from public.profile_edit_requests where user_id = p_worker and status in ('approved', 'pending');
  if v_used >= 1 then
    v_fee := public.profile_edit_fee();
    select wallet_balance into v_bal from public.users where id = auth.uid() for update;
    if v_bal < v_fee then raise exception 'INSUFFICIENT_BALANCE'; end if;
  end if;
  insert into public.profile_edit_requests (user_id, requested_by, changes, remove_photos, fee) values (p_worker, auth.uid(), '{}'::jsonb, v_rm, v_fee) returning id into v_id;
  if v_fee > 0 then
    perform set_config('app.ledger_kind', 'profile_edit_fee', true);
    perform set_config('app.ledger_ref', v_id::text, true);
    update public.users set wallet_balance = wallet_balance - v_fee where id = auth.uid();
  end if;
  update public.profile_photos set request_id = v_id where user_id = p_worker and state = 'agency_add' and request_id is null;
  return v_id;
end $$;

revoke all on function public.agency_girl_photos(uuid), public.agency_mosaic_direct(uuid, text), public.admin_mosaic_revert(uuid),
  public.admin_teaser_list(text, boolean, int, int), public.agency_photo_fee(uuid), public.agency_submit_photo_edit(uuid, uuid[]) from public, anon;
grant execute on function public.agency_girl_photos(uuid), public.agency_mosaic_direct(uuid, text), public.admin_mosaic_revert(uuid),
  public.admin_teaser_list(text, boolean, int, int), public.agency_photo_fee(uuid), public.agency_submit_photo_edit(uuid, uuid[]) to authenticated;
