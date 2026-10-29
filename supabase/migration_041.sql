-- =============================================================================
-- migration_041.sql — run ONCE after migration_040.sql
--   * chat: NO links of any kind (Google Maps too) and NO digits beyond one (two or more digits in a message are refused). Places, maps
--     and phone numbers go in the booking form instead. (Booking notes keep allowing room numbers and map links.)
--   * platform fee: 700 THB for massage and spa (500 for the rest); the Wallet charge and the 40 / 40 / 20 split follow the fee stored in the booking.
--   * massage / spa bookings: who travels to whom (jobs.travel_mode: worker_goes | customer_goes). When the customer goes, she gives the
--     place (name, room, optional map link) when she accepts (job_accept).
--   * "busy": a provider with an ACCEPTED booking is shown as busy from 3 hours before the appointment until she presses "finish"
--     (or the booking is cancelled / 12 hours after the appointment); nothing to switch by hand.
-- =============================================================================

-- ---------- chat filter ---------------------------------------------------------------------------------------
create or replace function public.chat_problem(p_text text)
returns text language plpgsql immutable set search_path = public as $$
declare s text := lower(coalesce(p_text, '')); r text;
begin
  if s ~ 'https?://' or s ~ 'www\.' or s ~ '[a-z0-9-]+\.(com|net|org|info|biz|co|th|me|io|app|link|ly|gl|ee|be|xyz|cc|tv|bz|asia|shop|site|online|store)(\M|/)'
     or s ~ '(line\.me|lin\.ee|t\.me|wa\.me|bit\.ly|tinyurl|fb\.com|youtu\.be|goo\.gl|maps\.)' or s ~ 'google[^a-z]*(map|แมป|แผนที่)' then
    return 'LINK';
  end if;
  r := public.contact_problem(p_text);
  if r is not null then return r; end if;
  -- any digits: two or more (Thai, Arabic, full-width, and spelled-out numbers) in one message are refused
  if char_length(regexp_replace(public.contact_numbers(s), '[^0-9]', '', 'g')) >= 2 then return 'NUMBER'; end if;
  return null;
end $$;
revoke all on function public.chat_problem(text) from public, anon, authenticated;

create or replace function public.send_message(p_thread uuid, p_body text, p_accept_fee boolean default false)
returns text language plpgsql security definer set search_path = public as $$
declare
  t   public.chat_threads;
  b   text := btrim(p_body);
  v_msg uuid;
  v_bal numeric;
  v_fee uuid;
  v_worker_side boolean;
  v_digits int;
  v_prior int;
  v_reason text;
  v_n int;
begin
  select * into t from public.chat_threads
   where id = p_thread and (auth.uid() in (customer_id, worker_id) or public.is_agency_of(auth.uid(), worker_id)) for update;
  if not found then raise exception 'FORBIDDEN'; end if;
  v_worker_side := auth.uid() <> t.customer_id;
  if b is null or char_length(b) not between 1 and 500 then raise exception 'BAD_MESSAGE'; end if;
  -- Thread suspended / closed by an admin (or by the red flag below)
  if t.status <> 'open' then raise exception 'THREAD_SUSPENDED'; end if;
  -- Contact details (numbers, links, IDs, "line" ...) are refused BEFORE any fee is held. Every attempt is recorded and
  -- raises the thread's flag: 1 = noted, 2 = yellow, 3 = orange, 4 = red (the thread is suspended until an admin decides).
  v_reason := public.chat_problem(b);
  if v_reason is null and public.is_number_only(b) then
    -- a number sent in pieces: this message plus the sender's earlier number-only messages of the last 30 minutes
    select coalesce(sum(char_length(regexp_replace(public.contact_numbers(m.body), '[^0-9]', '', 'g'))), 0) into v_prior
      from (select body from public.chat_messages
             where thread_id = p_thread and sender_id = auth.uid() and created_at > now() - interval '30 minutes'
             order by created_at desc limit 8) m
     where public.is_number_only(m.body);
    v_digits := v_prior + char_length(regexp_replace(public.contact_numbers(b), '[^0-9]', '', 'g'));
    if v_prior > 0 and v_digits >= 9 then v_reason := 'SPLIT_NUMBER'; end if;
  end if;
  if v_reason is not null then
    insert into public.chat_flag_events (thread_id, sender_id, reason, body) values (p_thread, auth.uid(), v_reason, left(b, 200));
    select count(*) into v_n from public.chat_flag_events
     where thread_id = p_thread and sender_id = auth.uid() and created_at > coalesce(t.flag_reset_at, '-infinity');
    update public.chat_threads set flag_level = greatest(flag_level, least(v_n, 4)) where id = p_thread;
    if v_n >= 4 then
      update public.chat_threads set status = 'suspended', suspended_at = now(), suspended_reason = 'auto_flag', last_message_at = now() where id = p_thread;
      insert into public.chat_messages (thread_id, sender_id, body, kind) values (p_thread, auth.uid(), 'ห้องนี้ถูกระงับโดยผู้ดูแล', 'sys_suspended');
      return 'THREAD_SUSPENDED';
    end if;
    return 'CONTACT_BLOCKED:' || v_n;
  end if;
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
  return 'OK';
