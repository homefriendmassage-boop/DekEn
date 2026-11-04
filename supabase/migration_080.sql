-- =============================================================================
-- migration_080.sql — run ONCE after migration_079.sql
-- New category "PR ร้าน" (key 'pr') in the night group, separate from bartender / ENT:
--   * free viewers see 4 clear faces per day (like bartender / ENT); a package opens the rest (can_view_category)
--   * the night group gets "รูปแบบการให้บริการ" (shop / outcall / both) — display only, bookings are unchanged
--   * PR girls may keep a regular venue name + a venue pin, changeable by herself at any time (no admin approval)
--   * PR "introduce yourself" choices; constraints, bulk drafts and ranking know the new category
-- Whole functions are written out in full (normalize_worker_profile from 068, ranked_workers from 072, bulk_create_drafts from 046).
-- =============================================================================

do $$
declare c text;
begin
  for c in select unnest(array['workers', 'worker_applications']) loop
    execute format('alter table public.%I drop constraint if exists %I', c, c || '_categories_check');
    execute format('alter table public.%I add constraint %I check (cardinality(categories) >= 1 and categories <@ array[''bartender'', ''ent'', ''pr'', ''masseuse'', ''spa''])', c, c || '_categories_check');
  end loop;
  alter table public.rank_boosts drop constraint if exists rank_boosts_category_check;
  alter table public.rank_boosts add constraint rank_boosts_category_check check (category = any (array['bartender', 'ent', 'pr', 'masseuse', 'spa']));
end $$;

create or replace function public.can_view_category(p_cat text, p_rank int, p_tier int)
returns boolean language sql immutable as $$
  select case p_cat
           when 'bartender' then p_tier > 0 or p_rank <= 10
           when 'ent'       then p_tier > 0 or p_rank <= 10
           when 'pr'        then p_tier > 0 or p_rank <= 10
           when 'masseuse'  then p_tier >= 2 or p_rank <= 10
           when 'spa'       then p_tier >= 3
           else false end
$$;

create or replace function public.normalize_worker_profile()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  e jsonb; v_out jsonb := '[]'::jsonb; v_label text; v_price numeric; v_n int := 0;
  v_tags text[]; v_moved boolean;
