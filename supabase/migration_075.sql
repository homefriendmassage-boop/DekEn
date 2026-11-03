-- =============================================================================
-- migration_075.sql — run ONCE after migration_074.sql           (booking rules, round 1: database + money)
--
-- NEW BOOKINGS (rules_v2 = true) follow these rules; bookings that were already open before this migration keep the old rules.
--   money   : the booking fee (500) is taken at booking. The 40/40/20 shares are paid only when the fee is EARNED
--             (job completed, customer cancels / does not show after the provider accepted, agreed reschedule) — never when it is refunded.
--   pending : provider does not answer within job_response_minutes (default 30) -> full refund
--             provider declines -> full refund · customer cancels -> refund minus job_cancel_fee (100), free in the first job_free_cancel_minutes (2)
--   matched : customer cancels >= job_early_cancel_hours (24) before the date -> refund minus 100 · later -> no refund (fee earned)
--             provider cancels / does not come / someone else comes / photos do not match (admin confirms) -> FULL refund + a strike for the provider
--             customer does not come (provider presses it after job_noshow_wait_minutes, customer may object for job_objection_hours) -> fee earned
--             agreed reschedule (one per job, asked >= job_resched_notice_hours before) -> the job is completed, fee earned, shares paid now
--             nobody reports anything until the date + job_autocomplete_hours (3) -> completed automatically
--   strikes : 1st = warning (Flex + reason), 2nd = block + fine 200, 3rd = 300, 4th = 400 ... until an admin resets the counter
--             (fine from the bonus balance first, then the Wallet). "Someone else came" = block until an admin unblocks.
--   disputes: any problem report that needs a decision waits for an admin only (no automatic refund)
--   stats   : worker_reliability() gives the 3 numbers shown on her page (90 days); an admin can void single events with a reason
--   customer compensation (optional) goes to the platform; the admin credits the provider's Wallet when he decides
-- =============================================================================

-- ---------- settings -------------------------------------------------------------------------------------------------------------------
insert into public.app_settings (key, value) values
  ('job_response_minutes', '30'), ('job_autocomplete_hours', '3'), ('job_free_cancel_minutes', '2'), ('job_cancel_fee', '100'),
  ('job_early_cancel_hours', '24'), ('job_noshow_wait_minutes', '30'), ('job_objection_hours', '6'), ('job_resched_notice_hours', '3'),
  ('penalty_step', '100'), ('penalty_from', '2'), ('cust_pause_count', '3'), ('cust_pause_days', '3'), ('cust_pause_window_days', '30'),
  ('job_comp_max', '500')
on conflict (key) do nothing;

create or replace function public.job_setting(p_key text, p_default numeric)
returns numeric language sql stable security definer set search_path = public as $$
  select coalesce((select nullif(btrim(value), '')::numeric from public.app_settings where key = p_key and value ~ '^[0-9]+(\.[0-9]+)?$'), p_default)
$$;

create or replace function public.admin_set_setting(p_key text, p_value text)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public.assert_admin();
  if p_key not in ('wallet_expiry_enabled', 'wallet_expiry_months', 'bonus_sweep_days', 'agency_leave_days', 'agency_promo_until',
                   'job_response_minutes', 'job_autocomplete_hours', 'job_free_cancel_minutes', 'job_cancel_fee', 'job_early_cancel_hours',
                   'job_noshow_wait_minutes', 'job_objection_hours', 'job_resched_notice_hours', 'penalty_step', 'penalty_from',
                   'cust_pause_count', 'cust_pause_days', 'cust_pause_window_days', 'job_comp_max') then raise exception 'BAD_INPUT'; end if;
  if p_key = 'wallet_expiry_enabled' and p_value not in ('true', 'false') then raise exception 'BAD_INPUT'; end if;
  if p_key = 'agency_promo_until' then
    if p_value <> '' and p_value !~ '^\d{4}-\d{2}-\d{2}$' then raise exception 'BAD_INPUT'; end if;
  elsif p_key <> 'wallet_expiry_enabled' and (p_value !~ '^[0-9]{1,4}$' or p_value::int < 0) then raise exception 'BAD_INPUT'; end if;
  if p_key = 'job_response_minutes' and (p_value::int < 5 or p_value::int > 180) then raise exception 'BAD_INPUT'; end if;
  insert into public.app_settings (key, value, updated_at, updated_by) values (p_key, p_value, now(), auth.uid())
  on conflict (key) do update set value = excluded.value, updated_at = now(), updated_by = auth.uid();
end $$;

-- the numbers the app needs to explain the rules to the user
create or replace function public.job_rules()
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'response_minutes', public.job_setting('job_response_minutes', 30), 'autocomplete_hours', public.job_setting('job_autocomplete_hours', 3),
    'free_cancel_minutes', public.job_setting('job_free_cancel_minutes', 2), 'cancel_fee', public.job_setting('job_cancel_fee', 100),
    'early_cancel_hours', public.job_setting('job_early_cancel_hours', 24), 'noshow_wait_minutes', public.job_setting('job_noshow_wait_minutes', 30),
    'objection_hours', public.job_setting('job_objection_hours', 6), 'resched_notice_hours', public.job_setting('job_resched_notice_hours', 3),
    'comp_max', public.job_setting('job_comp_max', 500), 'booking_fee', public.platform_booking_fee())
$$;

-- ---------- columns / tables -----------------------------------------------------------------------------------------------------------
alter table public.jobs
  add column if not exists rules_v2 boolean not null default false,
  add column if not exists settle_kind text,                 -- null while open | refund_full | refund_partial | earned
  add column if not exists cancel_note text,
  add column if not exists customer_noshow_at timestamptz,
  add column if not exists objection_until timestamptz,
  add column if not exists dispute_open boolean not null default false,
  add column if not exists dispute_by text,
  add column if not exists dispute_kind text,
  add column if not exists dispute_note text,
  add column if not exists dispute_at timestamptz,
  add column if not exists resolved_at timestamptz,
  add column if not exists resolution text,
  add column if not exists resched_to timestamptz,
  add column if not exists resched_by text,
  add column if not exists resched_status text,              -- null | pending | accepted | declined
  add column if not exists resched_at timestamptz;
