-- =============================================================================
-- migration_023.sql — run ONCE after migration_022.sql
-- 1) Members-only faces rotate daily: a free viewer sees the clear face of 10 providers per category, and WHICH
--    10 changes every day at midnight (Thailand time) — a stable daily shuffle, not a fixed "first 10".
--    Everyone can still open a profile and read the details, prices and text; only the clear photo is blurred
--    (the mosaic the provider uploaded) until they subscribe. Chat and booking still need the membership / visibility.
-- 2) "Location confirmed" is a real, server-side fact (loc_verified): true only when the position came from the
--    phone's GPS. A provider who types her province instead (or changes it later) is flagged as self-declared,
--    and her old GPS point is dropped so the two can never disagree.
-- =============================================================================

create or replace function public.rotation_day()
returns text language sql stable as $$ select to_char(now() at time zone 'Asia/Bangkok', 'YYYY-MM-DD') $$;

drop function if exists public.ranked_workers();
create function public.ranked_workers()
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
  organic as (select user_id, cat, row_number() over (partition by cat order by is_online desc, created_at, user_id) as k
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
  daily as (select user_id, cat, row_number() over (partition by cat order by md5(user_id::text || public.rotation_day()))::int as fr from base)
  select o.user_id, o.cat, o.rnk, o.boosted, d.fr
    from ordered o join daily d on d.user_id = o.user_id and d.cat = o.cat
$$;
revoke all on function public.ranked_workers() from public, anon;

create or replace function public.can_view_worker(w uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select w = auth.uid() or (public.worker_listed(w) and exists (
    select 1 from public.ranked_workers() r
     where r.user_id = w and public.can_view_category(r.category, r.free_rank, public.viewer_tier())))
$$;

-- ---------- location: verified only through GPS -------------------------------------------------------------------------
create or replace function public.normalize_worker_profile()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  e jsonb; v_out jsonb := '[]'::jsonb; v_label text; v_price numeric; v_n int := 0;
  v_tags text[]; v_moved boolean;
begin
  if tg_table_name = 'worker_applications' and tg_op = 'INSERT' then
    if new.accepted_terms is not true then raise exception 'TERMS_REQUIRED'; end if;
    new.terms_accepted_at := now();
  end if;

  select coalesce(array_agg(distinct x), '{}') into v_tags
    from unnest(coalesce(new.tags, '{}')) x
   where x = any (array['playful', 'fun_talk', 'not_picky', 'sing', 'dance', 'drinks', 'friendly']);
  new.tags := v_tags;
  new.about := nullif(btrim(coalesce(new.about, '')), '');
  new.measurements := nullif(btrim(coalesce(new.measurements, '')), '');

  if jsonb_typeof(coalesce(new.price_options, '[]'::jsonb)) <> 'array' then raise exception 'BAD_PRICE'; end if;
  for e in select * from jsonb_array_elements(coalesce(new.price_options, '[]'::jsonb)) loop
    exit when v_n >= 8;
    v_label := left(btrim(coalesce(e->>'label', '')), 30);
    begin v_price := (e->>'price')::numeric; exception when others then raise exception 'BAD_PRICE'; end;
    if v_label = '' then continue; end if;
    if v_price is null or v_price < 0 or v_price > 1000000 then raise exception 'BAD_PRICE'; end if;
    v_out := v_out || jsonb_build_object('label', v_label, 'price', round(v_price));
    v_n := v_n + 1;
  end loop;
  new.price_options := v_out;

  v_moved := (tg_op = 'INSERT' and new.loc_lat is not null)
             or (tg_op = 'UPDATE' and (new.loc_lat is distinct from old.loc_lat or new.loc_lng is distinct from old.loc_lng));
  if v_moved then
    if new.loc_lat is null or new.loc_lng is null or public.province_for(new.loc_lat, new.loc_lng) is null then
      raise exception 'BAD_LOCATION';
    end if;
    if coalesce(current_setting('app.no_fuzz', true), '') <> 'on' then
      new.loc_lat := round((new.loc_lat / 0.005)::numeric) * 0.005 + (random() - 0.5) * 0.004;
      new.loc_lng := round((new.loc_lng / 0.005)::numeric) * 0.005 + (random() - 0.5) * 0.004;
      new.loc_verified_at := now();
    end if;
    new.province := coalesce(public.province_for(new.loc_lat, new.loc_lng), new.province);
  elsif tg_op = 'UPDATE' and new.province is distinct from old.province
        and coalesce(current_setting('app.no_fuzz', true), '') <> 'on' then
    -- a province typed by hand replaces a GPS-confirmed one: the old point no longer applies, the profile is self-declared
    new.loc_lat := null; new.loc_lng := null; new.loc_verified_at := null;
  end if;
  return new;
end $$;

-- ---------- Feed: details for everyone, clear photo by the daily free set / membership ----------------------------------
drop function if exists public.list_workers(text);
create function public.list_workers(p_category text default null)
returns table (
  user_id uuid, display_name text, category text, categories text[], price numeric,
  profile_image text, original_path text,
  is_online boolean, is_boosted boolean, rank int, can_view boolean,
  province text, district text, nearby text, agency_name text, agency_logo text,
  gender text, age int, height_cm int, weight_kg int, measurements text, tags text[], about text, price_options jsonb,
  distance_km numeric, loc_verified boolean
) language sql stable security definer set search_path = public as $$
  with tier as (select public.viewer_tier() as t)
  select w.user_id, w.display_name, r.category, w.categories, w.price, w.profile_image,
         case when v.ok then w.original_path end,
         w.is_online, r.is_boosted, r.rank, v.ok,
         w.province, w.district, w.nearby, ag.name, ag.logo_path,
         w.gender, w.age::int, w.height_cm::int, w.weight_kg::int, w.measurements, w.tags, w.about, w.price_options,
         null::numeric, (w.loc_verified_at is not null and w.loc_lat is not null)
    from public.ranked_workers() r
    join public.workers w on w.user_id = r.user_id
    join tier on true
    cross join lateral (select public.can_view_category(r.category, r.free_rank, tier.t) as ok) v
    left join public.agencies ag on ag.user_id = w.agency_id
   where p_category is null or r.category = p_category
   order by r.category, r.rank
$$;
revoke all on function public.list_workers(text) from public, anon;
grant execute on function public.list_workers(text) to authenticated;

drop function if exists public.list_workers_near(double precision, double precision, numeric, text);
create function public.list_workers_near(p_lat double precision, p_lng double precision,
                                         p_radius_km numeric default 50, p_category text default null)
returns table (
  user_id uuid, display_name text, category text, categories text[], price numeric,
  profile_image text, original_path text,
  is_online boolean, is_boosted boolean, rank int, can_view boolean,
  province text, district text, nearby text, agency_name text, agency_logo text,
  gender text, age int, height_cm int, weight_kg int, measurements text, tags text[], about text, price_options jsonb,
  distance_km numeric, loc_verified boolean
) language sql stable security definer set search_path = public as $$
  select l.user_id, l.display_name, l.category, l.categories, l.price, l.profile_image, l.original_path,
         l.is_online, l.is_boosted, l.rank, l.can_view, l.province, l.district, l.nearby, l.agency_name, l.agency_logo,
         l.gender, l.age, l.height_cm, l.weight_kg, l.measurements, l.tags, l.about, l.price_options,
         greatest(1, ceil(public.geo_km(p_lat, p_lng, w.loc_lat, w.loc_lng)))::numeric, true
    from public.list_workers(p_category) l
    join public.workers w on w.user_id = l.user_id
   where p_lat between 5.4 and 20.7 and p_lng between 97.2 and 105.8
     and w.loc_lat is not null and w.loc_verified_at is not null
     and public.geo_km(p_lat, p_lng, w.loc_lat, w.loc_lng) <= least(greatest(p_radius_km, 1), 100)
   order by 25, l.rank
$$;
revoke all on function public.list_workers_near(double precision, double precision, numeric, text) from public, anon;
grant execute on function public.list_workers_near(double precision, double precision, numeric, text) to authenticated;
-- =============================================================================
