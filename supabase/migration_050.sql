-- =============================================================================
-- migration_050.sql — run ONCE after migration_049.sql
-- Active sellers (paid plan, or the owner of a seller OA) can see the faces and the details of ALL groups (also massage and spa)
-- so they can share them. It only widens what they SEE (list_workers / can_view_worker, photos, bookings): the package tiers, chat
-- and everything else keep following the membership (viewer_tier). Providers who are sellers for free get nothing extra.
-- =============================================================================

create or replace function public.seller_can_view()
returns boolean language sql stable security definer set search_path = public as $$
  select auth.uid() is not null and not public.is_suspended(auth.uid())
     and (exists (select 1 from public.vendors v where v.owner_user_id = auth.uid() and v.status = 'active')
          or exists (select 1 from public.users u where u.id = auth.uid() and u.seller_until > now()))
$$;
create or replace function public.view_tier()
returns int language sql stable security definer set search_path = public as $$
  select greatest(public.viewer_tier(), case when public.seller_can_view() then 3 else 0 end)
$$;
revoke all on function public.seller_can_view(), public.view_tier() from public, anon;
grant execute on function public.seller_can_view(), public.view_tier() to authenticated;

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

create or replace function public.can_view_worker(w uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select w = auth.uid()
      or exists (select 1 from public.workers x where x.user_id = w and x.agency_id = auth.uid())      -- an agency sees its own girls in full
      or (public.worker_listed(w) and exists (
    select 1 from public.ranked_workers() r
     where r.user_id = w and public.can_view_category(r.category, r.free_rank, public.view_tier())))
$$;
