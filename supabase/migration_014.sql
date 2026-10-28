-- =============================================================================
-- migration_014.sql — run ONCE after migration_013.sql
-- Step 1 of the revenue-sharing plan: two balances + a ledger of every movement.
--   wallet_balance : top-ups; pays for packages / chat / booking. NOT withdrawable.
--   bonus_balance  : referral / commission / chat income. Withdrawable later (min 200) or moved to the wallet.
-- Every change of either balance is written to public.wallet_ledger by a trigger, so no code path can
-- move money without leaving a trace. The existing money paths below only add a label for the entry.
-- =============================================================================

alter table public.users
  add column if not exists bonus_balance numeric(12,2) not null default 0 check (bonus_balance >= 0);

create table if not exists public.wallet_ledger (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references public.users (id) on delete cascade,
  wallet        text not null check (wallet in ('wallet', 'bonus')),
  amount        numeric(12,2) not null check (amount <> 0),       -- signed: + in, - out
  balance_after numeric(12,2) not null,
  kind          text not null,       -- opening | topup | booking_fee | booking_refund | bonus_transfer_out | bonus_transfer_in | adjustment | ...
  ref           text,                -- id of the payment / job / admin that caused it
  note          text,
  created_at    timestamptz not null default now()
);
create index if not exists wallet_ledger_user_idx on public.wallet_ledger (user_id, created_at desc);
alter table public.wallet_ledger enable row level security;
revoke all on public.wallet_ledger from anon, authenticated;
grant select on public.wallet_ledger to authenticated;
drop policy if exists wallet_ledger_own on public.wallet_ledger;
create policy wallet_ledger_own on public.wallet_ledger for select to authenticated using (user_id = auth.uid());

-- Opening entries for balances that already exist (only for users that have no ledger rows yet).
insert into public.wallet_ledger (user_id, wallet, amount, balance_after, kind, note)
select u.id, 'wallet', u.wallet_balance, u.wallet_balance, 'opening', 'balance before the ledger existed'
  from public.users u
 where u.wallet_balance > 0 and not exists (select 1 from public.wallet_ledger l where l.user_id = u.id);

-- Callers label the entry with set_config('app.ledger_kind' / 'app.ledger_ref' / 'app.ledger_note', ..., true)
-- right before updating a balance; the label is cleared after every ledgered update.
create or replace function public.users_ledger()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  k text := coalesce(nullif(current_setting('app.ledger_kind', true), ''), 'adjustment');
  r text := nullif(current_setting('app.ledger_ref', true), '');
  n text := nullif(current_setting('app.ledger_note', true), '');
begin
  if new.wallet_balance <> old.wallet_balance then
    insert into public.wallet_ledger (user_id, wallet, amount, balance_after, kind, ref, note)
    values (new.id, 'wallet', new.wallet_balance - old.wallet_balance, new.wallet_balance, k, r, n);
  end if;
  if new.bonus_balance <> old.bonus_balance then
    insert into public.wallet_ledger (user_id, wallet, amount, balance_after, kind, ref, note)
    values (new.id, 'bonus', new.bonus_balance - old.bonus_balance, new.bonus_balance, k, r, n);
  end if;
  perform set_config('app.ledger_kind', '', true);
  perform set_config('app.ledger_ref', '', true);
  perform set_config('app.ledger_note', '', true);
  return new;
end $$;
drop trigger if exists users_ledger on public.users;
create trigger users_ledger after update of wallet_balance, bonus_balance on public.users
  for each row when (old.wallet_balance is distinct from new.wallet_balance or old.bonus_balance is distinct from new.bonus_balance)
  execute function public.users_ledger();

-- ---------- Existing money paths: add the label only --------------------------
create or replace function public.jobs_before_insert()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_fee     numeric := public.platform_booking_fee();
  v_price   numeric;
  v_balance numeric;