end $$;
revoke all on function public.send_message(uuid, text, boolean) from public, anon;
grant execute on function public.send_message(uuid, text, boolean) to authenticated;

-- ---------- fee per category ----------------------------------------------------------------------------------
create or replace function public.booking_fee_for(p_worker uuid)
returns numeric language sql stable security definer set search_path = public as $$
  select case when exists (select 1 from public.workers w where w.user_id = p_worker and w.categories && array['masseuse', 'spa'])
              then 700::numeric else public.platform_booking_fee() end
$$;
revoke all on function public.booking_fee_for(uuid) from public, anon, authenticated;

alter table public.jobs add column if not exists travel_mode text not null default 'worker_goes' check (travel_mode in ('worker_goes', 'customer_goes'));
alter table public.job_private add column if not exists worker_place text, add column if not exists worker_place_url text;

create or replace function public.jobs_before_insert()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_fee     numeric;
  v_price   numeric;
  v_balance numeric;
  w         public.workers;
begin
  if auth.uid() is not null and new.customer_id <> auth.uid() then raise exception 'FORBIDDEN'; end if;
  if new.worker_id = new.customer_id then raise exception 'FORBIDDEN'; end if;
  -- Must be allowed to see this worker (tier + category + top-10 rule).
  if auth.uid() is not null and not public.can_view_worker(new.worker_id) then raise exception 'LOCKED'; end if;

  select * into w from public.workers where user_id = new.worker_id and is_online;
  if not found then raise exception 'WORKER_UNAVAILABLE'; end if;
  if not w.claimed then raise exception 'UNCLAIMED'; end if;
  v_fee := public.booking_fee_for(new.worker_id);      -- 500, or 700 for massage / spa

  -- the chosen rate: one of her price rows (a booking without a rate keeps the old behaviour: her starting price)
  if coalesce(new.rate_label, '') = '' then
    v_price := w.price; new.rate_label := w.start_rate;
  else
    select (o->>'price')::numeric into v_price from jsonb_array_elements(w.price_options) o where o->>'label' = new.rate_label limit 1;
    if v_price is null then raise exception 'BAD_RATE'; end if;
  end if;

  if auth.uid() is not null then
    if new.scheduled_at is null or new.scheduled_at < now() + interval '10 minutes' or new.scheduled_at > now() + interval '30 days' then
      raise exception 'BAD_TIME';
    end if;
    if public.contact_problem(concat_ws(' | ', new.place_note, new.customer_note)) is not null then raise exception 'CONTACT_IN_BOOKING'; end if;
  end if;

  select wallet_balance into v_balance from public.users where id = new.customer_id for update;
  if v_balance is null or v_balance < v_fee then raise exception 'INSUFFICIENT_BALANCE'; end if;

  perform set_config('app.ledger_kind', 'booking_fee', true);
  perform set_config('app.ledger_ref', new.id::text, true);
  update public.users set wallet_balance = wallet_balance - v_fee where id = new.customer_id;

  -- "customer from <seller>": the seller's OA (vendor) when she came through one, else the seller whose link she used
  select coalesce(bv.name, hv.name, nullif(btrim(s.seller_label), ''), s.display_name) into new.source_label
    from public.users c left join public.vendors bv on bv.id = new.sales_vendor left join public.vendors hv on hv.id = c.vendor_id
         left join public.users s on s.id = c.referred_by
   where c.id = new.customer_id;

  new.booking_fee   := v_fee;
  new.service_price := v_price;
  new.status        := 'pending';
  return new;
