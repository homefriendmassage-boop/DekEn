-- =============================================================================
-- migration_065.sql — run ONCE after migration_064.sql
-- Final money rules for the booking fee (40 / 40 / 20), growth offers and agency locks.
--   * RECRUITER slot (40 %): the girl's agency if it is PAID and has at least one girl besides its owner; otherwise her recruiter (a seller /
--     provider who brought her, within 90 days, renewing while she works); otherwise the platform
--   * SALES slot (40 %): the customer's first inviter if a seller / provider / approved agency (an unpaid agency counts); otherwise the platform
--   * one person, one slot per booking: only an agency that is paid and has another girl may hold both
--   * a plain customer who brings a girl gets a one-time bonus (admin setting, 50), a seller / provider / agency who brings one gets 100 (admin
--     setting): paid when she accepts her FIRST booking, once per girl, never when the customer is the one who brought her
--   * new profiles (approved in the last 3 days, up to 6 per group) go right after the places that were bought, with a "new" badge
--   * an agency without a paid plan cannot read / answer chats of its girls and cannot open their photos and details; its page shows what
--     it missed this month (agency_missed)
-- =============================================================================

insert into public.app_settings (key, value) values
  ('recruit_bonus', '100'), ('recruit_bonus_customer', '50'), ('new_profile_days', '3'), ('new_profile_cap', '6')
on conflict (key) do nothing;

create or replace function public.growth_num(p_key text, p_default numeric)
returns numeric language sql stable security definer set search_path = public as $$
  select coalesce(nullif(public.app_setting(p_key), '')::numeric, p_default)
$$;
revoke all on function public.growth_num(text, numeric) from public, anon, authenticated;

-- ---------- agency eligibility ---------------------------------------------------------------------------------------------------------
create or replace function public.agency_recruiter_eligible(p_agency uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select public.agency_active(p_agency)
     and exists (select 1 from public.workers w where w.agency_id = p_agency and w.user_id <> p_agency and w.deleted_at is null)
$$;
revoke all on function public.agency_recruiter_eligible(uuid) from public, anon, authenticated;

-- ---------- recruiter slot ----------------------------------------------------------------------------------------------------------------
create or replace function public.booking_recruiter(p_worker uuid)
returns uuid language plpgsql security definer set search_path = public as $$
declare w public.workers; v_until timestamptz;
begin
  select * into w from public.workers where user_id = p_worker for update;
  if not found then return null; end if;
  -- 1) her agency, when it is paid and has another girl (an owner registering herself never earns on her own bookings)
  if w.agency_id is not null and w.agency_id <> w.user_id and public.agency_recruiter_eligible(w.agency_id) then return w.agency_id; end if;
  -- 2) otherwise the seller / provider who brought her
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
  if not public.is_seller_at(w.recruiter_id, now()) then return null; end if;
  return w.recruiter_id;
end $$;

-- ---------- sharing the fee -----------------------------------------------------------------------------------------------------------------
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
  v_sales := public.resolve_sales(j.customer_id, j.sales_vendor);
  if v_rec   is not null and public.is_suspended(v_rec) then v_rec := null; end if;
  if v_sales is not null and (v_sales = j.customer_id or public.is_suspended(v_sales)) then v_sales := null; end if;
  -- one person, one slot per booking: only an agency that is paid and has a girl besides its owner may hold both
  if v_rec is not null and v_sales = v_rec and not public.agency_recruiter_eligible(v_rec) then v_sales := null; end if;
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

