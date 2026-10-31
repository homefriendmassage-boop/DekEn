-- =============================================================================
-- migration_062.sql — run ONCE after migration_061.sql
-- Withdrawals, new rules:
--   * fee = 10 % of the withdrawn amount (+ a flat fee, 0 now); NO tax is taken from the member (the platform bears it: the accountant makes
--     the withholding documents later, in one batch) -> no certificate is issued per withdrawal and the payer details are no longer required
--   * the minimum is on what the member RECEIVES: at least 100 THB net (so at least 111.12 requested with a 10 % fee)
--   * a Bonus balance below that minimum cannot be withdrawn; it can still be moved to the Wallet (transfer_bonus_to_wallet)
--   * identity verification before the first withdrawal is unchanged
-- Everything is a setting in the admin tab "ถอนเงิน → ตั้งค่า".
-- =============================================================================

alter table public.withdrawals add column if not exists fee_percent numeric not null default 0;

insert into public.app_settings (key, value) values
  ('withdraw_fee_percent', '10'), ('withdraw_min_net', '100'), ('withdraw_fee', '0'), ('withdraw_tax_percent', '0'), ('withdraw_min', '100')
on conflict (key) do update set value = excluded.value, updated_at = now();

-- the smallest amount that can be requested: what is left after the fee must reach the minimum net
create or replace function public.withdraw_min_gross()
returns numeric language sql stable security definer set search_path = public as $$
  select greatest(public.payout_num('withdraw_min', 0),
    ceil((public.payout_num('withdraw_min_net', 100) + public.payout_num('withdraw_fee', 0))
         / greatest(0.01, 1 - (public.payout_num('withdraw_fee_percent', 10) + public.payout_num('withdraw_tax_percent', 0)) / 100) * 100) / 100)
$$;
revoke all on function public.withdraw_min_gross() from public, anon, authenticated;

create or replace function public.my_payout_status()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare p public.payout_profiles; u public.users;
begin
  if auth.uid() is null then raise exception 'FORBIDDEN'; end if;
  select * into u from public.users where id = auth.uid();
  select * into p from public.payout_profiles where user_id = auth.uid();
  return jsonb_build_object(
    'profile', case when p.user_id is null then null else jsonb_build_object('status', p.status, 'full_name', p.full_name, 'id_last4', p.id_last4, 'reject_reason', p.reject_reason) end,
    'bonus', u.bonus_balance, 'min', public.withdraw_min_gross(), 'min_net', public.payout_num('withdraw_min_net', 100),
    'fee', public.payout_num('withdraw_fee', 0), 'fee_percent', public.payout_num('withdraw_fee_percent', 10),
    'tax_percent', public.payout_num('withdraw_tax_percent', 0),
    'today_used', exists (select 1 from public.withdrawals w where w.user_id = auth.uid() and w.status in ('pending', 'paid')
                           and (w.created_at at time zone 'Asia/Bangkok')::date = (now() at time zone 'Asia/Bangkok')::date));
end $$;

create or replace function public.request_withdrawal(p_amount numeric)
returns uuid language plpgsql security definer set search_path = public as $$
declare u public.users; p public.payout_profiles; v_gross numeric := round(p_amount, 2); v_min numeric := public.withdraw_min_gross();
        v_flat numeric := public.payout_num('withdraw_fee', 0); v_fpct numeric := public.payout_num('withdraw_fee_percent', 10);
        v_pct numeric := public.payout_num('withdraw_tax_percent', 0); v_fee numeric; v_tax numeric; v_net numeric; v_id uuid;
