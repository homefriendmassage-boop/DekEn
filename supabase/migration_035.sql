-- =============================================================================
-- migration_035.sql — run ONCE after migration_034.sql
-- Booking overhaul:
--   * the customer picks the RATE (4 h / 6 h / 60 min / ...), the date + time, the place (GPS pin and / or a Google Maps
--     link and / or a note) and leaves a phone number. Booking now goes through create_booking() (direct inserts are closed).
--   * the customer's phone and exact place are in job_private and are shown to the provider ONLY after she accepts; the
--     provider's contact (workers.booking_phone / booking_line_id, filled from her application, editable by her) is shown to
--     the customer ONLY after she accepts.
--   * the provider has 30 minutes to answer; then the booking is cancelled and the 500 THB fee refunded (cron, every minute).
--   * "arrived" button for the provider (job_arrived).
--   * Flex pushes: new booking -> provider; accepted / declined / expired / arrived / completed / cancelled -> the other side
--     (the Edge Function notify-chat, same URL and secret as the chat push).
--   * workers.claimed / claim_deadline: a profile an admin published for a girl who has not confirmed yet cannot be booked.
-- =============================================================================

alter table public.jobs
  add column if not exists rate_label text,
  add column if not exists scheduled_at timestamptz,
  add column if not exists place_note text,
  add column if not exists customer_note text,
  add column if not exists accepted_at timestamptz,
  add column if not exists arrived_at timestamptz,
  add column if not exists cancel_reason text;       -- customer | declined | expired | worker_cancelled | admin

create table if not exists public.job_private (
  job_id uuid primary key references public.jobs (id) on delete cascade,
  customer_phone text, place_lat double precision, place_lng double precision, place_url text
);
alter table public.job_private enable row level security;
revoke all on public.job_private from anon, authenticated;

alter table public.workers
  add column if not exists booking_phone text,
  add column if not exists booking_line_id text,
  add column if not exists claimed boolean not null default true,
  add column if not exists claim_deadline timestamptz;
-- default for existing providers: what she wrote in her application
update public.workers w set booking_phone = a.phone, booking_line_id = a.line_id
  from (select distinct on (user_id) user_id, phone, line_id from public.worker_applications order by user_id, created_at desc) a
 where a.user_id = w.user_id and w.booking_phone is null and w.booking_line_id is null;

-- ---------- insert guard: rate, time, notes, unclaimed ---------------------------------------
create or replace function public.jobs_before_insert()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_fee     numeric := public.platform_booking_fee();
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

  new.booking_fee   := v_fee;
  new.service_price := v_price;
  new.status        := 'pending';
  return new;
end $$;

-- ---------- status changes: who, refund, reason, accepted_at ------------------------------
create or replace function public.jobs_guard_update()
returns trigger language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid();
begin
  if new.status = old.status then return new; end if;

  if me is not null then
    if not (
      (me = new.customer_id and old.status = 'pending' and new.status = 'cancelled')
      or (me = new.worker_id and (
            (old.status = 'pending' and new.status in ('matched', 'cancelled'))
         or (old.status = 'matched' and new.status in ('completed', 'cancelled'))))
    ) then
      raise exception 'ILLEGAL_STATUS_TRANSITION';
    end if;
  end if;

  if new.status = 'matched' then new.accepted_at := now(); end if;
  if new.status = 'cancelled' then
    new.cancel_reason := case
      when coalesce(current_setting('app.job_expiry', true), '') = 'on' then 'expired'
      when old.status = 'matched' then case when me = new.worker_id then 'worker_cancelled' else 'admin' end
      when me = new.customer_id then 'customer'
      when me = new.worker_id then 'declined'
      when coalesce(current_setting('app.job_expiry', true), '') = 'on' then 'expired'
      else 'admin' end;
  end if;

  if old.status = 'pending' and new.status = 'cancelled' then
    perform set_config('app.ledger_kind', 'booking_refund', true);
    perform set_config('app.ledger_ref', old.id::text, true);
    update public.users set wallet_balance = wallet_balance + old.booking_fee where id = old.customer_id;
  end if;
  return new;
end $$;

-- ---------- booking RPC --------------------------------------------------------------------
create or replace function public.create_booking(p_worker uuid, p_rate text, p_scheduled timestamptz, p_place_note text default null,
                                                 p_note text default null, p_phone text default null,
                                                 p_lat double precision default null, p_lng double precision default null, p_url text default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_id uuid := gen_random_uuid(); v_digits text; v_url text := nullif(btrim(coalesce(p_url, '')), ''); v_note text := nullif(btrim(coalesce(p_place_note, '')), '');
begin
  if auth.uid() is null then raise exception 'FORBIDDEN'; end if;
  v_digits := regexp_replace(coalesce(p_phone, ''), '\D', '', 'g');
  if char_length(v_digits) not between 9 and 13 then raise exception 'BAD_PHONE'; end if;
  if (p_lat is null or p_lng is null) and v_url is null and v_note is null then raise exception 'PLACE_REQUIRED'; end if;
  if p_lat is not null and not (p_lat between 5.4 and 20.7 and p_lng between 97.2 and 105.8) then raise exception 'BAD_PLACE'; end if;
  if v_url is not null and (public.contact_problem(v_url) is not null
        or v_url !~* '(maps\.app\.goo\.gl|maps\.google\.|google\.[a-z.]+/maps|goo\.gl/maps)') then
    raise exception 'BAD_MAP_LINK';
  end if;
  insert into public.jobs (id, customer_id, worker_id, booking_fee, rate_label, scheduled_at, place_note, customer_note)
  values (v_id, auth.uid(), p_worker, 0, nullif(btrim(coalesce(p_rate, '')), ''), p_scheduled, left(v_note, 200), left(nullif(btrim(coalesce(p_note, '')), ''), 300));
  insert into public.job_private (job_id, customer_phone, place_lat, place_lng, place_url)
  values (v_id, v_digits, case when p_lat is not null and p_lng is not null then p_lat end, case when p_lat is not null and p_lng is not null then p_lng end, v_url);
  return v_id;
end $$;
revoke insert on public.jobs from authenticated;       -- booking only through create_booking()

-- ---------- lists --------------------------------------------------------------------------
create or replace function public.job_json(j public.jobs, p_for_worker boolean)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
      'id', j.id, 'status', j.status, 'created_at', j.created_at, 'scheduled_at', j.scheduled_at, 'rate_label', j.rate_label,
      'service_price', j.service_price, 'booking_fee', j.booking_fee, 'place_note', j.place_note, 'customer_note', j.customer_note,
      'accepted_at', j.accepted_at, 'arrived_at', j.arrived_at, 'cancel_reason', j.cancel_reason,
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
        'worker_line_id', case when j.status in ('matched', 'completed') then (select w.booking_line_id from public.workers w where w.user_id = j.worker_id) end) end
