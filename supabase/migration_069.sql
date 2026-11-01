-- =============================================================================
-- migration_069.sql — run ONCE after migration_068.sql
-- Modelling-agency SEATS ("D step 1"):
--   * an agency may accept an UNLIMITED number of girls (no AGENCY_FULL / NO_SLOT any more)
--   * 10 FREE seats per agency (the earliest girls first, the agency may re-pick every 30 days) + extra PAID seats (200 THB / girl / 30 days,
--     needs an active plan, lasts at most until the plan date). A girl who came by the agency's own link / draft has agreed already;
--     a girl who registered before, or moves from another agency, must AGREE before the agency may give her a seat (seat_requests).
--   * a girl with a seat: badge + leave lock (agency_leave_days) + the continuing 40 % recruiter slot for the agency
--       - agency PAID                      -> yes
--       - agency NOT paid, promo running   -> yes (setting agency_promo_until, set by the admin)
--       - agency NOT paid, no promo        -> no (only badge + lock)
--   * a girl without a seat ("waiting"): still has the badge, may cancel the agency at any time from day 1;
--     the agency earns the recruiter slot only when SHE came by the agency's own link / draft, for 90 FIXED days
--     counted once per girl-agency pair (never renewed), paid or not
--   * one slot only for an unpaid agency (the sales slot is dropped when the same agency already holds the recruiter slot — rule from 066)
-- =============================================================================

-- ---------- settings ------------------------------------------------------------------------------------------------------------------
insert into public.app_settings (key, value) values ('agency_promo_until', '') on conflict (key) do nothing;

create or replace function public.agency_promo_active()
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select value ~ '^\d{4}-\d{2}-\d{2}$' and now() < ((value::date + 1)::timestamp at time zone 'Asia/Bangkok')
                     from public.app_settings where key = 'agency_promo_until'), false)
$$;
revoke all on function public.agency_promo_active() from public, anon;
grant execute on function public.agency_promo_active() to authenticated;

create or replace function public.admin_set_setting(p_key text, p_value text)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public.assert_admin();
  if p_key not in ('wallet_expiry_enabled', 'wallet_expiry_months', 'bonus_sweep_days', 'agency_leave_days', 'agency_promo_until') then raise exception 'BAD_INPUT'; end if;
  if p_key = 'wallet_expiry_enabled' and p_value not in ('true', 'false') then raise exception 'BAD_INPUT'; end if;
  if p_key = 'agency_promo_until' then
    if p_value <> '' and p_value !~ '^\d{4}-\d{2}-\d{2}$' then raise exception 'BAD_INPUT'; end if;
  elsif p_key <> 'wallet_expiry_enabled' and (p_value !~ '^[0-9]{1,3}$' or p_value::int < 0) then raise exception 'BAD_INPUT'; end if;
  insert into public.app_settings (key, value, updated_at, updated_by) values (p_key, p_value, now(), auth.uid())
  on conflict (key) do update set value = excluded.value, updated_at = now(), updated_by = auth.uid();
end $$;
revoke all on function public.admin_set_setting(text, text) from public, anon;
grant execute on function public.admin_set_setting(text, text) to authenticated;

create or replace function public.admin_agency_settings()
returns table (promo_until text, promo_active boolean, leave_days int)
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.assert_admin();
  return query select coalesce(public.app_setting('agency_promo_until'), ''), public.agency_promo_active(), public.agency_leave_days();
end $$;
revoke all on function public.admin_agency_settings() from public, anon;
grant execute on function public.admin_agency_settings() to authenticated;

create or replace function public.agency_seat_days() returns int language sql immutable as $$ select 30 $$;
create or replace function public.agency_invite_days() returns int language sql immutable as $$ select 90 $$;

-- ---------- tables --------------------------------------------------------------------------------------------------------------------
alter table public.workers add column if not exists agency_via_link boolean not null default false;

