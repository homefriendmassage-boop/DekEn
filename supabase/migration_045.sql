-- =============================================================================
-- migration_045.sql — run ONCE after migration_044.sql
--   * Flex reminders 3 days before a SELLER plan or an AGENCY plan ends (daily, pg_cron), and the "activated / renewed" Flex for agencies
--     (sellers already get it from migration_044): `plan_notify` -> notify-chat (type 'seller' | 'agency').
--   * an agency sees ITS OWN girls in full (photos, details) — nobody else gets that for free: providers and agencies pay for a package
--     like customers (nothing else changed there), and chat between any two accounts is paid from the Wallet as before.
--   * the order of the girls that nobody bought a place for now rotates every day (random but stable for the day); clear faces for free
--     viewers stay limited to the free groups (bartender / ENT); the other groups are shown with the face covered.
-- =============================================================================

alter table public.users add column if not exists seller_reminded_until timestamptz;
alter table public.agencies add column if not exists reminded_until timestamptz;

create or replace function public.plan_notify(p_type text, p_user uuid, p_event text)
returns void language plpgsql security definer set search_path = public as $$
declare v_url text; v_secret text;
begin
  select value into v_url from public.private_config where key = 'chat_notify_url';
  select value into v_secret from public.private_config where key = 'chat_notify_secret';
  if v_url is null or v_secret is null then return; end if;
  execute format('select net.http_post(url := %L, headers := %L::jsonb, body := %L::jsonb)', v_url,
    jsonb_build_object('Content-Type', 'application/json', 'x-webhook-secret', v_secret)::text,
    jsonb_build_object('type', p_type, 'event', p_event, 'user_id', p_user)::text);
exception when others then
  return;
end $$;
revoke all on function public.plan_notify(text, uuid, text) from public, anon, authenticated;

-- agency pays / renews: Flex like the sellers
create or replace function public.agency_pay_plan()
returns timestamptz language plpgsql security definer set search_path = public as $$
declare
  a public.agencies; v_extra int; v_price numeric; v_bal numeric; v_exp timestamptz; v_was boolean;
begin
  if auth.uid() is null then raise exception 'FORBIDDEN'; end if;
  if public.is_suspended(auth.uid()) then raise exception 'SUSPENDED'; end if;
  select * into a from public.agencies where user_id = auth.uid() for update;
  if not found or a.status <> 'approved' then raise exception 'NOT_APPROVED'; end if;
  v_extra := greatest(0, public.agency_girl_count(a.user_id) - public.agency_included_girls());
  v_price := public.agency_plan_price() + public.agency_slot_price() * v_extra;
  select wallet_balance into v_bal from public.users where id = auth.uid() for update;
  if v_bal < v_price then raise exception 'INSUFFICIENT_BALANCE'; end if;
  v_was := coalesce(a.plan_expires_at > now(), false);
  v_exp := greatest(now(), coalesce(a.plan_expires_at, now())) + make_interval(days => public.agency_plan_days());
  perform set_config('app.ledger_kind', 'agency_plan', true);
  perform set_config('app.ledger_ref', a.user_id::text, true);
  update public.users set wallet_balance = wallet_balance - v_price where id = auth.uid();
  update public.agencies set plan_expires_at = v_exp, extra_slots = v_extra where user_id = a.user_id;
  perform public.plan_notify('agency', a.user_id, case when v_was then 'renewed' else 'activated' end);
  return v_exp;
end $$;

-- 3 days before the plan ends (once per period)
create or replace function public.remind_plan_expiry()
returns int language plpgsql security definer set search_path = public as $$
declare r record; n int := 0;
begin
  for r in select u.id, u.seller_until as until from public.users u
            where u.seller_until > now() and u.seller_until <= now() + interval '3 days'
              and u.seller_reminded_until is distinct from u.seller_until and public.seller_free_via(u.id) is null loop
    perform public.plan_notify('seller', r.id, 'expiring');
    update public.users set seller_reminded_until = r.until where id = r.id;
    n := n + 1;
  end loop;
  for r in select a.user_id as id, a.plan_expires_at as until from public.agencies a
            where a.status = 'approved' and a.plan_expires_at > now() and a.plan_expires_at <= now() + interval '3 days'
              and a.reminded_until is distinct from a.plan_expires_at loop
    perform public.plan_notify('agency', r.id, 'expiring');
    update public.agencies set reminded_until = r.until where user_id = r.id;
    n := n + 1;
  end loop;
  return n;