$$;
revoke all on function public.job_json(public.jobs, boolean) from public, anon, authenticated;

drop function if exists public.my_worker_jobs();
create or replace function public.my_worker_jobs()
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(public.job_json(j, true) order by j.created_at desc), '[]'::jsonb)
    from (select * from public.jobs where worker_id = auth.uid() order by created_at desc limit 100) j
$$;
create or replace function public.my_customer_jobs()
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(public.job_json(j, false) order by j.created_at desc), '[]'::jsonb)
    from (select * from public.jobs where customer_id = auth.uid() order by created_at desc limit 100) j
$$;

create or replace function public.job_arrived(p_job uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  update public.jobs set arrived_at = now() where id = p_job and worker_id = auth.uid() and status = 'matched' and arrived_at is null;
  if not found then raise exception 'NOT_FOUND'; end if;
end $$;

create or replace function public.update_my_booking_contact(p_phone text, p_line_id text)
returns void language plpgsql security definer set search_path = public as $$
declare v_phone text := nullif(regexp_replace(coalesce(p_phone, ''), '[^0-9+]', '', 'g'), ''); v_line text := left(nullif(btrim(coalesce(p_line_id, '')), ''), 40);
begin
  if v_phone is null and v_line is null then raise exception 'BAD_INPUT'; end if;
  if v_phone is not null and char_length(regexp_replace(v_phone, '\D', '', 'g')) not between 9 and 13 then raise exception 'BAD_PHONE'; end if;
  update public.workers set booking_phone = v_phone, booking_line_id = v_line where user_id = auth.uid();
  if not found then raise exception 'FORBIDDEN'; end if;
end $$;

-- ---------- 30 minutes to answer -----------------------------------------------------------
create or replace function public.expire_pending_jobs()
returns int language plpgsql security definer set search_path = public as $$
declare n int;
begin
  perform set_config('app.job_expiry', 'on', true);
  update public.jobs set status = 'cancelled' where status = 'pending' and created_at < now() - interval '30 minutes';
  get diagnostics n = row_count;
  return n;
end $$;
revoke all on function public.expire_pending_jobs() from public, anon, authenticated;

-- ---------- Flex pushes (through the notify-chat Edge Function) ------------------------------
create or replace function public.jobs_notify()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_url text; v_secret text; v_event text;
begin
  select value into v_url from public.private_config where key = 'chat_notify_url';
  select value into v_secret from public.private_config where key = 'chat_notify_secret';
  if v_url is null or v_secret is null then return new; end if;
  if tg_op = 'INSERT' then v_event := 'new';
  elsif new.status is distinct from old.status then
    v_event := case
      when new.status = 'matched' then 'accepted'
      when new.status = 'completed' then 'completed'
      when new.status = 'cancelled' then coalesce(new.cancel_reason, 'admin') end;
  elsif new.arrived_at is not null and old.arrived_at is null then v_event := 'arrived';
  end if;
  if v_event is null then return new; end if;
  execute format('select net.http_post(url := %L, headers := %L::jsonb, body := %L::jsonb)', v_url,
    jsonb_build_object('Content-Type', 'application/json', 'x-webhook-secret', v_secret)::text,
    jsonb_build_object('type', 'booking', 'event', v_event, 'job_id', new.id)::text);
  return new;
exception when others then
  return new;
end $$;
drop trigger if exists jobs_notify on public.jobs;
create trigger jobs_notify after insert or update of status, arrived_at on public.jobs
  for each row execute function public.jobs_notify();

revoke all on function public.create_booking(uuid, text, timestamptz, text, text, text, double precision, double precision, text),
  public.my_worker_jobs(), public.my_customer_jobs(), public.job_arrived(uuid), public.update_my_booking_contact(text, text) from public, anon;
grant execute on function public.create_booking(uuid, text, timestamptz, text, text, text, double precision, double precision, text),
  public.my_worker_jobs(), public.my_customer_jobs(), public.job_arrived(uuid), public.update_my_booking_contact(text, text) to authenticated;

do $$ begin
  create extension if not exists pg_cron;
  perform cron.schedule('expire-pending-jobs', '* * * * *', 'select public.expire_pending_jobs()');
exception when others then
  raise notice 'pg_cron is not enabled (%): pending bookings will not expire by themselves', sqlerrm;
end $$;
-- =============================================================================
