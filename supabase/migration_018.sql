-- =============================================================================
-- migration_018.sql — run ONCE after migration_017.sql
-- Step 4a: the booking fee (500 THB) is shared when the provider accepts a booking:
--     40% the provider's RECRUITER   40% the customer's SALES   20% platform
--   * recruiter = whoever's link the provider came in through (set when she applies), paid for 90 days
--     from approval; the 90 days renew automatically (another 90) when she had at least one booking in the
--     30 days before the window ended, otherwise the recruiter's share ends for good.
--   * sales     = the customer's sales (migration_015: link rules, 24 h takeover).
--   * a share without an owner (or an owner who is suspended) stays with the platform.
--   * shares go to the BONUS wallet when the provider accepts (status matched). A pending booking that is
--     cancelled/declined is refunded in full (nothing was shared yet).
-- Also: my_earnings() = income by source, for the "my earnings" view.
-- =============================================================================

create or replace function public.booking_share_recruiter_rate() returns numeric language sql immutable as $$ select 0.40::numeric $$;
create or replace function public.booking_share_sales_rate()     returns numeric language sql immutable as $$ select 0.40::numeric $$;
create or replace function public.recruiter_window_days()       returns int     language sql immutable as $$ select 90 $$;
create or replace function public.recruiter_active_days()        returns int     language sql immutable as $$ select 30 $$;

-- ---------- Recruiter on applications and providers ----------------------------------
alter table public.worker_applications add column if not exists recruiter_id uuid references public.users (id);
alter table public.workers
  add column if not exists recruiter_id     uuid references public.users (id),
  add column if not exists recruiter_until  timestamptz,
  add column if not exists recruiter_lapsed boolean not null default false;

-- Set on the server when an application is created: a link opened within the last 24 h, else the link she registered with.
create or replace function public.applications_set_recruiter()
returns trigger language plpgsql security definer set search_path = public as $$
declare v uuid;
begin
  select c.referrer_id into v from public.referral_clicks c
   where c.user_id = new.user_id and c.clicked_at > now() - interval '24 hours';
  if v is null then select referred_by into v from public.users where id = new.user_id; end if;
  new.recruiter_id := case when v is distinct from new.user_id then v end;
  return new;
end $$;
drop trigger if exists applications_set_recruiter on public.worker_applications;
create trigger applications_set_recruiter before insert on public.worker_applications
  for each row execute function public.applications_set_recruiter();

create or replace function public.approve_worker(p_app uuid)
returns void language plpgsql security definer set search_path = public as $$
declare a public.worker_applications;
begin
  select * into a from public.worker_applications where id = p_app and status = 'pending';
  if not found then raise exception 'NOT_FOUND'; end if;
  update public.users set role = 'worker' where id = a.user_id;
  insert into public.workers (user_id, display_name, categories, price, province, district, nearby,
                              profile_image, original_path, recruiter_id, recruiter_until)
  values (a.user_id, a.display_name, a.categories, a.price, a.province, a.district, a.nearby,
          a.profile_image, a.original_path, a.recruiter_id,
          case when a.recruiter_id is not null then now() + make_interval(days => public.recruiter_window_days()) end)
  on conflict (user_id) do update
    set display_name = excluded.display_name, categories = excluded.categories, price = excluded.price,
        province = excluded.province, district = excluded.district, nearby = excluded.nearby,
        profile_image = coalesce(excluded.profile_image, public.workers.profile_image),
        original_path = coalesce(excluded.original_path, public.workers.original_path);   -- keeps the existing recruiter
  update public.worker_applications set status = 'approved' where id = p_app;
end $$;
revoke all on function public.approve_worker(uuid) from public, anon, authenticated;

-- ---------- Who is the recruiter right now? ------------------------------------------
-- Rolls the 90-day window forward while the provider stayed active; ends it for good otherwise.
create or replace function public.booking_recruiter(p_worker uuid)
returns uuid language plpgsql security definer set search_path = public as $$
declare w public.workers; v_until timestamptz;
begin
  select * into w from public.workers where user_id = p_worker for update;
  if not found or w.recruiter_id is null or w.recruiter_lapsed then return null; end if;
  v_until := w.recruiter_until;
  while v_until <= now() loop
    if exists (select 1 from public.jobs j
                where j.worker_id = p_worker and j.status in ('matched', 'completed')
                  and j.created_at >= v_until - make_interval(days => public.recruiter_active_days())
                  and j.created_at <  v_until) then
      v_until := v_until + make_interval(days => public.recruiter_window_days());
    else
      update public.workers set recruiter_lapsed = true where user_id = p_worker;
      return null;
    end if;
  end loop;
  if v_until is distinct from w.recruiter_until then
    update public.workers set recruiter_until = v_until where user_id = p_worker;
  end if;
  return w.recruiter_id;
