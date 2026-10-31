-- =============================================================================
-- migration_061.sql — run ONCE after migration_060.sql
--   * A provider counts as a seller only while her profile is alive: not deleted, not hidden by an admin, not hidden for being inactive.
--   * The "recruiter" share (40 % of the booking fee of a girl who applied through somebody's link) goes only to a SELLER (a provider, a paid
--     seller or a seller-OA owner) at the time she applies and again at the time of each booking. A link shared by anybody else is the
--     central link: the platform keeps that share. (The 20 % package share is unchanged: it goes to the customer's first inviter.)
-- =============================================================================

create or replace function public.provider_alive(p_user uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.workers w
                  where w.user_id = p_user and w.deleted_at is null and not w.admin_hidden
                    and not coalesce((select a.hidden from public.worker_alive a where a.user_id = w.user_id), false))
$$;
revoke all on function public.provider_alive(uuid) from public, anon, authenticated;

create or replace function public.seller_free_via(p_user uuid)
returns text language sql stable security definer set search_path = public as $$
  select case when exists (select 1 from public.vendors v where v.owner_user_id = p_user and v.status = 'active') then 'vendor'
              when public.provider_alive(p_user) then 'provider' end
$$;

create or replace function public.is_seller_at(p_user uuid, p_at timestamptz)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.vendors v where v.owner_user_id = p_user and v.status = 'active' and v.created_at <= p_at)
      or (public.provider_alive(p_user) and exists (select 1 from public.workers w where w.user_id = p_user and w.created_at <= p_at))
      or exists (select 1 from public.users u where u.id = p_user and u.seller_since <= p_at and u.seller_until >= p_at)
$$;
revoke all on function public.seller_free_via(uuid), public.is_seller_at(uuid, timestamptz) from public, anon, authenticated;

-- recruiter on a new application: only a seller counts
create or replace function public.applications_set_recruiter()
returns trigger language plpgsql security definer set search_path = public as $$
declare v uuid;
begin
  select c.referrer_id into v from public.referral_clicks c
   where c.user_id = new.user_id and c.clicked_at > now() - interval '24 hours';
  if v is null then select referred_by into v from public.users where id = new.user_id; end if;
  new.recruiter_id := case when v is distinct from new.user_id and v is not null and public.is_seller_at(v, now()) then v end;
  return new;
end $$;

-- and again when a booking pays out (the whole function is written out: the agency rule of migration_019 + the seller check)
create or replace function public.booking_recruiter(p_worker uuid)
returns uuid language plpgsql security definer set search_path = public as $$
declare w public.workers; v_until timestamptz;
begin
  select * into w from public.workers where user_id = p_worker for update;
  if not found then return null; end if;
  if w.agency_id is not null then return w.agency_id; end if;
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
  -- only a seller earns the recruiter share; for anybody else it stays with the platform (the window is not used up)
  if not public.is_seller_at(w.recruiter_id, now()) then return null; end if;
  return w.recruiter_id;
end $$;
