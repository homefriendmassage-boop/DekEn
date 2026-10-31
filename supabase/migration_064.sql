-- =============================================================================
-- migration_064.sql — run ONCE after migration_063.sql
-- Modelling agency, after the admin approves it (paid plan or not):
--   * it can create / edit / submit / delete application drafts and send the 3-day links to its girls (no PLAN_INACTIVE any more)
--   * its girls stay listed for customers, and the agency badge stays on their photos while they belong to it
--   * WITHOUT a paid plan: the agency's 40 % recruiter share of its girls' bookings stays with the platform; the agency is not in the
--     strip and has no agency page; it can NOT buy slots / boosts
--   * with or without a plan it earns the 40 % sales share when a customer who came through its link books (an approved agency counts as a
--     seller, like any seller); the 20 % package share is unchanged
-- =============================================================================

-- ---------- drafts ------------------------------------------------------------------------------------------------------------
create or replace function public.draft_save(p_id uuid, p_data jsonb)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  r public.application_drafts; d public.application_drafts; v_id uuid;
  v_admin boolean := public.is_admin(); v_agency uuid;
begin
  if auth.uid() is null then raise exception 'FORBIDDEN'; end if;
  if not v_admin then
    select user_id into v_agency from public.agencies where user_id = auth.uid() and status = 'approved';
    if v_agency is null then raise exception 'NOT_APPROVED'; end if;      -- an approved agency may draft with or without a paid plan
  end if;
  r := jsonb_populate_record(null::public.application_drafts, coalesce(p_data, '{}'::jsonb));
  if r.categories is null or coalesce(array_length(r.categories, 1), 0) = 0 or btrim(coalesce(r.display_name, '')) = '' then raise exception 'BAD_INPUT'; end if;
  -- the province written here is only a temporary guess; the girl confirms her place by GPS when she accepts the link
  r.province := nullif(btrim(coalesce(r.province, '')), '');
  if r.province is not null and not exists (select 1 from public.province_centroids where name = r.province) then raise exception 'BAD_PROVINCE'; end if;

  if p_id is null then
    if (select count(*) from public.application_drafts where created_by = auth.uid() and status in ('draft', 'submitted', 'approved', 'rejected')) >= 40 then
      raise exception 'TOO_MANY_DRAFTS';
    end if;
    insert into public.application_drafts (created_by, source, agency_id, display_name, categories, gender, age, height_cm, weight_kg, measurements,
                                           tags, about, price, price_options, start_rate, service_mode, province, district, nearby, phone, line_id, note)
    values (auth.uid(), case when v_admin then 'admin' else 'agency' end, case when v_admin then null else v_agency end,
            r.display_name, r.categories, r.gender, r.age, r.height_cm, r.weight_kg, r.measurements,
            coalesce(r.tags, '{}'), r.about, coalesce(r.price, 0), coalesce(r.price_options, '[]'::jsonb), r.start_rate, r.service_mode,
            r.province, r.district, r.nearby, nullif(btrim(coalesce(r.phone, '')), ''), nullif(btrim(coalesce(r.line_id, '')), ''), left(r.note, 300))
    returning id into v_id;
    return v_id;
  end if;

  select * into d from public.application_drafts where id = p_id and (created_by = auth.uid() or (public.is_admin() and source = 'admin')) for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if d.status not in ('draft', 'rejected', 'approved', 'expired') then raise exception 'LOCKED'; end if;
  update public.application_drafts set
    display_name = r.display_name, categories = r.categories, gender = r.gender, age = r.age, height_cm = r.height_cm, weight_kg = r.weight_kg,
    measurements = r.measurements, tags = coalesce(r.tags, '{}'), about = r.about, price = coalesce(r.price, 0),
    price_options = coalesce(r.price_options, '[]'::jsonb), start_rate = r.start_rate, service_mode = r.service_mode,
    province = coalesce(r.province, d.province), district = r.district, nearby = r.nearby, phone = nullif(btrim(coalesce(r.phone, '')), ''), line_id = nullif(btrim(coalesce(r.line_id, '')), ''),
    note = left(r.note, 300), updated_at = now(),
    -- an agency's change after approval needs a new approval; an admin's own draft keeps its link
    status = case when v_admin then (case when d.status = 'expired' then 'draft' else d.status end) else 'draft' end,
    token = case when v_admin then d.token else null end,
    reject_reason = null
   where id = p_id;
  perform public.sync_managed_profile(p_id);
  return p_id;
end $$;

