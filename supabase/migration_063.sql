-- =============================================================================
-- migration_063.sql — run ONCE after migration_062.sql
-- Withdrawal rules, final: minimum 100 THB requested (before the fee), fee 10 %, no tax, so a request of 150 pays out 135 and the smallest
-- one (100) pays out 90. The "net minimum" of migration_062 is switched off (0).
-- =============================================================================
insert into public.app_settings (key, value) values
  ('withdraw_min', '100'), ('withdraw_min_net', '0'), ('withdraw_fee_percent', '10'), ('withdraw_fee', '0'), ('withdraw_tax_percent', '0')
on conflict (key) do update set value = excluded.value, updated_at = now();

create or replace function public.admin_payout_settings()
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform public.assert_admin();
  return jsonb_build_object('withdraw_min', public.payout_num('withdraw_min', 100), 'withdraw_min_net', public.payout_num('withdraw_min_net', 0),
    'withdraw_fee_percent', public.payout_num('withdraw_fee_percent', 10), 'withdraw_fee', public.payout_num('withdraw_fee', 0),
    'withdraw_tax_percent', public.payout_num('withdraw_tax_percent', 0), 'withdraw_min_gross', public.withdraw_min_gross(),
    'payer_name', coalesce(public.app_setting('payer_name'), ''), 'payer_tax_id', coalesce(public.app_setting('payer_tax_id'), ''),
    'payer_address', coalesce(public.app_setting('payer_address'), ''));
end $$;
revoke all on function public.admin_payout_settings() from public, anon;
grant execute on function public.admin_payout_settings() to authenticated;
