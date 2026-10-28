-- =============================================================================
-- migration_022.sql — run ONCE after migration_021.sql
-- Richer provider profiles, a verified location, "near me", and prices per time.
--   * Profile: gender (female / male / lgbt), age (20+), height, weight, measurements, presentation tags + free text.
--   * Prices: hourly (the "from" price) plus any of 4 h / 6 h and up to 5 custom rows (label + price) -> price_options.
--   * Location: the app sends the phone's GPS position when a provider applies/edits. The server NEVER stores it exactly:
--     it is snapped to a ~500 m grid and jittered (about +-0.5 km), the province is derived from it (nearest provincial
--     seat) instead of being typed, and customers only ever see a distance rounded up to whole km.
--   * "Near me": list_workers_near(lat, lng, radius <= 100 km) -> providers within 50 km by default, nearest first.
--     The customer's position is used for that query only and is not stored.
--   * Applying requires accepting the terms (entertainment work only; no sexual services or drugs).
-- =============================================================================

create table if not exists public.province_centroids (
  name text primary key, lat double precision not null, lng double precision not null
);
insert into public.province_centroids (name, lat, lng) values
  ('กรุงเทพมหานคร', 13.7563, 100.5018),
  ('กระบี่', 8.0863, 98.9063),
  ('กาญจนบุรี', 14.0228, 99.5328),
  ('กาฬสินธุ์', 16.4314, 103.5059),
  ('กำแพงเพชร', 16.4828, 99.5227),
  ('ขอนแก่น', 16.4322, 102.8236),
  ('จันทบุรี', 12.6112, 102.1039),
  ('ฉะเชิงเทรา', 13.6904, 101.078),
  ('ชลบุรี', 13.3611, 100.9847),
  ('ชัยนาท', 15.1851, 100.1251),
  ('ชัยภูมิ', 15.8068, 102.0316),
  ('ชุมพร', 10.493, 99.18),
  ('เชียงราย', 19.9072, 99.831),
  ('เชียงใหม่', 18.7883, 98.9853),
  ('ตรัง', 7.5563, 99.6114),
  ('ตราด', 12.2428, 102.5175),
  ('ตาก', 16.884, 99.1258),
  ('นครนายก', 14.2069, 101.2131),
  ('นครปฐม', 13.8196, 100.0443),
  ('นครพนม', 17.4108, 104.7783),
  ('นครราชสีมา', 14.9799, 102.0978),
  ('นครศรีธรรมราช', 8.4304, 99.9631),
  ('นครสวรรค์', 15.7047, 100.1372),
  ('นนทบุรี', 13.8621, 100.5144),
  ('นราธิวาส', 6.4254, 101.8253),
  ('น่าน', 18.7756, 100.773),
  ('บึงกาฬ', 18.3609, 103.6464),
  ('บุรีรัมย์', 14.993, 103.1029),
  ('ปทุมธานี', 14.0208, 100.525),
  ('ประจวบคีรีขันธ์', 11.8126, 99.7957),
  ('ปราจีนบุรี', 14.0509, 101.3711),
  ('ปัตตานี', 6.8695, 101.2505),
  ('พระนครศรีอยุธยา', 14.3532, 100.5689),
  ('พะเยา', 19.1664, 99.9019),
  ('พังงา', 8.4509, 98.5255),
  ('พัทลุง', 7.6167, 100.0778),
  ('พิจิตร', 16.4429, 100.3488),
  ('พิษณุโลก', 16.8211, 100.2659),
  ('เพชรบุรี', 13.1112, 99.9391),
  ('เพชรบูรณ์', 16.419, 101.1591),
  ('แพร่', 18.1446, 100.141),
  ('ภูเก็ต', 7.8804, 98.3923),
  ('มหาสารคาม', 16.1846, 103.301),
  ('มุกดาหาร', 16.5453, 104.7235),
  ('แม่ฮ่องสอน', 19.302, 97.9654),
  ('ยโสธร', 15.7921, 104.1453),
  ('ยะลา', 6.541, 101.2804),
  ('ร้อยเอ็ด', 16.0538, 103.652),
  ('ระนอง', 9.9658, 98.6348),
  ('ระยอง', 12.6814, 101.2816),
  ('ราชบุรี', 13.5283, 99.8134),
  ('ลพบุรี', 14.7995, 100.6534),
  ('ลำปาง', 18.2888, 99.4908),
  ('ลำพูน', 18.5745, 99.0087),
  ('เลย', 17.486, 101.7223),
  ('ศรีสะเกษ', 15.1186, 104.322),
  ('สกลนคร', 17.1664, 104.1486),
  ('สงขลา', 7.1897, 100.5951),
  ('สตูล', 6.6238, 100.0674),
  ('สมุทรปราการ', 13.5991, 100.5998),
  ('สมุทรสงคราม', 13.4098, 100.0023),
  ('สมุทรสาคร', 13.5475, 100.2744),
  ('สระแก้ว', 13.824, 102.0646),
  ('สระบุรี', 14.5289, 100.9101),
  ('สิงห์บุรี', 14.8936, 100.4059),
  ('สุโขทัย', 17.0078, 99.823),
  ('สุพรรณบุรี', 14.4745, 100.1177),
  ('สุราษฎร์ธานี', 9.1382, 99.3217),
  ('สุรินทร์', 14.8818, 103.4937),
  ('หนองคาย', 17.8783, 102.742),
  ('หนองบัวลำภู', 17.2218, 102.426),
  ('อ่างทอง', 14.5896, 100.455),
  ('อำนาจเจริญ', 15.8657, 104.6258),
  ('อุดรธานี', 17.4138, 102.7872),
  ('อุตรดิตถ์', 17.6201, 100.0993),
  ('อุทัยธานี', 15.3835, 100.0245),
  ('อุบลราชธานี', 15.2448, 104.8473)
