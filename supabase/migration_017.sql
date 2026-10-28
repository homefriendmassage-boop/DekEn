-- =============================================================================
-- migration_017.sql — run ONCE after migration_016.sql
-- Step 3.5 of the revenue-sharing plan: inactivity rules for the two balances.
--
--  1) BONUS -> WALLET after 30 days without renewing a package or paying in.
--     "Inactive since" = the later of (membership expiry, last payment [package or top-up]); an account with no
--     history counts from its sign-up date. Providers (anyone with a provider profile / role worker) are exempt:
--     their chat income is earnings, not a customer bonus. Runs daily; the money moves, it is never deleted.
--
--  2) WALLET expires after 6 months of NO activity (top-up, package, booking, chat fee, or any payment).
--     Money you move yourself from the bonus wallet does NOT count as activity (it cannot keep a wallet alive forever);
--     money the 30-day rule moves in does (otherwise it could vanish on the day it arrives). Expired money is written to the ledger
--     as `wallet_expired` (nothing is deleted from the history; an admin can reverse it with admin_adjust_balance).
--     *** Disabled by default. Have a lawyer review the terms and show them to customers before enabling:
--         update public.app_settings set value = 'true' where key = 'wallet_expiry_enabled';
-- =============================================================================

create table if not exists public.app_settings (
  key        text primary key,
  value      text not null,
  updated_at timestamptz not null default now(),
  updated_by uuid references public.users (id)
);
alter table public.app_settings enable row level security;
revoke all on public.app_settings from anon, authenticated;
insert into public.app_settings (key, value) values
  ('wallet_expiry_enabled', 'false'),
  ('wallet_expiry_months', '6'),
  ('bonus_sweep_days', '30')
on conflict (key) do nothing;

create or replace function public.app_setting(p_key text)
returns text language sql stable security definer set search_path = public as $$
  select value from public.app_settings where key = p_key
$$;
revoke all on function public.app_setting(text) from public, anon, authenticated;

create or replace function public.admin_set_setting(p_key text, p_value text)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public.assert_admin();
  if p_key not in ('wallet_expiry_enabled', 'wallet_expiry_months', 'bonus_sweep_days') then raise exception 'BAD_INPUT'; end if;
  if p_key = 'wallet_expiry_enabled' and p_value not in ('true', 'false') then raise exception 'BAD_INPUT'; end if;
  if p_key <> 'wallet_expiry_enabled' and (p_value !~ '^[0-9]{1,3}$' or p_value::int < 1) then raise exception 'BAD_INPUT'; end if;
  update public.app_settings set value = p_value, updated_at = now(), updated_by = auth.uid() where key = p_key;
end $$;
revoke all on function public.admin_set_setting(text, text) from public, anon;
grant execute on function public.admin_set_setting(text, text) to authenticated;

-- ---------- When does a user count as inactive? ------------------------------------
create or replace function public.bonus_inactive_since(p_user uuid)
returns timestamptz language sql stable security definer set search_path = public as $$
  select greatest(coalesce(u.vip_expires_at, u.created_at),
                  coalesce((select max(p.created_at) from public.payments p where p.user_id = u.id), u.created_at))
    from public.users u where u.id = p_user
$$;

create or replace function public.wallet_last_activity(p_user uuid)
returns timestamptz language sql stable security definer set search_path = public as $$
  select greatest(
    (select max(l.created_at) from public.wallet_ledger l
      where l.user_id = p_user and l.wallet = 'wallet'
        and l.kind in ('opening', 'topup', 'membership_purchase', 'booking_fee', 'chat_hold', 'bonus_swept_in')),
    (select max(p.created_at) from public.payments p where p.user_id = p_user))
$$;
revoke all on function public.bonus_inactive_since(uuid), public.wallet_last_activity(uuid) from public, anon, authenticated;

-- ---------- 1) Bonus -> wallet ---------------------------------------------------
create or replace function public.sweep_inactive_bonus()
returns int language plpgsql security definer set search_path = public as $$
declare
  u public.users;
  n int := 0;
  v_days int := coalesce(public.app_setting('bonus_sweep_days'), '30')::int;
