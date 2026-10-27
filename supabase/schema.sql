-- =============================================================================
-- PART 1: Supabase schema  (run in Supabase Dashboard > SQL Editor)
-- =============================================================================
-- Security model in one paragraph:
--   * The browser only ever uses the `anon` key + a logged-in user JWT.
--   * Money (wallet_balance), privileges (role, is_vip) and ranking (is_boosted)
--     can NOT be written by clients: column-level GRANTs block it. They are
--     changed only by SECURITY DEFINER triggers or by admins (service role /
--     SQL editor).
--   * Booking is a plain INSERT into `jobs`, but a BEFORE INSERT trigger
--     atomically checks + deducts the wallet and forces the fee, so the client
--     cannot cheat the amount or create a job without paying.
-- =============================================================================

create extension if not exists "pgcrypto";

-- ---------- Enums ------------------------------------------------------------
do $$ begin
  create type public.user_role  as enum ('customer', 'worker', 'partner');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.job_status as enum ('pending', 'matched', 'completed', 'cancelled');
exception when duplicate_object then null; end $$;

-- ---------- Tables -----------------------------------------------------------

-- One row per auth user. id == auth.users.id so RLS can use auth.uid().
create table if not exists public.users (
  id               uuid primary key references auth.users (id) on delete cascade,
  line_user_id     text unique not null,
  role             public.user_role not null default 'customer',
  wallet_balance   numeric(12,2) not null default 0 check (wallet_balance >= 0),
  is_vip           boolean not null default false,
  -- A PARTNER's own shareable code (the value used in ?ref=...). NULL for others.
  partner_ref_code text unique,
  -- A CUSTOMER's attribution: which partner brought them in (first-touch).
  referred_by      uuid references public.users (id) on delete set null,
  created_at       timestamptz not null default now()
);

create table if not exists public.workers (
  user_id       uuid primary key references public.users (id) on delete cascade,
  display_name  text not null,
  service_types text[] not null default '{}',          -- e.g. {'massage','singer'}
  price         numeric(12,2) not null check (price >= 0), -- cash paid to worker
  profile_image text,                                    -- public Storage URL
  is_online     boolean not null default false,
  is_boosted    boolean not null default false,          -- paid "Top Rank" (admin-set)
  created_at    timestamptz not null default now()
);

create table if not exists public.jobs (
  id            uuid primary key default gen_random_uuid(),
  customer_id   uuid not null references public.users (id),
  worker_id     uuid not null references public.workers (user_id),
  status        public.job_status not null default 'pending',
  booking_fee   numeric(12,2) not null,                  -- platform fee (forced by trigger)
  service_price numeric(12,2) not null default 0,        -- snapshot of worker.price at booking
  created_at    timestamptz not null default now()
);

create index if not exists workers_rank_idx on public.workers (is_boosted desc, is_online desc);
create index if not exists jobs_customer_idx on public.jobs (customer_id, created_at desc);
create index if not exists jobs_worker_idx   on public.jobs (worker_id,   created_at desc);

-- ---------- Config -----------------------------------------------------------
-- Single source of truth for the platform fee. Change here, not in the client.
create or replace function public.platform_booking_fee()
returns numeric language sql immutable as $$ select 500::numeric $$;

-- ---------- Triggers ---------------------------------------------------------

-- 1) Auto-create the public profile when an auth user signs up.
--    The `line-auth` Edge Function (and the mock login) pass line_user_id in
--    user_metadata.
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.users (id, line_user_id)
  values (new.id, coalesce(new.raw_user_meta_data ->> 'line_user_id', 'anon:' || new.id));
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- 2) Booking: validate, charge wallet, force fee/status. Runs atomically with the INSERT.
create or replace function public.jobs_before_insert()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_fee   numeric := public.platform_booking_fee();
  v_price numeric;
  v_balance numeric;
begin
  -- Only act for the logged-in customer on their own behalf (service role may bypass).
  if auth.uid() is not null and new.customer_id <> auth.uid() then
    raise exception 'FORBIDDEN';
  end if;

  select price into v_price from public.workers
   where user_id = new.worker_id and is_online;
  if not found then
    raise exception 'WORKER_UNAVAILABLE';
  end if;

  -- Row lock prevents double-spend from two concurrent bookings.
  select wallet_balance into v_balance from public.users
   where id = new.customer_id for update;
  if v_balance is null or v_balance < v_fee then
    raise exception 'INSUFFICIENT_BALANCE';
  end if;

  update public.users set wallet_balance = wallet_balance - v_fee where id = new.customer_id;

  new.booking_fee   := v_fee;     -- ignore whatever the client sent
  new.service_price := v_price;
  new.status        := 'pending';
  return new;
