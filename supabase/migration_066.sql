-- =============================================================================
-- migration_066.sql — run ONCE after migration_065.sql
--   * RECRUITER slot order: the seller / provider who brought the girl (within her 90 days, renewing while she works) comes FIRST, even
--     after the girl joined an agency; the agency (paid + another girl) takes the slot only when she has no valid recruiter; else the platform
--   * an agency earns the SALES slot only when the customer books one of ITS OWN girls (an agency that is also a provider / paid seller keeps
--     the normal seller rule for its other roles)
-- =============================================================================

create or replace function public.seller_only_via_agency(p_user uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.agencies a where a.user_id = p_user and a.status = 'approved')
     and not public.provider_alive(p_user)
     and not exists (select 1 from public.vendors v where v.owner_user_id = p_user and v.status = 'active')
     and not exists (select 1 from public.users u where u.id = p_user and u.seller_until >= now())
$$;
revoke all on function public.seller_only_via_agency(uuid) from public, anon, authenticated;

create or replace function public.booking_recruiter(p_worker uuid)
returns uuid language plpgsql security definer set search_path = public as $$
declare w public.workers; v_until timestamptz;
begin
  select * into w from public.workers where user_id = p_worker for update;
  if not found then return null; end if;
  -- 1) the seller / provider who brought her, while her window is alive (also after she joined an agency)
  if w.recruiter_id is not null and not w.recruiter_lapsed then
    v_until := w.recruiter_until;
    while v_until <= now() loop
      if exists (select 1 from public.jobs j
                  where j.worker_id = p_worker and j.status in ('matched', 'completed')
                    and j.created_at >= v_until - make_interval(days => public.recruiter_active_days())
                    and j.created_at <  v_until) then
        v_until := v_until + make_interval(days => public.recruiter_window_days());
      else
        update public.workers set recruiter_lapsed = true where user_id = p_worker;
        exit;
      end if;
    end loop;
    if not exists (select 1 from public.workers x where x.user_id = p_worker and x.recruiter_lapsed) then
      if v_until is distinct from w.recruiter_until then update public.workers set recruiter_until = v_until where user_id = p_worker; end if;
      if public.is_seller_at(w.recruiter_id, now()) then return w.recruiter_id; end if;
    end if;
  end if;
  -- 2) her agency, when it is paid and has a girl besides its owner (an owner registering herself never earns on her own bookings)
  if w.agency_id is not null and w.agency_id <> w.user_id and public.agency_recruiter_eligible(w.agency_id) then return w.agency_id; end if;
  return null;
end $$;

create or replace function public.pay_booking_shares(p_job uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  j        public.jobs;
  v_rec    uuid;
  v_sales  uuid;
  v_a_rec  numeric;
  v_a_sal  numeric;
  v_kind   text;
begin
  select * into j from public.jobs where id = p_job;
  if not found or j.booking_fee <= 0 then return; end if;
  if exists (select 1 from public.booking_shares where job_id = p_job) then return; end if;

  v_rec   := public.booking_recruiter(j.worker_id);
  v_sales := public.resolve_sales(j.customer_id, j.sales_vendor);
  if v_rec   is not null and public.is_suspended(v_rec) then v_rec := null; end if;
  if v_sales is not null and (v_sales = j.customer_id or public.is_suspended(v_sales)) then v_sales := null; end if;
  -- an agency earns the sales slot only on a booking of ITS OWN girl (when it has no other way of being a seller: not a provider, not a paid seller)
  if v_sales is not null and public.seller_only_via_agency(v_sales)
     and not exists (select 1 from public.workers w where w.user_id = j.worker_id and w.agency_id = v_sales) then v_sales := null; end if;
  -- one person, one slot per booking: only an agency that is paid and has a girl besides its owner may hold both
  if v_rec is not null and v_sales = v_rec and not public.agency_recruiter_eligible(v_rec) then v_sales := null; end if;
  v_a_rec := case when v_rec   is not null then round(j.booking_fee * public.booking_share_recruiter_rate(), 2) else 0 end;
  v_a_sal := case when v_sales is not null then round(j.booking_fee * public.booking_share_sales_rate(), 2) else 0 end;
  v_kind  := case when exists (select 1 from public.agencies where user_id = v_rec) then 'agency_share' else 'booking_share_recruiter' end;

  if v_rec is not null then
    insert into public.booking_shares (job_id, role, beneficiary, amount) values (p_job, 'recruiter', v_rec, v_a_rec);
    perform set_config('app.ledger_kind', v_kind, true);
    perform set_config('app.ledger_ref', p_job::text, true);
    update public.users set bonus_balance = bonus_balance + v_a_rec where id = v_rec;
  end if;
  if v_sales is not null then
    insert into public.booking_shares (job_id, role, beneficiary, amount) values (p_job, 'sales', v_sales, v_a_sal);
    perform set_config('app.ledger_kind', 'booking_share_sales', true);
    perform set_config('app.ledger_ref', p_job::text, true);
    update public.users set bonus_balance = bonus_balance + v_a_sal where id = v_sales;
  end if;
  insert into public.booking_shares (job_id, role, beneficiary, amount)
  values (p_job, 'platform', null, j.booking_fee - v_a_rec - v_a_sal);
end $$;