end $$;

drop function if exists public.create_booking(uuid, text, timestamptz, text, text, text, double precision, double precision, text, text);
create or replace function public.create_booking(p_worker uuid, p_rate text, p_scheduled timestamptz, p_place_note text default null,
                                                 p_note text default null, p_phone text default null,
                                                 p_lat double precision default null, p_lng double precision default null, p_url text default null,
                                                 p_vendor text default null, p_travel text default 'worker_goes')
returns uuid language plpgsql security definer set search_path = public as $$
declare v_id uuid := gen_random_uuid(); v_digits text; v_url text := nullif(btrim(coalesce(p_url, '')), ''); v_note text := nullif(btrim(coalesce(p_place_note, '')), ''); v_vendor text; v_cust_goes boolean := p_travel = 'customer_goes';
begin
  if auth.uid() is null then raise exception 'FORBIDDEN'; end if;
  v_digits := regexp_replace(coalesce(p_phone, ''), '\D', '', 'g');
  if char_length(v_digits) not between 9 and 13 then raise exception 'BAD_PHONE'; end if;
  if p_travel not in ('worker_goes', 'customer_goes') then raise exception 'BAD_INPUT'; end if;
  -- the customer travels to her (only massage / spa): he gives no place, she gives hers when she accepts
  if v_cust_goes and not exists (select 1 from public.workers w where w.user_id = p_worker and w.categories && array['masseuse', 'spa']) then raise exception 'BAD_INPUT'; end if;
  if not v_cust_goes and (p_lat is null or p_lng is null) and v_url is null and v_note is null then raise exception 'PLACE_REQUIRED'; end if;
  if p_lat is not null and not (p_lat between 5.4 and 20.7 and p_lng between 97.2 and 105.8) then raise exception 'BAD_PLACE'; end if;
  if v_url is not null and (public.contact_problem(v_url) is not null
        or v_url !~* '(maps\.app\.goo\.gl|maps\.google\.|google\.[a-z.]+/maps|goo\.gl/maps)') then
    raise exception 'BAD_MAP_LINK';
  end if;
  -- the seller whose link the customer is booking through (null = our own app); only an active seller counts
  select id into v_vendor from public.vendors where id = p_vendor and status = 'active';
  insert into public.jobs (id, customer_id, worker_id, booking_fee, rate_label, scheduled_at, place_note, customer_note, sales_vendor, travel_mode)
  values (v_id, auth.uid(), p_worker, 0, nullif(btrim(coalesce(p_rate, '')), ''), p_scheduled, left(v_note, 200), left(nullif(btrim(coalesce(p_note, '')), ''), 300), v_vendor, p_travel);
  insert into public.job_private (job_id, customer_phone, place_lat, place_lng, place_url)
  values (v_id, v_digits, case when p_lat is not null and p_lng is not null then p_lat end, case when p_lat is not null and p_lng is not null then p_lng end, v_url);
  return v_id;
end $$;