begin
  if auth.uid() is null then raise exception 'FORBIDDEN'; end if;
  if public.is_suspended(auth.uid()) then raise exception 'SUSPENDED'; end if;
  select * into p from public.payout_profiles where user_id = auth.uid();
  if not found or p.status <> 'verified' then raise exception 'NOT_VERIFIED'; end if;
  if v_gross is null or v_gross < v_min then raise exception 'BELOW_MIN'; end if;
  if exists (select 1 from public.withdrawals w where w.user_id = auth.uid() and w.status in ('pending', 'paid')
              and (w.created_at at time zone 'Asia/Bangkok')::date = (now() at time zone 'Asia/Bangkok')::date) then raise exception 'ONCE_A_DAY'; end if;
  v_fee := round(v_gross * v_fpct / 100, 2) + v_flat;
  v_tax := round(v_gross * v_pct / 100, 2);
  v_net := v_gross - v_fee - v_tax;
  if v_net < public.payout_num('withdraw_min_net', 100) then raise exception 'BELOW_MIN'; end if;
  select * into u from public.users where id = auth.uid() for update;
  if u.bonus_balance < v_gross then raise exception 'INSUFFICIENT_BONUS'; end if;
  perform set_config('app.ledger_kind', 'withdraw_hold', true);
  update public.users set bonus_balance = bonus_balance - v_gross where id = u.id;
  insert into public.withdrawals (user_id, gross, fee, fee_percent, tax_percent, tax_amount, net) values (u.id, v_gross, v_fee, v_fpct, v_pct, v_tax, v_net) returning id into v_id;
  perform set_config('app.ledger_ref', v_id::text, true);
  perform public.admin_notify('withdraw', p.full_name || ' · ' || to_char(v_net, 'FM999,999,990.00') || ' บาท');
  return v_id;
end $$;

-- paying out: just record the transfer (no certificate, no payer details needed). Returns null.
create or replace function public.admin_withdraw_pay(p_id uuid, p_ref text)
returns uuid language plpgsql security definer set search_path = public as $$
declare w public.withdrawals;
begin
  perform public.assert_admin();
  if char_length(btrim(coalesce(p_ref, ''))) < 3 then raise exception 'REF_REQUIRED'; end if;
  select * into w from public.withdrawals where id = p_id for update;
  if not found or w.status <> 'pending' then raise exception 'NOT_FOUND'; end if;
  update public.withdrawals set status = 'paid', paid_ref = left(btrim(p_ref), 100), decided_by = auth.uid(), decided_at = now() where id = w.id;
  perform public.approval_notify('withdraw', w.user_id, 'paid', to_char(w.net, 'FM999,999,990.00'));
  return null;
end $$;

create or replace function public.admin_payout_settings()
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform public.assert_admin();
  return jsonb_build_object('withdraw_min_net', public.payout_num('withdraw_min_net', 100), 'withdraw_fee_percent', public.payout_num('withdraw_fee_percent', 10),
    'withdraw_fee', public.payout_num('withdraw_fee', 0), 'withdraw_tax_percent', public.payout_num('withdraw_tax_percent', 0),
    'withdraw_min_gross', public.withdraw_min_gross(),
    'payer_name', coalesce(public.app_setting('payer_name'), ''), 'payer_tax_id', coalesce(public.app_setting('payer_tax_id'), ''),
    'payer_address', coalesce(public.app_setting('payer_address'), ''));
end $$;

create or replace function public.admin_set_payout_setting(p_key text, p_value text)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public.assert_admin();
  if p_key in ('withdraw_min', 'withdraw_min_net', 'withdraw_fee', 'withdraw_fee_percent', 'withdraw_tax_percent') then
    if p_value is null or p_value !~ '^[0-9]{1,6}(\.[0-9]{1,2})?$' then raise exception 'BAD_INPUT'; end if;
    if p_key in ('withdraw_tax_percent', 'withdraw_fee_percent') and p_value::numeric > 50 then raise exception 'BAD_INPUT'; end if;
  elsif p_key in ('payer_name', 'payer_tax_id', 'payer_address') then
    if char_length(coalesce(p_value, '')) > 250 then raise exception 'BAD_INPUT'; end if;
  else raise exception 'BAD_INPUT'; end if;
  insert into public.app_settings (key, value, updated_at, updated_by) values (p_key, btrim(p_value), now(), auth.uid())
  on conflict (key) do update set value = excluded.value, updated_at = now(), updated_by = auth.uid();
end $$;

revoke all on function public.my_payout_status(), public.request_withdrawal(numeric), public.admin_withdraw_pay(uuid, text),
  public.admin_payout_settings(), public.admin_set_payout_setting(text, text) from public, anon;
grant execute on function public.my_payout_status(), public.request_withdrawal(numeric), public.admin_withdraw_pay(uuid, text),
  public.admin_payout_settings(), public.admin_set_payout_setting(text, text) to authenticated;