-- one row per girl-agency pair: the 90 fixed days of an invited girl are counted once and never renewed
create table if not exists public.agency_invites (
  agency_id uuid not null references public.agencies (user_id) on delete cascade,
  worker_id uuid not null,
  invited_at timestamptz not null default now(),
  primary key (agency_id, worker_id)
);
alter table public.agency_invites enable row level security;

create table if not exists public.agency_seats (
  worker_id  uuid primary key,
  agency_id  uuid not null references public.agencies (user_id) on delete cascade,
  kind       text not null check (kind in ('free', 'paid')),
  started_at timestamptz not null default now(),
  expires_at timestamptz                      -- null for a free seat
);
create index if not exists agency_seats_agency on public.agency_seats (agency_id);
alter table public.agency_seats enable row level security;

create table if not exists public.seat_requests (
  id         uuid primary key default gen_random_uuid(),
  agency_id  uuid not null references public.agencies (user_id) on delete cascade,
  worker_id  uuid not null,
  kind       text not null check (kind in ('free', 'paid')),
  release_worker uuid,                        -- the girl whose free seat is given up when this one is accepted
  paid_amount numeric not null default 0,
  status     text not null default 'pending' check (status in ('pending', 'accepted', 'declined', 'expired', 'cancelled')),
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default now() + interval '7 days'
);
create index if not exists seat_requests_worker on public.seat_requests (worker_id, status);
create unique index if not exists seat_requests_one_pending on public.seat_requests (agency_id, worker_id) where status = 'pending';
alter table public.seat_requests enable row level security;
-- no policies: every read / write goes through the functions below

-- ---------- helpers -------------------------------------------------------------------------------------------------------------------
create or replace function public.has_seat(p_worker uuid, p_agency uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.agency_seats s
                  where s.worker_id = p_worker and s.agency_id = p_agency and (s.expires_at is null or s.expires_at > now()))
$$;

create or replace function public.agency_free_used(p_agency uuid)
returns int language sql stable security definer set search_path = public as $$
  select count(*)::int from public.agency_seats s where s.agency_id = p_agency and s.kind = 'free'
$$;