begin
  if auth.uid() is not null and new.customer_id <> auth.uid() then
    raise exception 'FORBIDDEN';
  end if;
  if new.worker_id = new.customer_id then
    raise exception 'FORBIDDEN';
  end if;
  -- Must be allowed to see this worker (tier + category + top-10 rule).
  if auth.uid() is not null and not public.can_view_worker(new.worker_id) then
    raise exception 'LOCKED';
  end if;

  select price into v_price from public.workers
   where user_id = new.worker_id and is_online;
  if not found then
    raise exception 'WORKER_UNAVAILABLE';
  end if;

  select wallet_balance into v_balance from public.users
   where id = new.customer_id for update;
  if v_balance is null or v_balance < v_fee then
    raise exception 'INSUFFICIENT_BALANCE';
  end if;

  perform set_config('app.ledger_kind', 'booking_fee', true);

  perform set_config('app.ledger_ref', new.id::text, true);

  update public.users set wallet_balance = wallet_balance - v_fee where id = new.customer_id;

  new.booking_fee   := v_fee;
  new.service_price := v_price;
  new.status        := 'pending';
  return new;
end $$;

create or replace function public.jobs_guard_update()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
begin
  if new.status = old.status then return new; end if;

  if me is not null then
    if not (
      (me = new.customer_id and old.status = 'pending' and new.status = 'cancelled')
      or (me = new.worker_id and (
            (old.status = 'pending' and new.status in ('matched', 'cancelled'))
         or (old.status = 'matched' and new.status in ('completed', 'cancelled'))))
    ) then
      raise exception 'ILLEGAL_STATUS_TRANSITION';
    end if;
  end if;

  if old.status = 'pending' and new.status = 'cancelled' then
    perform set_config('app.ledger_kind', 'booking_refund', true);
    perform set_config('app.ledger_ref', old.id::text, true);
    update public.users set wallet_balance = wallet_balance + old.booking_fee where id = old.customer_id;
  end if;
  return new;
end $$;