begin
  -- finishing a profile deletion blanks the location / prices on purpose: no re-validation then
  if coalesce(current_setting('app.profile_wipe', true), '') = 'on' then return new; end if;
  if tg_table_name = 'worker_applications' and tg_op = 'INSERT' then
    if new.accepted_terms is not true then raise exception 'TERMS_REQUIRED'; end if;
    new.terms_accepted_at := now();
  end if;

  -- profile group: night (bartender / ENT) or spa (masseuse / spa); one profile never mixes the two
  new.grp := case when new.categories && array['bartender', 'ent', 'pr'] then 'night' when new.categories && array['masseuse', 'spa'] then 'spa' else 'night' end;
  if new.categories && array['bartender', 'ent', 'pr'] and new.categories && array['masseuse', 'spa']
     and (tg_op = 'INSERT' or new.categories is distinct from old.categories) then
    raise exception 'MIXED_GROUPS';
  end if;
  new.service_mode := case when new.service_mode in ('shop', 'outcall', 'both') then new.service_mode else null end;   -- night: shown only, the booking flow does not use it

  select coalesce(array_agg(distinct x), '{}') into v_tags
    from unnest(coalesce(new.tags, '{}')) x
   where x = any (case when new.grp = 'spa'
                        then array['thai_massage', 'oil', 'foot', 'aroma', 'sports', 'scrub', 'polite', 'punctual', 'experienced', 'girlfriend_feel', 'fun_talk', 'playful', 'sweet', 'attentive', 'relax_massage', 'drinks', 'no_drink', 'not_picky', 'anything']
                        else array['playful', 'fun_talk', 'not_picky', 'sing', 'dance', 'drinks', 'friendly', 'banquet', 'ordination', 'wedding', 'auspicious', 'no_shameful_jobs', 'no_illegal_jobs', 'pr_table_care', 'pr_menu', 'pr_cheer', 'pr_regular', 'pr_events'] end);
  new.tags := v_tags;
  new.about := nullif(btrim(coalesce(new.about, '')), '');
  new.measurements := nullif(btrim(coalesce(new.measurements, '')), '');
  -- contact details must not hide in the public profile text either (only checked when the text is new or changed)
  if tg_op = 'INSERT' or new.about is distinct from old.about or new.display_name is distinct from old.display_name
     or new.nearby is distinct from old.nearby or new.district is distinct from old.district then
    if public.contact_problem(concat_ws(' | ', new.display_name, new.about, new.nearby, new.district)) is not null then
      raise exception 'CONTACT_IN_PROFILE';
    end if;
  end if;

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
  -- Every rate lives in price_options ('1h', '@4h', '@6h' or her own rows); the starting rate must be one of them and
  -- `price` always mirrors it (bookings and the feed read that column). Legacy rows only had `price` = hourly.
  new.start_rate := nullif(btrim(coalesce(new.start_rate, '')), '');
  if (new.start_rate is null or new.start_rate = '1h') and coalesce(new.price, 0) > 0
     and not exists (select 1 from jsonb_array_elements(new.price_options) o where o->>'label' = '1h')
     and (new.start_rate = '1h' or jsonb_array_length(new.price_options) = 0) then
    new.price_options := new.price_options || jsonb_build_object('label', '1h', 'price', round(new.price));
    new.start_rate := '1h';
  end if;
  if new.start_rate is null then
    select o->>'label' into new.start_rate from jsonb_array_elements(new.price_options) o
     order by case o->>'label' when '@4h' then 1 when '@6h' then 2 when '@60' then 3 when '@90' then 4 when '@120' then 5 when '1h' then 6 else 7 end limit 1;
  end if;
  select (o->>'price')::numeric into v_price from jsonb_array_elements(new.price_options) o where o->>'label' = new.start_rate limit 1;
  if new.start_rate is null or v_price is null then raise exception 'BAD_START_RATE'; end if;
  new.price := v_price;
  return new;
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
         case when d.fr <= (case d.cat when 'bartender' then 4 when 'ent' then 4 when 'pr' then 4 when 'masseuse' then 2 else 0 end)
              then 1 else 99 end     -- 1 = clear face for free viewers, 99 = blurred
    from ordered o join daily d on d.user_id = o.user_id and d.cat = o.cat
$$;

revoke all on function public.ranked_workers() from public, anon;

-- ---- the venue (PR girls): name + pin, edited by herself, no approval ----
alter table public.workers add column if not exists venue_name text, add column if not exists venue_lat double precision, add column if not exists venue_lng double precision;

create or replace function public.set_my_venue(p_name text, p_lat double precision default null, p_lng double precision default null)
returns void language plpgsql security definer set search_path = public as $$
declare v_name text := nullif(btrim(coalesce(p_name, '')), '');
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not exists (select 1 from public.workers w where w.user_id = auth.uid() and 'pr' = any (w.categories)) then raise exception 'NOT_PR'; end if;
  if v_name is not null and (char_length(v_name) < 2 or char_length(v_name) > 60) then raise exception 'BAD_VENUE_NAME'; end if;
  if v_name is not null and public.contact_problem(v_name) is not null then raise exception 'CONTACT_IN_PROFILE'; end if;
  if (p_lat is null) <> (p_lng is null) then raise exception 'BAD_LOCATION'; end if;
  if p_lat is not null and (p_lat not between -90 and 90 or p_lng not between -180 and 180 or public.province_for(p_lat, p_lng) is null) then raise exception 'BAD_LOCATION'; end if;
  update public.workers set venue_name = v_name, venue_lat = round(p_lat::numeric, 5), venue_lng = round(p_lng::numeric, 5) where user_id = auth.uid();
end $$;
revoke all on function public.set_my_venue(text, double precision, double precision) from public, anon;
grant execute on function public.set_my_venue(text, double precision, double precision) to authenticated;