-- an invited girl (came by the agency's own link / draft): inside her 90 fixed days, counted once per pair
create or replace function public.agency_invite_alive(p_agency uuid, p_worker uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.agency_invites i
                  where i.agency_id = p_agency and i.worker_id = p_worker
                    and i.invited_at + make_interval(days => public.agency_invite_days()) > now())
     and exists (select 1 from public.workers w where w.user_id = p_worker and w.agency_id = p_agency and w.agency_via_link)
$$;

-- fill empty FREE seats with the earliest waiting girls (they joined by their own accepting, so no further consent)
create or replace function public.agency_fill_seats(p_agency uuid)
returns void language plpgsql security definer set search_path = public as $$
declare r record;
begin
  delete from public.agency_seats where agency_id = p_agency and kind = 'paid' and expires_at <= now();
  for r in select w.user_id from public.workers w
            where w.agency_id = p_agency and w.user_id <> p_agency and w.deleted_at is null
              and not exists (select 1 from public.agency_seats s where s.worker_id = w.user_id)
              and not exists (select 1 from public.seat_requests q where q.worker_id = w.user_id and q.agency_id = p_agency and q.status = 'pending')
            order by w.agency_since, w.user_id loop
    exit when public.agency_free_used(p_agency) >= public.agency_included_girls();
    insert into public.agency_seats (worker_id, agency_id, kind, started_at) values (r.user_id, p_agency, 'free', now())
    on conflict (worker_id) do nothing;
  end loop;
end $$;

-- does the agency earn the recruiter slot (40 %) on this girl's bookings right now?
create or replace function public.agency_earns_on(p_agency uuid, p_worker uuid)
returns boolean language plpgsql stable security definer set search_path = public as $$
begin
  if p_agency is null or p_agency = p_worker then return false; end if;
  if not exists (select 1 from public.agencies a where a.user_id = p_agency and a.status = 'approved' and not public.is_suspended(a.user_id)) then return false; end if;
  -- a girl the agency invited itself: 90 fixed days, always
  if public.agency_invite_alive(p_agency, p_worker) then return true; end if;
  -- a girl with a seat: continuing, when the agency is paid (and has a girl besides its owner) or the promo is running
  if public.has_seat(p_worker, p_agency) then
    if public.agency_recruiter_eligible(p_agency) then return true; end if;
    if public.agency_promo_active() then return true; end if;
  end if;
  return false;
end $$;

revoke all on function public.has_seat(uuid, uuid), public.agency_free_used(uuid), public.agency_invite_alive(uuid, uuid),
  public.agency_fill_seats(uuid), public.agency_earns_on(uuid, uuid) from public, anon, authenticated;

-- ---------- a girl joins / changes / leaves an agency ---------------------------------------------------------------------------------
create or replace function public.trg_worker_agency_change()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_old uuid;
begin
  if tg_op = 'INSERT' then
    if new.agency_id is null then return new; end if;
  else
    if new.agency_id is not distinct from old.agency_id then return new; end if;
    v_old := old.agency_id;
  end if;
  if v_old is not null then
    delete from public.agency_seats where worker_id = new.user_id;
    update public.seat_requests set status = 'cancelled' where worker_id = new.user_id and agency_id = v_old and status = 'pending';
  end if;
  if new.agency_id is not null then
    if tg_op = 'INSERT' then new.agency_via_link := true; end if;     -- registered through the agency's code
    if current_setting('app.agency_via_link', true) = '1' then new.agency_via_link := true; end if;
    if tg_op = 'UPDATE' and current_setting('app.agency_via_link', true) is distinct from '1' then new.agency_via_link := false; end if;
  else
    new.agency_via_link := false;
  end if;
  return new;
end $$;
drop trigger if exists workers_agency_change on public.workers;
create trigger workers_agency_change before insert or update of agency_id on public.workers
  for each row execute function public.trg_worker_agency_change();

create or replace function public.trg_worker_agency_after()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'UPDATE' and new.agency_id is not distinct from old.agency_id then return new; end if;
  if tg_op = 'UPDATE' and old.agency_id is not null then perform public.agency_fill_seats(old.agency_id); end if;
  if new.agency_id is null or new.agency_id = new.user_id then return new; end if;
  if new.agency_via_link then
    insert into public.agency_invites (agency_id, worker_id) values (new.agency_id, new.user_id) on conflict do nothing;
  end if;
  perform public.agency_fill_seats(new.agency_id);
  return new;
end $$;
drop trigger if exists workers_agency_after on public.workers;
create trigger workers_agency_after after insert or update of agency_id on public.workers
  for each row execute function public.trg_worker_agency_after();

-- no more capacity limits
create or replace function public.applications_set_agency()
returns trigger language plpgsql security definer set search_path = public as $$
declare a public.agencies;
begin
  if new.agency_code is null or btrim(new.agency_code) = '' then
    new.agency_code := null; new.agency_id := null; new.agency_status := null;
    return new;
  end if;
  select * into a from public.agencies where code = btrim(new.agency_code) and status = 'approved';
  if not found or a.user_id = new.user_id then raise exception 'AGENCY_NOT_FOUND'; end if;
  new.agency_id := a.user_id;
  new.agency_status := 'accepted';
  return new;
end $$;

create or replace function public.agency_review_girl(p_app uuid, p_accept boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  if p_accept then raise exception 'BAD_INPUT'; end if;      -- accepting happens automatically
  update public.worker_applications set agency_status = 'rejected'
   where id = p_app and agency_id = auth.uid() and status = 'pending';
  if not found then raise exception 'NOT_FOUND'; end if;
end $$;

-- a registered independent girl accepts an agency invitation (no application, no admin step)
create or replace function public.worker_join_agency(p_code text)
returns void language plpgsql security definer set search_path = public as $$
declare w public.workers; a public.agencies; v_draft boolean;
begin
  if auth.uid() is null then raise exception 'FORBIDDEN'; end if;
  if public.is_suspended(auth.uid()) then raise exception 'SUSPENDED'; end if;
  select * into w from public.workers where user_id = auth.uid() for update;
  if not found then raise exception 'NOT_A_WORKER'; end if;
  if w.agency_id is not null then raise exception 'ALREADY_IN_AGENCY'; end if;
  select * into a from public.agencies where code = btrim(p_code) and status = 'approved';
  if not found or a.user_id = auth.uid() then raise exception 'AGENCY_NOT_FOUND'; end if;
  -- "invited by the agency's own link" only when she has just claimed THAT agency's own draft (decided here, never by the client)
  select exists (select 1 from public.application_drafts d
                  where d.claimed_by = auth.uid() and d.source = 'agency' and d.agency_id = a.user_id and d.claimed_at > now() - interval '5 minutes')
    into v_draft;
  perform set_config('app.agency_via_link', case when v_draft then '1' else '0' end, true);
  update public.workers set agency_id = a.user_id, agency_since = now() where user_id = auth.uid();
  perform set_config('app.agency_via_link', '0', true);
end $$;

create or replace function public.worker_leave_agency()
returns void language plpgsql security definer set search_path = public as $$
declare w public.workers; s public.agency_seats;
begin
  select * into w from public.workers where user_id = auth.uid();
  if not found or w.agency_id is null then raise exception 'NOT_FOUND'; end if;
  select * into s from public.agency_seats where worker_id = auth.uid() and (expires_at is null or expires_at > now());
  -- only a girl WITH a seat is locked, for the first N days of her seat; a waiting girl leaves at any time
  if found and now() < s.started_at + make_interval(days => public.agency_leave_days()) then raise exception 'AGENCY_ACTIVE'; end if;
  update public.workers set agency_id = null, agency_since = null where user_id = auth.uid();
end $$;

drop function if exists public.my_worker_agency();
create or replace function public.my_worker_agency()
returns table (agency_name text, logo_path text, plan_expires_at timestamptz, can_leave boolean, can_leave_at timestamptz, has_seat boolean)
language sql stable security definer set search_path = public as $$
  select a.name, a.logo_path, a.plan_expires_at,
         (s.worker_id is null) or now() >= s.started_at + make_interval(days => public.agency_leave_days()),
         case when s.worker_id is not null then s.started_at + make_interval(days => public.agency_leave_days()) end,
         s.worker_id is not null
    from public.workers w join public.agencies a on a.user_id = w.agency_id
    left join public.agency_seats s on s.worker_id = w.user_id and (s.expires_at is null or s.expires_at > now())
   where w.user_id = auth.uid()
$$;

-- ---------- money: the recruiter slot ------------------------------------------------------------------------------------------------
create or replace function public.booking_recruiter(p_worker uuid)
returns uuid language plpgsql security definer set search_path = public as $$
declare w public.workers; v_until timestamptz;
begin
  select * into w from public.workers where user_id = p_worker for update;
  if not found then return null; end if;
  -- 1) her agency, when it earns on her now (invited by its link within 90 fixed days; or seated and paid / in promo)
  if w.agency_id is not null and public.agency_earns_on(w.agency_id, p_worker) then return w.agency_id; end if;
  -- 2) otherwise the seller / provider who brought her, while her 90 days are alive (renewing while she works)
  if w.recruiter_id is null or w.recruiter_lapsed then return null; end if;
  v_until := w.recruiter_until;
  while v_until <= now() loop
    if exists (select 1 from public.jobs j
                where j.worker_id = p_worker and j.status in ('matched', 'completed')
                  and j.created_at >= v_until - make_interval(days => public.recruiter_active_days())
                  and j.created_at <  v_until) then
      v_until := v_until + make_interval(days => public.recruiter_window_days());
    else
      update public.workers set recruiter_lapsed = true where user_id = p_worker;
      return null;
    end if;
  end loop;
  if v_until is distinct from w.recruiter_until then
    update public.workers set recruiter_until = v_until where user_id = p_worker;
  end if;
  if not public.is_seller_at(w.recruiter_id, now()) then return null; end if;
  return w.recruiter_id;