alter table public.jobs alter column rules_v2 set default true;      -- bookings made from now on; the rows above stay false

create table if not exists public.job_events (
  id          uuid primary key default gen_random_uuid(),
  job_id      uuid not null,
  worker_id   uuid not null,
  customer_id uuid not null,
  kind        text not null check (kind in ('worker_fault', 'customer_noshow', 'customer_cancel')),
  detail      text,
  worker_reason text,                                         -- what she wrote after the warning
  at          timestamptz not null default now(),
  voided_at   timestamptz, voided_by uuid, void_reason text,
  unique (job_id, kind)
);
create index if not exists job_events_worker on public.job_events (worker_id, at desc);
create index if not exists job_events_customer on public.job_events (customer_id, at desc);
alter table public.job_events enable row level security;
revoke all on public.job_events from anon, authenticated;

create table if not exists public.worker_strikes (
  worker_id  uuid primary key,
  strikes    int not null default 0 check (strikes >= 0),
  blocked    boolean not null default false,
  block_kind text check (block_kind in ('fine', 'imposter')),
  fine_due   numeric not null default 0,
  updated_at timestamptz not null default now()
);
alter table public.worker_strikes enable row level security;
revoke all on public.worker_strikes from anon, authenticated;

create table if not exists public.customer_holds (
  customer_id uuid primary key, until timestamptz not null
);
alter table public.customer_holds enable row level security;
revoke all on public.customer_holds from anon, authenticated;

create table if not exists public.job_compensation (
  job_id uuid primary key, customer_id uuid not null, worker_id uuid not null,
  amount numeric not null check (amount > 0), status text not null default 'pending' check (status in ('pending', 'credited', 'dismissed')),
  credited_amount numeric, created_at timestamptz not null default now(), decided_at timestamptz, decided_by uuid
);
alter table public.job_compensation enable row level security;
revoke all on public.job_compensation from anon, authenticated;

create or replace function public.worker_blocked(p_worker uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select s.blocked from public.worker_strikes s where s.worker_id = p_worker), false)
$$;