on conflict (name) do nothing;
alter table public.province_centroids enable row level security;
revoke all on public.province_centroids from anon, authenticated;

create or replace function public.geo_km(a_lat double precision, a_lng double precision, b_lat double precision, b_lng double precision)
returns double precision language sql immutable as $$
  select 2 * 6371 * asin(sqrt(
    power(sin(radians(b_lat - a_lat) / 2), 2) +
    cos(radians(a_lat)) * cos(radians(b_lat)) * power(sin(radians(b_lng - a_lng) / 2), 2)))
$$;

-- nearest provincial seat; null when the point is not in Thailand
create or replace function public.province_for(p_lat double precision, p_lng double precision)
returns text language sql stable security definer set search_path = public as $$
  select c.name from public.province_centroids c
   where p_lat between 5.4 and 20.7 and p_lng between 97.2 and 105.8
   order by public.geo_km(p_lat, p_lng, c.lat, c.lng) limit 1
$$;
revoke all on function public.province_for(double precision, double precision) from public, anon;
grant execute on function public.province_for(double precision, double precision) to authenticated;

-- ---------- Columns ---------------------------------------------------------------------------------------
alter table public.workers
  add column if not exists gender text check (gender in ('female', 'male', 'lgbt')),
  add column if not exists age smallint check (age between 20 and 70),
  add column if not exists height_cm smallint check (height_cm between 120 and 230),
  add column if not exists weight_kg smallint check (weight_kg between 30 and 200),
  add column if not exists measurements text check (char_length(measurements) <= 20),
  add column if not exists tags text[] not null default '{}',
  add column if not exists about text check (char_length(about) <= 300),
  add column if not exists price_options jsonb not null default '[]',
  add column if not exists loc_lat double precision,
  add column if not exists loc_lng double precision,
  add column if not exists loc_verified_at timestamptz;
alter table public.worker_applications
  add column if not exists gender text check (gender in ('female', 'male', 'lgbt')),
  add column if not exists age smallint check (age between 20 and 70),
  add column if not exists height_cm smallint check (height_cm between 120 and 230),
  add column if not exists weight_kg smallint check (weight_kg between 30 and 200),
  add column if not exists measurements text check (char_length(measurements) <= 20),
  add column if not exists tags text[] not null default '{}',
  add column if not exists about text check (char_length(about) <= 300),
  add column if not exists price_options jsonb not null default '[]',
  add column if not exists loc_lat double precision,
  add column if not exists loc_lng double precision,
  add column if not exists loc_verified_at timestamptz,
  add column if not exists accepted_terms boolean,
  add column if not exists terms_accepted_at timestamptz;

-- one validation / privacy trigger for both tables
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

  -- tags: only the known keys, no duplicates
  select coalesce(array_agg(distinct x), '{}') into v_tags
    from unnest(coalesce(new.tags, '{}')) x
   where x = any (array['playful', 'fun_talk', 'not_picky', 'sing', 'dance', 'drinks', 'friendly']);
  new.tags := v_tags;
  new.about := nullif(btrim(coalesce(new.about, '')), '');
  new.measurements := nullif(btrim(coalesce(new.measurements, '')), '');

  -- price rows: [{label, price}], at most 8, sanitised
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

  -- location: keep it approximate, derive the province
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
  end if;
  return new;