end $$;
-- pay_booking_shares stays as in 066: an agency that is not "paid + another girl" never holds both slots.

-- ---------- agency side ---------------------------------------------------------------------------------------------------------------
drop function if exists public.my_agency();
create or replace function public.my_agency()
returns table (user_id uuid, name text, contact text, logo_path text, code text, status text, reject_reason text,
               plan_expires_at timestamptz, extra_slots int, girls int, capacity int, renewal_price numeric, active boolean, promo boolean)
language sql stable security definer set search_path = public as $$
  select a.user_id, a.name, a.contact, a.logo_path, a.code, a.status, a.reject_reason, a.plan_expires_at,
         (select count(*)::int from public.agency_seats s where s.agency_id = a.user_id and s.kind = 'paid' and s.expires_at > now()),
         (select count(*)::int from public.workers w where w.agency_id = a.user_id and w.user_id <> a.user_id and w.deleted_at is null),
         public.agency_included_girls()
           + (select count(*)::int from public.agency_seats s where s.agency_id = a.user_id and s.kind = 'paid' and s.expires_at > now()),
         public.agency_plan_price(),
         public.agency_active(a.user_id),
         public.agency_promo_active()
    from public.agencies a where a.user_id = auth.uid()
$$;

-- the plan price is flat now: extra seats are bought one by one
create or replace function public.agency_pay_plan()
returns timestamptz language plpgsql security definer set search_path = public as $$
declare
  a public.agencies; v_price numeric; v_bal numeric; v_exp timestamptz; v_was boolean;
