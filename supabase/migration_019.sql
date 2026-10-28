-- =============================================================================
-- migration_019.sql — run ONCE after migration_018.sql
-- Step 4b: modelling agencies ("สังกัด").
--   * An agency is a normal user with a row in public.agencies. It is never shown to customers; it has its own
--     back office (girls, income, chat). An admin approves the agency (name + logo) first.
--   * Plan: 1,000 THB / 30 days from the Wallet, 10 girls included, each extra girl +200 THB / 30 days.
--     While the plan is not active, the agency's girls disappear from the feed.
--   * A girl joins by opening the agency's link and applying herself (her own LINE account is the proof, so nobody
--     can post someone else's photos). The agency confirms her, an admin approves her as usual.
--   * Agency girls: the agency is the "recruiter" and takes that 40% share of every booking while she belongs to
--     it (no 90-day limit). Her chat income (30 THB) still goes to her. The agency may read and answer her chats.
--   * A girl can leave only when the agency's plan period has ended; an agency can remove a girl at any time.
-- =============================================================================

create or replace function public.agency_plan_price()    returns numeric language sql immutable as $$ select 1000::numeric $$;
create or replace function public.agency_slot_price()    returns numeric language sql immutable as $$ select 200::numeric $$;
create or replace function public.agency_included_girls() returns int    language sql immutable as $$ select 10 $$;
create or replace function public.agency_plan_days()     returns int     language sql immutable as $$ select 30 $$;

create table if not exists public.agencies (
  user_id         uuid primary key references public.users (id) on delete cascade,
  name            text not null check (char_length(btrim(name)) between 2 and 60),
  contact         text,
  logo_path       text,                         -- file in the public bucket agency-logos
  code            text not null unique,         -- the girls' invitation code (?agency=<code>)
  status          text not null default 'pending' check (status in ('pending', 'approved', 'rejected')),
  reject_reason   text,
  plan_expires_at timestamptz,
  extra_slots     int not null default 0 check (extra_slots >= 0),
  created_at      timestamptz not null default now(),
  reviewed_by     uuid references public.users (id),
  reviewed_at     timestamptz
);
alter table public.agencies enable row level security;
revoke all on public.agencies from anon, authenticated;
grant select on public.agencies to authenticated;
drop policy if exists agencies_own on public.agencies;
create policy agencies_own on public.agencies for select to authenticated using (user_id = auth.uid());

alter table public.workers add column if not exists agency_id uuid references public.agencies (user_id);
alter table public.worker_applications
  add column if not exists agency_code   text,
  add column if not exists agency_id     uuid references public.agencies (user_id),
  add column if not exists agency_status text check (agency_status in ('pending', 'accepted', 'rejected'));
grant insert (agency_code) on public.worker_applications to authenticated;       -- chosen once, when applying

-- Is the agency in good standing right now?
create or replace function public.agency_active(p_agency uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select a.status = 'approved' and a.plan_expires_at > now() and not public.is_suspended(a.user_id)
                     from public.agencies a where a.user_id = p_agency), false)
$$;

