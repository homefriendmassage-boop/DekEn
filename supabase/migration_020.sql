-- =============================================================================
-- migration_020.sql — run ONCE after migration_019.sql (and 017, which creates app_settings)
-- Simpler agency membership:
--   * A girl who applies through an agency's own link is accepted by that agency automatically
--     (the agency sent the link). Only the admin's approval of her profile remains.
--   * If the agency's girl slots are full, the application is refused ("agency full") until the agency adds a slot.
--   * She may leave the agency after a waiting period (default 15 days from joining; setting agency_leave_days),
--     or at any time once the agency's plan is not active, and then works on her own, still online.
--   * An independent girl (also one who left) joins an agency by opening its link and accepting
--     (worker_join_agency): no new application, no admin step.
-- =============================================================================

alter table public.workers add column if not exists agency_since timestamptz;
update public.workers set agency_since = now() where agency_id is not null and agency_since is null;
insert into public.app_settings (key, value) values ('agency_leave_days', '15') on conflict (key) do nothing;

create or replace function public.agency_leave_days() returns int language sql stable security definer set search_path = public as $$
  select coalesce(public.app_setting('agency_leave_days'), '15')::int
$$;

-- allow the new setting to be changed from the admin side too
create or replace function public.admin_set_setting(p_key text, p_value text)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public.assert_admin();
  if p_key not in ('wallet_expiry_enabled', 'wallet_expiry_months', 'bonus_sweep_days', 'agency_leave_days') then raise exception 'BAD_INPUT'; end if;
  if p_key = 'wallet_expiry_enabled' and p_value not in ('true', 'false') then raise exception 'BAD_INPUT'; end if;
  if p_key <> 'wallet_expiry_enabled' and (p_value !~ '^[0-9]{1,3}$' or p_value::int < 0) then raise exception 'BAD_INPUT'; end if;
  update public.app_settings set value = p_value, updated_at = now(), updated_by = auth.uid() where key = p_key;
end $$;

-- ---------- Applying through the link: accepted at once, unless the agency is full ----------------------
create or replace function public.applications_set_agency()
returns trigger language plpgsql security definer set search_path = public as $$
declare a public.agencies;
begin
  if new.agency_code is null or btrim(new.agency_code) = '' then
    new.agency_code := null; new.agency_id := null; new.agency_status := null;
    return new;
  end if;
  select * into a from public.agencies where code = btrim(new.agency_code) and status = 'approved';
  if not found or a.user_id = new.user_id then raise exception 'AGENCY_NOT_FOUND'; end if;
  if public.agency_girl_count(a.user_id) >= public.agency_included_girls() + a.extra_slots then raise exception 'AGENCY_FULL'; end if;
  new.agency_id := a.user_id;
  new.agency_status := 'accepted';
  return new;
end $$;