begin
  if auth.uid() is null then raise exception 'FORBIDDEN'; end if;
  if public.is_suspended(auth.uid()) then raise exception 'SUSPENDED'; end if;
  select * into a from public.agencies where user_id = auth.uid() for update;
  if not found or a.status <> 'approved' then raise exception 'NOT_APPROVED'; end if;
  v_price := public.agency_plan_price();
  select wallet_balance into v_bal from public.users where id = auth.uid() for update;
  if v_bal < v_price then raise exception 'INSUFFICIENT_BALANCE'; end if;
  v_was := coalesce(a.plan_expires_at > now(), false);
  v_exp := greatest(now(), coalesce(a.plan_expires_at, now())) + make_interval(days => public.agency_plan_days());
  perform set_config('app.ledger_kind', 'agency_plan', true);
  perform set_config('app.ledger_ref', a.user_id::text, true);
  update public.users set wallet_balance = wallet_balance - v_price where id = auth.uid();
  update public.agencies set plan_expires_at = v_exp where user_id = a.user_id;
  perform public.plan_notify('agency', a.user_id, case when v_was then 'renewed' else 'activated' end);
  return v_exp;
end $$;

drop function if exists public.agency_buy_slot();

-- the seat board of the agency
create or replace function public.agency_seat_board()
returns table (user_id uuid, display_name text, categories text[], joined_at timestamptz, via_link boolean, invite_until timestamptz,
               seat_kind text, seat_started timestamptz, seat_expires timestamptz, can_swap_at timestamptz,
               request_status text, pos int)
