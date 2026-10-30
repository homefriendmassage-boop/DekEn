-- =============================================================================
-- migration_055.sql — run ONCE after migration_054.sql   (step 6: cash withdrawals + identity + withholding-tax certificates)
--   * no Flex for Wallet top-ups any more (only the package payments)
--   * who: anybody with a Bonus wallet (sellers' commissions, providers' chat income, inviters). The Bonus wallet only; the Wallet is not withdrawable.
--   * identity first: the member registers his name as on the ID card, the 13-digit national ID, address and PromptPay once
--     (national ID, address and PromptPay are encrypted: pgcrypto + a key kept in Supabase Vault); an admin verifies him (through LINE chat) before the first withdrawal
--   * a withdrawal request holds the amount at once (out of the Bonus wallet), goes to the admin queue, the admin transfers by PromptPay and enters the slip
--     reference: the request closes and a withholding-tax certificate (ใบหัก ณ ที่จ่าย) is issued in the payee's name
--   * amounts (all editable in the admin tab "💸 ถอนเงิน" → ตั้งค่า): minimum 200, fee 20 per withdrawal, withholding tax % of the withdrawn amount (default 3),
--     one withdrawal per day. The tax rate and the certificate wording MUST be confirmed with an accountant.
-- =============================================================================

-- ---------- 1) no Flex for top-ups ---------------------------------------------------------------------------------------------------------
create or replace function public.trg_payment_notify() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.kind = 'membership' then
    perform public.push_notify(jsonb_build_object('type', 'payment', 'kind', 'membership', 'user_id', new.user_id, 'tier', new.tier, 'amount', new.amount));
  end if;
  return new;
end $$;

-- ---------- 2) settings --------------------------------------------------------------------------------------------------------------------------
insert into public.app_settings (key, value) values
  ('withdraw_min', '200'), ('withdraw_fee', '20'), ('withdraw_tax_percent', '3'),
  ('payer_name', ''), ('payer_tax_id', ''), ('payer_address', '')
on conflict (key) do nothing;

create or replace function public.payout_num(p_key text, p_default numeric)
returns numeric language sql stable security definer set search_path = public as $$
  select coalesce(nullif(public.app_setting(p_key), '')::numeric, p_default)
$$;
revoke all on function public.payout_num(text, numeric) from public, anon, authenticated;

create or replace function public.admin_payout_settings()
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform public.assert_admin();
  return jsonb_build_object('withdraw_min', public.payout_num('withdraw_min', 200), 'withdraw_fee', public.payout_num('withdraw_fee', 20),
    'withdraw_tax_percent', public.payout_num('withdraw_tax_percent', 3), 'payer_name', coalesce(public.app_setting('payer_name'), ''),
    'payer_tax_id', coalesce(public.app_setting('payer_tax_id'), ''), 'payer_address', coalesce(public.app_setting('payer_address'), ''));
end $$;

create or replace function public.admin_set_payout_setting(p_key text, p_value text)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public.assert_admin();
  if p_key in ('withdraw_min', 'withdraw_fee', 'withdraw_tax_percent') then
    if p_value is null or p_value !~ '^[0-9]{1,6}(\.[0-9]{1,2})?$' then raise exception 'BAD_INPUT'; end if;
    if p_key = 'withdraw_tax_percent' and p_value::numeric > 50 then raise exception 'BAD_INPUT'; end if;
  elsif p_key in ('payer_name', 'payer_tax_id', 'payer_address') then
    if char_length(coalesce(p_value, '')) > 250 then raise exception 'BAD_INPUT'; end if;
  else raise exception 'BAD_INPUT'; end if;
  insert into public.app_settings (key, value, updated_at, updated_by) values (p_key, btrim(p_value), now(), auth.uid())
  on conflict (key) do update set value = excluded.value, updated_at = now(), updated_by = auth.uid();
end $$;