end $$;
drop trigger if exists workers_normalize on public.workers;
create trigger workers_normalize before insert or update on public.workers
  for each row execute function public.normalize_worker_profile();
drop trigger if exists applications_normalize on public.worker_applications;
create trigger applications_normalize before insert or update on public.worker_applications
  for each row execute function public.normalize_worker_profile();

grant update (gender, age, height_cm, weight_kg, measurements, tags, about, price_options, loc_lat, loc_lng)
  on public.workers to authenticated;
grant insert (gender, age, height_cm, weight_kg, measurements, tags, about, price_options, loc_lat, loc_lng, accepted_terms)
  on public.worker_applications to authenticated;
grant update (gender, age, height_cm, weight_kg, measurements, tags, about, price_options, loc_lat, loc_lng)
  on public.worker_applications to authenticated;

-- ---------- approve: copy everything ---------------------------------------------------------------------------
create or replace function public.approve_worker(p_app uuid)
returns void language plpgsql security definer set search_path = public as $$
declare a public.worker_applications;
begin
  select * into a from public.worker_applications where id = p_app and status = 'pending';
  if not found then raise exception 'NOT_FOUND'; end if;
  if a.agency_id is not null and a.agency_status is distinct from 'accepted' then raise exception 'AGENCY_NOT_CONFIRMED'; end if;
  update public.users set role = 'worker' where id = a.user_id;
  perform set_config('app.no_fuzz', 'on', true);        -- the application's position is already approximate
  insert into public.workers (user_id, display_name, categories, price, province, district, nearby,
                              profile_image, original_path, recruiter_id, recruiter_until, agency_id, agency_since,
                              gender, age, height_cm, weight_kg, measurements, tags, about, price_options,
                              loc_lat, loc_lng, loc_verified_at)
  values (a.user_id, a.display_name, a.categories, a.price, a.province, a.district, a.nearby,
          a.profile_image, a.original_path, a.recruiter_id,
          case when a.recruiter_id is not null then now() + make_interval(days => public.recruiter_window_days()) end,
          a.agency_id, case when a.agency_id is not null then now() end,
          a.gender, a.age, a.height_cm, a.weight_kg, a.measurements, a.tags, a.about, a.price_options,
          a.loc_lat, a.loc_lng, a.loc_verified_at)
  on conflict (user_id) do update
    set display_name = excluded.display_name, categories = excluded.categories, price = excluded.price,
        province = excluded.province, district = excluded.district, nearby = excluded.nearby,
        profile_image = coalesce(excluded.profile_image, public.workers.profile_image),
        original_path = coalesce(excluded.original_path, public.workers.original_path),
        agency_id = coalesce(excluded.agency_id, public.workers.agency_id),
        agency_since = case when excluded.agency_id is not null and excluded.agency_id is distinct from public.workers.agency_id
                            then now() else public.workers.agency_since end,
        gender = coalesce(excluded.gender, public.workers.gender), age = coalesce(excluded.age, public.workers.age),
        height_cm = coalesce(excluded.height_cm, public.workers.height_cm), weight_kg = coalesce(excluded.weight_kg, public.workers.weight_kg),
        measurements = coalesce(excluded.measurements, public.workers.measurements),
        tags = excluded.tags, about = coalesce(excluded.about, public.workers.about),
        price_options = case when jsonb_array_length(excluded.price_options) > 0 then excluded.price_options else public.workers.price_options end,
        loc_lat = coalesce(excluded.loc_lat, public.workers.loc_lat), loc_lng = coalesce(excluded.loc_lng, public.workers.loc_lng),
        loc_verified_at = coalesce(excluded.loc_verified_at, public.workers.loc_verified_at);
  update public.worker_applications set status = 'approved' where id = p_app;
end $$;
revoke all on function public.approve_worker(uuid) from public, anon, authenticated;