-- Visible to customers: not suspended itself, and (independent or its agency is active).
create or replace function public.worker_listed(p_worker uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select not public.is_suspended(p_worker)
     and coalesce((select w.agency_id is null or public.agency_active(w.agency_id)
                     from public.workers w where w.user_id = p_worker), false)
$$;

create or replace function public.is_agency_of(p_agency uuid, p_worker uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.workers w where w.user_id = p_worker and w.agency_id = p_agency)
$$;

-- ---------- Feed: hide girls whose agency is inactive; show the agency badge ---------------
create or replace function public.can_view_worker(w uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select w = auth.uid() or (public.worker_listed(w) and exists (
    select 1 from (
      select x.user_id, c as category,
             row_number() over (partition by c
               order by x.is_boosted desc, x.is_online desc, x.created_at, x.user_id)::int as rk
        from public.workers x, unnest(x.categories) c
       where public.worker_listed(x.user_id)
    ) r
    where r.user_id = w and public.can_view_category(r.category, r.rk, public.viewer_tier())
  ))
$$;

drop function if exists public.list_workers(text);
create function public.list_workers(p_category text default null)
returns table (
  user_id uuid, display_name text, category text, categories text[], price numeric,
  profile_image text, original_path text,
  is_online boolean, is_boosted boolean, rank int, can_view boolean,
  province text, district text, nearby text, agency_name text, agency_logo text
) language sql stable security definer set search_path = public as $$
  with tier as (select public.viewer_tier() as t),
  r as (
    select w.*, c as cat,
           row_number() over (partition by c
             order by w.is_boosted desc, w.is_online desc, w.created_at, w.user_id)::int as rk
      from public.workers w, unnest(w.categories) c
     where public.worker_listed(w.user_id)
  )
  select r.user_id, r.display_name, r.cat, r.categories, r.price, r.profile_image,
         case when public.can_view_category(r.cat, r.rk, tier.t) then r.original_path end,
         r.is_online, r.is_boosted, r.rk,
         public.can_view_category(r.cat, r.rk, tier.t),
         r.province, r.district, r.nearby, ag.name, ag.logo_path
    from r join tier on true
    left join public.agencies ag on ag.user_id = r.agency_id
   where p_category is null or r.cat = p_category
   order by r.cat, r.rk
$$;
revoke all on function public.list_workers(text) from public, anon;
grant execute on function public.list_workers(text) to authenticated;

-- ---------- Agency account ---------------------------------------------------------------------
create or replace function public.agency_new_code()
returns text language plpgsql volatile as $$
declare v text;
begin
  loop
    v := (select string_agg(substr('abcdefghjkmnpqrstuvwxyz23456789', 1 + floor(random() * 31)::int, 1), '') from generate_series(1, 8));
    exit when not exists (select 1 from public.agencies where code = v);
  end loop;
  return v;
end $$;

-- Apply (or re-apply after a rejection). The logo is uploaded to agency-logos/<user id>/logo.jpg first.
create or replace function public.agency_apply(p_name text, p_contact text, p_logo_path text)
returns void language plpgsql security definer set search_path = public as $$
declare a public.agencies;
begin
  if auth.uid() is null then raise exception 'FORBIDDEN'; end if;
  if public.is_suspended(auth.uid()) then raise exception 'SUSPENDED'; end if;
  if char_length(btrim(coalesce(p_name, ''))) not between 2 and 60 then raise exception 'BAD_INPUT'; end if;
  if p_logo_path is not null and p_logo_path not like auth.uid()::text || '/%' then raise exception 'BAD_INPUT'; end if;
  select * into a from public.agencies where user_id = auth.uid();
  if found and a.status = 'approved' then raise exception 'ALREADY_APPROVED'; end if;
  if found then
    update public.agencies set name = btrim(p_name), contact = nullif(btrim(coalesce(p_contact, '')), ''),
           logo_path = coalesce(p_logo_path, logo_path), status = 'pending', reject_reason = null
     where user_id = auth.uid();
  else
    insert into public.agencies (user_id, name, contact, logo_path, code)
    values (auth.uid(), btrim(p_name), nullif(btrim(coalesce(p_contact, '')), ''), p_logo_path, public.agency_new_code());
  end if;
end $$;

create or replace function public.agency_girl_count(p_agency uuid)
returns int language sql stable security definer set search_path = public as $$
  select (select count(*) from public.workers w where w.agency_id = p_agency)::int
       + (select count(*) from public.worker_applications x
           where x.agency_id = p_agency and x.agency_status = 'accepted' and x.status = 'pending')::int
$$;

create or replace function public.my_agency()
returns table (user_id uuid, name text, contact text, logo_path text, code text, status text, reject_reason text,
               plan_expires_at timestamptz, extra_slots int, girls int, capacity int, renewal_price numeric, active boolean)
language sql stable security definer set search_path = public as $$
  select a.user_id, a.name, a.contact, a.logo_path, a.code, a.status, a.reject_reason, a.plan_expires_at, a.extra_slots,
         public.agency_girl_count(a.user_id),
         public.agency_included_girls() + a.extra_slots,
         public.agency_plan_price() + public.agency_slot_price() * greatest(0, public.agency_girl_count(a.user_id) - public.agency_included_girls()),
         public.agency_active(a.user_id)
    from public.agencies a where a.user_id = auth.uid()
$$;

-- What a girl sees when she opens an agency link.
create or replace function public.agency_public(p_code text)
returns table (name text, logo_path text)
language sql stable security definer set search_path = public as $$
  select a.name, a.logo_path from public.agencies a where a.code = p_code and a.status = 'approved'
$$;

-- Pay / renew the plan from the Wallet.
create or replace function public.agency_pay_plan()
returns timestamptz language plpgsql security definer set search_path = public as $$
declare
  a public.agencies; v_extra int; v_price numeric; v_bal numeric; v_exp timestamptz;
begin
  if auth.uid() is null then raise exception 'FORBIDDEN'; end if;
  if public.is_suspended(auth.uid()) then raise exception 'SUSPENDED'; end if;
  select * into a from public.agencies where user_id = auth.uid() for update;
  if not found or a.status <> 'approved' then raise exception 'NOT_APPROVED'; end if;
  v_extra := greatest(0, public.agency_girl_count(a.user_id) - public.agency_included_girls());
  v_price := public.agency_plan_price() + public.agency_slot_price() * v_extra;
  select wallet_balance into v_bal from public.users where id = auth.uid() for update;
  if v_bal < v_price then raise exception 'INSUFFICIENT_BALANCE'; end if;
  v_exp := greatest(now(), coalesce(a.plan_expires_at, now())) + make_interval(days => public.agency_plan_days());
  perform set_config('app.ledger_kind', 'agency_plan', true);
  perform set_config('app.ledger_ref', a.user_id::text, true);
  update public.users set wallet_balance = wallet_balance - v_price where id = auth.uid();
  update public.agencies set plan_expires_at = v_exp, extra_slots = v_extra where user_id = a.user_id;
  return v_exp;
end $$;

-- One more girl slot for the running period.
create or replace function public.agency_buy_slot()
returns int language plpgsql security definer set search_path = public as $$
declare a public.agencies; v_bal numeric;
begin
  if auth.uid() is null then raise exception 'FORBIDDEN'; end if;
  select * into a from public.agencies where user_id = auth.uid() for update;
  if not found or not public.agency_active(a.user_id) then raise exception 'PLAN_INACTIVE'; end if;
  select wallet_balance into v_bal from public.users where id = auth.uid() for update;
  if v_bal < public.agency_slot_price() then raise exception 'INSUFFICIENT_BALANCE'; end if;
  perform set_config('app.ledger_kind', 'agency_slot', true);
  perform set_config('app.ledger_ref', a.user_id::text, true);
  update public.users set wallet_balance = wallet_balance - public.agency_slot_price() where id = auth.uid();
  update public.agencies set extra_slots = extra_slots + 1 where user_id = a.user_id;
  return a.extra_slots + 1;
end $$;

-- ---------- Girls joining -------------------------------------------------------------------------
create or replace function public.applications_set_agency()
returns trigger language plpgsql security definer set search_path = public as $$
declare v uuid;
begin
  if new.agency_code is null or btrim(new.agency_code) = '' then
    new.agency_code := null; new.agency_id := null; new.agency_status := null;
    return new;
  end if;
  select user_id into v from public.agencies where code = btrim(new.agency_code) and status = 'approved';
  if v is null or v = new.user_id then raise exception 'AGENCY_NOT_FOUND'; end if;
  new.agency_id := v;
  new.agency_status := 'pending';
  return new;
end $$;
drop trigger if exists applications_set_agency on public.worker_applications;
create trigger applications_set_agency before insert on public.worker_applications
  for each row execute function public.applications_set_agency();

create or replace function public.agency_pending_girls()
returns table (app_id uuid, display_name text, categories text[], province text, note text, created_at timestamptz)
language sql stable security definer set search_path = public as $$
  select x.id, x.display_name, x.categories, x.province, x.note, x.created_at
    from public.worker_applications x
   where x.agency_id = auth.uid() and x.agency_status = 'pending' and x.status = 'pending'
   order by x.created_at
$$;

create or replace function public.agency_review_girl(p_app uuid, p_accept boolean)
returns void language plpgsql security definer set search_path = public as $$
declare x public.worker_applications; a public.agencies;
begin
  select * into x from public.worker_applications
   where id = p_app and agency_id = auth.uid() and agency_status = 'pending' and status = 'pending' for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  select * into a from public.agencies where user_id = auth.uid() for update;
  if p_accept then
    if not public.agency_active(a.user_id) then raise exception 'PLAN_INACTIVE'; end if;
    if public.agency_girl_count(a.user_id) >= public.agency_included_girls() + a.extra_slots then raise exception 'NO_SLOT'; end if;
    update public.worker_applications set agency_status = 'accepted' where id = p_app;
  else
    update public.worker_applications set agency_status = 'rejected' where id = p_app;
  end if;
end $$;

create or replace function public.agency_girls()
returns table (user_id uuid, display_name text, categories text[], listed boolean, jobs_month int, earned numeric)
language sql stable security definer set search_path = public as $$
  select w.user_id, w.display_name, w.categories, public.worker_listed(w.user_id),
         (select count(*)::int from public.jobs j where j.worker_id = w.user_id and j.status in ('matched', 'completed')
             and j.created_at >= date_trunc('month', now())),
         coalesce((select sum(s.amount) from public.booking_shares s join public.jobs j on j.id = s.job_id
                    where s.role = 'recruiter' and s.beneficiary = auth.uid() and j.worker_id = w.user_id), 0)
    from public.workers w where w.agency_id = auth.uid() order by w.display_name
$$;

create or replace function public.agency_remove_girl(p_worker uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  update public.workers set agency_id = null where user_id = p_worker and agency_id = auth.uid();
  if not found then raise exception 'NOT_FOUND'; end if;
end $$;

-- A girl can leave only once the agency's plan period is over.
create or replace function public.my_worker_agency()
returns table (agency_name text, logo_path text, plan_expires_at timestamptz, can_leave boolean)
language sql stable security definer set search_path = public as $$
  select a.name, a.logo_path, a.plan_expires_at, not public.agency_active(a.user_id)
    from public.workers w join public.agencies a on a.user_id = w.agency_id where w.user_id = auth.uid()
$$;
create or replace function public.worker_leave_agency()
returns void language plpgsql security definer set search_path = public as $$
declare v uuid;
begin
  select agency_id into v from public.workers where user_id = auth.uid();
  if v is null then raise exception 'NOT_FOUND'; end if;
  if public.agency_active(v) then raise exception 'AGENCY_ACTIVE'; end if;
  update public.workers set agency_id = null where user_id = auth.uid();
end $$;

-- Admin approval of the girl needs the agency's confirmation first.
create or replace function public.approve_worker(p_app uuid)
returns void language plpgsql security definer set search_path = public as $$
declare a public.worker_applications;
begin
  select * into a from public.worker_applications where id = p_app and status = 'pending';
  if not found then raise exception 'NOT_FOUND'; end if;
  if a.agency_id is not null and a.agency_status is distinct from 'accepted' then raise exception 'AGENCY_NOT_CONFIRMED'; end if;
  update public.users set role = 'worker' where id = a.user_id;
  insert into public.workers (user_id, display_name, categories, price, province, district, nearby,
                              profile_image, original_path, recruiter_id, recruiter_until, agency_id)
  values (a.user_id, a.display_name, a.categories, a.price, a.province, a.district, a.nearby,
          a.profile_image, a.original_path, a.recruiter_id,
          case when a.recruiter_id is not null then now() + make_interval(days => public.recruiter_window_days()) end,
          a.agency_id)
  on conflict (user_id) do update
    set display_name = excluded.display_name, categories = excluded.categories, price = excluded.price,
        province = excluded.province, district = excluded.district, nearby = excluded.nearby,
        profile_image = coalesce(excluded.profile_image, public.workers.profile_image),
        original_path = coalesce(excluded.original_path, public.workers.original_path),
        agency_id = coalesce(excluded.agency_id, public.workers.agency_id);
  update public.worker_applications set status = 'approved' where id = p_app;
end $$;
revoke all on function public.approve_worker(uuid) from public, anon, authenticated;

-- The booking fee's "recruiter" share goes to the agency while the girl belongs to it.
create or replace function public.booking_recruiter(p_worker uuid)
returns uuid language plpgsql security definer set search_path = public as $$
declare w public.workers; v_until timestamptz;
begin
  select * into w from public.workers where user_id = p_worker for update;
  if not found then return null; end if;
  if w.agency_id is not null then return w.agency_id; end if;
  if w.recruiter_id is null or w.recruiter_lapsed then return null; end if;
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

create or replace function public.pay_booking_shares(p_job uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  j        public.jobs;
  v_rec    uuid;
  v_sales  uuid;
  v_a_rec  numeric;
  v_a_sal  numeric;
  v_kind   text;
begin
  select * into j from public.jobs where id = p_job;
  if not found or j.booking_fee <= 0 then return; end if;
  if exists (select 1 from public.booking_shares where job_id = p_job) then return; end if;

  v_rec   := public.booking_recruiter(j.worker_id);
  v_sales := public.resolve_sales(j.customer_id);
  if v_rec   is not null and public.is_suspended(v_rec) then v_rec := null; end if;
  if v_sales is not null and (v_sales = j.customer_id or public.is_suspended(v_sales)) then v_sales := null; end if;
  v_a_rec := case when v_rec   is not null then round(j.booking_fee * public.booking_share_recruiter_rate(), 2) else 0 end;
  v_a_sal := case when v_sales is not null then round(j.booking_fee * public.booking_share_sales_rate(), 2) else 0 end;
  v_kind  := case when exists (select 1 from public.agencies where user_id = v_rec) then 'agency_share' else 'booking_share_recruiter' end;

  if v_rec is not null then
    insert into public.booking_shares (job_id, role, beneficiary, amount) values (p_job, 'recruiter', v_rec, v_a_rec);
    perform set_config('app.ledger_kind', v_kind, true);
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

-- ---------- Chat: the agency reads and answers its girls' chats ------------------------------------
drop policy if exists threads_select on public.chat_threads;
create policy threads_select on public.chat_threads for select to authenticated
  using (auth.uid() in (customer_id, worker_id) or public.is_agency_of(auth.uid(), worker_id));
drop policy if exists messages_select on public.chat_messages;
create policy messages_select on public.chat_messages for select to authenticated using (exists (
  select 1 from public.chat_threads t
   where t.id = thread_id and (auth.uid() in (t.customer_id, t.worker_id) or public.is_agency_of(auth.uid(), t.worker_id))));

create or replace function public.send_message(p_thread uuid, p_body text, p_accept_fee boolean default false)
returns void language plpgsql security definer set search_path = public as $$
declare
  t   public.chat_threads;
  b   text := btrim(p_body);
  v_msg uuid;
  v_bal numeric;
  v_fee uuid;
  v_worker_side boolean;
begin
  select * into t from public.chat_threads
   where id = p_thread and (auth.uid() in (customer_id, worker_id) or public.is_agency_of(auth.uid(), worker_id)) for update;
  if not found then raise exception 'FORBIDDEN'; end if;
  v_worker_side := auth.uid() <> t.customer_id;
  if b is null or char_length(b) not between 1 and 500 then raise exception 'BAD_MESSAGE'; end if;
  if not v_worker_side and public.viewer_tier() < 1 then raise exception 'MEMBERS_ONLY'; end if;
  if (select count(*) from public.chat_messages
       where sender_id = auth.uid() and created_at > now() - interval '1 minute') >= 10 then
    raise exception 'RATE_LIMIT';
  end if;

  perform public.release_chat_holds(null, p_thread);

  if not v_worker_side
     and coalesce(t.paid_until, '-infinity') <= now()
     and not exists (select 1 from public.chat_fees where thread_id = p_thread and status = 'held') then
    if not p_accept_fee then raise exception 'FEE_CONSENT_REQUIRED'; end if;
    select wallet_balance into v_bal from public.users where id = t.customer_id for update;
    if v_bal < public.chat_fee_amount() then raise exception 'INSUFFICIENT_BALANCE'; end if;
    insert into public.chat_fees (thread_id, customer_id, worker_id, amount, worker_amount, platform_amount, hold_expires_at)
    values (p_thread, t.customer_id, t.worker_id, public.chat_fee_amount(), public.chat_fee_to_worker(),
            public.chat_fee_amount() - public.chat_fee_to_worker(), now() + make_interval(hours => public.chat_hold_hours()))
    returning id into v_fee;
    perform set_config('app.ledger_kind', 'chat_hold', true);
    perform set_config('app.ledger_ref', v_fee::text, true);
    update public.users set wallet_balance = wallet_balance - public.chat_fee_amount() where id = t.customer_id;
  end if;

  insert into public.chat_messages (thread_id, sender_id, body) values (p_thread, auth.uid(), b) returning id into v_msg;
  update public.chat_threads
     set last_message_at = now(),
         customer_last_read = case when not v_worker_side then now() else customer_last_read end,
         worker_last_read   = case when v_worker_side     then now() else worker_last_read end
   where id = p_thread;

  if v_worker_side and public.chat_reply_valid(b) then
    perform public.capture_chat_fee(p_thread, v_msg);
  end if;
end $$;

create or replace function public.chat_fee_status(p_thread uuid)
returns table (role text, state text, until timestamptz, amount numeric, worker_amount numeric, hold_hours int)
language plpgsql security definer set search_path = public as $$
declare
  t public.chat_threads;
  f public.chat_fees;
  v_role text;
begin
  select * into t from public.chat_threads
   where id = p_thread and (auth.uid() in (customer_id, worker_id) or public.is_agency_of(auth.uid(), worker_id));
  if not found then raise exception 'FORBIDDEN'; end if;
  v_role := case when auth.uid() = t.customer_id then 'customer' else 'worker' end;
  perform public.release_chat_holds(null, p_thread);
  select * into f from public.chat_fees where thread_id = p_thread and status = 'held';
  if found then
    return query select v_role, 'held', f.hold_expires_at, f.amount, f.worker_amount, public.chat_hold_hours();
  elsif coalesce(t.paid_until, '-infinity') > now() then
    return query select v_role, 'free', t.paid_until, public.chat_fee_amount(), public.chat_fee_to_worker(), public.chat_hold_hours();
  else
    return query select v_role, case when v_role = 'customer' then 'need_fee' else 'idle' end, null::timestamptz,
                        public.chat_fee_amount(), public.chat_fee_to_worker(), public.chat_hold_hours();
  end if;
end $$;

create or replace function public.mark_read(p_thread uuid)
returns void language sql security definer set search_path = public as $$
  update public.chat_threads
     set customer_last_read = case when auth.uid() = customer_id then now() else customer_last_read end,
         worker_last_read   = case when auth.uid() <> customer_id then now() else worker_last_read end
   where id = p_thread and (auth.uid() in (customer_id, worker_id) or public.is_agency_of(auth.uid(), worker_id));
$$;

create or replace function public.agency_threads()
returns table (id uuid, worker_id uuid, other_name text, girl_name text, last_body text, last_message_at timestamptz, unread int)
language sql stable security definer set search_path = public as $$
  select t.id, t.worker_id, coalesce(cu.display_name, '—'), w.display_name,
         (select m.body from public.chat_messages m where m.thread_id = t.id order by m.created_at desc limit 1),
         t.last_message_at,
         (select count(*)::int from public.chat_messages m
           where m.thread_id = t.id and m.sender_id = t.customer_id and m.created_at > t.worker_last_read)
    from public.chat_threads t
    join public.workers w  on w.user_id = t.worker_id and w.agency_id = auth.uid()
    join public.users   cu on cu.id = t.customer_id
   order by t.last_message_at desc nulls last
   limit 50
$$;

-- ---------- Admin: review agencies; applications show the agency --------------------------------------
create or replace function public.admin_list_agencies(p_status text default null)
returns table (user_id uuid, user_name text, name text, contact text, logo_path text, status text, reject_reason text,
               plan_expires_at timestamptz, girls int, created_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.assert_admin();
  return query
    select a.user_id, u.display_name, a.name, a.contact, a.logo_path, a.status, a.reject_reason, a.plan_expires_at,
           public.agency_girl_count(a.user_id), a.created_at
      from public.agencies a join public.users u on u.id = a.user_id
     where p_status is null or a.status = p_status
     order by (a.status = 'pending') desc, a.created_at desc limit 100;
end $$;

create or replace function public.admin_review_agency(p_user uuid, p_approve boolean, p_reason text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public.assert_admin();
  update public.agencies
     set status = case when p_approve then 'approved' else 'rejected' end,
         reject_reason = case when p_approve then null else left(nullif(btrim(coalesce(p_reason, '')), ''), 300) end,
         reviewed_by = auth.uid(), reviewed_at = now()
   where user_id = p_user and status = 'pending';
  if not found then raise exception 'NOT_FOUND'; end if;
end $$;

drop function if exists public.admin_list_applications(text);
create function public.admin_list_applications(p_status text default 'pending')
returns table (id uuid, user_id uuid, user_name text, display_name text, categories text[], price numeric,
               province text, district text, nearby text, phone text, line_id text, note text,
               profile_image text, original_path text, status text, reject_reason text, created_at timestamptz,
               agency_name text, agency_status text)
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.assert_admin();
  return query
    select a.id, a.user_id, u.display_name, a.display_name, a.categories, a.price,
           a.province, a.district, a.nearby, a.phone, a.line_id, a.note,
           a.profile_image, a.original_path, a.status, a.reject_reason, a.created_at,
           ag.name, a.agency_status
      from public.worker_applications a join public.users u on u.id = a.user_id
      left join public.agencies ag on ag.user_id = a.agency_id
     where p_status is null or a.status = p_status
     order by a.created_at desc
     limit 100;
end $$;

-- ---------- Logos: a public bucket, each agency writes only in its own folder while its application is open ------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('agency-logos', 'agency-logos', true, 1048576, array['image/jpeg', 'image/png'])
on conflict (id) do nothing;
drop policy if exists "agency-logos_insert" on storage.objects;
create policy "agency-logos_insert" on storage.objects for insert to authenticated
  with check (bucket_id = 'agency-logos' and (storage.foldername(name))[1] = auth.uid()::text
              and not exists (select 1 from public.agencies a where a.user_id = auth.uid() and a.status = 'approved'));
drop policy if exists "agency-logos_update" on storage.objects;
create policy "agency-logos_update" on storage.objects for update to authenticated
  using (bucket_id = 'agency-logos' and (storage.foldername(name))[1] = auth.uid()::text
         and not exists (select 1 from public.agencies a where a.user_id = auth.uid() and a.status = 'approved'));

revoke all on function public.agency_apply(text, text, text), public.my_agency(), public.agency_public(text),
  public.agency_pay_plan(), public.agency_buy_slot(), public.agency_pending_girls(), public.agency_review_girl(uuid, boolean),
  public.agency_girls(), public.agency_remove_girl(uuid), public.my_worker_agency(), public.worker_leave_agency(),
  public.agency_threads(), public.admin_list_agencies(text), public.admin_review_agency(uuid, boolean, text),
  public.admin_list_applications(text), public.agency_girl_count(uuid), public.agency_new_code(),
  public.agency_active(uuid), public.worker_listed(uuid), public.is_agency_of(uuid, uuid),
  public.send_message(uuid, text, boolean), public.chat_fee_status(uuid), public.mark_read(uuid)
  from public, anon;
grant execute on function public.agency_apply(text, text, text), public.my_agency(), public.agency_public(text),
  public.agency_pay_plan(), public.agency_buy_slot(), public.agency_pending_girls(), public.agency_review_girl(uuid, boolean),
  public.agency_girls(), public.agency_remove_girl(uuid), public.my_worker_agency(), public.worker_leave_agency(),
  public.agency_threads(), public.admin_list_agencies(text), public.admin_review_agency(uuid, boolean, text),
  public.admin_list_applications(text), public.send_message(uuid, text, boolean), public.chat_fee_status(uuid),
  public.mark_read(uuid) to authenticated;
-- policies call these helpers as the logged-in user
grant execute on function public.is_agency_of(uuid, uuid) to authenticated;
-- =============================================================================
