-- =============================================================================
-- migration_042.sql — run ONCE after migration_041.sql
--   * "busy" starts 1 hour before an accepted appointment (was 3) and lasts until she presses "finish" / the booking is cancelled,
--     or — if she forgets — until 2 hours after the booked length has passed.
--   * worker_booked_slots(): the time ranges a provider already has ACCEPTED bookings for (no customer data), so a new customer sees
--     them in the booking form and can decide whether to book another time. A booking for a busy provider still goes to her as a
--     request: she accepts or declines; no answer in 30 minutes = declined, the fee is refunded and the customer is told (unchanged).
-- =============================================================================

-- how long a booked rate lasts: '@60' / '@90' / '@120' = minutes, '@4h' / '@6h' / '1h' = hours, anything else = 4 hours
create or replace function public.rate_minutes(p_label text)
returns int language sql immutable as $$
  select case
    when p_label ~ '^@(60|90|120)$' then substr(p_label, 2)::int
    when p_label ~ '^@?[0-9]{1,2}h$' then (regexp_replace(p_label, '[^0-9]', '', 'g'))::int * 60
    else 240 end
$$;

create or replace function public.worker_busy(p_worker uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.jobs j where j.worker_id = p_worker and j.status = 'matched' and j.scheduled_at is not null
                    and now() >= j.scheduled_at - interval '1 hour'
                    and now() <= j.scheduled_at + make_interval(mins => public.rate_minutes(j.rate_label)) + interval '2 hours')
$$;

create or replace function public.worker_booked_slots(p_worker uuid)
returns table (start_at timestamptz, end_at timestamptz) language sql stable security definer set search_path = public as $$
  select j.scheduled_at, j.scheduled_at + make_interval(mins => public.rate_minutes(j.rate_label))
    from public.jobs j
   where j.worker_id = p_worker and j.status = 'matched' and j.scheduled_at is not null
     and j.scheduled_at + make_interval(mins => public.rate_minutes(j.rate_label)) > now() and j.scheduled_at < now() + interval '31 days'
   order by j.scheduled_at
$$;

revoke all on function public.rate_minutes(text), public.worker_busy(uuid), public.worker_booked_slots(uuid) from public, anon;
grant execute on function public.rate_minutes(text), public.worker_booked_slots(uuid) to authenticated;
revoke all on function public.worker_busy(uuid) from authenticated;