create or replace function public.draft_submit(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare d public.application_drafts;
begin
  select * into d from public.application_drafts where id = p_id and created_by = auth.uid() and source = 'agency' for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if d.status not in ('draft', 'rejected') then raise exception 'LOCKED'; end if;
  if not exists (select 1 from public.draft_photos where draft_id = p_id) then raise exception 'NO_PHOTO'; end if;
  update public.application_drafts set status = 'submitted', reject_reason = null, updated_at = now() where id = p_id;
end $$;

create or replace function public.draft_issue_link(p_id uuid)
returns text language plpgsql security definer set search_path = public as $$
declare d public.application_drafts; v_tok text := public.draft_new_token(); v_admin boolean := public.is_admin();
begin
  select * into d from public.application_drafts where id = p_id and (created_by = auth.uid() or v_admin) for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if d.source = 'agency' and not v_admin then
    if d.status not in ('approved', 'expired') then raise exception 'NOT_APPROVED'; end if;
  else
    if d.status not in ('draft', 'approved', 'expired') and not (v_admin and d.status = 'submitted') then raise exception 'LOCKED'; end if;
  end if;
  if not exists (select 1 from public.draft_photos where draft_id = p_id) then raise exception 'NO_PHOTO'; end if;
  update public.application_drafts set status = 'approved', token = v_tok, link_issued_at = now(), link_expires_at = now() + interval '3 days',
         reviewed_by = case when v_admin then auth.uid() else reviewed_by end, reviewed_at = case when v_admin then now() else reviewed_at end,
         updated_at = now() where id = p_id;
  -- an unclaimed published profile keeps showing for 14 more days from the moment a link is (re)issued
  update public.workers set claim_deadline = greatest(coalesce(claim_deadline, now()), now() + interval '14 days')
   where user_id = d.managed_user_id and not claimed;
  return v_tok;
end $$;

-- ---------- listing: a girl of an unpaid agency is still shown ------------------------------------------------------------------------
create or replace function public.worker_listed(p_worker uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select not public.is_suspended(p_worker)
     and not coalesce((select a.hidden from public.worker_alive a where a.user_id = p_worker), false)
     and coalesce((select w.deleted_at is null and w.delete_requested_at is null and not w.admin_hidden and (w.claimed or w.claim_deadline > now())
                     from public.workers w where w.user_id = p_worker), false)
$$;

-- ---------- recruiter share ---------------------------------------------------------------------------------------------------------
create or replace function public.booking_recruiter(p_worker uuid)
returns uuid language plpgsql security definer set search_path = public as $$
declare w public.workers; v_until timestamptz;
begin
  select * into w from public.workers where user_id = p_worker for update;
  if not found then return null; end if;
  -- the agency's 40 % only while its plan is paid; otherwise the platform keeps it
  if w.agency_id is not null then return case when public.agency_active(w.agency_id) then w.agency_id end; end if;
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

-- ---------- an approved agency is a seller ------------------------------------------------------------------------------------------
create or replace function public.seller_free_via(p_user uuid)
returns text language sql stable security definer set search_path = public as $$
  select case when exists (select 1 from public.vendors v where v.owner_user_id = p_user and v.status = 'active') then 'vendor'
              when public.provider_alive(p_user) then 'provider'
              when exists (select 1 from public.agencies a where a.user_id = p_user and a.status = 'approved') then 'agency' end
$$;

create or replace function public.is_seller_at(p_user uuid, p_at timestamptz)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.vendors v where v.owner_user_id = p_user and v.status = 'active' and v.created_at <= p_at)
      or (public.provider_alive(p_user) and exists (select 1 from public.workers w where w.user_id = p_user and w.created_at <= p_at))
      or exists (select 1 from public.agencies a where a.user_id = p_user and a.status = 'approved' and coalesce(a.reviewed_at, a.created_at) <= p_at)
      or exists (select 1 from public.users u where u.id = p_user and u.seller_since <= p_at and u.seller_until >= p_at)
$$;
revoke all on function public.seller_free_via(uuid), public.is_seller_at(uuid, timestamptz) from public, anon, authenticated;

-- ---------- the customer directory ------------------------------------------------------------------------------------------------
-- agencies (strip / page): paid plans only. members: every listed girl of every approved agency (the badge stays on her photo).
-- badges: whether each approved agency shows its badge.
create or replace function public.agency_directory()
returns jsonb language sql stable security definer set search_path = public as $$
  with ap as (select a.*, public.agency_active(a.user_id) as paid,
                     exists (select 1 from public.agency_boosts b where b.agency_id = a.user_id and b.ends_at > now()) as boosted
                from public.agencies a where a.status = 'approved' and not public.is_suspended(a.user_id)),
       gs as (select w.user_id, w.agency_id, w.categories from public.workers w join ap on ap.user_id = w.agency_id where public.worker_listed(w.user_id)),
       cc as (select gs.agency_id, c, count(*)::int as n from gs, unnest(gs.categories) c group by 1, 2)
  select jsonb_build_object(
    'agencies', coalesce((select jsonb_agg(jsonb_build_object(
         'id', ap.user_id, 'name', ap.name, 'logo', ap.logo_path, 'intro', ap.intro, 'show_badge', ap.show_badge, 'show_count', ap.show_count,
         'boosted', ap.boosted,
         'girls', case when ap.show_count then (select coalesce(jsonb_object_agg(cc.c, cc.n), '{}'::jsonb) from cc where cc.agency_id = ap.user_id) end,
         'cats', (select coalesce(jsonb_agg(cc.c), '[]'::jsonb) from cc where cc.agency_id = ap.user_id))
         order by ap.boosted desc, md5(ap.user_id::text || (now() at time zone 'Asia/Bangkok')::date::text))
       from ap where ap.paid and exists (select 1 from gs where gs.agency_id = ap.user_id)), '[]'::jsonb),
    'members', coalesce((select jsonb_object_agg(gs.user_id, gs.agency_id) from gs), '{}'::jsonb),
    'badges', coalesce((select jsonb_object_agg(ap.user_id, ap.show_badge) from ap), '{}'::jsonb),
    'paid', coalesce((select jsonb_object_agg(ap.user_id, ap.paid) from ap), '{}'::jsonb))
$$;

revoke all on function public.draft_save(uuid, jsonb), public.draft_submit(uuid), public.draft_issue_link(uuid) from public, anon;
grant execute on function public.draft_save(uuid, jsonb), public.draft_submit(uuid), public.draft_issue_link(uuid) to authenticated;