-- the venue is shown wherever the profile can be opened (or to the owner herself)
create or replace function public.worker_venue(p_worker uuid)
returns table (venue_name text, venue_lat double precision, venue_lng double precision)
language sql stable security definer set search_path = public as $$
  select w.venue_name, w.venue_lat, w.venue_lng
    from public.workers w
   where w.user_id = p_worker and 'pr' = any (w.categories)
     and (w.user_id = auth.uid()
          or exists (select 1 from public.get_worker(p_worker) g where g.can_view))
$$;
revoke all on function public.worker_venue(uuid) from public, anon;
grant execute on function public.worker_venue(uuid) to anon, authenticated;

create or replace function public.bulk_create_drafts(p_admin uuid, p_rows jsonb)
returns table (draft_id uuid, display_name text, grp text)
language plpgsql security definer set search_path = public as $$
declare r jsonb; v_id uuid; v_grp text; v_cats text[]; v_opts jsonb; v_start text; v_price numeric; k text; v_val numeric; v_tags text[];
begin
  if not exists (select 1 from public.admins where user_id = p_admin) then raise exception 'NOT_ADMIN'; end if;
  perform set_config('request.jwt.claim.sub', p_admin::text, true);          -- draft_save() runs as this admin
  for r in select * from jsonb_array_elements(p_rows) loop
    v_grp := coalesce(nullif(r->>'grp', ''), 'night');
    v_cats := string_to_array(replace(coalesce(r->>'category', ''), ' ', ''), ',');
    if v_grp not in ('night', 'spa') then raise exception 'BAD_GROUP: %', r->>'name'; end if;
    if v_grp = 'night' and not (v_cats <@ array['bartender', 'ent', 'pr']) then raise exception 'BAD_CATEGORY (night = bartender / ent / pr): %', r->>'name'; end if;
    if v_grp = 'spa' and not (v_cats <@ array['masseuse', 'spa']) then raise exception 'BAD_CATEGORY (spa = masseuse / spa): %', r->>'name'; end if;
    v_opts := '[]'::jsonb; v_start := null; v_price := 0;
    foreach k in array case when v_grp = 'night' then array['@4h', '@6h', '1h'] else array['@60', '@90', '@120'] end loop
      v_val := nullif(r->>(case k when '@4h' then 'p4h' when '@6h' then 'p6h' when '1h' then 'p1h' when '@60' then 'p60' when '@90' then 'p90' else 'p120' end), '')::numeric;
      if v_val is not null and v_val > 0 then
        v_opts := v_opts || jsonb_build_array(jsonb_build_object('label', k, 'price', v_val));
        if v_start is null then v_start := k; v_price := v_val; end if;
      end if;
    end loop;
    if v_start is null then raise exception 'NO_PRICE: %', r->>'name'; end if;
    v_tags := string_to_array(replace(coalesce(r->>'tags', ''), ' ', ''), ',');
    v_id := public.draft_save(null, jsonb_strip_nulls(jsonb_build_object(
      'display_name', btrim(r->>'name'), 'categories', to_jsonb(v_cats), 'gender', nullif(r->>'gender', ''), 'age', nullif(r->>'age', '')::int,
      'height_cm', nullif(r->>'height', '')::int, 'weight_kg', nullif(r->>'weight', '')::int, 'measurements', nullif(r->>'measurements', ''),
      'tags', to_jsonb(coalesce(v_tags, '{}')), 'about', nullif(r->>'about', ''), 'price', v_price, 'price_options', v_opts, 'start_rate', v_start,
      'service_mode', case when v_grp = 'spa' then coalesce(nullif(r->>'mode', ''), 'both') end,
      'province', nullif(r->>'province', ''), 'district', nullif(r->>'district', ''), 'nearby', nullif(r->>'nearby', ''),
      'phone', nullif(r->>'phone', ''), 'line_id', nullif(r->>'line_id', ''), 'note', nullif(r->>'note', ''))));
    update public.application_drafts set grp = v_grp where id = v_id;
    draft_id := v_id; display_name := btrim(r->>'name'); grp := v_grp;
    return next;
  end loop;
end $$;

revoke all on function public.bulk_create_drafts(uuid, jsonb) from public, anon, authenticated;
