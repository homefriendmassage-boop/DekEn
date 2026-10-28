-- =============================================================================
-- migration_007.sql — run ONCE after migration_006.sql
-- Automatic payment: PromptPay QR with a unique amount + slip verification (Thunder).
--
-- How a payment is matched without trusting the browser:
--   1. The customer asks for a payment "intent": plan price + a random satang suffix
--      (e.g. 100.37). The suffix is unique among all pending intents.
--   2. They pay that exact amount (the QR has it pre-filled) and attach the slip.
--   3. The Edge Function sends the slip's QR payload to Thunder, checks the receiver,
--      and calls apply_slip_payment(): the slip amount must equal one of the user's
--      pending intents, and the transfer reference can only ever be used once.
-- An old slip can't be replayed: its amount won't match a fresh unique intent.
-- =============================================================================

-- ---------- payments: allow system-recorded entries --------------------------
alter table public.payments alter column recorded_by drop not null;   -- NULL = automatic
alter table public.payments
  add column if not exists source text not null default 'admin' check (source in ('admin', 'slip_auto'));

-- ---------- Intents ----------------------------------------------------------
create table if not exists public.payment_intents (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references public.users (id) on delete cascade,
  kind        text not null check (kind in ('membership', 'wallet_topup')),
  tier        smallint check (tier between 1 and 3),
  days        int check (days between 1 and 365),
  base_amount numeric(12,2) not null,
  amount      numeric(12,2) not null,                -- base + satang suffix: what must be transferred
  status      text not null default 'pending' check (status in ('pending', 'paid', 'expired')),
  created_at  timestamptz not null default now(),
  expires_at  timestamptz not null,
  paid_at     timestamptz,
  payment_id  uuid references public.payments (id),
  check (kind = 'wallet_topup' or (tier is not null and days is not null))
);
-- No two pending intents may share an amount (that's what makes the amount an identifier).
create unique index if not exists payment_intents_pending_amount on public.payment_intents (amount) where status = 'pending';
create index if not exists payment_intents_user_idx on public.payment_intents (user_id, created_at desc);
alter table public.payment_intents enable row level security;
revoke all on public.payment_intents from anon, authenticated;

-- Every slip submission, kept for rate limiting and for the admin to see failures.
create table if not exists public.slip_attempts (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references public.users (id) on delete cascade,
  result     text not null,
  trans_ref  text,
  detail     jsonb,
  created_at timestamptz not null default now()
);
create index if not exists slip_attempts_user_idx on public.slip_attempts (user_id, created_at desc);
alter table public.slip_attempts enable row level security;
revoke all on public.slip_attempts from anon, authenticated;

-- ---------- Functions --------------------------------------------------------
-- Server-side price list (the client's copy is display-only).
create or replace function public.plan_price(p_tier int)
returns numeric language sql immutable as $$
  select (case p_tier when 1 then 100 when 2 then 200 when 3 then 300 end)::numeric
$$;

create or replace function public.create_payment_intent(p_kind text, p_tier int default null, p_amount numeric default null)
returns table (intent_id uuid, intent_amount numeric, intent_expires_at timestamptz)
language plpgsql security definer set search_path = public as $$
declare
  v_base   numeric;
  v_amount numeric;
  v_id     uuid;
  v_exp    timestamptz := now() + interval '30 minutes';
  v_tries  int := 0;
begin
  if auth.uid() is null then raise exception 'FORBIDDEN'; end if;

  if p_kind = 'membership' then
    if coalesce(p_tier, 0) not between 1 and 3 then raise exception 'BAD_INPUT'; end if;
    v_base := public.plan_price(p_tier);
  elsif p_kind = 'wallet_topup' then
    if p_amount is null or p_amount < 100 or p_amount > 10000 or p_amount <> trunc(p_amount) then
      raise exception 'BAD_INPUT';
    end if;
    v_base := p_amount;
  else
    raise exception 'BAD_INPUT';
  end if;

  -- Housekeeping: expire lapsed intents, and keep at most the 2 newest pending ones per user.
  update public.payment_intents set status = 'expired' where status = 'pending' and expires_at < now();
  update public.payment_intents set status = 'expired'
   where id in (select id from public.payment_intents
                 where user_id = auth.uid() and status = 'pending'
                 order by created_at desc offset 2);

  loop
    v_amount := v_base + (1 + floor(random() * 99))::int / 100.0;
    begin
      insert into public.payment_intents (user_id, kind, tier, days, base_amount, amount, expires_at)
      values (auth.uid(), p_kind,
              case when p_kind = 'membership' then p_tier end,
              case when p_kind = 'membership' then 30 end,
              v_base, v_amount, v_exp)
      returning id into v_id;
      exit;
    exception when unique_violation then
      v_tries := v_tries + 1;
      if v_tries > 25 then raise exception 'BUSY'; end if;
    end;
  end loop;

  return query select v_id, v_amount, v_exp;
end $$;

-- Called ONLY by the Edge Function (service role) after Thunder confirmed the slip.
create or replace function public.apply_slip_payment(p_user uuid, p_amount numeric, p_trans_ref text)
returns table (kind text, tier int, days int, paid numeric)
language plpgsql security definer set search_path = public as $$
declare
  i     public.payment_intents;
  v_pay uuid;
begin
  select * into i from public.payment_intents
   where user_id = p_user and status = 'pending' and expires_at > now() and amount = p_amount
   order by created_at desc limit 1
   for update;
  if not found then raise exception 'NO_MATCHING_INTENT'; end if;

  begin
    insert into public.payments (user_id, kind, tier, days, amount, method, reference, note, recorded_by, source)
    values (p_user, i.kind, i.tier, i.days, i.amount, 'promptpay', p_trans_ref, 'auto: slip verified', null, 'slip_auto')
    returning id into v_pay;
  exception when unique_violation then
    raise exception 'DUPLICATE_SLIP';          -- this transfer reference was already credited
  end;

  update public.payment_intents set status = 'paid', paid_at = now(), payment_id = v_pay where id = i.id;

  if i.kind = 'membership' then
    perform public.set_membership(p_user, i.tier, i.days);
  else
    update public.users set wallet_balance = wallet_balance + i.amount where id = p_user;
  end if;

  return query select i.kind, i.tier::int, i.days, i.amount;
end $$;

revoke all on function public.plan_price(int), public.create_payment_intent(text, int, numeric),
  public.apply_slip_payment(uuid, numeric, text) from public, anon, authenticated;
grant execute on function public.create_payment_intent(text, int, numeric) to authenticated;
grant execute on function public.apply_slip_payment(uuid, numeric, text) to service_role;

-- ---------- Admin: ledger shows automatic entries; failed slip attempts ------
drop function if exists public.admin_list_payments(int);
create function public.admin_list_payments(p_limit int default 100)
returns table (id uuid, created_at timestamptz, user_id uuid, user_name text, kind text, tier smallint,
               days int, amount numeric, method text, reference text, note text, source text, admin_name text)
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.assert_admin();
  return query
    select p.id, p.created_at, p.user_id, u.display_name, p.kind, p.tier, p.days, p.amount,
           p.method, p.reference, p.note, p.source, a.display_name
      from public.payments p
      join public.users u on u.id = p.user_id
      left join public.users a on a.id = p.recorded_by
     order by p.created_at desc
     limit least(greatest(p_limit, 1), 500);
end $$;

create or replace function public.admin_list_slip_attempts(p_limit int default 50)
returns table (id uuid, created_at timestamptz, user_id uuid, user_name text, result text,
               trans_ref text, detail jsonb)
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.assert_admin();
  return query
    select s.id, s.created_at, s.user_id, u.display_name, s.result, s.trans_ref, s.detail
      from public.slip_attempts s join public.users u on u.id = s.user_id
     where s.result <> 'OK'
     order by s.created_at desc
     limit least(greatest(p_limit, 1), 200);
end $$;

revoke all on function public.admin_list_payments(int), public.admin_list_slip_attempts(int) from public, anon;
grant execute on function public.admin_list_payments(int), public.admin_list_slip_attempts(int) to authenticated;