end $$;

drop trigger if exists jobs_before_insert on public.jobs;
create trigger jobs_before_insert
  before insert on public.jobs
  for each row execute function public.jobs_before_insert();

-- 3) Status changes: only legal transitions, only by the right party.
--    NOTE: refund policy on cancel is a business decision and is NOT implemented here.
create or replace function public.jobs_guard_update()
returns trigger language plpgsql set search_path = public as $$
declare
  me uuid := auth.uid();
begin
  if me is null then return new; end if;                  -- admin / service role
  if new.status = old.status then return new; end if;

  if me = new.customer_id and old.status = 'pending' and new.status = 'cancelled' then
    return new;
  elsif me = new.worker_id and (
       (old.status = 'pending' and new.status in ('matched', 'cancelled'))
    or (old.status = 'matched' and new.status in ('completed', 'cancelled'))
  ) then
    return new;
  end if;
  raise exception 'ILLEGAL_STATUS_TRANSITION';
end $$;

drop trigger if exists jobs_guard_update on public.jobs;
create trigger jobs_guard_update
  before update on public.jobs
  for each row execute function public.jobs_guard_update();

-- ---------- Partner attribution RPC -----------------------------------------
-- Sets users.referred_by ONCE (first touch) from a partner's ref code.
create or replace function public.attribute_referrer(p_code text)
returns boolean language plpgsql security definer set search_path = public as $$
declare
  v_partner uuid;
begin
  select id into v_partner from public.users
   where partner_ref_code = p_code and role = 'partner';
  if v_partner is null or v_partner = auth.uid() then return false; end if;

  update public.users set referred_by = v_partner
   where id = auth.uid() and referred_by is null;
  return found;
end $$;

revoke all on function public.attribute_referrer(text) from public, anon;
grant execute on function public.attribute_referrer(text) to authenticated;

-- ---------- Column-level privileges (what clients may touch at all) ----------
revoke all on public.users, public.workers, public.jobs from anon, authenticated;

grant select on public.users to authenticated;                 -- no client writes at all
grant select on public.workers to authenticated;
grant insert (user_id, display_name, service_types, price, profile_image, is_online)
  on public.workers to authenticated;                          -- is_boosted excluded
grant update (display_name, service_types, price, profile_image, is_online)
  on public.workers to authenticated;
grant select on public.jobs to authenticated;
grant insert (customer_id, worker_id, booking_fee) on public.jobs to authenticated;
grant update (status) on public.jobs to authenticated;

-- ---------- Row Level Security ----------------------------------------------
alter table public.users   enable row level security;
alter table public.workers enable row level security;
alter table public.jobs    enable row level security;

-- users: you can read only your own row (wallet, vip flag, ...).
drop policy if exists users_select_own on public.users;
create policy users_select_own on public.users
  for select to authenticated using (id = auth.uid());

-- workers: any signed-in user can browse; only an approved worker edits their own card.
-- (role = 'worker' is granted by an admin after vetting.)
drop policy if exists workers_select_all on public.workers;
create policy workers_select_all on public.workers
  for select to authenticated using (true);

drop policy if exists workers_insert_own on public.workers;
create policy workers_insert_own on public.workers
  for insert to authenticated
  with check (
    user_id = auth.uid()
    and exists (select 1 from public.users u where u.id = auth.uid() and u.role = 'worker')
  );

drop policy if exists workers_update_own on public.workers;
create policy workers_update_own on public.workers
  for update to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

-- jobs: visible to the two parties; customer creates; either party updates status
-- (transitions policed by jobs_guard_update).
drop policy if exists jobs_select_parties on public.jobs;
create policy jobs_select_parties on public.jobs
  for select to authenticated
  using (customer_id = auth.uid() or worker_id = auth.uid());

drop policy if exists jobs_insert_customer on public.jobs;
create policy jobs_insert_customer on public.jobs
  for insert to authenticated with check (customer_id = auth.uid());

drop policy if exists jobs_update_parties on public.jobs;
create policy jobs_update_parties on public.jobs
  for update to authenticated
  using (customer_id = auth.uid() or worker_id = auth.uid())
  with check (customer_id = auth.uid() or worker_id = auth.uid());

-- ---------- Realtime (wallet balance + job status live updates) --------------
alter publication supabase_realtime add table public.users, public.jobs;