-- a blocked provider is not shown (everything else in the old rule is kept)
create or replace function public.worker_listed(p_worker uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select not public.is_suspended(p_worker)
     and not public.worker_blocked(p_worker)
     and not coalesce((select a.hidden from public.worker_alive a where a.user_id = p_worker), false)
     and coalesce((select w.deleted_at is null and w.delete_requested_at is null and not w.admin_hidden and (w.claimed or w.claim_deadline > now())
                     from public.workers w where w.user_id = p_worker), false)
$$;

-- ---------- booking checks ---------------------------------------------------------------------------------------------------------------
create or replace function public.trg_job_block_checks()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if public.worker_blocked(new.worker_id) then raise exception 'WORKER_BLOCKED'; end if;
  if exists (select 1 from public.customer_holds h where h.customer_id = new.customer_id and h.until > now()) then raise exception 'BOOKING_PAUSED'; end if;
  return new;
end $$;
drop trigger if exists jobs_block_checks on public.jobs;
create trigger jobs_block_checks before insert on public.jobs for each row execute function public.trg_job_block_checks();

-- ---------- strikes ------------------------------------------------------------------------------------------------------------------------
-- p_kind: cancel | noshow | mismatch | imposter | other. Idempotent per job.
create or replace function public.worker_strike_add(p_worker uuid, p_job uuid, p_kind text)
returns void language plpgsql security definer set search_path = public as $$
declare v_ev uuid; j public.jobs; s public.worker_strikes;
begin
  select * into j from public.jobs where id = p_job;
  insert into public.job_events (job_id, worker_id, customer_id, kind, detail) values (p_job, p_worker, j.customer_id, 'worker_fault', p_kind)
  on conflict (job_id, kind) do nothing returning id into v_ev;
  if v_ev is null then return; end if;
  insert into public.worker_strikes (worker_id, strikes) values (p_worker, 1)
  on conflict (worker_id) do update set strikes = public.worker_strikes.strikes + 1, updated_at = now();
  select * into s from public.worker_strikes where worker_id = p_worker;
  if p_kind = 'imposter' then
    update public.worker_strikes set blocked = true, block_kind = 'imposter', fine_due = 0, updated_at = now() where worker_id = p_worker;
  elsif s.strikes >= public.job_setting('penalty_from', 2) and coalesce(s.block_kind, 'fine') <> 'imposter' then
    update public.worker_strikes set blocked = true, block_kind = 'fine', fine_due = public.job_setting('penalty_step', 100) * s.strikes, updated_at = now() where worker_id = p_worker;
  end if;
  select * into s from public.worker_strikes where worker_id = p_worker;
  perform public.push_notify(jsonb_build_object('type', 'strike', 'event', case when s.blocked then 'blocked' else 'warn' end, 'user_id', p_worker,
          'detail', s.fine_due::text, 'kind', coalesce(s.block_kind, ''), 'event_id', v_ev));
end $$;

create or replace function public.customer_event_add(p_customer uuid, p_worker uuid, p_job uuid, p_kind text)
returns void language plpgsql security definer set search_path = public as $$
declare v_ev uuid; v_n int;
begin
  insert into public.job_events (job_id, worker_id, customer_id, kind) values (p_job, p_worker, p_customer, p_kind)
  on conflict (job_id, kind) do nothing returning id into v_ev;
  if v_ev is null then return; end if;
  select count(*) into v_n from public.job_events e
   where e.customer_id = p_customer and e.kind in ('customer_noshow', 'customer_cancel') and e.voided_at is null
     and e.at > now() - make_interval(days => public.job_setting('cust_pause_window_days', 30)::int);
  if v_n >= public.job_setting('cust_pause_count', 3) then
    insert into public.customer_holds (customer_id, until) values (p_customer, now() + make_interval(days => public.job_setting('cust_pause_days', 3)::int))
    on conflict (customer_id) do update set until = excluded.until;
  end if;
end $$;
revoke all on function public.worker_strike_add(uuid, uuid, text), public.customer_event_add(uuid, uuid, uuid, text), public.job_setting(text, numeric),
  public.worker_blocked(uuid) from public, anon, authenticated;
grant execute on function public.job_setting(text, numeric), public.worker_blocked(uuid) to authenticated;

-- ---------- the guard: who may move a job, and what the money does ------------------------------------------------------------------
-- internal callers set app.job_system = 'on' and app.job_cause = <reason>
create or replace function public.jobs_guard_update()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  v_sys boolean := coalesce(current_setting('app.job_system', true), '') = 'on';
  v_cause text := nullif(current_setting('app.job_cause', true), '');
  v_amt numeric;
begin
  if new.status = old.status then return new; end if;
  if old.status in ('completed', 'cancelled') then raise exception 'ILLEGAL_STATUS_TRANSITION'; end if;

  if me is not null and not v_sys then
    if not (
      (me = new.customer_id and old.status = 'pending' and new.status = 'cancelled')
      or (me = new.worker_id and (
            (old.status = 'pending' and new.status in ('matched', 'cancelled'))
         or (old.status = 'matched' and new.status in ('completed', 'cancelled'))))
    ) then
      raise exception 'ILLEGAL_STATUS_TRANSITION';
    end if;
    if old.rules_v2 and old.dispute_open then raise exception 'DISPUTE_OPEN'; end if;
    if me = new.worker_id and old.status = 'pending' and new.status = 'matched' and public.worker_blocked(new.worker_id) then raise exception 'WORKER_BLOCKED'; end if;
  end if;

  if new.status = 'matched' then new.accepted_at := now(); end if;
  if new.status = 'cancelled' then
    new.cancel_reason := case
      when v_cause is not null then v_cause
      when coalesce(current_setting('app.job_expiry', true), '') = 'on' then 'expired'
      when old.status = 'matched' then case when me = new.worker_id then 'worker_cancelled' else 'admin' end
      when me = new.customer_id then 'customer'
      when me = new.worker_id then 'declined'
      else 'admin' end;
  end if;

  -- ---- bookings made before this migration: the old rules (refund only a pending job; shares were paid at "accepted") ----
  if not old.rules_v2 then
    if old.status = 'pending' and new.status = 'cancelled' then
      perform set_config('app.ledger_kind', 'booking_refund', true);
      perform set_config('app.ledger_ref', old.id::text, true);
      update public.users set wallet_balance = wallet_balance + old.booking_fee where id = old.customer_id;
    end if;
    return new;
  end if;

  -- ---- new rules ----
  if new.status = 'completed' then
    new.settle_kind := 'earned';
  elsif new.status = 'cancelled' then
    new.settle_kind := case new.cancel_reason
      when 'customer' then case when now() - old.created_at <= make_interval(secs => public.job_setting('job_free_cancel_minutes', 2) * 60) then 'refund_full' else 'refund_partial' end
      when 'customer_early' then 'refund_partial'
      when 'customer_late' then 'earned'
      when 'customer_noshow' then 'earned'
      else 'refund_full' end;          -- declined, expired, worker_cancelled, worker_noshow, imposter, mismatch, worker_fault_other, admin_refund, admin
  end if;
  if new.settle_kind in ('refund_full', 'refund_partial') then
    v_amt := case when new.settle_kind = 'refund_full' then old.booking_fee else greatest(old.booking_fee - public.job_setting('job_cancel_fee', 100), 0) end;
    if v_amt > 0 then
      perform set_config('app.ledger_kind', 'booking_refund', true);
      perform set_config('app.ledger_ref', old.id::text, true);
      update public.users set wallet_balance = wallet_balance + v_amt where id = old.customer_id;
    end if;
  end if;
  return new;
end $$;

-- after the row is saved: pay the shares when the fee is earned, record the events (strikes, customer history)
create or replace function public.jobs_settle_after()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_skip boolean := coalesce(current_setting('app.no_strike', true), '') = 'on';
begin
  if not new.rules_v2 or new.status = old.status then return new; end if;
  if new.settle_kind = 'earned' and old.settle_kind is distinct from 'earned' then perform public.pay_booking_shares(new.id); end if;
  if new.status = 'cancelled' and old.status = 'matched' then
    if new.cancel_reason in ('worker_cancelled', 'worker_noshow', 'mismatch', 'imposter', 'worker_fault_other') and not v_skip then
      perform public.worker_strike_add(new.worker_id, new.id, case new.cancel_reason when 'worker_cancelled' then 'cancel' when 'worker_noshow' then 'noshow'
                                                                  when 'worker_fault_other' then 'other' else new.cancel_reason end);
    elsif new.cancel_reason in ('customer_early', 'customer_late') then
      perform public.customer_event_add(new.customer_id, new.worker_id, new.id, 'customer_cancel');
    elsif new.cancel_reason = 'customer_noshow' then
      perform public.customer_event_add(new.customer_id, new.worker_id, new.id, 'customer_noshow');
    end if;
  end if;
  return new;
end $$;
drop trigger if exists jobs_settle_after on public.jobs;
create trigger jobs_settle_after after update of status on public.jobs for each row execute function public.jobs_settle_after();

-- the old "shares at accepted" only for bookings made before this migration
create or replace function public.jobs_share_fee()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if not new.rules_v2 and new.status = 'matched' and old.status is distinct from 'matched' then
    perform public.pay_booking_shares(new.id);
  end if;
  return new;
end $$;

-- the "recruit bonus" (a friend's first booking): old bookings at accepted, new ones when the fee is earned
create or replace function public.trg_recruit_bonus() returns trigger language plpgsql security definer set search_path = public as $$
declare v_ref uuid; v_amt numeric; v_go boolean;
begin
  v_go := case when new.rules_v2 then (new.settle_kind = 'earned' and old.settle_kind is distinct from 'earned')
               else (new.status = 'matched' and old.status is distinct from 'matched') end;
  if not v_go then return new; end if;
  if exists (select 1 from public.recruit_bonuses b where b.worker_id = new.worker_id) then return new; end if;
  select a.referrer_id into v_ref from public.worker_applications a where a.user_id = new.worker_id and a.referrer_id is not null order by a.created_at desc limit 1;
  if v_ref is null or v_ref = new.worker_id or v_ref = new.customer_id or public.is_suspended(v_ref) then return new; end if;
  v_amt := case when public.is_seller_at(v_ref, now()) then public.growth_num('recruit_bonus', 100) else public.growth_num('recruit_bonus_customer', 50) end;
  if v_amt <= 0 then return new; end if;
  insert into public.recruit_bonuses (worker_id, referrer_id, amount, job_id) values (new.worker_id, v_ref, v_amt, new.id);
  perform set_config('app.ledger_kind', 'recruit_bonus', true);
  perform set_config('app.ledger_ref', new.worker_id::text, true);
  update public.users set bonus_balance = bonus_balance + v_amt where id = v_ref;
  return new;
end $$;

-- ---------- what the app reads ------------------------------------------------------------------------------------------------------------
create or replace function public.job_json(j public.jobs, p_for_worker boolean)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
      'id', j.id, 'status', j.status, 'created_at', j.created_at, 'scheduled_at', j.scheduled_at, 'rate_label', j.rate_label,
      'service_price', j.service_price, 'booking_fee', j.booking_fee, 'place_note', j.place_note, 'customer_note', j.customer_note,
      'accepted_at', j.accepted_at, 'arrived_at', j.arrived_at, 'cancel_reason', j.cancel_reason, 'source_label', j.source_label, 'travel_mode', j.travel_mode, 'fee', j.booking_fee,
      'expires_at', case when j.status = 'pending' then j.created_at + make_interval(mins => public.job_setting('job_response_minutes', 30)::int) end,
      'rules_v2', j.rules_v2, 'settle_kind', j.settle_kind, 'cancel_note', j.cancel_note, 'dispute_open', j.dispute_open, 'dispute_kind', j.dispute_kind,
      'customer_noshow_at', j.customer_noshow_at, 'objection_until', j.objection_until,
      'resched_to', j.resched_to, 'resched_by', j.resched_by, 'resched_status', j.resched_status)
   || case when p_for_worker then jsonb_build_object(
        'customer_name', (select u.display_name from public.users u where u.id = j.customer_id),
        'customer_phone', case when j.status in ('matched', 'completed') then (select p.customer_phone from public.job_private p where p.job_id = j.id) end,
        'place_lat', case when j.status in ('matched', 'completed') then (select p.place_lat from public.job_private p where p.job_id = j.id) end,
        'place_lng', case when j.status in ('matched', 'completed') then (select p.place_lng from public.job_private p where p.job_id = j.id) end,
        'place_url', case when j.status in ('matched', 'completed') then (select p.place_url from public.job_private p where p.job_id = j.id) end)
      else jsonb_build_object(
        'worker_id', j.worker_id,
        'worker_name', (select w.display_name from public.workers w where w.user_id = j.worker_id),
        'worker_image', (select w.profile_image from public.workers w where w.user_id = j.worker_id),
        'worker_phone', case when j.status in ('matched', 'completed') then (select w.booking_phone from public.workers w where w.user_id = j.worker_id) end,
        'worker_line_id', case when j.status in ('matched', 'completed') then (select w.booking_line_id from public.workers w where w.user_id = j.worker_id) end,
        'worker_place', case when j.status in ('matched', 'completed') then (select p.worker_place from public.job_private p where p.job_id = j.id) end,
        'worker_place_url', case when j.status in ('matched', 'completed') then (select p.worker_place_url from public.job_private p where p.job_id = j.id) end) end
$$;
revoke all on function public.job_json(public.jobs, boolean) from public, anon, authenticated;

-- ---------- the customer ------------------------------------------------------------------------------------------------------------------
-- cancel: pending (refund minus the cancel fee, free in the first minutes) or matched (>= 24 h before: minus the fee; later: no refund). The reason is sent to the provider.
create or replace function public.customer_cancel_job(p_job uuid, p_reason text, p_note text default null, p_comp numeric default 0)
returns text language plpgsql security definer set search_path = public as $$
declare j public.jobs; v_cause text; v_note text := left(nullif(btrim(concat_ws(' · ', nullif(btrim(coalesce(p_reason, '')), ''), nullif(btrim(coalesce(p_note, '')), ''))), ''), 300);
        v_comp numeric := round(coalesce(p_comp, 0), 2); v_bal numeric;
begin
  if auth.uid() is null then raise exception 'FORBIDDEN'; end if;
  select * into j from public.jobs where id = p_job and customer_id = auth.uid() for update;
  if not found then raise exception 'FORBIDDEN'; end if;
  if v_note is not null and public.contact_problem(v_note) is not null then raise exception 'CONTACT_IN_BOOKING'; end if;
  if j.status = 'pending' then
    v_cause := 'customer'; v_comp := 0;
  elsif j.status = 'matched' and j.rules_v2 then
    if j.dispute_open then raise exception 'DISPUTE_OPEN'; end if;
    v_cause := case when j.scheduled_at is not null and j.scheduled_at - now() >= make_interval(hours => public.job_setting('job_early_cancel_hours', 24)::int) then 'customer_early' else 'customer_late' end;
  else
    raise exception 'ILLEGAL_STATUS_TRANSITION';
  end if;
  if v_comp < 0 or v_comp > public.job_setting('job_comp_max', 500) then raise exception 'BAD_INPUT'; end if;
  if v_comp > 0 then
    select wallet_balance into v_bal from public.users where id = auth.uid() for update;
    if v_bal < v_comp then raise exception 'INSUFFICIENT_BALANCE'; end if;
    perform set_config('app.ledger_kind', 'compensation', true);
    perform set_config('app.ledger_ref', j.id::text, true);
    update public.users set wallet_balance = wallet_balance - v_comp where id = auth.uid();
    insert into public.job_compensation (job_id, customer_id, worker_id, amount) values (j.id, j.customer_id, j.worker_id, v_comp);
  end if;
  perform set_config('app.job_system', 'on', true);
  perform set_config('app.job_cause', v_cause, true);
  update public.jobs set status = 'cancelled', cancel_note = v_note where id = j.id;
  perform set_config('app.job_system', '', true);
  perform set_config('app.job_cause', '', true);
  return v_cause;
end $$;

-- a problem report. 'worker_noshow' settles at once when she never pressed "arrived"; everything else waits for an admin.
create or replace function public.customer_report_problem(p_job uuid, p_kind text, p_note text default null)
returns text language plpgsql security definer set search_path = public as $$
declare j public.jobs; v_note text := left(nullif(btrim(coalesce(p_note, '')), ''), 300); v_end timestamptz;
begin
  if auth.uid() is null then raise exception 'FORBIDDEN'; end if;
  if p_kind not in ('worker_noshow', 'imposter', 'mismatch', 'other') then raise exception 'BAD_INPUT'; end if;
  select * into j from public.jobs where id = p_job and customer_id = auth.uid() for update;
  if not found or j.status <> 'matched' or not j.rules_v2 or j.scheduled_at is null then raise exception 'ILLEGAL_STATUS_TRANSITION'; end if;
  if j.dispute_open then raise exception 'DISPUTE_OPEN'; end if;
  if v_note is not null and public.contact_problem(v_note) is not null then raise exception 'CONTACT_IN_BOOKING'; end if;
  v_end := j.scheduled_at + make_interval(secs => public.job_setting('job_autocomplete_hours', 3) * 3600);
  if now() > v_end then raise exception 'TOO_LATE'; end if;
  if p_kind = 'worker_noshow' then
    if now() < j.scheduled_at + make_interval(mins => public.job_setting('job_noshow_wait_minutes', 30)::int) then raise exception 'TOO_EARLY'; end if;
    if j.arrived_at is null then
      perform set_config('app.job_system', 'on', true);
      perform set_config('app.job_cause', 'worker_noshow', true);
      update public.jobs set status = 'cancelled', cancel_note = v_note where id = j.id;
      perform set_config('app.job_system', '', true);
      perform set_config('app.job_cause', '', true);
      return 'settled';
    end if;
  elsif now() < j.scheduled_at then
    raise exception 'TOO_EARLY';
  end if;
  update public.jobs set dispute_open = true, dispute_by = 'customer', dispute_kind = p_kind, dispute_note = v_note, dispute_at = now() where id = j.id;
  perform public.admin_notify('dispute', p_kind);
  perform public.push_notify(jsonb_build_object('type', 'booking', 'event', 'dispute', 'job_id', j.id));
  return 'dispute';
end $$;

-- "we met / the job is done" (optional): closes the job early
create or replace function public.customer_confirm_done(p_job uuid)
returns void language plpgsql security definer set search_path = public as $$
declare j public.jobs;
begin
  if auth.uid() is null then raise exception 'FORBIDDEN'; end if;
  select * into j from public.jobs where id = p_job and customer_id = auth.uid() for update;
  if not found or j.status <> 'matched' or not j.rules_v2 or j.dispute_open or j.scheduled_at is null then raise exception 'ILLEGAL_STATUS_TRANSITION'; end if;
  if now() < j.scheduled_at - interval '30 minutes' then raise exception 'TOO_EARLY'; end if;
  perform set_config('app.job_system', 'on', true);
  update public.jobs set status = 'completed' where id = j.id;
  perform set_config('app.job_system', '', true);
end $$;

-- the customer says "I was there": the claim becomes a dispute for an admin
create or replace function public.customer_object_noshow(p_job uuid, p_note text default null)
returns void language plpgsql security definer set search_path = public as $$
declare j public.jobs;
begin
  if auth.uid() is null then raise exception 'FORBIDDEN'; end if;
  select * into j from public.jobs where id = p_job and customer_id = auth.uid() for update;
  if not found or j.status <> 'matched' or j.customer_noshow_at is null or j.dispute_open or j.objection_until < now() then raise exception 'ILLEGAL_STATUS_TRANSITION'; end if;
  update public.jobs set dispute_open = true, dispute_by = 'customer', dispute_kind = 'customer_noshow_claim', dispute_note = left(nullif(btrim(coalesce(p_note, '')), ''), 300), dispute_at = now() where id = j.id;
  perform public.admin_notify('dispute', 'customer_noshow_claim');
end $$;

-- ---------- the provider ------------------------------------------------------------------------------------------------------------------
create or replace function public.worker_report_customer_noshow(p_job uuid)
returns void language plpgsql security definer set search_path = public as $$
declare j public.jobs;
begin
  if auth.uid() is null then raise exception 'FORBIDDEN'; end if;
  select * into j from public.jobs where id = p_job and worker_id = auth.uid() for update;
  if not found or j.status <> 'matched' or not j.rules_v2 or j.dispute_open or j.customer_noshow_at is not null or j.arrived_at is null then raise exception 'ILLEGAL_STATUS_TRANSITION'; end if;
  if now() < j.arrived_at + make_interval(mins => public.job_setting('job_noshow_wait_minutes', 30)::int) then raise exception 'TOO_EARLY'; end if;
  update public.jobs set customer_noshow_at = now(), objection_until = now() + make_interval(hours => public.job_setting('job_objection_hours', 6)::int) where id = j.id;
  perform public.push_notify(jsonb_build_object('type', 'booking', 'event', 'noshow_claim', 'job_id', j.id));
end $$;

-- the reason she writes after the warning
create or replace function public.worker_strike_reason(p_event uuid, p_text text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'FORBIDDEN'; end if;
  if public.contact_problem(coalesce(p_text, '')) is not null then raise exception 'CONTACT_IN_BOOKING'; end if;
  update public.job_events set worker_reason = left(nullif(btrim(coalesce(p_text, '')), ''), 300) where id = p_event and worker_id = auth.uid() and kind = 'worker_fault';
  if not found then raise exception 'NOT_FOUND'; end if;
end $$;

create or replace function public.my_strike_status()
returns table (strikes int, blocked boolean, block_kind text, fine_due numeric, bonus_balance numeric, wallet_balance numeric, last_event uuid, last_reason text)
language sql stable security definer set search_path = public as $$
  select coalesce(s.strikes, 0), coalesce(s.blocked, false), s.block_kind, coalesce(s.fine_due, 0), u.bonus_balance, u.wallet_balance,
         (select e.id from public.job_events e where e.worker_id = auth.uid() and e.kind = 'worker_fault' and e.voided_at is null order by e.at desc limit 1),
         (select e.worker_reason from public.job_events e where e.worker_id = auth.uid() and e.kind = 'worker_fault' and e.voided_at is null order by e.at desc limit 1)
    from public.users u left join public.worker_strikes s on s.worker_id = u.id where u.id = auth.uid()
$$;

-- pay the fine: the bonus balance first, the rest from the Wallet (top the Wallet up the usual way if it is not enough)
create or replace function public.worker_pay_fine()
returns void language plpgsql security definer set search_path = public as $$
declare s public.worker_strikes; u public.users; v_b numeric; v_w numeric;
begin
  if auth.uid() is null then raise exception 'FORBIDDEN'; end if;
  select * into s from public.worker_strikes where worker_id = auth.uid() for update;
  if not found or not s.blocked or s.block_kind <> 'fine' or s.fine_due <= 0 then raise exception 'NOT_FOUND'; end if;
  select * into u from public.users where id = auth.uid() for update;
  v_b := least(u.bonus_balance, s.fine_due);
  v_w := s.fine_due - v_b;
  if u.wallet_balance < v_w then raise exception 'INSUFFICIENT_BALANCE'; end if;
  perform set_config('app.ledger_kind', 'penalty_fine', true);
  perform set_config('app.ledger_ref', auth.uid()::text, true);
  update public.users set bonus_balance = bonus_balance - v_b, wallet_balance = wallet_balance - v_w where id = auth.uid();
  update public.worker_strikes set blocked = false, fine_due = 0, updated_at = now() where worker_id = auth.uid();
end $$;

-- the three numbers on her page (90 days). Shown only when she accepted at least one booking in that time.
create or replace function public.worker_reliability(p_worker uuid)
returns table (shown boolean, worker_faults int, customer_noshows int, customer_cancels int)
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.jobs j where j.worker_id = p_worker and j.accepted_at > now() - interval '90 days'),
         (select count(*)::int from public.job_events e where e.worker_id = p_worker and e.kind = 'worker_fault' and e.voided_at is null and e.at > now() - interval '90 days'),
         (select count(*)::int from public.job_events e where e.worker_id = p_worker and e.kind = 'customer_noshow' and e.voided_at is null and e.at > now() - interval '90 days'),
         (select count(*)::int from public.job_events e where e.worker_id = p_worker and e.kind = 'customer_cancel' and e.voided_at is null and e.at > now() - interval '90 days')
$$;

-- ---------- reschedule (one agreed change per job) ---------------------------------------------------------------------------------------
create or replace function public.job_request_reschedule(p_job uuid, p_new timestamptz)
returns void language plpgsql security definer set search_path = public as $$
declare j public.jobs; v_by text;
begin
  if auth.uid() is null then raise exception 'FORBIDDEN'; end if;
  select * into j from public.jobs where id = p_job and (customer_id = auth.uid() or worker_id = auth.uid()) for update;
  if not found or j.status <> 'matched' or not j.rules_v2 or j.dispute_open or j.resched_status is not null or j.scheduled_at is null then raise exception 'ILLEGAL_STATUS_TRANSITION'; end if;
  if now() > j.scheduled_at - make_interval(hours => public.job_setting('job_resched_notice_hours', 3)::int) then raise exception 'TOO_LATE'; end if;
  if p_new is null or p_new <= now() + interval '30 minutes' or p_new > now() + interval '30 days' or p_new = j.scheduled_at then raise exception 'BAD_TIME'; end if;
  v_by := case when auth.uid() = j.customer_id then 'customer' else 'worker' end;
  update public.jobs set resched_to = p_new, resched_by = v_by, resched_status = 'pending', resched_at = now() where id = j.id;
  perform public.push_notify(jsonb_build_object('type', 'booking', 'event', 'resched_request', 'job_id', j.id));
end $$;

-- the OTHER side answers. Accepting = both agreed: the job is completed (fee earned, shares paid now)
create or replace function public.job_answer_reschedule(p_job uuid, p_accept boolean)
returns void language plpgsql security definer set search_path = public as $$
declare j public.jobs; v_me text;
begin
  if auth.uid() is null then raise exception 'FORBIDDEN'; end if;
  select * into j from public.jobs where id = p_job and (customer_id = auth.uid() or worker_id = auth.uid()) for update;
  if not found or j.resched_status <> 'pending' or j.status <> 'matched' then raise exception 'ILLEGAL_STATUS_TRANSITION'; end if;
  v_me := case when auth.uid() = j.customer_id then 'customer' else 'worker' end;
  if v_me = j.resched_by then raise exception 'FORBIDDEN'; end if;
  if p_accept then
    update public.jobs set resched_status = 'accepted' where id = j.id;
    perform set_config('app.job_system', 'on', true);
    update public.jobs set status = 'completed' where id = j.id;
    perform set_config('app.job_system', '', true);
    perform public.push_notify(jsonb_build_object('type', 'booking', 'event', 'resched_accepted', 'job_id', j.id));
  else
    update public.jobs set resched_status = 'declined' where id = j.id;
    perform public.push_notify(jsonb_build_object('type', 'booking', 'event', 'resched_declined', 'job_id', j.id));
  end if;
end $$;

-- ---------- the clock ----------------------------------------------------------------------------------------------------------------------------
create or replace function public.expire_pending_jobs()
returns int language plpgsql security definer set search_path = public as $$
declare n int;
begin
  perform set_config('app.job_expiry', 'on', true);
  update public.jobs set status = 'cancelled'
   where status = 'pending' and created_at < now() - make_interval(mins => public.job_setting('job_response_minutes', 30)::int);
  get diagnostics n = row_count;
  perform set_config('app.job_expiry', '', true);
  return n;
end $$;

create or replace function public.job_tick()
returns int language plpgsql security definer set search_path = public as $$
declare n int := 0; k int;
begin
  n := public.expire_pending_jobs();
  -- a pending reschedule nobody answered an hour before the date is declined
  update public.jobs set resched_status = 'declined' where status = 'matched' and resched_status = 'pending' and scheduled_at - interval '1 hour' < now();
  perform set_config('app.job_system', 'on', true);
  -- "customer did not come": nobody objected in time -> the fee is earned
  perform set_config('app.job_cause', 'customer_noshow', true);
  update public.jobs set status = 'cancelled' where status = 'matched' and rules_v2 and not dispute_open and customer_noshow_at is not null and objection_until < now();
  get diagnostics k = row_count; n := n + k;
  -- nobody reported a problem until the date + N hours -> completed
  perform set_config('app.job_cause', '', true);
  update public.jobs set status = 'completed'
   where status = 'matched' and rules_v2 and not dispute_open and customer_noshow_at is null and resched_status is distinct from 'pending'
     and scheduled_at is not null and scheduled_at + make_interval(secs => public.job_setting('job_autocomplete_hours', 3) * 3600) < now();
  get diagnostics k = row_count; n := n + k;
  perform set_config('app.job_system', '', true);
  return n;
end $$;
revoke all on function public.expire_pending_jobs(), public.job_tick() from public, anon, authenticated;

do $$ begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(jobid) from cron.job where jobname in ('expire-pending-jobs', 'job-tick');
    perform cron.schedule('job-tick', '* * * * *', 'select public.job_tick()');
  end if;
exception when others then raise notice 'pg_cron: %', sqlerrm;
end $$;

-- ---------- admin -------------------------------------------------------------------------------------------------------------------------------
create or replace function public.admin_disputes(p_open boolean default true)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform public.assert_admin();
  return coalesce((select jsonb_agg(x order by x->>'dispute_at' desc) from (
    select jsonb_build_object('job_id', j.id, 'dispute_kind', j.dispute_kind, 'dispute_by', j.dispute_by, 'dispute_note', j.dispute_note, 'dispute_at', j.dispute_at,
        'status', j.status, 'scheduled_at', j.scheduled_at, 'arrived_at', j.arrived_at, 'customer_noshow_at', j.customer_noshow_at, 'booking_fee', j.booking_fee,
        'resolution', j.resolution, 'resolved_at', j.resolved_at, 'cancel_reason', j.cancel_reason,
        'customer_id', j.customer_id, 'customer_name', cu.display_name, 'worker_id', j.worker_id, 'worker_name', w.display_name,
        'worker_90d', (select to_jsonb(r) from public.worker_reliability(j.worker_id) r),
        'customer_90d', (select count(*) from public.job_events e where e.customer_id = j.customer_id and e.kind in ('customer_noshow', 'customer_cancel') and e.voided_at is null and e.at > now() - interval '90 days')) as x
      from public.jobs j join public.users cu on cu.id = j.customer_id join public.workers w on w.user_id = j.worker_id
     where (p_open and j.dispute_open) or (not p_open and j.resolved_at is not null)
     order by j.dispute_at desc limit 100) q), '[]'::jsonb);
end $$;

-- decision: 'customer' (the report is right) | 'worker' (it is not) | 'none' (nobody is at fault). p_strike: with 'customer', count it against the provider
create or replace function public.admin_dispute_resolve(p_job uuid, p_decision text, p_note text default null, p_strike boolean default true)
returns void language plpgsql security definer set search_path = public as $$
declare j public.jobs; v_cause text;
begin
  perform public.assert_admin();
  if p_decision not in ('customer', 'worker', 'none') then raise exception 'BAD_INPUT'; end if;
  select * into j from public.jobs where id = p_job for update;
  if not found or not j.dispute_open or j.status <> 'matched' then raise exception 'NOT_FOUND'; end if;
  v_cause := case
    when p_decision = 'none' then 'admin_refund'
    when j.dispute_kind = 'customer_noshow_claim' then case when p_decision = 'worker' then 'customer_noshow' else 'admin_refund' end
    when p_decision = 'worker' then 'customer_late'                                  -- the customer's report was not upheld: it counts as his cancellation
    else case j.dispute_kind when 'worker_noshow' then 'worker_noshow' when 'imposter' then 'imposter' when 'mismatch' then 'mismatch' else 'worker_fault_other' end
  end;
  if not coalesce(p_strike, true) then perform set_config('app.no_strike', 'on', true); end if;
  perform set_config('app.job_system', 'on', true);
  perform set_config('app.job_cause', v_cause, true);
  update public.jobs set status = 'cancelled', dispute_open = false, resolved_at = now(), resolution = p_decision || coalesce(': ' || left(p_note, 200), '') where id = j.id;
  perform set_config('app.job_system', '', true);
  perform set_config('app.job_cause', '', true);
  perform set_config('app.no_strike', '', true);
end $$;

create or replace function public.admin_job_events(p_worker uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform public.assert_admin();
  return coalesce((select jsonb_agg(jsonb_build_object('id', e.id, 'kind', e.kind, 'detail', e.detail, 'at', e.at, 'worker_reason', e.worker_reason, 'voided_at', e.voided_at,
            'void_reason', e.void_reason, 'job_id', e.job_id) order by e.at desc)
            from public.job_events e where e.worker_id = p_worker and e.at > now() - interval '180 days'), '[]'::jsonb);
end $$;

-- "do not count this one": the reason is required and kept. A provider fault that is voided also takes one off her counter.
create or replace function public.admin_event_void(p_event uuid, p_reason text)
returns void language plpgsql security definer set search_path = public as $$
declare e public.job_events; s public.worker_strikes;
begin
  perform public.assert_admin();
  if char_length(btrim(coalesce(p_reason, ''))) < 3 then raise exception 'BAD_INPUT'; end if;
  select * into e from public.job_events where id = p_event and voided_at is null for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  update public.job_events set voided_at = now(), voided_by = auth.uid(), void_reason = left(btrim(p_reason), 300) where id = e.id;
  if e.kind = 'worker_fault' then
    update public.worker_strikes set strikes = greatest(strikes - 1, 0), updated_at = now() where worker_id = e.worker_id returning * into s;
    if found and s.blocked and s.block_kind = 'fine' and s.strikes < public.job_setting('penalty_from', 2) then
      update public.worker_strikes set blocked = false, fine_due = 0 where worker_id = e.worker_id;
    end if;
  end if;
end $$;

create or replace function public.admin_strikes()
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform public.assert_admin();
  return coalesce((select jsonb_agg(jsonb_build_object('worker_id', s.worker_id, 'name', w.display_name, 'strikes', s.strikes, 'blocked', s.blocked,
            'block_kind', s.block_kind, 'fine_due', s.fine_due, 'updated_at', s.updated_at) order by s.blocked desc, s.strikes desc)
            from public.worker_strikes s join public.workers w on w.user_id = s.worker_id where s.strikes > 0 or s.blocked), '[]'::jsonb);
end $$;

create or replace function public.admin_strike_set(p_worker uuid, p_count int)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public.assert_admin();
  if p_count is null or p_count < 0 or p_count > 99 then raise exception 'BAD_INPUT'; end if;
  insert into public.worker_strikes (worker_id, strikes) values (p_worker, p_count)
  on conflict (worker_id) do update set strikes = p_count, updated_at = now();
  update public.worker_strikes set blocked = false, fine_due = 0, block_kind = null
   where worker_id = p_worker and block_kind = 'fine' and p_count < public.job_setting('penalty_from', 2);
end $$;

-- unblock (e.g. after the selfie check of "someone else came", or when the fine is waived)
create or replace function public.admin_worker_unblock(p_worker uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public.assert_admin();
  update public.worker_strikes set blocked = false, fine_due = 0, block_kind = null, updated_at = now() where worker_id = p_worker;
end $$;

create or replace function public.admin_compensations(p_status text default 'pending')
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform public.assert_admin();
  return coalesce((select jsonb_agg(jsonb_build_object('job_id', c.job_id, 'amount', c.amount, 'status', c.status, 'credited_amount', c.credited_amount, 'at', c.created_at,
            'customer_name', cu.display_name, 'worker_id', c.worker_id, 'worker_name', w.display_name, 'note', j.cancel_note) order by c.created_at desc)
            from public.job_compensation c join public.users cu on cu.id = c.customer_id join public.workers w on w.user_id = c.worker_id join public.jobs j on j.id = c.job_id
           where c.status = p_status), '[]'::jsonb);
end $$;

-- credit the provider's Wallet from the compensation the customer paid (default: all of it)
create or replace function public.admin_compensation_credit(p_job uuid, p_amount numeric default null)
returns void language plpgsql security definer set search_path = public as $$
declare c public.job_compensation; v_amt numeric;
begin
  perform public.assert_admin();
  select * into c from public.job_compensation where job_id = p_job and status = 'pending' for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  v_amt := round(coalesce(p_amount, c.amount), 2);
  if v_amt <= 0 or v_amt > c.amount then raise exception 'BAD_INPUT'; end if;
  perform set_config('app.ledger_kind', 'compensation_credit', true);
  perform set_config('app.ledger_ref', p_job::text, true);
  update public.users set wallet_balance = wallet_balance + v_amt where id = c.worker_id;
  update public.job_compensation set status = 'credited', credited_amount = v_amt, decided_at = now(), decided_by = auth.uid() where job_id = p_job;
end $$;

create or replace function public.admin_compensation_dismiss(p_job uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public.assert_admin();
  update public.job_compensation set status = 'dismissed', decided_at = now(), decided_by = auth.uid() where job_id = p_job and status = 'pending';
end $$;

create or replace function public.admin_job_settings()
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform public.assert_admin();
  return public.job_rules() || jsonb_build_object('penalty_step', public.job_setting('penalty_step', 100), 'penalty_from', public.job_setting('penalty_from', 2),
    'cust_pause_count', public.job_setting('cust_pause_count', 3), 'cust_pause_days', public.job_setting('cust_pause_days', 3),
    'cust_pause_window_days', public.job_setting('cust_pause_window_days', 30));
end $$;

revoke all on function public.job_rules(), public.customer_cancel_job(uuid, text, text, numeric), public.customer_report_problem(uuid, text, text), public.customer_confirm_done(uuid),
  public.customer_object_noshow(uuid, text), public.worker_report_customer_noshow(uuid), public.worker_strike_reason(uuid, text), public.my_strike_status(), public.worker_pay_fine(),
  public.worker_reliability(uuid), public.job_request_reschedule(uuid, timestamptz), public.job_answer_reschedule(uuid, boolean),
  public.admin_disputes(boolean), public.admin_dispute_resolve(uuid, text, text, boolean), public.admin_job_events(uuid), public.admin_event_void(uuid, text), public.admin_strikes(),
  public.admin_strike_set(uuid, int), public.admin_worker_unblock(uuid), public.admin_compensations(text), public.admin_compensation_credit(uuid, numeric),
  public.admin_compensation_dismiss(uuid), public.admin_job_settings() from public, anon;
grant execute on function public.job_rules(), public.customer_cancel_job(uuid, text, text, numeric), public.customer_report_problem(uuid, text, text), public.customer_confirm_done(uuid),
  public.customer_object_noshow(uuid, text), public.worker_report_customer_noshow(uuid), public.worker_strike_reason(uuid, text), public.my_strike_status(), public.worker_pay_fine(),
  public.worker_reliability(uuid), public.job_request_reschedule(uuid, timestamptz), public.job_answer_reschedule(uuid, boolean),
  public.admin_disputes(boolean), public.admin_dispute_resolve(uuid, text, text, boolean), public.admin_job_events(uuid), public.admin_event_void(uuid, text), public.admin_strikes(),
  public.admin_strike_set(uuid, int), public.admin_worker_unblock(uuid), public.admin_compensations(text), public.admin_compensation_credit(uuid, numeric),
  public.admin_compensation_dismiss(uuid), public.admin_job_settings() to authenticated;