begin
  for u in select * from public.users x
            where x.bonus_balance > 0 and x.role <> 'worker'
              and not exists (select 1 from public.workers w where w.user_id = x.id)
              and (x.vip_expires_at is null or x.vip_expires_at <= now())
              and public.bonus_inactive_since(x.id) <= now() - make_interval(days => v_days)
            for update skip locked loop
    perform set_config('app.ledger_kind', 'bonus_swept_out', true);
    perform set_config('app.ledger_note', v_days || ' days without renewing or paying in', true);
    update public.users set bonus_balance = bonus_balance - u.bonus_balance where id = u.id;
    perform set_config('app.ledger_kind', 'bonus_swept_in', true);
    perform set_config('app.ledger_note', v_days || ' days without renewing or paying in', true);
    update public.users set wallet_balance = wallet_balance + u.bonus_balance where id = u.id;
    n := n + 1;
  end loop;
  return n;
end $$;

-- ---------- 2) Wallet expiry --------------------------------------------------------
create or replace function public.expire_inactive_wallets()
returns int language plpgsql security definer set search_path = public as $$
declare
  u public.users;
  n int := 0;
  v_months int := coalesce(public.app_setting('wallet_expiry_months'), '6')::int;
begin
  if coalesce(public.app_setting('wallet_expiry_enabled'), 'false') <> 'true' then return 0; end if;
  for u in select * from public.users x
            where x.wallet_balance > 0
              and coalesce(public.wallet_last_activity(x.id), x.created_at) <= now() - make_interval(months => v_months)
            for update skip locked loop
    perform set_config('app.ledger_kind', 'wallet_expired', true);
    perform set_config('app.ledger_note', v_months || ' months without activity', true);
    update public.users set wallet_balance = 0 where id = u.id;
    n := n + 1;
  end loop;
  return n;
end $$;
revoke all on function public.sweep_inactive_bonus(), public.expire_inactive_wallets() from public, anon, authenticated;

-- ---------- What the app tells the customer -------------------------------------------
create or replace function public.my_wallet_rules()
returns table (bonus_sweep_at timestamptz, wallet_expires_at timestamptz, expiry_enabled boolean)
language plpgsql stable security definer set search_path = public as $$
declare
  me public.users;
  v_days int := coalesce(public.app_setting('bonus_sweep_days'), '30')::int;
  v_months int := coalesce(public.app_setting('wallet_expiry_months'), '6')::int;
  v_on boolean := coalesce(public.app_setting('wallet_expiry_enabled'), 'false') = 'true';
begin
  if auth.uid() is null then raise exception 'FORBIDDEN'; end if;
  select * into me from public.users where id = auth.uid();
  return query select
    case when me.bonus_balance > 0 and me.role <> 'worker'
              and not exists (select 1 from public.workers w where w.user_id = me.id)
              and (me.vip_expires_at is null or me.vip_expires_at <= now())
         then public.bonus_inactive_since(me.id) + make_interval(days => v_days) end,
    case when v_on and me.wallet_balance > 0
         then coalesce(public.wallet_last_activity(me.id), me.created_at) + make_interval(months => v_months) end,
    v_on;
end $$;
revoke all on function public.my_wallet_rules() from public, anon;
grant execute on function public.my_wallet_rules() to authenticated;

-- Daily (needs pg_cron: Database > Extensions > pg_cron). Harmless if it is not enabled.
do $$ begin
  create extension if not exists pg_cron;
  perform cron.schedule('sweep-inactive-bonus', '10 20 * * *', 'select public.sweep_inactive_bonus()');   -- 03:10 Thailand
  perform cron.schedule('expire-inactive-wallets', '20 20 * * *', 'select public.expire_inactive_wallets()'); -- no-op until enabled
exception when others then
  raise notice 'pg_cron is not enabled (%): schedule public.sweep_inactive_bonus() and public.expire_inactive_wallets() yourself', sqlerrm;
end $$;
-- =============================================================================
