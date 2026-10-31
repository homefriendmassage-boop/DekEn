-- =============================================================================
-- migration_060.sql — run ONCE after migration_059.sql
-- Massage / spa details (age, height, weight, measurements, personality tags, introduction text, the full price list) are no longer sent
-- to people who may not see that group: the database leaves them out instead of the screen hiding them. The card keeps name, covered
-- photo, area, online state and the "starting from" price. Bartender / ENT behave as before. get_worker and list_workers_near read
-- list_workers, so they follow.
-- =============================================================================

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
         case when v.ok or coalesce(w.agency_id = auth.uid(), false) then w.original_path end,
         w.is_online, r.is_boosted, r.rank, (v.ok or coalesce(w.agency_id = auth.uid(), false)),
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
    cross join lateral (select r.category in ('masseuse', 'spa') and not (v.ok or coalesce(w.agency_id = auth.uid(), false)) as locked) lk
    left join public.agencies ag on ag.user_id = w.agency_id
   where p_category is null or r.category = p_category
   order by r.category, r.rank
$$;

