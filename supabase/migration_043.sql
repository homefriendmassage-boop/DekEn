-- =============================================================================
-- migration_043.sql — run ONCE after migration_042.sql
-- A time range a provider has ACCEPTED cannot be booked by anybody else until she presses "finish" (or the booking is cancelled):
--   * create_booking refuses an overlapping time (WORKER_BOOKED)
--   * she cannot accept a second booking that overlaps an accepted one (TIME_CONFLICT)
-- Pending (not yet accepted) bookings do not block anybody.
-- =============================================================================

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
    -- a time she has already accepted is not available until she presses "finish" (or the booking is cancelled)
    if exists (select 1 from public.jobs o where o.worker_id = new.worker_id and o.status = 'matched' and o.scheduled_at is not null
                  and new.scheduled_at < o.scheduled_at + make_interval(mins => public.rate_minutes(o.rate_label))
                  and new.scheduled_at + make_interval(mins => public.rate_minutes(new.rate_label)) > o.scheduled_at) then
      raise exception 'WORKER_BOOKED';
    end if;
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

create or replace function public.job_accept(p_job uuid, p_place text default null, p_url text default null)
returns void language plpgsql security definer set search_path = public as $$
declare j public.jobs; v_place text := nullif(btrim(coalesce(p_place, '')), ''); v_url text := nullif(btrim(coalesce(p_url, '')), '');
begin
  if auth.uid() is null then raise exception 'FORBIDDEN'; end if;
  select * into j from public.jobs where id = p_job and worker_id = auth.uid() for update;
  if not found then raise exception 'FORBIDDEN'; end if;
  if j.status <> 'pending' then raise exception 'ILLEGAL_STATUS_TRANSITION'; end if;
  -- she cannot accept two overlapping bookings: press "finish" on the earlier one first, or decline this one
  if exists (select 1 from public.jobs o where o.worker_id = j.worker_id and o.status = 'matched' and o.id <> j.id and o.scheduled_at is not null
                and j.scheduled_at < o.scheduled_at + make_interval(mins => public.rate_minutes(o.rate_label))
                and j.scheduled_at + make_interval(mins => public.rate_minutes(j.rate_label)) > o.scheduled_at) then
    raise exception 'TIME_CONFLICT';
  end if;
  if j.travel_mode = 'customer_goes' then
    if v_place is null or char_length(v_place) < 2 then raise exception 'PLACE_REQUIRED'; end if;
    if public.contact_problem(v_place) is not null then raise exception 'CONTACT_IN_BOOKING'; end if;
    if v_url is not null and (public.contact_problem(v_url) is not null
         or v_url !~* '(maps\.app\.goo\.gl|maps\.google\.|google\.[a-z.]+/maps|goo\.gl/maps)') then raise exception 'BAD_MAP_LINK'; end if;
    update public.job_private set worker_place = left(v_place, 200), worker_place_url = v_url where job_id = p_job;
  end if;
  update public.jobs set status = 'matched' where id = p_job;
end $$;
revoke all on function public.job_accept(uuid, text, text) from public, anon;
grant execute on function public.job_accept(uuid, text, text) to authenticated;