language sql stable security definer set search_path = public as $$
  select w.user_id, w.display_name, w.categories, w.agency_since, w.agency_via_link,
         case when w.agency_via_link then i.invited_at + make_interval(days => public.agency_invite_days()) end,
         s.kind, s.started_at, s.expires_at,
         case when s.kind = 'free' then s.started_at + make_interval(days => public.agency_seat_days()) end,
         (select q.status from public.seat_requests q where q.worker_id = w.user_id and q.agency_id = auth.uid() and q.status = 'pending' limit 1),
         (row_number() over (order by w.agency_since, w.user_id))::int
    from public.workers w
    left join public.agency_seats s on s.worker_id = w.user_id and s.agency_id = auth.uid() and (s.expires_at is null or s.expires_at > now())
    left join public.agency_invites i on i.agency_id = auth.uid() and i.worker_id = w.user_id
   where w.agency_id = auth.uid() and w.user_id <> auth.uid() and w.deleted_at is null
   order by w.agency_since, w.user_id
$$;

-- give a girl a seat. 'free' needs an empty free seat, or p_release = a free-seat girl whose seat is >= 30 days old;
-- 'paid' costs the seat price from the agency Wallet (plan must be active) and lasts 30 days or until the plan date.
-- Consent is needed unless she came by the agency's own link / draft; then a request is sent and the price (if any) is held, refunded on decline.
create or replace function public.agency_give_seat(p_worker uuid, p_kind text, p_release uuid default null)
returns text language plpgsql security definer set search_path = public as $$
declare a public.agencies; w public.workers; s public.agency_seats; v_bal numeric; v_price numeric := 0; v_need boolean; v_exp timestamptz;
begin
  if auth.uid() is null then raise exception 'FORBIDDEN'; end if;
  if p_kind not in ('free', 'paid') then raise exception 'BAD_INPUT'; end if;
  select * into a from public.agencies where user_id = auth.uid() and status = 'approved' for update;
  if not found then raise exception 'NOT_APPROVED'; end if;
  select * into w from public.workers where user_id = p_worker and agency_id = a.user_id and deleted_at is null;
  if not found or p_worker = a.user_id then raise exception 'NOT_FOUND'; end if;
  if public.has_seat(p_worker, a.user_id) then raise exception 'ALREADY_SEATED'; end if;
  if exists (select 1 from public.seat_requests where agency_id = a.user_id and worker_id = p_worker and status = 'pending') then raise exception 'REQUEST_PENDING'; end if;
  perform public.agency_fill_seats(a.user_id);
  if public.has_seat(p_worker, a.user_id) then raise exception 'ALREADY_SEATED'; end if;
  if p_kind = 'free' then
    if public.agency_free_used(a.user_id) >= public.agency_included_girls() then
      if p_release is null then raise exception 'NO_FREE_SEAT'; end if;
      select * into s from public.agency_seats where worker_id = p_release and agency_id = a.user_id and kind = 'free';
      if not found then raise exception 'NOT_FOUND'; end if;
      if now() < s.started_at + make_interval(days => public.agency_seat_days()) then raise exception 'SEAT_TOO_NEW'; end if;
    end if;
  else
    if not public.agency_active(a.user_id) then raise exception 'PLAN_INACTIVE'; end if;
    v_price := public.agency_slot_price();
    v_exp := least(now() + make_interval(days => public.agency_seat_days()), a.plan_expires_at);
    select wallet_balance into v_bal from public.users where id = a.user_id for update;
    if v_bal < v_price then raise exception 'INSUFFICIENT_BALANCE'; end if;
  end if;
  v_need := not w.agency_via_link;       -- came by the agency's own link / draft = agreed from the start

  if v_price > 0 then
    perform set_config('app.ledger_kind', 'agency_slot', true);
    perform set_config('app.ledger_ref', p_worker::text, true);
    update public.users set wallet_balance = wallet_balance - v_price where id = a.user_id;
  end if;

  if v_need then
    insert into public.seat_requests (agency_id, worker_id, kind, release_worker, paid_amount)
    values (a.user_id, p_worker, p_kind, p_release, v_price);
    perform public.push_notify(jsonb_build_object('type', 'seat', 'event', 'request', 'user_id', p_worker, 'detail', left(a.name, 60)));
    return 'requested';
  end if;

  if p_release is not null then delete from public.agency_seats where worker_id = p_release and agency_id = a.user_id and kind = 'free'; end if;
  insert into public.agency_seats (worker_id, agency_id, kind, started_at, expires_at)
  values (p_worker, a.user_id, p_kind, now(), case when p_kind = 'paid' then v_exp end)
  on conflict (worker_id) do update set agency_id = excluded.agency_id, kind = excluded.kind, started_at = excluded.started_at, expires_at = excluded.expires_at;
  return 'seated';
