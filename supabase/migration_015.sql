-- =============================================================================
-- migration_015.sql — run ONCE after migration_014.sql
-- Step 2 of the revenue-sharing plan:
--   * every user has a share code (link / Flex / QR) -> the person whose link a customer used is that customer's "sales"
--   * 20% of every membership payment goes to the customer's sales, into the bonus wallet
--   * membership can be paid (new / renew / upgrade) from the Wallet
-- Who is a customer's sales:
--   - registering through a link => that person, right away
--   - a later click on another link only takes over if the customer then pays for a package (or books)
--     within 24 hours of the click; otherwise the click is forgotten and the previous sales stays.
--   - top-ups never change it, and existing accounts are never re-attributed retroactively.
-- =============================================================================

-- ---------- Share codes -------------------------------------------------------
create or replace function public.my_share_code()
returns text language plpgsql security definer set search_path = public as $$
declare
  v text;
  i int := 0;
begin
  if auth.uid() is null then raise exception 'FORBIDDEN'; end if;
  select partner_ref_code into v from public.users where id = auth.uid();
  if v is not null then return v; end if;
  loop
    v := (select string_agg(substr('abcdefghjkmnpqrstuvwxyz23456789', 1 + floor(random() * 31)::int, 1), '')
            from generate_series(1, 8));
    begin
      update public.users set partner_ref_code = v where id = auth.uid() and partner_ref_code is null;
      select partner_ref_code into v from public.users where id = auth.uid();
      return v;
    exception when unique_violation then
      i := i + 1;
      if i > 10 then raise exception 'BUSY'; end if;
    end;
  end loop;
end $$;

-- ---------- Sales attribution -------------------------------------------------
create table if not exists public.referral_clicks (
  user_id     uuid primary key references public.users (id) on delete cascade,
  referrer_id uuid not null references public.users (id) on delete cascade,
  clicked_at  timestamptz not null default now()
);
alter table public.referral_clicks enable row level security;
revoke all on public.referral_clicks from anon, authenticated;

create or replace function public.register_referral_click(p_code text)
returns boolean language plpgsql security definer set search_path = public as $$
declare
  v_ref uuid;
  me    public.users;
begin
  if auth.uid() is null then raise exception 'FORBIDDEN'; end if;
  select id into v_ref from public.users where partner_ref_code = p_code;
  if v_ref is null or v_ref = auth.uid() then return false; end if;
  select * into me from public.users where id = auth.uid();

  -- First registration through a link: that person is the sales immediately.
  if me.referred_by is null and me.created_at > now() - interval '30 minutes' then
    update public.users set referred_by = v_ref where id = me.id;
    return true;
  end if;
  if me.referred_by = v_ref then
    delete from public.referral_clicks where user_id = me.id;   -- already the sales; nothing to take over
    return true;
  end if;
  insert into public.referral_clicks (user_id, referrer_id, clicked_at) values (me.id, v_ref, now())
  on conflict (user_id) do update set referrer_id = excluded.referrer_id, clicked_at = excluded.clicked_at;
  return true;
end $$;

-- Called when a package is paid or a booking is made: a click made in the last 24 hours takes over.
create or replace function public.resolve_sales(p_user uuid)
returns uuid language plpgsql security definer set search_path = public as $$
declare c public.referral_clicks;
begin
  select * into c from public.referral_clicks where user_id = p_user for update;
  if found then
    if c.clicked_at > now() - interval '24 hours' and c.referrer_id <> p_user then
      update public.users set referred_by = c.referrer_id where id = p_user;
    end if;
    delete from public.referral_clicks where user_id = p_user;
  end if;
  return (select referred_by from public.users where id = p_user);
end $$;

-- ---------- 20% of membership payments to the sales ---------------------------
create table if not exists public.referral_rewards (
  id          uuid primary key default gen_random_uuid(),
  beneficiary uuid not null references public.users (id),
  payer       uuid not null references public.users (id),
  source_type text not null,                    -- membership_payment
  source_id   uuid not null,
  base_amount numeric(12,2) not null,
  amount      numeric(12,2) not null,
  created_at  timestamptz not null default now(),
  unique (source_type, source_id)               -- one reward per payment, ever
);
create index if not exists referral_rewards_ben_idx on public.referral_rewards (beneficiary, created_at desc);
alter table public.referral_rewards enable row level security;
revoke all on public.referral_rewards from anon, authenticated;