-- ---------- 3) encryption helpers (pgcrypto + a key in Vault) -------------------------------------------------------------------------
create extension if not exists pgcrypto;
do $$ begin
  if not exists (select 1 from vault.decrypted_secrets where name = 'payout_enc_key') then
    perform vault.create_secret(replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', ''), 'payout_enc_key');
  end if;
end $$;

create or replace function public.payout_enc(p text)
returns bytea language plpgsql security definer set search_path = public, extensions as $$
declare k text;
begin
  select decrypted_secret into k from vault.decrypted_secrets where name = 'payout_enc_key';
  if k is null then raise exception 'NO_KEY'; end if;
  return pgp_sym_encrypt(p, k);
end $$;
create or replace function public.payout_dec(p bytea)
returns text language plpgsql security definer set search_path = public, extensions as $$
declare k text;
begin
  select decrypted_secret into k from vault.decrypted_secrets where name = 'payout_enc_key';
  if k is null then raise exception 'NO_KEY'; end if;
  return pgp_sym_decrypt(p, k);
end $$;
revoke all on function public.payout_enc(text), public.payout_dec(bytea) from public, anon, authenticated;

-- Thai national ID: 13 digits, last one is a check digit
create or replace function public.thai_id_valid(p text)
returns boolean language plpgsql immutable as $$
declare s int := 0; i int;
begin
  if p !~ '^[0-9]{13}$' then return false; end if;
  for i in 1..12 loop s := s + substr(p, i, 1)::int * (14 - i); end loop;
  return (11 - s % 11) % 10 = substr(p, 13, 1)::int;
end $$;

-- ---------- 4) tables -------------------------------------------------------------------------------------------------------------------------------
create table if not exists public.payout_profiles (
  user_id uuid primary key references public.users (id) on delete cascade,
  full_name text not null, id_last4 text not null, enc bytea not null,          -- enc = {national_id, address, promptpay}
  status text not null default 'pending' check (status in ('pending', 'verified', 'rejected')),
  reject_reason text, created_at timestamptz not null default now(), verified_by uuid references public.users (id), verified_at timestamptz
);
create table if not exists public.withdrawals (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.users (id),
  gross numeric(12,2) not null check (gross > 0), fee numeric(12,2) not null, tax_percent numeric(5,2) not null, tax_amount numeric(12,2) not null, net numeric(12,2) not null,
  status text not null default 'pending' check (status in ('pending', 'paid', 'rejected', 'cancelled')),
  created_at timestamptz not null default now(), decided_by uuid references public.users (id), decided_at timestamptz, paid_ref text, reject_reason text
);
create index if not exists withdrawals_user_idx on public.withdrawals (user_id, created_at desc);
create index if not exists withdrawals_status_idx on public.withdrawals (status, created_at);
create table if not exists public.cert_counters (year int primary key, n int not null default 0);
create table if not exists public.withholding_certificates (
  id uuid primary key default gen_random_uuid(),
  cert_no text not null unique, withdrawal_id uuid not null unique references public.withdrawals (id), user_id uuid not null references public.users (id),
  paid_at timestamptz not null, income_type text not null, amount numeric(12,2) not null, tax_percent numeric(5,2) not null, tax_amount numeric(12,2) not null,
  payer_name text not null, payer_tax_id text, payer_address text, payee_name text not null, payee_enc bytea not null, created_at timestamptz not null default now()
);
alter table public.payout_profiles enable row level security; alter table public.withdrawals enable row level security;
alter table public.cert_counters enable row level security; alter table public.withholding_certificates enable row level security;
revoke all on public.payout_profiles, public.withdrawals, public.cert_counters, public.withholding_certificates from anon, authenticated;

-- ---------- 5) the member ------------------------------------------------------------------------------------------------------------------------
create or replace function public.my_payout_status()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare p public.payout_profiles; u public.users;
begin
  if auth.uid() is null then raise exception 'FORBIDDEN'; end if;
  select * into u from public.users where id = auth.uid();
  select * into p from public.payout_profiles where user_id = auth.uid();
  return jsonb_build_object(
    'profile', case when p.user_id is null then null else jsonb_build_object('status', p.status, 'full_name', p.full_name, 'id_last4', p.id_last4, 'reject_reason', p.reject_reason) end,
    'bonus', u.bonus_balance, 'min', public.payout_num('withdraw_min', 200), 'fee', public.payout_num('withdraw_fee', 20),
    'tax_percent', public.payout_num('withdraw_tax_percent', 3),
    'today_used', exists (select 1 from public.withdrawals w where w.user_id = auth.uid() and w.status in ('pending', 'paid')
                           and (w.created_at at time zone 'Asia/Bangkok')::date = (now() at time zone 'Asia/Bangkok')::date));
end $$;

create or replace function public.payout_submit(p_name text, p_national_id text, p_address text, p_promptpay text)
returns void language plpgsql security definer set search_path = public as $$
declare v_name text := btrim(coalesce(p_name, '')); v_id text := regexp_replace(coalesce(p_national_id, ''), '\D', '', 'g');
        v_pp text := regexp_replace(coalesce(p_promptpay, ''), '\D', '', 'g'); v_addr text := btrim(coalesce(p_address, ''));