create or replace function public.admin_record_payment(
  p_user uuid, p_kind text, p_tier int, p_days int, p_amount numeric,
  p_method text, p_request_id uuid, p_reference text default null, p_note text default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v uuid;
  v_idx text;
begin
  perform public.assert_admin();
  if p_request_id is null then raise exception 'BAD_INPUT'; end if;
  if not exists (select 1 from public.users where id = p_user) then raise exception 'USER_NOT_FOUND'; end if;
  if p_kind = 'membership' and (coalesce(p_tier, 0) not between 1 and 3 or coalesce(p_days, 0) not between 1 and 365) then
    raise exception 'BAD_INPUT';
  end if;

  -- The same submission arriving twice (double tap, retry after a slow network): refuse, change nothing.
  if exists (select 1 from public.payments where request_id = p_request_id) then
    raise exception 'DUPLICATE_REQUEST';
  end if;

  begin
    insert into public.payments (user_id, kind, tier, days, amount, method, reference, note, recorded_by, request_id)
    values (p_user, p_kind,
            case when p_kind = 'membership' then p_tier end,
            case when p_kind = 'membership' then p_days end,
            p_amount, p_method, nullif(btrim(p_reference), ''), nullif(btrim(p_note), ''), auth.uid(), p_request_id)
    returning id into v;
  exception when unique_violation then
    get stacked diagnostics v_idx = constraint_name;        -- two simultaneous taps hit the unique index
    if v_idx = 'payments_request_unique' then raise exception 'DUPLICATE_REQUEST'; end if;
    raise exception 'DUPLICATE_REFERENCE';
  end;

  if p_kind = 'membership' then
    perform public.set_membership(p_user, p_tier, p_days);
  else
    perform set_config('app.ledger_kind', 'topup', true);
    perform set_config('app.ledger_ref', v::text, true);
    update public.users set wallet_balance = wallet_balance + p_amount where id = p_user;
  end if;
  return v;
end $$;

create or replace function public.apply_slip_payment(p_user uuid, p_amount numeric, p_trans_ref text)
returns table (kind text, tier int, days int, paid numeric)
language plpgsql security definer set search_path = public as $$
declare
  i     public.payment_intents;
  v_pay uuid;
  v_cur int;
begin
  if exists (select 1 from public.payment_reviews where trans_ref = p_trans_ref) then
    raise exception 'DUPLICATE_SLIP';
  end if;

  select * into i from public.payment_intents
   where user_id = p_user and status = 'pending' and expires_at > now() and amount = p_amount
   order by created_at desc limit 1
   for update;
  if not found then raise exception 'NO_MATCHING_INTENT'; end if;

  -- An upgrade only makes sense while the lower plan is still running; otherwise the admin decides.
  if i.is_upgrade then
    select coalesce((select vip_tier from public.users where id = p_user and vip_expires_at > now()), 0) into v_cur;
    if v_cur = 0 or v_cur >= i.tier then raise exception 'NO_MATCHING_INTENT'; end if;
  end if;

  begin
    insert into public.payments (user_id, kind, tier, days, amount, method, reference, note, recorded_by, source)
    values (p_user, i.kind, i.tier, i.days, i.amount, 'promptpay', p_trans_ref,
            case when i.is_upgrade then 'auto: upgrade (difference), expiry unchanged' else 'auto: slip verified' end,
            null, 'slip_auto')
    returning id into v_pay;
  exception when unique_violation then
    raise exception 'DUPLICATE_SLIP';
  end;

  update public.payment_intents set status = 'paid', paid_at = now(), payment_id = v_pay where id = i.id;

  if i.kind = 'membership' then
    if i.is_upgrade then
      update public.users set vip_tier = i.tier where id = p_user;          -- same expiry date
      insert into public.membership_events (user_id, action, old_tier, new_tier, new_expires, reason)
      select p_user, 'set_membership', v_cur, i.tier, vip_expires_at, 'upgrade (paid difference)'
        from public.users where id = p_user;
    else
      perform public.set_membership(p_user, i.tier, i.days);
    end if;
  else
    perform set_config('app.ledger_kind', 'topup', true);
    perform set_config('app.ledger_ref', v_pay::text, true);
    update public.users set wallet_balance = wallet_balance + i.amount where id = p_user;
  end if;

  return query select i.kind, i.tier::int, i.days, i.amount;
end $$;

create or replace function public.admin_resolve_review(
  p_review uuid, p_approve boolean, p_kind text, p_tier int, p_days int, p_request_id uuid, p_reason text default null)
returns void language plpgsql security definer set search_path = public as $$
declare
  r        public.payment_reviews;
  v_pay    uuid;
  v_thread uuid;
  v_idx    text;
  v_msg    text;
begin
  perform public.assert_admin();
  select * into r from public.payment_reviews where id = p_review and status = 'pending' for update;
  if not found then raise exception 'NOT_FOUND'; end if;

  if p_approve then
    if p_request_id is null then raise exception 'BAD_INPUT'; end if;
    if p_kind not in ('membership', 'wallet_topup')
       or (p_kind = 'membership' and (coalesce(p_tier, 0) not between 1 and 3 or coalesce(p_days, 0) not between 1 and 365)) then
      raise exception 'BAD_INPUT';
    end if;
    if exists (select 1 from public.payments where request_id = p_request_id) then raise exception 'DUPLICATE_REQUEST'; end if;

    begin
      insert into public.payments (user_id, kind, tier, days, amount, method, reference, note, recorded_by, request_id)
      values (r.user_id, p_kind,
              case when p_kind = 'membership' then p_tier end,
              case when p_kind = 'membership' then p_days end,
              r.paid_amount, 'bank_transfer', r.trans_ref, 'approved from slip review', auth.uid(), p_request_id)
      returning id into v_pay;
    exception when unique_violation then
      get stacked diagnostics v_idx = constraint_name;
      if v_idx = 'payments_request_unique' then raise exception 'DUPLICATE_REQUEST'; end if;
      raise exception 'DUPLICATE_REFERENCE';
    end;

    if p_kind = 'membership' then
      perform public.set_membership(r.user_id, p_tier, p_days);
    else
      perform set_config('app.ledger_kind', 'topup', true);
      perform set_config('app.ledger_ref', v_pay::text, true);
      update public.users set wallet_balance = wallet_balance + r.paid_amount where id = r.user_id;
    end if;

    update public.payment_reviews set status = 'approved', resolved_by = auth.uid(), resolved_at = now(), payment_id = v_pay
     where id = p_review;
    update public.payment_intents set status = 'expired' where user_id = r.user_id and status = 'pending';
    v_msg := '✅ แอดมินตรวจสลิปแล้ว: อนุมัติ' || case when p_kind = 'membership' then ' เปิดสิทธิ์สมาชิกให้เรียบร้อย' else ' เติมเงินเข้า Wallet เรียบร้อย' end;
  else
    update public.payment_reviews
       set status = 'rejected', reject_reason = left(nullif(btrim(p_reason), ''), 300),
           resolved_by = auth.uid(), resolved_at = now()
     where id = p_review;
    v_msg := '❌ แอดมินตรวจสลิปแล้ว: ไม่อนุมัติ' || coalesce(' — ' || left(nullif(btrim(p_reason), ''), 300), '');
  end if;

  insert into public.support_threads (user_id) values (r.user_id) on conflict (user_id) do nothing;
  select id into v_thread from public.support_threads where user_id = r.user_id;
  insert into public.support_messages (thread_id, sender_id, from_admin, kind, body)
  values (v_thread, auth.uid(), true, 'system', v_msg);
  update public.support_threads set last_message_at = now(), admin_last_read = now() where id = v_thread;
end $$;

-- ---------- Bonus -> wallet (one way) ------------------------------------------
create or replace function public.transfer_bonus_to_wallet(p_amount numeric)
returns void language plpgsql security definer set search_path = public as $$
declare v numeric;
begin
  if auth.uid() is null then raise exception 'FORBIDDEN'; end if;
  if public.is_suspended(auth.uid()) then raise exception 'SUSPENDED'; end if;
  if p_amount is null or p_amount <= 0 or p_amount <> round(p_amount, 2) then raise exception 'BAD_INPUT'; end if;
  select bonus_balance into v from public.users where id = auth.uid() for update;
  if v is null or v < p_amount then raise exception 'INSUFFICIENT_BONUS'; end if;
  perform set_config('app.ledger_kind', 'bonus_transfer_out', true);
  update public.users set bonus_balance = bonus_balance - p_amount where id = auth.uid();
  perform set_config('app.ledger_kind', 'bonus_transfer_in', true);
  update public.users set wallet_balance = wallet_balance + p_amount where id = auth.uid();
end $$;
revoke all on function public.transfer_bonus_to_wallet(numeric) from public, anon;
grant execute on function public.transfer_bonus_to_wallet(numeric) to authenticated;

-- ---------- Admin: manual correction (needs a reason, is ledgered) ------------
create or replace function public.admin_adjust_balance(p_user uuid, p_wallet text, p_amount numeric, p_reason text)
returns void language plpgsql security definer set search_path = public as $$
declare v numeric;
begin
  perform public.assert_admin();
  if p_wallet not in ('wallet', 'bonus') or p_amount is null or p_amount = 0 or abs(p_amount) > 100000
     or p_amount <> round(p_amount, 2) then raise exception 'BAD_INPUT'; end if;
  if char_length(btrim(coalesce(p_reason, ''))) < 2 then raise exception 'REASON_REQUIRED'; end if;
  select case p_wallet when 'wallet' then wallet_balance else bonus_balance end into v
    from public.users where id = p_user for update;
  if not found then raise exception 'USER_NOT_FOUND'; end if;
  if v + p_amount < 0 then raise exception 'INSUFFICIENT_BALANCE'; end if;
  perform set_config('app.ledger_kind', 'adjustment', true);
  perform set_config('app.ledger_ref', auth.uid()::text, true);
  perform set_config('app.ledger_note', left(btrim(p_reason), 200), true);
  if p_wallet = 'wallet' then
    update public.users set wallet_balance = wallet_balance + p_amount where id = p_user;
  else
    update public.users set bonus_balance = bonus_balance + p_amount where id = p_user;
  end if;
end $$;
revoke all on function public.admin_adjust_balance(uuid, text, numeric, text) from public, anon;
grant execute on function public.admin_adjust_balance(uuid, text, numeric, text) to authenticated;
-- =============================================================================
