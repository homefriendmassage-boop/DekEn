-- =============================================================================
-- migration_052.sql — run ONCE after migration_051.sql
-- Free viewers (no package) see clear faces for:  bartender / ENT = 6 (as before migration_051; bought places still come first and can
-- grow it up to 10),  massage = 3,  spa = none. The set is reshuffled every midnight (Thailand time). The clear ones can be opened
-- (details, booking, full-size photo); the covered ones need a package.
-- =============================================================================

create or replace function public.can_view_category(p_cat text, p_rank int, p_tier int)
returns boolean language sql immutable as $$
  select case p_cat
           when 'bartender' then p_tier > 0 or p_rank <= 10
           when 'ent'       then p_tier > 0 or p_rank <= 10
           when 'masseuse'  then p_tier >= 2 or p_rank <= 10      -- p_rank = 1 only for the 3 free clear faces
           when 'spa'       then p_tier >= 3
           else false end
$$;

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
         case when d.fr <= (case d.cat when 'bartender' then least(10, greatest(6, d.nb)) when 'ent' then least(10, greatest(6, d.nb)) when 'masseuse' then 3 else 0 end)
              then 1 else 99 end     -- 1 = clear face for free viewers, 99 = blurred
    from ordered o join daily d on d.user_id = o.user_id and d.cat = o.cat
$$;
revoke all on function public.ranked_workers() from public, anon;