end $$;

-- the girl's side of a seat request
create or replace function public.my_seat_requests()
returns table (id uuid, agency_name text, logo_path text, kind text, created_at timestamptz, expires_at timestamptz)
language sql stable security definer set search_path = public as $$
  select q.id, a.name, a.logo_path, q.kind, q.created_at, q.expires_at
    from public.seat_requests q join public.agencies a on a.user_id = q.agency_id
   where q.worker_id = auth.uid() and q.status = 'pending' and q.expires_at > now()
   order by q.created_at
$$;

create or replace function public.answer_seat_request(p_id uuid, p_accept boolean)
returns void language plpgsql security definer set search_path = public as $$
declare q public.seat_requests; a public.agencies; v_exp timestamptz; v_ok boolean := true;
begin
  select * into q from public.seat_requests where id = p_id and worker_id = auth.uid() and status = 'pending' for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  select * into a from public.agencies where user_id = q.agency_id for update;
  if q.expires_at <= now() or not p_accept or not exists (select 1 from public.workers w where w.user_id = auth.uid() and w.agency_id = q.agency_id) then
    v_ok := false;
  elsif q.kind = 'free' and public.agency_free_used(q.agency_id) >= public.agency_included_girls() then
    if q.release_worker is null or not exists (select 1 from public.agency_seats s where s.worker_id = q.release_worker and s.agency_id = q.agency_id and s.kind = 'free'
                                                and now() >= s.started_at + make_interval(days => public.agency_seat_days())) then
      v_ok := false;
    else
      delete from public.agency_seats where worker_id = q.release_worker and agency_id = q.agency_id;
    end if;
  end if;
  v_exp := case when q.kind = 'paid' then least(now() + make_interval(days => public.agency_seat_days()), coalesce(a.plan_expires_at, now())) end;
  if v_ok and q.kind = 'paid' and v_exp <= now() then v_ok := false; end if;

  if not v_ok then
    update public.seat_requests set status = case when q.expires_at <= now() then 'expired' when not p_accept then 'declined' else 'cancelled' end where id = q.id;
    if q.paid_amount > 0 then
      perform set_config('app.ledger_kind', 'agency_slot_refund', true);
      perform set_config('app.ledger_ref', q.worker_id::text, true);
      update public.users set wallet_balance = wallet_balance + q.paid_amount where id = q.agency_id;
    end if;
    return;
  end if;
  insert into public.agency_seats (worker_id, agency_id, kind, started_at, expires_at) values (q.worker_id, q.agency_id, q.kind, now(), v_exp)
  on conflict (worker_id) do update set agency_id = excluded.agency_id, kind = excluded.kind, started_at = excluded.started_at, expires_at = excluded.expires_at;
  update public.seat_requests set status = 'accepted' where id = q.id;
end $$;

-- the agency withdraws a pending request (refund)
create or replace function public.agency_cancel_seat_request(p_worker uuid)
returns void language plpgsql security definer set search_path = public as $$
declare q public.seat_requests;
begin
  select * into q from public.seat_requests where agency_id = auth.uid() and worker_id = p_worker and status = 'pending' for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  update public.seat_requests set status = 'cancelled' where id = q.id;
  if q.paid_amount > 0 then
    perform set_config('app.ledger_kind', 'agency_slot_refund', true);
    perform set_config('app.ledger_ref', q.worker_id::text, true);
    update public.users set wallet_balance = wallet_balance + q.paid_amount where id = q.agency_id;
  end if;
end $$;

