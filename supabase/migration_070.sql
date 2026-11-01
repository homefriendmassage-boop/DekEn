-- =============================================================================
-- migration_070.sql — run ONCE after migration_069.sql
--   * a PAID agency earns the continuing 40 % (recruiter slot) on ALL its girls: with a seat or waiting, from the link or not
--     (the seat only matters for the badge-lock and for an UNPAID agency during the promotion)
--   * the seat consent push carries the request id, so the Flex can hold "ยินยอม" / "ไม่ยินยอม" buttons
-- =============================================================================

create or replace function public.agency_earns_on(p_agency uuid, p_worker uuid)
returns boolean language plpgsql stable security definer set search_path = public as $$
begin
  if p_agency is null or p_agency = p_worker then return false; end if;
  if not exists (select 1 from public.agencies a where a.user_id = p_agency and a.status = 'approved' and not public.is_suspended(a.user_id)) then return false; end if;
  -- PAID agency (and a girl besides its owner): every girl of the agency
  if public.agency_recruiter_eligible(p_agency) then return true; end if;
  -- NOT paid: a girl the agency invited itself (its own link / draft), 90 fixed days
  if public.agency_invite_alive(p_agency, p_worker) then return true; end if;
  -- NOT paid but the promotion is running: a girl with a seat
  if public.agency_promo_active() and public.has_seat(p_worker, p_agency) then return true; end if;
  return false;
end $$;
revoke all on function public.agency_earns_on(uuid, uuid) from public, anon, authenticated;

create or replace function public.agency_give_seat(p_worker uuid, p_kind text, p_release uuid default null)
returns text language plpgsql security definer set search_path = public as $$
declare a public.agencies; w public.workers; s public.agency_seats; v_bal numeric; v_price numeric := 0; v_need boolean; v_exp timestamptz; v_req uuid;
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
    values (a.user_id, p_worker, p_kind, p_release, v_price) returning id into v_req;
    perform public.push_notify(jsonb_build_object('type', 'seat', 'event', 'request', 'user_id', p_worker, 'detail', left(a.name, 60), 'request_id', v_req));
    return 'requested';
  end if;

  if p_release is not null then delete from public.agency_seats where worker_id = p_release and agency_id = a.user_id and kind = 'free'; end if;
  insert into public.agency_seats (worker_id, agency_id, kind, started_at, expires_at)
  values (p_worker, a.user_id, p_kind, now(), case when p_kind = 'paid' then v_exp end)
  on conflict (worker_id) do update set agency_id = excluded.agency_id, kind = excluded.kind, started_at = excluded.started_at, expires_at = excluded.expires_at;
  return 'seated';
end $$;
