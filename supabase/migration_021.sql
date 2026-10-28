-- =============================================================================
-- migration_021.sql — run ONCE after migration_020.sql
-- 1) Paid ranking ("ซื้ออันดับ"): a provider buys a place in one of three blocks of her category's list
--      A = positions 1-4 (first screen)   90 THB/day
--      B = positions 5-8                   60 THB/day
--      C = positions 9-12                  30 THB/day       4 places per block and category
--    Packages: 1 day, 3 days, 7 days (pay for 5). Paid from the bonus wallet first, the rest from the Wallet.
--    A bought place is a FIXED position: if a block is not full the free positions are filled by the normal order
--    (online first, then oldest), so nobody ends up higher than they paid for. Admin-pinned ("is_boosted") providers
--    stay on top. Rank decides what a free member may see (top 10) exactly as before.
-- 2) report_slip_problem(): the app reports the size/type of a slip picture it could not read, so we can see why
--    (shown in the admin "failed slips" list; no picture is sent).
-- =============================================================================

create or replace function public.rank_block_price(p_block text)
returns numeric language sql immutable as $$ select (case p_block when 'A' then 90 when 'B' then 60 when 'C' then 30 end)::numeric $$;
create or replace function public.rank_block_capacity() returns int language sql immutable as $$ select 4 $$;

create table if not exists public.rank_boosts (
  id          uuid primary key default gen_random_uuid(),
  worker_id   uuid not null references public.workers (user_id) on delete cascade,
  category    text not null check (category in ('bartender', 'ent', 'masseuse', 'spa')),
  block       text not null check (block in ('A', 'B', 'C')),
  starts_at   timestamptz not null default now(),
  ends_at     timestamptz not null,
  paid        numeric(12,2) not null default 0,
  created_at  timestamptz not null default now()
);
create index if not exists rank_boosts_slot_idx on public.rank_boosts (category, block, ends_at);
create index if not exists rank_boosts_worker_idx on public.rank_boosts (worker_id, ends_at desc);
alter table public.rank_boosts enable row level security;
revoke all on public.rank_boosts from anon, authenticated;
grant select on public.rank_boosts to authenticated;
drop policy if exists rank_boosts_own on public.rank_boosts;
create policy rank_boosts_own on public.rank_boosts for select to authenticated using (worker_id = auth.uid());

-- ---------- The ranking (one place for the feed and for the "may I see her" rule) ------------------------
create or replace function public.ranked_workers()
returns table (user_id uuid, category text, rank int, is_boosted boolean)
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
  organic as (select user_id, cat, row_number() over (partition by cat order by is_online desc, created_at, user_id) as k
                from rest where blk is null),
  tot    as (select cat, count(*) as n from rest group by cat),
  free   as (select t.cat, s as pos, row_number() over (partition by t.cat order by s) as fk
               from tot t cross join lateral generate_series(1, t.n + 12) s
              where not exists (select 1 from bpos b where b.cat = t.cat and b.pos = s)),
  placed as (select user_id, cat, pos from bpos
             union all
             select o.user_id, o.cat, f.pos from organic o join free f on f.cat = o.cat and f.fk = o.k)
  select p.user_id, p.cat, p.pn::int, true from pinned p
  union all
  select pl.user_id, pl.cat,
         (coalesce((select n from pcount c where c.cat = pl.cat), 0) + row_number() over (partition by pl.cat order by pl.pos))::int,
         exists (select 1 from bpos b where b.user_id = pl.user_id and b.cat = pl.cat)
    from placed pl
$$;
revoke all on function public.ranked_workers() from public, anon;