end $$;
revoke all on function public.remind_plan_expiry() from public, anon, authenticated;

do $$ begin
  perform cron.schedule('remind-plan-expiry', '0 2 * * *', 'select public.remind_plan_expiry()');     -- 09:00 Thailand
exception when others then
  raise notice 'pg_cron is not enabled (%): schedule select public.remind_plan_expiry() daily yourself', sqlerrm;
end $$;

-- ---------- an agency sees its own girls ------------------------------------------------------------------------------------
create or replace function public.can_view_worker(w uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select w = auth.uid()
      or exists (select 1 from public.workers x where x.user_id = w and x.agency_id = auth.uid())      -- an agency sees its own girls in full
      or (public.worker_listed(w) and exists (
    select 1 from public.ranked_workers() r
     where r.user_id = w and public.can_view_category(r.category, r.free_rank, public.viewer_tier())))
$$;

drop function if exists public.agency_girls();
create or replace function public.agency_girls()
returns table (user_id uuid, display_name text, categories text[], listed boolean, jobs_month int, earned numeric, profile_image text)
language sql stable security definer set search_path = public as $$
  select w.user_id, w.display_name, w.categories, public.worker_listed(w.user_id),
         (select count(*)::int from public.jobs j where j.worker_id = w.user_id and j.status in ('matched', 'completed')
             and j.created_at >= date_trunc('month', now())),
         coalesce((select sum(s.amount) from public.booking_shares s join public.jobs j on j.id = s.job_id
                    where s.role = 'recruiter' and s.beneficiary = auth.uid() and j.worker_id = w.user_id), 0),
         w.profile_image
    from public.workers w where w.agency_id = auth.uid() order by w.display_name
$$;
revoke all on function public.agency_girls() from public, anon;
grant execute on function public.agency_girls() to authenticated;

-- ---------- daily rotation of the unbought places ---------------------------------------------------------------------------
create or replace function public.ranked_workers()
returns table (user_id uuid, category text, rank int, is_boosted boolean, free_rank int)
language sql stable security definer set search_path = public as $$
  with base as (
    select w.user_id, c as cat, w.is_boosted as pinned, w.is_online, w.created_at,
           (select b.block from public.rank_boosts b
             where b.worker_id = w.user_id and b.category = c and b.ends_at > now()
             order by b.ends_at desc limit 1) as blk,
           (select min(b.created_at) from public.rank_boosts b
             where b.worker_id = w.user_id and b.category = c and b.ends_at > now()) as bought
      from public.workers w, unnest(w.categories) c
     where public.worker_listed(w.user_id)
  ),
  pinned as (select *, row_number() over (partition by cat order by created_at, user_id) as pn from base where pinned),
  pcount as (select cat, count(*) as n from pinned group by cat),
  rest   as (select * from base where not pinned),
  bpos   as (select user_id, cat,
                    case blk when 'A' then 0 when 'B' then 4 else 8 end
                    + row_number() over (partition by cat, blk order by bought, user_id) as pos
               from rest where blk is not null),
  organic as (select user_id, cat, row_number() over (partition by cat order by is_online desc, md5(user_id::text || public.rotation_day()), user_id) as k
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
         case when d.fr <= least(10, greatest(6, d.nb)) then 1 else 99 end     -- 1 = clear face for free viewers, 99 = blurred
    from ordered o join daily d on d.user_id = o.user_id and d.cat = o.cat
$$;
revoke all on function public.ranked_workers() from public, anon;

drop function if exists public.get_worker(uuid);
drop function if exists public.list_workers_near(double precision, double precision, numeric, text);
drop function if exists public.list_workers(text);
create function public.list_workers(p_category text default null)
returns table (
  user_id uuid, display_name text, category text, categories text[], price numeric,
  profile_image text, original_path text,
  is_online boolean, is_boosted boolean, rank int, can_view boolean,
  province text, district text, nearby text, agency_name text, agency_logo text,
  gender text, age int, height_cm int, weight_kg int, measurements text, tags text[], about text, price_options jsonb,
  distance_km numeric, loc_verified boolean, start_rate text, start_price numeric, grp text, service_mode text, claimed boolean, is_busy boolean
) language sql stable security definer set search_path = public as $$
  with tier as (select public.viewer_tier() as t)
  select w.user_id, w.display_name, r.category, w.categories, w.price, w.profile_image,
         case when v.ok or coalesce(w.agency_id = auth.uid(), false) then w.original_path end,
         w.is_online, r.is_boosted, r.rank, (v.ok or coalesce(w.agency_id = auth.uid(), false)),
         w.province, w.district, w.nearby, ag.name, ag.logo_path,
         w.gender, w.age::int, w.height_cm::int, w.weight_kg::int, w.measurements, w.tags, w.about, w.price_options,
         null::numeric, (w.loc_verified_at is not null and w.loc_lat is not null), w.start_rate,
         case when w.start_rate = '1h' then w.price else (select (o->>'price')::numeric from jsonb_array_elements(w.price_options) o where o->>'label' = w.start_rate limit 1) end,
         w.grp, w.service_mode, w.claimed, public.worker_busy(w.user_id)
    from public.ranked_workers() r
    join public.workers w on w.user_id = r.user_id
    join tier on true
    cross join lateral (select public.can_view_category(r.category, r.free_rank, tier.t) as ok) v
    left join public.agencies ag on ag.user_id = w.agency_id
   where p_category is null or r.category = p_category
   order by r.category, r.rank
$$;
create function public.list_workers_near(p_lat double precision, p_lng double precision,
                                         p_radius_km numeric default 50, p_category text default null)
returns table (
  user_id uuid, display_name text, category text, categories text[], price numeric,
  profile_image text, original_path text,
  is_online boolean, is_boosted boolean, rank int, can_view boolean,
  province text, district text, nearby text, agency_name text, agency_logo text,
  gender text, age int, height_cm int, weight_kg int, measurements text, tags text[], about text, price_options jsonb,
  distance_km numeric, loc_verified boolean, start_rate text, start_price numeric, grp text, service_mode text, claimed boolean, is_busy boolean
) language sql stable security definer set search_path = public as $$
  select l.user_id, l.display_name, l.category, l.categories, l.price, l.profile_image, l.original_path,
         l.is_online, l.is_boosted, l.rank, l.can_view, l.province, l.district, l.nearby, l.agency_name, l.agency_logo,
         l.gender, l.age, l.height_cm, l.weight_kg, l.measurements, l.tags, l.about, l.price_options,
         greatest(1, ceil(public.geo_km(p_lat, p_lng, w.loc_lat, w.loc_lng)))::numeric, true, l.start_rate, l.start_price, l.grp, l.service_mode, l.claimed, l.is_busy
    from public.list_workers(p_category) l
    join public.workers w on w.user_id = l.user_id
   where p_lat between 5.4 and 20.7 and p_lng between 97.2 and 105.8
     and w.loc_lat is not null and w.loc_verified_at is not null
     and public.geo_km(p_lat, p_lng, w.loc_lat, w.loc_lng) <= least(greatest(p_radius_km, 1), 100)
   order by 25, l.rank
$$;

create function public.get_worker(p_worker uuid)
returns table (
  user_id uuid, display_name text, category text, categories text[], price numeric,
  profile_image text, original_path text,
  is_online boolean, is_boosted boolean, rank int, can_view boolean,
  province text, district text, nearby text, agency_name text, agency_logo text,
  gender text, age int, height_cm int, weight_kg int, measurements text, tags text[], about text, price_options jsonb,
  distance_km numeric, loc_verified boolean, start_rate text, start_price numeric, grp text, service_mode text, claimed boolean, is_busy boolean
) language sql stable security definer set search_path = public as $$
  select * from public.list_workers(null) l where l.user_id = p_worker order by l.rank limit 1
$$;


revoke all on function public.list_workers(text), public.list_workers_near(double precision, double precision, numeric, text), public.get_worker(uuid) from public, anon;
grant execute on function public.list_workers(text), public.list_workers_near(double precision, double precision, numeric, text), public.get_worker(uuid) to authenticated;
