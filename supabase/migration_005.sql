-- =============================================================================
-- migration_005.sql — run ONCE after migration_004.sql
-- Admin back office: application review + payment ledger (membership / wallet top-up).
-- Admins are rows in public.admins; every admin_* function re-checks that server-side,
-- so knowing the admin page URL gives a non-admin nothing.
-- =============================================================================

-- ---------- Admins -----------------------------------------------------------
create table if not exists public.admins (
  user_id    uuid primary key references public.users (id) on delete cascade,
  created_at timestamptz not null default now()
);
alter table public.admins enable row level security;
revoke all on public.admins from anon, authenticated;   -- no client access at all
-- Add yourself (SQL Editor):  insert into public.admins (user_id) values ('<your users.id>');

create or replace function public.is_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.admins where user_id = auth.uid())
$$;

create or replace function public.assert_admin()
returns void language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'FORBIDDEN'; end if;
end $$;

-- ---------- Payment ledger ---------------------------------------------------
create table if not exists public.payments (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references public.users (id),
  kind        text not null check (kind in ('membership', 'wallet_topup')),
  tier        smallint check (tier between 1 and 3),
  days        int check (days between 1 and 365),
  amount      numeric(12,2) not null check (amount > 0),
  method      text not null check (method in ('promptpay', 'bank_transfer', 'cash', 'other')),
  reference   text,                       -- transfer ref / slip number
  note        text,
  recorded_by uuid not null references public.users (id),
  created_at  timestamptz not null default now(),
  check (kind = 'wallet_topup' or (tier is not null and days is not null))
);
-- The same transfer reference can't be credited twice (slip re-use / double entry).
create unique index if not exists payments_ref_unique on public.payments (method, reference) where reference is not null;
create index if not exists payments_created_idx on public.payments (created_at desc);
alter table public.payments enable row level security;
revoke all on public.payments from anon, authenticated;  -- reads/writes only via admin_* functions

-- ---------- Application review columns --------------------------------------
alter table public.worker_applications
  add column if not exists reject_reason text,
  add column if not exists reviewed_by   uuid references public.users (id),
  add column if not exists reviewed_at   timestamptz;

-- ---------- Admin functions --------------------------------------------------
create or replace function public.admin_stats()
returns table (pending_apps int, gold int, platinum int, diamond int, expiring_7d int,
               membership_month numeric, topup_month numeric)
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.assert_admin();
  return query select
    (select count(*)::int from public.worker_applications where status = 'pending'),
    (select count(*)::int from public.users where vip_tier = 1 and vip_expires_at > now()),
    (select count(*)::int from public.users where vip_tier = 2 and vip_expires_at > now()),
    (select count(*)::int from public.users where vip_tier = 3 and vip_expires_at > now()),
    (select count(*)::int from public.users where vip_tier > 0 and vip_expires_at > now()
        and vip_expires_at < now() + interval '7 days'),
    coalesce((select sum(amount) from public.payments where kind = 'membership'
               and created_at >= date_trunc('month', now())), 0),
    coalesce((select sum(amount) from public.payments where kind = 'wallet_topup'
               and created_at >= date_trunc('month', now())), 0);
end $$;