create or replace function public.ranked_workers()
returns table (user_id uuid, category text, rank int, is_boosted boolean, free_rank int)
language sql stable security definer set search_path = public as $$
  with base0 as (
    select w.user_id, c as cat, w.is_boosted as pinned, w.is_online, w.created_at,
           (w.claimed and w.created_at > now() - make_interval(days => public.growth_num('new_profile_days', 3)::int)) as is_new,
           (select b.block from public.rank_boosts b
             where b.worker_id = w.user_id and b.category = c and b.ends_at > now()
             order by b.ends_at desc limit 1) as blk,
           (select min(b.created_at) from public.rank_boosts b
             where b.worker_id = w.user_id and b.category = c and b.ends_at > now()) as bought
      from public.workers w, unnest(w.categories) c
     where public.worker_listed(w.user_id)
  ),
  -- a profile approved in the last N days is "new": the first few (cap) go right after the places that were bought, rotating daily
  base as (select b.*, row_number() over (partition by b.cat, b.is_new order by md5(b.user_id::text || public.rotation_day()), b.user_id) as nrk from base0 b),
  pinned as (select *, row_number() over (partition by cat order by created_at, user_id) as pn from base where pinned),
  pcount as (select cat, count(*) as n from pinned group by cat),
  rest   as (select * from base where not pinned),
  bpos   as (select user_id, cat,
                    case blk when 'A' then 0 when 'B' then 4 else 8 end
                    + row_number() over (partition by cat, blk order by bought, user_id) as pos
               from rest where blk is not null),
  organic as (select user_id, cat, row_number() over (partition by cat order by (case when is_new and nrk <= public.growth_num('new_profile_cap', 6) then 0 else 1 end), is_online desc, md5(user_id::text || public.rotation_day()), user_id) as k
                from rest where blk is null),
  tot    as (select cat, count(*) as n from rest group by cat),
  free   as (select t.cat, s as pos, row_number() over (partition by t.cat order by s) as fk
               from tot t cross join lateral generate_series(1, t.n + 12) s
              where not exists (select 1 from bpos b where b.cat = t.cat and b.pos = s)),
  placed as (select user_id, cat, pos from bpos
             union all
             select o.user_id, o.cat, f.pos from organic o join free f on f.cat = o.cat and f.fk = o.k),
  ordered as (
    select p.user_id, p.cat, p.pn::int as rnk, true as boosted from pinned p
    union all
    select pl.user_id, pl.cat,
           (coalesce((select n from pcount c where c.cat = pl.cat), 0) + row_number() over (partition by pl.cat order by pl.pos))::int,
           exists (select 1 from bpos b where b.user_id = pl.user_id and b.cat = pl.cat)
      from placed pl
  ),
  daily as (
    select b.user_id, b.cat,
           row_number() over (partition by b.cat
                              order by (case when b.pinned then 0 when b.blk is not null then 1 else 2 end),
                                       (case b.blk when 'A' then 1 when 'B' then 2 when 'C' then 3 else 4 end),
                                       b.bought,
                                       md5(b.user_id::text || public.rotation_day()))::int as fr,
           count(*) filter (where b.pinned or b.blk is not null) over (partition by b.cat)::int as nb
      from base b
  )
  select o.user_id, o.cat, o.rnk, o.boosted,
         case when d.fr <= (case d.cat when 'bartender' then least(10, greatest(6, d.nb)) when 'ent' then least(10, greatest(6, d.nb)) when 'masseuse' then 3 else 0 end)
              then 1 else 99 end     -- 1 = clear face for free viewers, 99 = blurred
    from ordered o join daily d on d.user_id = o.user_id and d.cat = o.cat
$$;
revoke all on function public.ranked_workers() from public, anon;

