-- =============================================================================
-- migration_067.sql — run ONCE after migration_066.sql
-- The simple rule for the recruiter slot (40 %), in this order:
--   1) the girl's agency, when it is PAID and has a girl besides its owner  -> the agency, always (a recruiter of the girl gets nothing then)
--   2) otherwise the seller / provider who brought her, while her 90 days are alive (renewing while she works)
--   3) otherwise the platform
-- (migration_066 had put the recruiter before the agency; this puts the paid agency first again.) The sales slot stays as in 066.
-- =============================================================================

create or replace function public.booking_recruiter(p_worker uuid)
returns uuid language plpgsql security definer set search_path = public as $$
declare w public.workers; v_until timestamptz;
begin
  select * into w from public.workers where user_id = p_worker for update;
  if not found then return null; end if;
  -- 1) her agency, when it is paid and has another girl (an owner registering herself never earns on her own bookings)
  if w.agency_id is not null and w.agency_id <> w.user_id and public.agency_recruiter_eligible(w.agency_id) then return w.agency_id; end if;
  -- 2) otherwise the seller / provider who brought her
  if w.recruiter_id is null or w.recruiter_lapsed then return null; end if;
  v_until := w.recruiter_until;
  while v_until <= now() loop
    if exists (select 1 from public.jobs j
                where j.worker_id = p_worker and j.status in ('matched', 'completed')
                  and j.created_at >= v_until - make_interval(days => public.recruiter_active_days())
                  and j.created_at <  v_until) then
      v_until := v_until + make_interval(days => public.recruiter_window_days());
    else
      update public.workers set recruiter_lapsed = true where user_id = p_worker;
      return null;
    end if;
  end loop;
  if v_until is distinct from w.recruiter_until then
    update public.workers set recruiter_until = v_until where user_id = p_worker;
  end if;
  if not public.is_seller_at(w.recruiter_id, now()) then return null; end if;
  return w.recruiter_id;
end $$;