create or replace function public.admin_list_applications(p_status text default 'pending')
returns table (id uuid, user_id uuid, user_name text, display_name text, categories text[], price numeric,
               province text, district text, nearby text, phone text, line_id text, note text,
               profile_image text, original_path text, status text, reject_reason text, created_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.assert_admin();
  return query
    select a.id, a.user_id, u.display_name, a.display_name, a.categories, a.price,
           a.province, a.district, a.nearby, a.phone, a.line_id, a.note,
           a.profile_image, a.original_path, a.status, a.reject_reason, a.created_at
      from public.worker_applications a join public.users u on u.id = a.user_id
     where p_status is null or a.status = p_status
     order by a.created_at desc
     limit 100;
end $$;

create or replace function public.admin_review_application(p_app uuid, p_approve boolean, p_reason text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public.assert_admin();
  if p_approve then
    perform public.approve_worker(p_app);            -- raises NOT_FOUND unless pending
    update public.worker_applications set reviewed_by = auth.uid(), reviewed_at = now() where id = p_app;
  else
    update public.worker_applications
       set status = 'rejected', reject_reason = left(nullif(btrim(p_reason), ''), 300),
           reviewed_by = auth.uid(), reviewed_at = now()
     where id = p_app and status = 'pending';
    if not found then raise exception 'NOT_FOUND'; end if;
  end if;
end $$;

create or replace function public.admin_search_users(p_q text)
returns table (id uuid, display_name text, line_user_id text, role public.user_role,
               wallet_balance numeric, vip_tier smallint, vip_expires_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.assert_admin();
  return query
    select u.id, u.display_name, u.line_user_id, u.role, u.wallet_balance, u.vip_tier, u.vip_expires_at
      from public.users u
     where btrim(p_q) <> ''
       and (u.display_name ilike '%' || btrim(p_q) || '%' or u.line_user_id ilike '%' || btrim(p_q) || '%')
     order by u.display_name
     limit 20;
end $$;

create or replace function public.admin_list_members()
returns table (id uuid, display_name text, line_user_id text, vip_tier smallint,
               vip_expires_at timestamptz, wallet_balance numeric)
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.assert_admin();
  return query
    select u.id, u.display_name, u.line_user_id, u.vip_tier, u.vip_expires_at, u.wallet_balance
      from public.users u
     where u.vip_tier > 0 and u.vip_expires_at > now()
     order by u.vip_expires_at;
end $$;

-- Records a payment AND applies it (membership extension or wallet credit) in one transaction.
create or replace function public.admin_record_payment(
  p_user uuid, p_kind text, p_tier int, p_days int, p_amount numeric,
  p_method text, p_reference text default null, p_note text default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare v uuid;
begin
  perform public.assert_admin();
  if not exists (select 1 from public.users where id = p_user) then raise exception 'USER_NOT_FOUND'; end if;
  if p_kind = 'membership' and (coalesce(p_tier, 0) not between 1 and 3 or coalesce(p_days, 0) not between 1 and 365) then
    raise exception 'BAD_INPUT';
  end if;

  begin
    insert into public.payments (user_id, kind, tier, days, amount, method, reference, note, recorded_by)
    values (p_user, p_kind,
            case when p_kind = 'membership' then p_tier end,
            case when p_kind = 'membership' then p_days end,
            p_amount, p_method, nullif(btrim(p_reference), ''), nullif(btrim(p_note), ''), auth.uid())
    returning id into v;
  exception when unique_violation then
    raise exception 'DUPLICATE_REFERENCE';
  end;

  if p_kind = 'membership' then
    perform public.set_membership(p_user, p_tier, p_days);
  else
    update public.users set wallet_balance = wallet_balance + p_amount where id = p_user;
  end if;
  return v;
end $$;

create or replace function public.admin_list_payments(p_limit int default 100)
returns table (id uuid, created_at timestamptz, user_id uuid, user_name text, kind text, tier smallint,
               days int, amount numeric, method text, reference text, note text, admin_name text)
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.assert_admin();
  return query
    select p.id, p.created_at, p.user_id, u.display_name, p.kind, p.tier, p.days, p.amount,
           p.method, p.reference, p.note, a.display_name
      from public.payments p
      join public.users u on u.id = p.user_id
      join public.users a on a.id = p.recorded_by
     order by p.created_at desc
     limit least(greatest(p_limit, 1), 500);
end $$;

revoke all on function public.is_admin(), public.assert_admin(), public.admin_stats(),
  public.admin_list_applications(text), public.admin_review_application(uuid, boolean, text),
  public.admin_search_users(text), public.admin_list_members(),
  public.admin_record_payment(uuid, text, int, int, numeric, text, text, text),
  public.admin_list_payments(int) from public, anon;
grant execute on function public.is_admin(), public.admin_stats(),
  public.admin_list_applications(text), public.admin_review_application(uuid, boolean, text),
  public.admin_search_users(text), public.admin_list_members(),
  public.admin_record_payment(uuid, text, int, int, numeric, text, text, text),
  public.admin_list_payments(int) to authenticated;
-- assert_admin() stays internal (no grant to authenticated).

-- Admins can open applicants' full-size originals (to verify the person) via signed URL.
drop policy if exists "worker-originals_admin_select" on storage.objects;
create policy "worker-originals_admin_select" on storage.objects for select to authenticated
  using (bucket_id = 'worker-originals' and public.is_admin());
