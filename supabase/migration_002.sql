-- =============================================================================
-- migration_002.sql  — run ONCE in SQL Editor, AFTER schema.sql
-- Adds: 5 categories, membership tiers (30 days), face-mosaic photo storage,
--       worker applications + admin approval, worker job inbox, refund on decline.
-- =============================================================================

-- ---------- 1) users: display name + membership ------------------------------
alter table public.users
  add column if not exists display_name   text,
  add column if not exists vip_tier       smallint not null default 0 check (vip_tier between 0 and 3),
  add column if not exists vip_expires_at timestamptz;
-- (users.is_vip from schema.sql is no longer used; tier + expiry replace it.)

create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.users (id, line_user_id, display_name)
  values (new.id,
          coalesce(new.raw_user_meta_data ->> 'line_user_id', 'anon:' || new.id),
          left(new.raw_user_meta_data ->> 'display_name', 60));
  return new;
end $$;

-- The client reports its LINE display name on every login (cosmetic only).
create or replace function public.touch_profile(p_name text)
returns void language sql security definer set search_path = public as $$
  update public.users set display_name = left(p_name, 60) where id = auth.uid();
$$;

-- ---------- 2) workers: category + private original photo --------------------
alter table public.workers
  add column if not exists category text not null default 'ent'
    check (category in ('bartender','ent','ent_hard','masseuse','spa_vip')),
  add column if not exists original_path text;   -- path in private bucket 'worker-originals'
-- profile_image now = PUBLIC teaser (face mosaicked by the worker's browser).

-- Re-map the 4 demo workers from seed.sql (harmless if they don't exist).
update public.workers set category = 'masseuse' where user_id = '00000000-0000-0000-0000-000000000001';
update public.workers set category = 'ent'      where user_id = '00000000-0000-0000-0000-000000000002';
update public.workers set category = 'spa_vip'  where user_id = '00000000-0000-0000-0000-000000000003';
update public.workers set category = 'bartender' where user_id = '00000000-0000-0000-0000-000000000004';

-- Workers can only read their OWN row directly; everyone else goes via list_workers().
revoke all on public.workers from anon, authenticated;
grant select on public.workers to authenticated;
grant update (display_name, price, profile_image, original_path, is_online)
  on public.workers to authenticated;            -- category / is_boosted: admin only

drop policy if exists workers_select_all  on public.workers;
drop policy if exists workers_insert_own  on public.workers;
drop policy if exists workers_select_own  on public.workers;
create policy workers_select_own on public.workers
  for select to authenticated using (user_id = auth.uid());

-- ---------- 3) Access rules (single source of truth) -------------------------
-- tier 0 (free): bartender + ent, only the top 10 of each category
-- tier 1 (100) : bartender + ent, everyone
-- tier 2 (200) : + masseuse
-- tier 3 (300) : everything
create or replace function public.viewer_tier()
returns int language sql stable security definer set search_path = public as $$
  select coalesce((select case when vip_expires_at > now() then vip_tier else 0 end
                     from public.users where id = auth.uid()), 0)
$$;

create or replace function public.can_view_category(p_cat text, p_rank int, p_tier int)
returns boolean language sql immutable as $$
  select p_tier >= (case p_cat when 'masseuse' then 2 when 'ent_hard' then 3 when 'spa_vip' then 3 else 0 end)
     and (p_tier > 0 or p_rank <= 10)
$$;

-- Rank inside a category: boosted first, then online, then oldest.
create or replace function public.can_view_worker(w uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select w = auth.uid() or exists (
    select 1 from (
      select user_id, category,
             row_number() over (partition by category
               order by is_boosted desc, is_online desc, created_at, user_id)::int as rk
        from public.workers
    ) r
    where r.user_id = w and public.can_view_category(r.category, r.rk, public.viewer_tier())
  )
$$;

-- The feed. original_path is only returned for workers the caller may view.
create or replace function public.list_workers(p_category text default null)
returns table (
  user_id uuid, display_name text, category text, price numeric,
  profile_image text, original_path text,
  is_online boolean, is_boosted boolean, rank int, can_view boolean
) language sql stable security definer set search_path = public as $$
  with tier as (select public.viewer_tier() as t),
  r as (
    select w.*, row_number() over (partition by w.category
             order by w.is_boosted desc, w.is_online desc, w.created_at, w.user_id)::int as rk
      from public.workers w
  )
  select r.user_id, r.display_name, r.category, r.price, r.profile_image,
         case when public.can_view_category(r.category, r.rk, tier.t) then r.original_path end,
         r.is_online, r.is_boosted, r.rk,
         public.can_view_category(r.category, r.rk, tier.t)
    from r, tier
   where p_category is null or r.category = p_category
   order by r.category, r.rk
$$;

-- ---------- 4) Booking guard + refund on decline -----------------------------
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

  update public.users set wallet_balance = wallet_balance - v_fee where id = new.customer_id;

  new.booking_fee   := v_fee;
  new.service_price := v_price;
  new.status        := 'pending';
  return new;
end $$;

-- BUSINESS DECISION (change if you disagree): a PENDING job that is cancelled /
-- declined is refunded, because no service happened. matched -> cancelled is NOT
-- refunded automatically; handle those manually (admin).
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
    update public.users set wallet_balance = wallet_balance + old.booking_fee
     where id = old.customer_id;
  end if;
  return new;
end $$;

-- ---------- 5) Worker inbox ---------------------------------------------------
create or replace function public.my_worker_jobs()
returns table (id uuid, status public.job_status, booking_fee numeric,
               service_price numeric, created_at timestamptz, customer_name text)