create or replace function public.job_json(j public.jobs, p_for_worker boolean)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
      'id', j.id, 'status', j.status, 'created_at', j.created_at, 'scheduled_at', j.scheduled_at, 'rate_label', j.rate_label,
      'service_price', j.service_price, 'booking_fee', j.booking_fee, 'place_note', j.place_note, 'customer_note', j.customer_note,
      'accepted_at', j.accepted_at, 'arrived_at', j.arrived_at, 'cancel_reason', j.cancel_reason, 'source_label', j.source_label, 'travel_mode', j.travel_mode, 'fee', j.booking_fee,
      'expires_at', case when j.status = 'pending' then j.created_at + interval '30 minutes' end)
   || case when p_for_worker then jsonb_build_object(
        'customer_name', (select u.display_name from public.users u where u.id = j.customer_id),
        'customer_phone', case when j.status in ('matched', 'completed') then (select p.customer_phone from public.job_private p where p.job_id = j.id) end,
        'place_lat', case when j.status in ('matched', 'completed') then (select p.place_lat from public.job_private p where p.job_id = j.id) end,
        'place_lng', case when j.status in ('matched', 'completed') then (select p.place_lng from public.job_private p where p.job_id = j.id) end,
        'place_url', case when j.status in ('matched', 'completed') then (select p.place_url from public.job_private p where p.job_id = j.id) end)
      else jsonb_build_object(
        'worker_id', j.worker_id,
        'worker_name', (select w.display_name from public.workers w where w.user_id = j.worker_id),
        'worker_image', (select w.profile_image from public.workers w where w.user_id = j.worker_id),
        'worker_phone', case when j.status in ('matched', 'completed') then (select w.booking_phone from public.workers w where w.user_id = j.worker_id) end,
        'worker_line_id', case when j.status in ('matched', 'completed') then (select w.booking_line_id from public.workers w where w.user_id = j.worker_id) end,
        'worker_place', case when j.status in ('matched', 'completed') then (select p.worker_place from public.job_private p where p.job_id = j.id) end,
        'worker_place_url', case when j.status in ('matched', 'completed') then (select p.worker_place_url from public.job_private p where p.job_id = j.id) end) end
$$;

-- the provider accepts; when the customer travels to her she gives the place now (name + room, optionally a map link)
create or replace function public.job_accept(p_job uuid, p_place text default null, p_url text default null)
returns void language plpgsql security definer set search_path = public as $$
declare j public.jobs; v_place text := nullif(btrim(coalesce(p_place, '')), ''); v_url text := nullif(btrim(coalesce(p_url, '')), '');
begin
  if auth.uid() is null then raise exception 'FORBIDDEN'; end if;
  select * into j from public.jobs where id = p_job and worker_id = auth.uid() for update;
  if not found then raise exception 'FORBIDDEN'; end if;
  if j.status <> 'pending' then raise exception 'ILLEGAL_STATUS_TRANSITION'; end if;
  if j.travel_mode = 'customer_goes' then
    if v_place is null or char_length(v_place) < 2 then raise exception 'PLACE_REQUIRED'; end if;
    if public.contact_problem(v_place) is not null then raise exception 'CONTACT_IN_BOOKING'; end if;
    if v_url is not null and (public.contact_problem(v_url) is not null
         or v_url !~* '(maps\.app\.goo\.gl|maps\.google\.|google\.[a-z.]+/maps|goo\.gl/maps)') then raise exception 'BAD_MAP_LINK'; end if;
    update public.job_private set worker_place = left(v_place, 200), worker_place_url = v_url where job_id = p_job;
  end if;
  update public.jobs set status = 'matched' where id = p_job;
end $$;

-- ---------- busy ------------------------------------------------------------------------------------------------
create or replace function public.worker_busy(p_worker uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.jobs j where j.worker_id = p_worker and j.status = 'matched' and j.scheduled_at is not null
                    and now() >= j.scheduled_at - interval '3 hours' and now() <= j.scheduled_at + interval '12 hours')
$$;

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
         case when v.ok then w.original_path end,
         w.is_online, r.is_boosted, r.rank, v.ok,
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

revoke all on function public.job_accept(uuid, text, text), public.worker_busy(uuid), public.create_booking(uuid, text, timestamptz, text, text, text, double precision, double precision, text, text, text),
  public.list_workers(text), public.list_workers_near(double precision, double precision, numeric, text), public.get_worker(uuid), public.job_json(public.jobs, boolean) from public, anon;
grant execute on function public.job_accept(uuid, text, text), public.create_booking(uuid, text, timestamptz, text, text, text, double precision, double precision, text, text, text),
  public.list_workers(text), public.list_workers_near(double precision, double precision, numeric, text), public.get_worker(uuid) to authenticated;
revoke all on function public.worker_busy(uuid), public.job_json(public.jobs, boolean) from authenticated;