-- ---------- Feed -------------------------------------------------------------------------------------------------
-- The profile details (everything below the province) are only returned for providers the viewer may open.
drop function if exists public.list_workers(text);
create function public.list_workers(p_category text default null)
returns table (
  user_id uuid, display_name text, category text, categories text[], price numeric,
  profile_image text, original_path text,
  is_online boolean, is_boosted boolean, rank int, can_view boolean,
  province text, district text, nearby text, agency_name text, agency_logo text,
  gender text, age int, height_cm int, weight_kg int, measurements text, tags text[], about text, price_options jsonb,
  distance_km numeric
) language sql stable security definer set search_path = public as $$
  with tier as (select public.viewer_tier() as t)
  select w.user_id, w.display_name, r.category, w.categories, w.price, w.profile_image,
         case when public.can_view_category(r.category, r.rank, tier.t) then w.original_path end,
         w.is_online, r.is_boosted, r.rank,
         public.can_view_category(r.category, r.rank, tier.t),
         w.province, w.district, w.nearby, ag.name, ag.logo_path,
         case when v.ok then w.gender end, case when v.ok then w.age::int end, case when v.ok then w.height_cm::int end,
         case when v.ok then w.weight_kg::int end, case when v.ok then w.measurements end,
         case when v.ok then w.tags else '{}'::text[] end, case when v.ok then w.about end,
         case when v.ok then w.price_options else '[]'::jsonb end,
         null::numeric
    from public.ranked_workers() r
    join public.workers w on w.user_id = r.user_id
    join tier on true
    cross join lateral (select public.can_view_category(r.category, r.rank, tier.t) as ok) v
    left join public.agencies ag on ag.user_id = w.agency_id
   where p_category is null or r.category = p_category
   order by r.category, r.rank
$$;
revoke all on function public.list_workers(text) from public, anon;
grant execute on function public.list_workers(text) to authenticated;

-- Providers within p_radius_km of the customer, nearest first. The distance is rounded UP to whole km (min 1).
create or replace function public.list_workers_near(p_lat double precision, p_lng double precision,
                                                    p_radius_km numeric default 50, p_category text default null)
returns table (
  user_id uuid, display_name text, category text, categories text[], price numeric,
  profile_image text, original_path text,
  is_online boolean, is_boosted boolean, rank int, can_view boolean,
  province text, district text, nearby text, agency_name text, agency_logo text,
  gender text, age int, height_cm int, weight_kg int, measurements text, tags text[], about text, price_options jsonb,
  distance_km numeric
) language sql stable security definer set search_path = public as $$
  select l.user_id, l.display_name, l.category, l.categories, l.price, l.profile_image, l.original_path,
         l.is_online, l.is_boosted, l.rank, l.can_view, l.province, l.district, l.nearby, l.agency_name, l.agency_logo,
         l.gender, l.age, l.height_cm, l.weight_kg, l.measurements, l.tags, l.about, l.price_options,
         greatest(1, ceil(public.geo_km(p_lat, p_lng, w.loc_lat, w.loc_lng)))::numeric
    from public.list_workers(p_category) l
    join public.workers w on w.user_id = l.user_id
   where p_lat between 5.4 and 20.7 and p_lng between 97.2 and 105.8
     and w.loc_lat is not null
     and public.geo_km(p_lat, p_lng, w.loc_lat, w.loc_lng) <= least(greatest(p_radius_km, 1), 100)
   order by 25, l.rank
$$;
revoke all on function public.list_workers_near(double precision, double precision, numeric, text) from public, anon;
grant execute on function public.list_workers_near(double precision, double precision, numeric, text) to authenticated;
-- ---------- Admin: applications show the new details -----------------------------------------------------------------
drop function if exists public.admin_list_applications(text);
create function public.admin_list_applications(p_status text default 'pending')
returns table (id uuid, user_id uuid, user_name text, display_name text, categories text[], price numeric,
               province text, district text, nearby text, phone text, line_id text, note text,
               profile_image text, original_path text, status text, reject_reason text, created_at timestamptz,
               agency_name text, agency_status text,
               gender text, age int, height_cm int, weight_kg int, measurements text, tags text[], about text,
               price_options jsonb, loc_verified boolean)
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.assert_admin();
  return query
    select a.id, a.user_id, u.display_name, a.display_name, a.categories, a.price,
           a.province, a.district, a.nearby, a.phone, a.line_id, a.note,
           a.profile_image, a.original_path, a.status, a.reject_reason, a.created_at,
           ag.name, a.agency_status,
           a.gender, a.age::int, a.height_cm::int, a.weight_kg::int, a.measurements, a.tags, a.about,
           a.price_options, a.loc_verified_at is not null
      from public.worker_applications a join public.users u on u.id = a.user_id
      left join public.agencies ag on ag.user_id = a.agency_id
     where p_status is null or a.status = p_status
     order by a.created_at desc
     limit 100;
end $$;
revoke all on function public.admin_list_applications(text) from public, anon;
grant execute on function public.admin_list_applications(text) to authenticated;
-- =============================================================================