end $$;

-- ---------- Sharing the fee ------------------------------------------------------------
create table if not exists public.booking_shares (
  id          uuid primary key default gen_random_uuid(),
  job_id      uuid not null references public.jobs (id),
  role        text not null check (role in ('recruiter', 'sales', 'platform')),
  beneficiary uuid references public.users (id),         -- null for the platform
  amount      numeric(12,2) not null,
  created_at  timestamptz not null default now(),
  unique (job_id, role)
);
create index if not exists booking_shares_ben_idx on public.booking_shares (beneficiary, created_at desc);
alter table public.booking_shares enable row level security;
revoke all on public.booking_shares from anon, authenticated;

create or replace function public.pay_booking_shares(p_job uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  j        public.jobs;
  v_rec    uuid;
  v_sales  uuid;
  v_a_rec  numeric;
  v_a_sal  numeric;
begin
  select * into j from public.jobs where id = p_job;
  if not found or j.booking_fee <= 0 then return; end if;
  if exists (select 1 from public.booking_shares where job_id = p_job) then return; end if;   -- once per booking

  v_rec   := public.booking_recruiter(j.worker_id);
  v_sales := public.resolve_sales(j.customer_id);
  if v_rec   is not null and (public.is_suspended(v_rec))   then v_rec := null; end if;
  if v_sales is not null and (v_sales = j.customer_id or public.is_suspended(v_sales)) then v_sales := null; end if;
  v_a_rec := case when v_rec   is not null then round(j.booking_fee * public.booking_share_recruiter_rate(), 2) else 0 end;
  v_a_sal := case when v_sales is not null then round(j.booking_fee * public.booking_share_sales_rate(), 2) else 0 end;

  if v_rec is not null then
    insert into public.booking_shares (job_id, role, beneficiary, amount) values (p_job, 'recruiter', v_rec, v_a_rec);
    perform set_config('app.ledger_kind', 'booking_share_recruiter', true);
    perform set_config('app.ledger_ref', p_job::text, true);
    update public.users set bonus_balance = bonus_balance + v_a_rec where id = v_rec;
  end if;
  if v_sales is not null then
    insert into public.booking_shares (job_id, role, beneficiary, amount) values (p_job, 'sales', v_sales, v_a_sal);
    perform set_config('app.ledger_kind', 'booking_share_sales', true);
    perform set_config('app.ledger_ref', p_job::text, true);
    update public.users set bonus_balance = bonus_balance + v_a_sal where id = v_sales;
  end if;
  insert into public.booking_shares (job_id, role, beneficiary, amount)
  values (p_job, 'platform', null, j.booking_fee - v_a_rec - v_a_sal);
end $$;
revoke all on function public.pay_booking_shares(uuid), public.booking_recruiter(uuid) from public, anon, authenticated;

create or replace function public.jobs_share_fee()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.status = 'matched' and old.status is distinct from 'matched' then
    perform public.pay_booking_shares(new.id);
  end if;
  return new;
end $$;
drop trigger if exists jobs_share_fee on public.jobs;
create trigger jobs_share_fee after update of status on public.jobs
  for each row execute function public.jobs_share_fee();

-- ---------- My earnings, by source ---------------------------------------------------------
create or replace function public.my_earnings()
returns table (kind text, total numeric, this_month numeric, n int)
language sql stable security definer set search_path = public as $$
  select l.kind, sum(l.amount), coalesce(sum(l.amount) filter (where l.created_at >= date_trunc('month', now())), 0), count(*)::int
    from public.wallet_ledger l
   where l.user_id = auth.uid() and l.wallet = 'bonus' and l.amount > 0
     and l.kind in ('referral_membership', 'booking_share_sales', 'booking_share_recruiter', 'chat_income', 'agency_share')
   group by l.kind
   order by sum(l.amount) desc
$$;
revoke all on function public.my_earnings() from public, anon;
grant execute on function public.my_earnings() to authenticated;
-- =============================================================================