create or replace function public.referral_membership_rate()
returns numeric language sql immutable as $$ select 0.20::numeric $$;

create or replace function public.payments_referral()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_sales uuid;
  v_amt   numeric;
  v_id    uuid;
begin
  v_sales := public.resolve_sales(new.user_id);
  if v_sales is null or v_sales = new.user_id or public.is_suspended(v_sales) then return new; end if;
  v_amt := round(new.amount * public.referral_membership_rate(), 2);
  if v_amt <= 0 then return new; end if;

  insert into public.referral_rewards (beneficiary, payer, source_type, source_id, base_amount, amount)
  values (v_sales, new.user_id, 'membership_payment', new.id, new.amount, v_amt)
  on conflict (source_type, source_id) do nothing
  returning id into v_id;
  if v_id is null then return new; end if;

  perform set_config('app.ledger_kind', 'referral_membership', true);
  perform set_config('app.ledger_ref', new.id::text, true);
  update public.users set bonus_balance = bonus_balance + v_amt where id = v_sales;
  return new;
end $$;
drop trigger if exists payments_referral on public.payments;
create trigger payments_referral after insert on public.payments
  for each row when (new.kind = 'membership')
  execute function public.payments_referral();

-- ---------- Pay a package from the Wallet -------------------------------------
alter table public.payments drop constraint if exists payments_method_check;
alter table public.payments add constraint payments_method_check
  check (method in ('promptpay', 'bank_transfer', 'cash', 'other', 'wallet'));
alter table public.payments drop constraint if exists payments_source_check;
alter table public.payments add constraint payments_source_check check (source in ('admin', 'slip_auto', 'wallet'));

-- What this user must pay now for a plan: full price, or only the difference when upgrading a running plan.
create or replace function public.membership_quote(p_user uuid, p_tier int)
returns table (price numeric, is_upgrade boolean, cur int)
language plpgsql stable security definer set search_path = public as $$
declare v_cur int;
begin
  if coalesce(p_tier, 0) not between 1 and 3 then raise exception 'BAD_INPUT'; end if;
  select coalesce((select vip_tier from public.users where id = p_user and vip_expires_at > now()), 0) into v_cur;
  if p_tier < v_cur then raise exception 'ALREADY_HIGHER'; end if;
  return query select public.plan_price(p_tier) - case when v_cur > 0 and p_tier > v_cur then public.plan_price(v_cur) else 0 end,
                      (v_cur > 0 and p_tier > v_cur), v_cur;
end $$;
revoke all on function public.membership_quote(uuid, int) from public, anon, authenticated;

create or replace function public.buy_membership_with_wallet(p_tier int)
returns table (kind text, tier int, days int, paid numeric)
language plpgsql security definer set search_path = public as $$
declare
  q     record;
  v_bal numeric;
  v_pay uuid;
begin
  if auth.uid() is null then raise exception 'FORBIDDEN'; end if;
  if public.is_suspended(auth.uid()) then raise exception 'SUSPENDED'; end if;
  select wallet_balance into v_bal from public.users where id = auth.uid() for update;
  select * into q from public.membership_quote(auth.uid(), p_tier);

  -- a double tap must not buy twice
  if exists (select 1 from public.payments p where p.user_id = auth.uid() and p.method = 'wallet'
              and p.tier = p_tier and p.created_at > now() - interval '10 seconds') then
    raise exception 'DUPLICATE_REQUEST';
  end if;
  if v_bal < q.price then raise exception 'INSUFFICIENT_BALANCE'; end if;

  insert into public.payments (user_id, kind, tier, days, amount, method, reference, note, recorded_by, source)
  values (auth.uid(), 'membership', p_tier, 30, q.price, 'wallet', null,
          case when q.is_upgrade then 'wallet: upgrade (difference), expiry unchanged' else 'wallet' end, null, 'wallet')
  returning id into v_pay;

  perform set_config('app.ledger_kind', 'membership_purchase', true);
  perform set_config('app.ledger_ref', v_pay::text, true);
  update public.users set wallet_balance = wallet_balance - q.price where id = auth.uid();

  if q.is_upgrade then
    update public.users set vip_tier = p_tier where id = auth.uid();
    insert into public.membership_events (user_id, action, old_tier, new_tier, new_expires, reason)
    select auth.uid(), 'set_membership', q.cur, p_tier, vip_expires_at, 'upgrade (paid from wallet)'
      from public.users where id = auth.uid();
  else
    perform public.set_membership(auth.uid(), p_tier, 30);
  end if;
  return query select 'membership'::text, p_tier, 30, q.price;