create or replace function public.can_view_worker(w uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select w = auth.uid() or (public.worker_listed(w) and exists (
    select 1 from public.ranked_workers() r
     where r.user_id = w and public.can_view_category(r.category, r.rank, public.viewer_tier())))
$$;

drop function if exists public.list_workers(text);
create function public.list_workers(p_category text default null)
returns table (
  user_id uuid, display_name text, category text, categories text[], price numeric,
  profile_image text, original_path text,
  is_online boolean, is_boosted boolean, rank int, can_view boolean,
  province text, district text, nearby text, agency_name text, agency_logo text
) language sql stable security definer set search_path = public as $$
  with tier as (select public.viewer_tier() as t)
  select w.user_id, w.display_name, r.category, w.categories, w.price, w.profile_image,
         case when public.can_view_category(r.category, r.rank, tier.t) then w.original_path end,
         w.is_online, r.is_boosted, r.rank,
         public.can_view_category(r.category, r.rank, tier.t),
         w.province, w.district, w.nearby, ag.name, ag.logo_path
    from public.ranked_workers() r
    join public.workers w on w.user_id = r.user_id
    join tier on true
    left join public.agencies ag on ag.user_id = w.agency_id
   where p_category is null or r.category = p_category
   order by r.category, r.rank
$$;
revoke all on function public.list_workers(text) from public, anon;
grant execute on function public.list_workers(text) to authenticated;

-- ---------- Buying ------------------------------------------------------------------------------------------
create or replace function public.rank_boost_slots(p_category text)
returns table (block text, price_day numeric, price_week numeric, capacity int, taken int, free_at timestamptz)
language sql stable security definer set search_path = public as $$
  select b.block, public.rank_block_price(b.block), public.rank_block_price(b.block) * 5, public.rank_block_capacity(),
         (select count(*)::int from public.rank_boosts x where x.category = p_category and x.block = b.block and x.ends_at > now()),
         (select min(x.ends_at) from public.rank_boosts x where x.category = p_category and x.block = b.block and x.ends_at > now())
    from (values ('A'), ('B'), ('C')) b(block)
   order by b.block
$$;

create or replace function public.my_rank_boosts()
returns table (category text, block text, ends_at timestamptz)
language sql stable security definer set search_path = public as $$
  select b.category, b.block, b.ends_at from public.rank_boosts b
   where b.worker_id = auth.uid() and b.ends_at > now() order by b.ends_at
$$;

create or replace function public.buy_rank_boost(p_category text, p_block text, p_days int)
returns timestamptz language plpgsql security definer set search_path = public as $$
declare
  w public.workers;
  v_unit numeric := public.rank_block_price(p_block);
  v_price numeric;
  v_bonus numeric; v_wallet numeric; v_from_bonus numeric; v_from_wallet numeric;
  cur public.rank_boosts;
  v_ends timestamptz;
begin
  if auth.uid() is null then raise exception 'FORBIDDEN'; end if;
  if public.is_suspended(auth.uid()) then raise exception 'SUSPENDED'; end if;
  if v_unit is null or p_days not in (1, 3, 7) then raise exception 'BAD_INPUT'; end if;
  select * into w from public.workers where user_id = auth.uid();
  if not found or not (p_category = any (w.categories)) then raise exception 'NOT_A_WORKER'; end if;
  if not public.worker_listed(auth.uid()) then raise exception 'NOT_LISTED'; end if;
  v_price := v_unit * case when p_days = 7 then 5 else p_days end;

  perform pg_advisory_xact_lock(hashtext('rank:' || p_category || ':' || p_block));
  select * into cur from public.rank_boosts
   where worker_id = auth.uid() and category = p_category and ends_at > now() order by ends_at desc limit 1;
  if found and cur.block <> p_block then raise exception 'ALREADY_BOOSTED'; end if;
  if not found and (select count(*) from public.rank_boosts x
                     where x.category = p_category and x.block = p_block and x.ends_at > now()) >= public.rank_block_capacity() then
    raise exception 'SLOTS_FULL';
  end if;

  select bonus_balance, wallet_balance into v_bonus, v_wallet from public.users where id = auth.uid() for update;
  v_from_bonus  := least(v_bonus, v_price);
  v_from_wallet := v_price - v_from_bonus;
  if v_wallet < v_from_wallet then raise exception 'INSUFFICIENT_BALANCE'; end if;
  perform set_config('app.ledger_kind', 'rank_boost', true);
  perform set_config('app.ledger_ref', p_category || ':' || p_block, true);
  if v_from_bonus > 0 then update public.users set bonus_balance = bonus_balance - v_from_bonus where id = auth.uid(); end if;
  perform set_config('app.ledger_kind', 'rank_boost', true);
  perform set_config('app.ledger_ref', p_category || ':' || p_block, true);
  if v_from_wallet > 0 then update public.users set wallet_balance = wallet_balance - v_from_wallet where id = auth.uid(); end if;

  if cur.id is not null then
    v_ends := cur.ends_at + make_interval(days => p_days);
    update public.rank_boosts set ends_at = v_ends, paid = paid + v_price where id = cur.id;
  else
    v_ends := now() + make_interval(days => p_days);
    insert into public.rank_boosts (worker_id, category, block, ends_at, paid) values (auth.uid(), p_category, p_block, v_ends, v_price);
  end if;
  return v_ends;
end $$;

revoke all on function public.rank_boost_slots(text), public.my_rank_boosts(), public.buy_rank_boost(text, text, int) from public, anon;
grant execute on function public.rank_boost_slots(text), public.my_rank_boosts(), public.buy_rank_boost(text, text, int) to authenticated;

-- ---------- Slip pictures the phone could not read ----------------------------------------------------------------
create or replace function public.report_slip_problem(p_detail jsonb)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'FORBIDDEN'; end if;
  if (select count(*) from public.slip_attempts where user_id = auth.uid() and result = 'CLIENT_NO_QR'
        and created_at > now() - interval '1 hour') >= 20 then return; end if;
  insert into public.slip_attempts (user_id, result, detail)
  values (auth.uid(), 'CLIENT_NO_QR', jsonb_build_object(
    'width', p_detail->'width', 'height', p_detail->'height', 'type', p_detail->'type', 'bytes', p_detail->'bytes', 'error', p_detail->'error'));
end $$;
revoke all on function public.report_slip_problem(jsonb) from public, anon;
grant execute on function public.report_slip_problem(jsonb) to authenticated;
-- =============================================================================