begin
  if auth.uid() is null then raise exception 'FORBIDDEN'; end if;
  if public.is_suspended(auth.uid()) then raise exception 'SUSPENDED'; end if;
  if char_length(v_name) not between 3 and 80 or v_name ~ '[0-9]' then raise exception 'BAD_NAME'; end if;
  if not public.thai_id_valid(v_id) then raise exception 'BAD_ID'; end if;
  if char_length(v_addr) not between 10 and 300 then raise exception 'BAD_ADDRESS'; end if;
  if char_length(v_pp) not in (10, 13, 15) then raise exception 'BAD_PROMPTPAY'; end if;
  if exists (select 1 from public.payout_profiles where user_id = auth.uid() and status = 'verified') then raise exception 'ALREADY_VERIFIED'; end if;
  insert into public.payout_profiles (user_id, full_name, id_last4, enc, status)
  values (auth.uid(), v_name, right(v_id, 4), public.payout_enc(jsonb_build_object('national_id', v_id, 'address', v_addr, 'promptpay', v_pp)::text), 'pending')
  on conflict (user_id) do update set full_name = excluded.full_name, id_last4 = excluded.id_last4, enc = excluded.enc, status = 'pending',
        reject_reason = null, created_at = now(), verified_by = null, verified_at = null;
  perform public.admin_notify('identity', v_name);
end $$;

create or replace function public.request_withdrawal(p_amount numeric)
returns uuid language plpgsql security definer set search_path = public as $$
declare u public.users; p public.payout_profiles; v_gross numeric := round(p_amount, 2); v_min numeric := public.payout_num('withdraw_min', 200);
        v_fee numeric := public.payout_num('withdraw_fee', 20); v_pct numeric := public.payout_num('withdraw_tax_percent', 3); v_tax numeric; v_net numeric; v_id uuid;
begin
  if auth.uid() is null then raise exception 'FORBIDDEN'; end if;
  if public.is_suspended(auth.uid()) then raise exception 'SUSPENDED'; end if;
  select * into p from public.payout_profiles where user_id = auth.uid();
  if not found or p.status <> 'verified' then raise exception 'NOT_VERIFIED'; end if;
  if v_gross is null or v_gross < v_min then raise exception 'BELOW_MIN'; end if;
  if exists (select 1 from public.withdrawals w where w.user_id = auth.uid() and w.status in ('pending', 'paid')
              and (w.created_at at time zone 'Asia/Bangkok')::date = (now() at time zone 'Asia/Bangkok')::date) then raise exception 'ONCE_A_DAY'; end if;
  v_tax := round(v_gross * v_pct / 100, 2);
  v_net := v_gross - v_tax - v_fee;
  if v_net <= 0 then raise exception 'BELOW_MIN'; end if;
  select * into u from public.users where id = auth.uid() for update;
  if u.bonus_balance < v_gross then raise exception 'INSUFFICIENT_BONUS'; end if;
  perform set_config('app.ledger_kind', 'withdraw_hold', true);
  update public.users set bonus_balance = bonus_balance - v_gross where id = u.id;
  insert into public.withdrawals (user_id, gross, fee, tax_percent, tax_amount, net) values (u.id, v_gross, v_fee, v_pct, v_tax, v_net) returning id into v_id;
  perform set_config('app.ledger_ref', v_id::text, true);
  perform public.admin_notify('withdraw', p.full_name || ' · ' || to_char(v_net, 'FM999,999,990.00') || ' บาท');
  return v_id;
end $$;

create or replace function public.cancel_withdrawal(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare w public.withdrawals;
begin
  select * into w from public.withdrawals where id = p_id and user_id = auth.uid() for update;
  if not found or w.status <> 'pending' then raise exception 'NOT_FOUND'; end if;
  perform set_config('app.ledger_kind', 'withdraw_refund', true);
  perform set_config('app.ledger_ref', w.id::text, true);
  update public.users set bonus_balance = bonus_balance + w.gross where id = w.user_id;
  update public.withdrawals set status = 'cancelled', decided_at = now() where id = w.id;
end $$;

create or replace function public.my_withdrawals()
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', w.id, 'gross', w.gross, 'fee', w.fee, 'tax_amount', w.tax_amount, 'tax_percent', w.tax_percent, 'net', w.net,
           'status', w.status, 'created_at', w.created_at, 'decided_at', w.decided_at, 'reject_reason', w.reject_reason,
           'has_certificate', exists (select 1 from public.withholding_certificates c where c.withdrawal_id = w.id)) order by w.created_at desc), '[]'::jsonb)
    from public.withdrawals w where w.user_id = auth.uid()