end $$;

-- create_payment_intent now reads the price from membership_quote (same behaviour as migration_012).
create or replace function public.create_payment_intent(p_kind text, p_tier int default null, p_amount numeric default null)
returns table (intent_id uuid, intent_amount numeric, intent_expires_at timestamptz)
language plpgsql security definer set search_path = public as $$
declare
  v_base   numeric;
  v_amount numeric;
  v_id     uuid;
  v_exp    timestamptz := now() + interval '30 minutes';
  v_tries  int := 0;
  v_upg    boolean := false;
  e        public.payment_intents;
begin
  if auth.uid() is null then raise exception 'FORBIDDEN'; end if;
  if public.is_suspended(auth.uid()) then raise exception 'SUSPENDED'; end if;

  if p_kind = 'membership' then
    select q.price, q.is_upgrade into v_base, v_upg from public.membership_quote(auth.uid(), p_tier) q;
  elsif p_kind = 'wallet_topup' then
    if p_amount is null or p_amount < 100 or p_amount > 10000 or p_amount <> trunc(p_amount) then
      raise exception 'BAD_INPUT';
    end if;
    v_base := p_amount;
  else
    raise exception 'BAD_INPUT';
  end if;

  select * into e from public.payment_intents
   where user_id = auth.uid() and status = 'pending' and expires_at > now()
     and kind = p_kind and base_amount = v_base and is_upgrade = v_upg
     and tier is not distinct from (case when p_kind = 'membership' then p_tier::smallint end)
   order by created_at desc limit 1;
  if found then
    return query select e.id, e.amount, e.expires_at;
    return;
  end if;

  update public.payment_intents set status = 'expired' where status = 'pending' and expires_at < now();
  update public.payment_intents set status = 'expired'
   where id in (select id from public.payment_intents
                 where user_id = auth.uid() and status = 'pending'
                 order by created_at desc offset 2);

  loop
    v_amount := v_base + (1 + floor(random() * 99))::int / 100.0;
    begin
      insert into public.payment_intents (user_id, kind, tier, days, base_amount, amount, expires_at, is_upgrade)
      values (auth.uid(), p_kind,
              case when p_kind = 'membership' then p_tier end,
              case when p_kind = 'membership' then 30 end,
              v_base, v_amount, v_exp, v_upg)
      returning id into v_id;
      exit;
    exception when unique_violation then
      v_tries := v_tries + 1;
      if v_tries > 25 then raise exception 'BUSY'; end if;
    end;
  end loop;

  return query select v_id, v_amount, v_exp;
end $$;

-- ---------- My referral numbers -------------------------------------------------
create or replace function public.my_referral_stats()
returns table (code text, friends int, earned numeric, earned_month numeric)
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'FORBIDDEN'; end if;
  return query
    select public.my_share_code(),
           (select count(*)::int from public.users u where u.referred_by = auth.uid()),
           coalesce((select sum(r.amount) from public.referral_rewards r where r.beneficiary = auth.uid()), 0),
           coalesce((select sum(r.amount) from public.referral_rewards r
                      where r.beneficiary = auth.uid() and r.created_at >= date_trunc('month', now())), 0);
end $$;

revoke all on function public.my_share_code(), public.register_referral_click(text), public.resolve_sales(uuid),
  public.buy_membership_with_wallet(int), public.my_referral_stats(), public.referral_membership_rate() from public, anon;
grant execute on function public.my_share_code(), public.register_referral_click(text),
  public.buy_membership_with_wallet(int), public.my_referral_stats() to authenticated;
revoke all on function public.resolve_sales(uuid) from authenticated;   -- internal (triggers / service role)
-- =============================================================================