-- ---------- viewing: only a PAID agency opens its own girls in full ---------------------------------------------------------------------
create or replace function public.can_view_worker(w uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select w = auth.uid()
      or (public.agency_active(auth.uid()) and exists (select 1 from public.workers x where x.user_id = w and x.agency_id = auth.uid()))      -- a PAID agency sees its own girls in full
      or (public.worker_listed(w) and exists (
    select 1 from public.ranked_workers() r
     where r.user_id = w and public.can_view_category(r.category, r.free_rank, public.view_tier())))
$$;

create or replace function public.list_workers(p_category text default null)
returns table (
  user_id uuid, display_name text, category text, categories text[], price numeric,
  profile_image text, original_path text,
  is_online boolean, is_boosted boolean, rank int, can_view boolean,
  province text, district text, nearby text, agency_name text, agency_logo text,
  gender text, age int, height_cm int, weight_kg int, measurements text, tags text[], about text, price_options jsonb,
  distance_km numeric, loc_verified boolean, start_rate text, start_price numeric, grp text, service_mode text, claimed boolean, is_busy boolean
) language sql stable security definer set search_path = public as $$
  with tier as (select public.view_tier() as t)
  select w.user_id, w.display_name, r.category, w.categories, w.price, w.profile_image,
         case when v.ok or coalesce(w.agency_id = auth.uid() and public.agency_active(auth.uid()), false) then w.original_path end,
         w.is_online, r.is_boosted, r.rank, (v.ok or coalesce(w.agency_id = auth.uid() and public.agency_active(auth.uid()), false)),
         w.province, w.district, w.nearby, ag.name, ag.logo_path,
         w.gender, case when lk.locked then null else w.age::int end, case when lk.locked then null else w.height_cm::int end,
         case when lk.locked then null else w.weight_kg::int end, case when lk.locked then null else w.measurements end,
         case when lk.locked then '{}'::text[] else w.tags end, case when lk.locked then null else w.about end,
         case when lk.locked then '[]'::jsonb else w.price_options end,
         null::numeric, (w.loc_verified_at is not null and w.loc_lat is not null), w.start_rate,
         case when w.start_rate = '1h' then w.price else (select (o->>'price')::numeric from jsonb_array_elements(w.price_options) o where o->>'label' = w.start_rate limit 1) end,
         w.grp, w.service_mode, w.claimed, public.worker_busy(w.user_id)
    from public.ranked_workers() r
    join public.workers w on w.user_id = r.user_id
    join tier on true
    cross join lateral (select public.can_view_category(r.category, r.free_rank, tier.t) as ok) v
    -- massage / spa details are for members only: the DATABASE leaves them out (not just the screen); the price from "เริ่มต้น" stays for the card
    cross join lateral (select r.category in ('masseuse', 'spa') and not (v.ok or coalesce(w.agency_id = auth.uid() and public.agency_active(auth.uid()), false)) as locked) lk
    left join public.agencies ag on ag.user_id = w.agency_id
   where p_category is null or r.category = p_category
   order by r.category, r.rank
$$;

-- ---------- an unpaid agency cannot read / answer chats or open its girls ----------------------------------------------------------------
create or replace function public.is_agency_of(p_agency uuid, p_worker uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select public.agency_active(p_agency) and exists (select 1 from public.workers w where w.user_id = p_worker and w.agency_id = p_agency)
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
   where public.agency_active(auth.uid())
   order by t.last_message_at desc nulls last
   limit 50
$$;

drop function if exists public.agency_girls();
create function public.agency_girls()
returns table (user_id uuid, display_name text, categories text[], listed boolean, jobs_month int, earned numeric, profile_image text)
language sql stable security definer set search_path = public as $$
  select w.user_id, w.display_name, w.categories, public.worker_listed(w.user_id),
         (select count(*)::int from public.jobs j where j.worker_id = w.user_id and j.status in ('matched', 'completed')
             and j.created_at >= date_trunc('month', now())),
         coalesce((select sum(s.amount) from public.booking_shares s join public.jobs j on j.id = s.job_id
                    where s.role = 'recruiter' and s.beneficiary = auth.uid() and j.worker_id = w.user_id), 0),
         case when public.agency_active(auth.uid()) then w.profile_image end
    from public.workers w where w.agency_id = auth.uid() order by w.display_name
$$;
revoke all on function public.agency_girls() from public, anon;
grant execute on function public.agency_girls() to authenticated;

-- what an agency that is not eligible for the 40 % missed this month
create or replace function public.agency_missed()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_n int; v_amt numeric;
begin
  if auth.uid() is null then raise exception 'FORBIDDEN'; end if;
  select count(*)::int, coalesce(sum(round(j.booking_fee * public.booking_share_recruiter_rate(), 2)), 0) into v_n, v_amt
    from public.jobs j join public.workers w on w.user_id = j.worker_id
   where w.agency_id = auth.uid() and j.status in ('matched', 'completed') and j.created_at >= date_trunc('month', now())
     and not exists (select 1 from public.booking_shares s where s.job_id = j.id and s.role = 'recruiter' and s.beneficiary = auth.uid());
  return jsonb_build_object('jobs', v_n, 'amount', v_amt, 'paid', public.agency_active(auth.uid()),
    'eligible', public.agency_recruiter_eligible(auth.uid()),
    'has_other_girl', exists (select 1 from public.workers w where w.agency_id = auth.uid() and w.user_id <> auth.uid() and w.deleted_at is null));
end $$;
revoke all on function public.agency_missed() from public, anon;
grant execute on function public.agency_missed() to authenticated;

-- ---------- new profiles ---------------------------------------------------------------------------------------------------------------------
create or replace function public.new_worker_ids()
returns uuid[] language sql stable security definer set search_path = public as $$
  select coalesce(array_agg(w.user_id), '{}') from public.workers w
   where w.claimed and w.created_at > now() - make_interval(days => public.growth_num('new_profile_days', 3)::int) and public.worker_listed(w.user_id)
$$;
revoke all on function public.new_worker_ids() from public, anon;
grant execute on function public.new_worker_ids() to authenticated;

-- ---------- who brought a girl: the first link she opened (any user) -----------------------------------------------------------------------
alter table public.worker_applications add column if not exists referrer_id uuid references public.users (id);

create or replace function public.applications_set_recruiter()
returns trigger language plpgsql security definer set search_path = public as $$
declare v uuid;
begin
  select c.referrer_id into v from public.referral_clicks c
   where c.user_id = new.user_id and c.clicked_at > now() - interval '24 hours';
  if v is null then select referred_by into v from public.users where id = new.user_id; end if;
  new.referrer_id := case when v is distinct from new.user_id then v end;                     -- anybody who brought her (for the one-time bonus)
  new.recruiter_id := case when v is distinct from new.user_id and v is not null and public.is_seller_at(v, now()) then v end;   -- the 40 % slot: sellers only
  return new;
end $$;

create table if not exists public.recruit_bonuses (
  worker_id uuid primary key references public.users (id) on delete cascade,
  referrer_id uuid not null references public.users (id),
  amount numeric not null, job_id uuid, created_at timestamptz not null default now()
);
alter table public.recruit_bonuses enable row level security;
revoke all on public.recruit_bonuses from anon, authenticated;

create or replace function public.trg_recruit_bonus() returns trigger language plpgsql security definer set search_path = public as $$
declare v_ref uuid; v_amt numeric;
begin
  if new.status <> 'matched' or old.status = 'matched' then return new; end if;
  if exists (select 1 from public.recruit_bonuses b where b.worker_id = new.worker_id) then return new; end if;
  select a.referrer_id into v_ref from public.worker_applications a where a.user_id = new.worker_id and a.referrer_id is not null order by a.created_at desc limit 1;
  if v_ref is null or v_ref = new.worker_id or v_ref = new.customer_id or public.is_suspended(v_ref) then return new; end if;
  v_amt := case when public.is_seller_at(v_ref, now()) then public.growth_num('recruit_bonus', 100) else public.growth_num('recruit_bonus_customer', 50) end;
  if v_amt <= 0 then return new; end if;
  insert into public.recruit_bonuses (worker_id, referrer_id, amount, job_id) values (new.worker_id, v_ref, v_amt, new.id);
  perform set_config('app.ledger_kind', 'recruit_bonus', true);
  perform set_config('app.ledger_ref', new.worker_id::text, true);
  update public.users set bonus_balance = bonus_balance + v_amt where id = v_ref;
  return new;
end $$;
drop trigger if exists jobs_recruit_bonus on public.jobs;
create trigger jobs_recruit_bonus after update of status on public.jobs for each row execute function public.trg_recruit_bonus();

create or replace function public.recruit_rewards()
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object('seller_bonus', public.growth_num('recruit_bonus', 100), 'customer_bonus', public.growth_num('recruit_bonus_customer', 50),
    'is_seller', public.is_seller_at(auth.uid(), now()) or exists (select 1 from public.users u where u.id = auth.uid() and u.seller_until > now()))
$$;
revoke all on function public.recruit_rewards() from public, anon;
grant execute on function public.recruit_rewards() to authenticated;

-- ---------- admin: the numbers -----------------------------------------------------------------------------------------------------------------
create or replace function public.admin_growth_settings()
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform public.assert_admin();
  return jsonb_build_object('recruit_bonus', public.growth_num('recruit_bonus', 100), 'recruit_bonus_customer', public.growth_num('recruit_bonus_customer', 50),
    'new_profile_days', public.growth_num('new_profile_days', 3), 'new_profile_cap', public.growth_num('new_profile_cap', 6),
    'bonuses_paid', (select coalesce(sum(amount), 0) from public.recruit_bonuses), 'bonuses_count', (select count(*) from public.recruit_bonuses));
end $$;

create or replace function public.admin_set_growth_setting(p_key text, p_value text)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public.assert_admin();
  if p_key not in ('recruit_bonus', 'recruit_bonus_customer', 'new_profile_days', 'new_profile_cap') then raise exception 'BAD_INPUT'; end if;
  if p_value is null or p_value !~ '^[0-9]{1,5}$' then raise exception 'BAD_INPUT'; end if;
  insert into public.app_settings (key, value, updated_at, updated_by) values (p_key, p_value, now(), auth.uid())
  on conflict (key) do update set value = excluded.value, updated_at = now(), updated_by = auth.uid();
end $$;
revoke all on function public.admin_growth_settings(), public.admin_set_growth_setting(text, text) from public, anon;
grant execute on function public.admin_growth_settings(), public.admin_set_growth_setting(text, text) to authenticated;