-- the agency may still withdraw a girl whose profile is waiting for approval
create or replace function public.agency_review_girl(p_app uuid, p_accept boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  if p_accept then raise exception 'BAD_INPUT'; end if;      -- accepting happens automatically now
  update public.worker_applications set agency_status = 'rejected'
   where id = p_app and agency_id = auth.uid() and status = 'pending';
  if not found then raise exception 'NOT_FOUND'; end if;
end $$;

create or replace function public.agency_pending_girls()
returns table (app_id uuid, display_name text, categories text[], province text, note text, created_at timestamptz)
language sql stable security definer set search_path = public as $$
  select x.id, x.display_name, x.categories, x.province, x.note, x.created_at
    from public.worker_applications x
   where x.agency_id = auth.uid() and x.agency_status = 'accepted' and x.status = 'pending'
   order by x.created_at
$$;

create or replace function public.agency_girl_count(p_agency uuid)
returns int language sql stable security definer set search_path = public as $$
  select (select count(*) from public.workers w where w.agency_id = p_agency)::int
       + (select count(*) from public.worker_applications x
           where x.agency_id = p_agency and x.agency_status = 'accepted' and x.status = 'pending')::int
$$;

create or replace function public.approve_worker(p_app uuid)
returns void language plpgsql security definer set search_path = public as $$
declare a public.worker_applications;
begin
  select * into a from public.worker_applications where id = p_app and status = 'pending';
  if not found then raise exception 'NOT_FOUND'; end if;
  if a.agency_id is not null and a.agency_status is distinct from 'accepted' then raise exception 'AGENCY_NOT_CONFIRMED'; end if;
  update public.users set role = 'worker' where id = a.user_id;
  insert into public.workers (user_id, display_name, categories, price, province, district, nearby,
                              profile_image, original_path, recruiter_id, recruiter_until, agency_id, agency_since)
  values (a.user_id, a.display_name, a.categories, a.price, a.province, a.district, a.nearby,
          a.profile_image, a.original_path, a.recruiter_id,
          case when a.recruiter_id is not null then now() + make_interval(days => public.recruiter_window_days()) end,
          a.agency_id, case when a.agency_id is not null then now() end)
  on conflict (user_id) do update
    set display_name = excluded.display_name, categories = excluded.categories, price = excluded.price,
        province = excluded.province, district = excluded.district, nearby = excluded.nearby,
        profile_image = coalesce(excluded.profile_image, public.workers.profile_image),
        original_path = coalesce(excluded.original_path, public.workers.original_path),
        agency_id = coalesce(excluded.agency_id, public.workers.agency_id),
        agency_since = case when excluded.agency_id is not null and excluded.agency_id is distinct from public.workers.agency_id
                            then now() else public.workers.agency_since end;
  update public.worker_applications set status = 'approved' where id = p_app;
end $$;
revoke all on function public.approve_worker(uuid) from public, anon, authenticated;

-- ---------- Leaving / joining ------------------------------------------------------------------------
drop function if exists public.my_worker_agency();
create function public.my_worker_agency()
returns table (agency_name text, logo_path text, plan_expires_at timestamptz, can_leave boolean, can_leave_at timestamptz)
language sql stable security definer set search_path = public as $$
  select a.name, a.logo_path, a.plan_expires_at,
         (not public.agency_active(a.user_id)) or now() >= coalesce(w.agency_since, now()) + make_interval(days => public.agency_leave_days()),
         coalesce(w.agency_since, now()) + make_interval(days => public.agency_leave_days())
    from public.workers w join public.agencies a on a.user_id = w.agency_id where w.user_id = auth.uid()
$$;

create or replace function public.worker_leave_agency()
returns void language plpgsql security definer set search_path = public as $$
declare w public.workers;
begin
  select * into w from public.workers where user_id = auth.uid();
  if not found or w.agency_id is null then raise exception 'NOT_FOUND'; end if;
  if public.agency_active(w.agency_id)
     and now() < coalesce(w.agency_since, now()) + make_interval(days => public.agency_leave_days()) then
    raise exception 'AGENCY_ACTIVE';
  end if;
  update public.workers set agency_id = null, agency_since = null where user_id = auth.uid();
end $$;

-- An approved independent girl accepts an invitation: she is in the agency right away.
create or replace function public.worker_join_agency(p_code text)
returns void language plpgsql security definer set search_path = public as $$
declare w public.workers; a public.agencies;
begin
  if auth.uid() is null then raise exception 'FORBIDDEN'; end if;
  if public.is_suspended(auth.uid()) then raise exception 'SUSPENDED'; end if;
  select * into w from public.workers where user_id = auth.uid() for update;
  if not found then raise exception 'NOT_A_WORKER'; end if;
  if w.agency_id is not null then raise exception 'ALREADY_IN_AGENCY'; end if;
  select * into a from public.agencies where code = btrim(p_code) and status = 'approved';
  if not found then raise exception 'AGENCY_NOT_FOUND'; end if;
  if public.agency_girl_count(a.user_id) >= public.agency_included_girls() + a.extra_slots then raise exception 'AGENCY_FULL'; end if;
  update public.workers set agency_id = a.user_id, agency_since = now() where user_id = auth.uid();
end $$;

revoke all on function public.agency_leave_days(), public.my_worker_agency(), public.worker_leave_agency(),
  public.worker_join_agency(text), public.agency_review_girl(uuid, boolean), public.agency_pending_girls(),
  public.agency_girl_count(uuid), public.admin_set_setting(text, text) from public, anon;
grant execute on function public.my_worker_agency(), public.worker_leave_agency(), public.worker_join_agency(text),
  public.agency_review_girl(uuid, boolean), public.agency_pending_girls(), public.admin_set_setting(text, text) to authenticated;
-- =============================================================================