language sql stable security definer set search_path = public as $$
  select j.id, j.status, j.booking_fee, j.service_price, j.created_at, u.display_name
    from public.jobs j join public.users u on u.id = j.customer_id
   where j.worker_id = auth.uid()
   order by j.created_at desc
   limit 100
$$;

-- ---------- 6) Worker applications -------------------------------------------
create table if not exists public.worker_applications (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null references public.users (id) on delete cascade,
  display_name text not null,
  category     text not null check (category in ('bartender','ent','ent_hard','masseuse','spa_vip')),
  price        numeric(12,2) not null check (price >= 0),
  contact      text,
  note         text,
  status       text not null default 'pending' check (status in ('pending','approved','rejected')),
  created_at   timestamptz not null default now()
);
create unique index if not exists one_pending_application
  on public.worker_applications (user_id) where status = 'pending';

alter table public.worker_applications enable row level security;
revoke all on public.worker_applications from anon, authenticated;
grant select on public.worker_applications to authenticated;
grant insert (user_id, display_name, category, price, contact, note)
  on public.worker_applications to authenticated;

drop policy if exists app_select_own on public.worker_applications;
create policy app_select_own on public.worker_applications
  for select to authenticated using (user_id = auth.uid());
drop policy if exists app_insert_own on public.worker_applications;
create policy app_insert_own on public.worker_applications
  for insert to authenticated with check (user_id = auth.uid());

-- ---------- 7) Admin functions (NOT callable from the app) -------------------
-- Run from the SQL Editor, e.g.   select public.approve_worker('<application id>');
create or replace function public.approve_worker(p_app uuid)
returns void language plpgsql security definer set search_path = public as $$
declare a public.worker_applications;
begin
  select * into a from public.worker_applications where id = p_app and status = 'pending';
  if not found then raise exception 'NOT_FOUND'; end if;
  update public.users set role = 'worker' where id = a.user_id;
  insert into public.workers (user_id, display_name, category, price)
  values (a.user_id, a.display_name, a.category, a.price)
  on conflict (user_id) do update
    set display_name = excluded.display_name, category = excluded.category, price = excluded.price;
  update public.worker_applications set status = 'approved' where id = p_app;
end $$;

-- Grant / extend membership:  select public.set_membership('<user id>', 1, 30);
-- Same tier while still active => extends from the current expiry; otherwise starts now.
create or replace function public.set_membership(p_user uuid, p_tier int, p_days int default 30)
returns void language sql security definer set search_path = public as $$
  update public.users
     set vip_expires_at = (case when vip_tier = p_tier and vip_expires_at > now()
                                then vip_expires_at else now() end) + make_interval(days => p_days),
         vip_tier = p_tier
   where id = p_user;
$$;

-- Function permissions: only signed-in users may call the app-facing ones.
revoke all on function public.touch_profile(text), public.viewer_tier(),
  public.can_view_worker(uuid), public.list_workers(text), public.my_worker_jobs()
  from public, anon;
grant execute on function public.touch_profile(text), public.viewer_tier(),
  public.can_view_worker(uuid), public.list_workers(text), public.my_worker_jobs()
  to authenticated;
revoke all on function public.approve_worker(uuid), public.set_membership(uuid, int, int)
  from public, anon, authenticated;

-- ---------- 8) Storage: public (mosaic) + private (original) buckets ---------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types) values
  ('worker-public',    'worker-public',    true,  5242880, array['image/jpeg']),
  ('worker-originals', 'worker-originals', false, 5242880, array['image/jpeg'])
on conflict (id) do nothing;

-- Each worker writes only inside their own folder  <uid>/...
do $$
declare b text;
begin
  foreach b in array array['worker-public', 'worker-originals'] loop
    execute format('drop policy if exists "%1$s_insert" on storage.objects', b);
    execute format('drop policy if exists "%1$s_delete" on storage.objects', b);
    execute format($p$create policy "%1$s_insert" on storage.objects for insert to authenticated
      with check (bucket_id = %1$L and (storage.foldername(name))[1] = auth.uid()::text
        and exists (select 1 from public.users u where u.id = auth.uid() and u.role = 'worker'))$p$, b);
    execute format($p$create policy "%1$s_delete" on storage.objects for delete to authenticated
      using (bucket_id = %1$L and (storage.foldername(name))[1] = auth.uid()::text)$p$, b);
  end loop;
end $$;

-- Originals can be read (signed URL) only by the owner or members allowed to view that worker.
drop policy if exists "worker-originals_select" on storage.objects;
create policy "worker-originals_select" on storage.objects for select to authenticated
  using (bucket_id = 'worker-originals'
         and public.can_view_worker(((storage.foldername(name))[1])::uuid));