$$;

-- ---------- 6) certificate --------------------------------------------------------------------------------------------------------------------------
create or replace function public.cert_json(c public.withholding_certificates)
returns jsonb language plpgsql security definer set search_path = public as $$
declare e jsonb := public.payout_dec(c.payee_enc)::jsonb;
begin
  return jsonb_build_object('cert_no', c.cert_no, 'paid_at', c.paid_at, 'income_type', c.income_type, 'amount', c.amount, 'tax_percent', c.tax_percent, 'tax_amount', c.tax_amount,
    'payer', jsonb_build_object('name', c.payer_name, 'tax_id', c.payer_tax_id, 'address', c.payer_address),
    'payee', jsonb_build_object('name', c.payee_name, 'national_id', e->>'national_id', 'address', e->>'address'));
end $$;
revoke all on function public.cert_json(public.withholding_certificates) from public, anon, authenticated;

create or replace function public.my_certificate(p_withdrawal uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare c public.withholding_certificates;
begin
  select * into c from public.withholding_certificates where withdrawal_id = p_withdrawal and user_id = auth.uid();
  if not found then raise exception 'NOT_FOUND'; end if;
  return public.cert_json(c);
end $$;
create or replace function public.admin_certificate(p_withdrawal uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare c public.withholding_certificates;
begin
  perform public.assert_admin();
  select * into c from public.withholding_certificates where withdrawal_id = p_withdrawal;
  if not found then raise exception 'NOT_FOUND'; end if;
  return public.cert_json(c);
end $$;

-- ---------- 7) admin ----------------------------------------------------------------------------------------------------------------------------------
create or replace function public.admin_payout_profiles(p_status text default 'pending')
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform public.assert_admin();
  return coalesce((select jsonb_agg(jsonb_build_object('user_id', p.user_id, 'user_name', u.display_name, 'full_name', p.full_name, 'id_last4', p.id_last4,
            'status', p.status, 'reject_reason', p.reject_reason, 'created_at', p.created_at) order by p.created_at)
     from public.payout_profiles p join public.users u on u.id = p.user_id where p.status = p_status), '[]'::jsonb);
end $$;
create or replace function public.admin_payout_detail(p_user uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare p public.payout_profiles;
begin
  perform public.assert_admin();
  select * into p from public.payout_profiles where user_id = p_user;
  if not found then raise exception 'NOT_FOUND'; end if;
  return jsonb_build_object('full_name', p.full_name) || public.payout_dec(p.enc)::jsonb;
end $$;
create or replace function public.admin_payout_decide(p_user uuid, p_approve boolean, p_reason text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public.assert_admin();
  update public.payout_profiles set status = case when p_approve then 'verified' else 'rejected' end, reject_reason = case when p_approve then null else left(p_reason, 200) end,
         verified_by = auth.uid(), verified_at = now() where user_id = p_user and status = 'pending';
  if not found then raise exception 'NOT_FOUND'; end if;
  perform public.approval_notify('identity', p_user, case when p_approve then 'approved' else 'rejected' end, p_reason);
end $$;

create or replace function public.admin_withdrawals(p_status text default 'pending')
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform public.assert_admin();
  return coalesce((select jsonb_agg(jsonb_build_object('id', w.id, 'user_id', w.user_id, 'user_name', u.display_name, 'payee_name', p.full_name,
            'promptpay', public.payout_dec(p.enc)::jsonb->>'promptpay', 'gross', w.gross, 'fee', w.fee, 'tax_percent', w.tax_percent, 'tax_amount', w.tax_amount, 'net', w.net,
            'status', w.status, 'created_at', w.created_at, 'decided_at', w.decided_at, 'paid_ref', w.paid_ref, 'reject_reason', w.reject_reason,
            'has_certificate', exists (select 1 from public.withholding_certificates c where c.withdrawal_id = w.id)) order by w.created_at)
     from public.withdrawals w join public.users u on u.id = w.user_id left join public.payout_profiles p on p.user_id = w.user_id where w.status = p_status), '[]'::jsonb);
end $$;

create or replace function public.admin_withdraw_pay(p_id uuid, p_ref text)
returns uuid language plpgsql security definer set search_path = public as $$
declare w public.withdrawals; p public.payout_profiles; v_year int := extract(year from now() at time zone 'Asia/Bangkok')::int; v_n int; v_cert uuid;
begin
  perform public.assert_admin();
  if char_length(btrim(coalesce(p_ref, ''))) < 3 then raise exception 'REF_REQUIRED'; end if;
  select * into w from public.withdrawals where id = p_id for update;
  if not found or w.status <> 'pending' then raise exception 'NOT_FOUND'; end if;
  if btrim(coalesce(public.app_setting('payer_name'), '')) = '' then raise exception 'PAYER_NOT_SET'; end if;
  select * into p from public.payout_profiles where user_id = w.user_id;
  insert into public.cert_counters (year, n) values (v_year, 1) on conflict (year) do update set n = public.cert_counters.n + 1 returning n into v_n;
  insert into public.withholding_certificates (cert_no, withdrawal_id, user_id, paid_at, income_type, amount, tax_percent, tax_amount, payer_name, payer_tax_id, payer_address, payee_name, payee_enc)
  values ((v_year + 543)::text || '-' || lpad(v_n::text, 6, '0'), w.id, w.user_id, now(), 'ค่านายหน้า / ค่าบริการ', w.gross, w.tax_percent, w.tax_amount,
          public.app_setting('payer_name'), nullif(public.app_setting('payer_tax_id'), ''), nullif(public.app_setting('payer_address'), ''), p.full_name, p.enc)
  returning id into v_cert;
  update public.withdrawals set status = 'paid', paid_ref = left(btrim(p_ref), 100), decided_by = auth.uid(), decided_at = now() where id = w.id;
  perform public.approval_notify('withdraw', w.user_id, 'paid', to_char(w.net, 'FM999,999,990.00'));
  return v_cert;
end $$;

create or replace function public.admin_withdraw_reject(p_id uuid, p_reason text)
returns void language plpgsql security definer set search_path = public as $$
declare w public.withdrawals;
begin
  perform public.assert_admin();
  if char_length(btrim(coalesce(p_reason, ''))) < 3 then raise exception 'REASON_REQUIRED'; end if;
  select * into w from public.withdrawals where id = p_id for update;
  if not found or w.status <> 'pending' then raise exception 'NOT_FOUND'; end if;
  perform set_config('app.ledger_kind', 'withdraw_refund', true);
  perform set_config('app.ledger_ref', w.id::text, true);
  update public.users set bonus_balance = bonus_balance + w.gross where id = w.user_id;
  update public.withdrawals set status = 'rejected', reject_reason = left(btrim(p_reason), 200), decided_by = auth.uid(), decided_at = now() where id = w.id;
  perform public.approval_notify('withdraw', w.user_id, 'rejected', p_reason);
end $$;

create or replace function public.admin_withdraw_pending_count()
returns int language plpgsql stable security definer set search_path = public as $$
begin
  perform public.assert_admin();
  return (select count(*) from public.payout_profiles where status = 'pending')::int + (select count(*) from public.withdrawals where status = 'pending')::int;
end $$;

revoke all on function public.my_payout_status(), public.payout_submit(text, text, text, text), public.request_withdrawal(numeric), public.cancel_withdrawal(uuid), public.my_withdrawals(),
  public.my_certificate(uuid), public.admin_certificate(uuid), public.admin_payout_profiles(text), public.admin_payout_detail(uuid), public.admin_payout_decide(uuid, boolean, text),
  public.admin_withdrawals(text), public.admin_withdraw_pay(uuid, text), public.admin_withdraw_reject(uuid, text), public.admin_withdraw_pending_count(),
  public.admin_payout_settings(), public.admin_set_payout_setting(text, text), public.thai_id_valid(text) from public, anon;
grant execute on function public.my_payout_status(), public.payout_submit(text, text, text, text), public.request_withdrawal(numeric), public.cancel_withdrawal(uuid), public.my_withdrawals(),
  public.my_certificate(uuid), public.admin_certificate(uuid), public.admin_payout_profiles(text), public.admin_payout_detail(uuid), public.admin_payout_decide(uuid, boolean, text),
  public.admin_withdrawals(text), public.admin_withdraw_pay(uuid, text), public.admin_withdraw_reject(uuid, text), public.admin_withdraw_pending_count(),
  public.admin_payout_settings(), public.admin_set_payout_setting(text, text), public.thai_id_valid(text) to authenticated;