-- housekeeping, daily: expire old requests (refund), clear ended paid seats, refill free seats
create or replace function public.seats_housekeeping()
returns void language plpgsql security definer set search_path = public as $$
declare q record;
begin
  for q in select * from public.seat_requests where status = 'pending' and expires_at <= now() for update loop
    update public.seat_requests set status = 'expired' where id = q.id;
    if q.paid_amount > 0 then
      perform set_config('app.ledger_kind', 'agency_slot_refund', true);
      perform set_config('app.ledger_ref', q.worker_id::text, true);
      update public.users set wallet_balance = wallet_balance + q.paid_amount where id = q.agency_id;
    end if;
  end loop;
  for q in select distinct agency_id from public.workers where agency_id is not null loop
    perform public.agency_fill_seats(q.agency_id);
  end loop;
end $$;
revoke all on function public.seats_housekeeping() from public, anon, authenticated;
do $$ begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'seats-housekeeping';
    perform cron.schedule('seats-housekeeping', '15 3 * * *', 'select public.seats_housekeeping()');
  end if;
exception when others then null;
end $$;

-- ---------- existing agencies ---------------------------------------------------------------------------------------------------------
-- girls who applied through an agency's code (accepted application) keep the invite window from the day they joined
update public.workers w set agency_via_link = true
 where w.agency_id is not null and w.agency_id <> w.user_id
   and exists (select 1 from public.worker_applications x where x.user_id = w.user_id and x.agency_id = w.agency_id and x.agency_status = 'accepted');
insert into public.agency_invites (agency_id, worker_id, invited_at)
select w.agency_id, w.user_id, coalesce(w.agency_since, now()) from public.workers w
 where w.agency_id is not null and w.agency_id <> w.user_id and w.agency_via_link on conflict do nothing;

-- the earliest 10 girls of each agency get the free seats (their days run on from the day they joined)
insert into public.agency_seats (worker_id, agency_id, kind, started_at)
select x.user_id, x.agency_id, 'free', coalesce(x.agency_since, now())
  from (select w.user_id, w.agency_id, w.agency_since,
               row_number() over (partition by w.agency_id order by w.agency_since, w.user_id) rn
          from public.workers w where w.agency_id is not null and w.user_id <> w.agency_id and w.deleted_at is null) x
 where x.rn <= public.agency_included_girls()
on conflict (worker_id) do nothing;

-- girls above 10 that had a paid slot keep a paid seat until the plan date
insert into public.agency_seats (worker_id, agency_id, kind, started_at, expires_at)
select x.user_id, x.agency_id, 'paid', now(), a.plan_expires_at
  from (select w.user_id, w.agency_id,
               row_number() over (partition by w.agency_id order by w.agency_since, w.user_id) rn
          from public.workers w where w.agency_id is not null and w.user_id <> w.agency_id and w.deleted_at is null) x
  join public.agencies a on a.user_id = x.agency_id
 where x.rn > public.agency_included_girls() and x.rn <= public.agency_included_girls() + a.extra_slots and a.plan_expires_at > now()
on conflict (worker_id) do nothing;

revoke all on function public.my_worker_agency(), public.worker_leave_agency(), public.worker_join_agency(text), public.agency_review_girl(uuid, boolean),
  public.my_agency(), public.agency_pay_plan(), public.agency_seat_board(), public.agency_give_seat(uuid, text, uuid), public.my_seat_requests(),
  public.answer_seat_request(uuid, boolean), public.agency_cancel_seat_request(uuid) from public, anon;
grant execute on function public.my_worker_agency(), public.worker_leave_agency(), public.worker_join_agency(text), public.agency_review_girl(uuid, boolean),
  public.my_agency(), public.agency_pay_plan(), public.agency_seat_board(), public.agency_give_seat(uuid, text, uuid), public.my_seat_requests(),
  public.answer_seat_request(uuid, boolean), public.agency_cancel_seat_request(uuid) to authenticated;
