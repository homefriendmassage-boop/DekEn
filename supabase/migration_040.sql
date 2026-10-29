-- =============================================================================
-- migration_040.sql — run ONCE after migration_039.sql
-- Referral / seller rules and a few app changes:
--   * PACKAGE payments (20 %): the first inviter, for ever (a link clicked later never takes over; an inviter-less customer can
--     still adopt a link clicked in the last 24 h). The existing rule "bonus -> Wallet after bonus_sweep_days without renewing" is unchanged.
--   * BOOKING sales share (40 %): 1) the seller whose link the booking was made through, 2) else the customer's first inviter IF he is
--     a seller on the booking date, 3) else the platform. A seller = an approved seller (users.seller_since), a seller with his own OA
--     (vendors.owner_user_id) or any registered provider (workers) — from that date on.
--   * seller applications (admin approves), admin tool to correct a customer's inviter (with reason + history), seller earnings list.
--   * draft applications carry a temporary province (the girl confirms her place by GPS later).
-- =============================================================================

-- ---------- who counts as a seller, and from when -----------------------------------------------------
alter table public.users add column if not exists seller_since timestamptz;

create table if not exists public.seller_requests (
  user_id uuid primary key references public.users (id) on delete cascade,
  status text not null default 'pending' check (status in ('pending', 'approved', 'rejected')),
  note text, admin_note text,
  created_at timestamptz not null default now(), decided_at timestamptz, decided_by uuid references public.users (id)
);
alter table public.seller_requests enable row level security;
revoke all on public.seller_requests from anon, authenticated;

create or replace function public.seller_since_of(p_user uuid)
returns timestamptz language sql stable security definer set search_path = public as $$
  select least(
    (select u.seller_since from public.users u where u.id = p_user),
    (select min(v.created_at) from public.vendors v where v.owner_user_id = p_user and v.status = 'active'),
    (select w.created_at from public.workers w where w.user_id = p_user))
$$;
create or replace function public.is_seller_at(p_user uuid, p_at timestamptz)
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce(public.seller_since_of(p_user) <= p_at, false)
$$;
revoke all on function public.seller_since_of(uuid), public.is_seller_at(uuid, timestamptz) from public, anon, authenticated;

-- ---------- referral resolution ------------------------------------------------------------------------
create or replace function public.resolve_referrer(p_user uuid)
returns uuid language plpgsql security definer set search_path = public as $$
declare c public.referral_clicks;
begin
  select * into c from public.referral_clicks where user_id = p_user for update;
  if found then
    -- first touch wins: a link clicked later only counts for someone who has no inviter yet
    if c.clicked_at > now() - interval '24 hours' and c.referrer_id <> p_user then
      update public.users set referred_by = c.referrer_id where id = p_user and referred_by is null;
    end if;
    delete from public.referral_clicks where user_id = p_user;
  end if;
  return (select referred_by from public.users where id = p_user);
end $$;

create or replace function public.resolve_package_referrer(p_user uuid)
returns uuid language plpgsql security definer set search_path = public as $$
begin
  return coalesce(public.resolve_referrer(p_user),
                  (select v.owner_user_id from public.users u join public.vendors v on v.id = u.vendor_id where u.id = p_user));
end $$;

create or replace function public.resolve_sales(p_user uuid)
returns uuid language sql security definer set search_path = public as $$ select public.resolve_sales(p_user, null::text) $$;

create or replace function public.resolve_sales(p_user uuid, p_vendor text)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_owner uuid; v_ref uuid;
begin
  if p_vendor is not null then                                   -- booked through a seller's link
    select owner_user_id into v_owner from public.vendors where id = p_vendor;
    if v_owner is not null then return v_owner; end if;
  end if;
  v_ref := public.resolve_referrer(p_user);                        -- booked in our own app: his first inviter, if a seller today
  if v_ref is not null and public.is_seller_at(v_ref, now()) then return v_ref; end if;
  return null;                                                     -- the platform keeps it
end $$;
revoke all on function public.resolve_referrer(uuid), public.resolve_package_referrer(uuid), public.resolve_sales(uuid), public.resolve_sales(uuid, text) from public, anon, authenticated;

-- ---------- seller applications ----------------------------------------------------------------------------
create or replace function public.my_seller_status()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_since timestamptz; r public.seller_requests;
begin
  if auth.uid() is null then raise exception 'FORBIDDEN'; end if;
  v_since := public.seller_since_of(auth.uid());
  select * into r from public.seller_requests where user_id = auth.uid();
  return jsonb_build_object('is_seller', v_since is not null, 'since', v_since,
    'via', case when exists (select 1 from public.vendors v where v.owner_user_id = auth.uid() and v.status = 'active') then 'vendor'
                when exists (select 1 from public.workers w where w.user_id = auth.uid()) then 'provider'
                when (select seller_since from public.users where id = auth.uid()) is not null then 'approved' end,
    'request', case when r.user_id is null then null else jsonb_build_object('status', r.status, 'admin_note', r.admin_note, 'created_at', r.created_at) end);
end $$;

create or replace function public.seller_apply(p_note text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'FORBIDDEN'; end if;
  if public.is_suspended(auth.uid()) then raise exception 'SUSPENDED'; end if;
  if public.seller_since_of(auth.uid()) is not null then raise exception 'ALREADY_SELLER'; end if;
  insert into public.seller_requests (user_id, note) values (auth.uid(), left(nullif(btrim(coalesce(p_note, '')), ''), 300))
  on conflict (user_id) do update set status = 'pending', note = excluded.note, created_at = now(), decided_at = null, decided_by = null, admin_note = null
   where public.seller_requests.status = 'rejected';
end $$;

create or replace function public.admin_seller_requests(p_status text default 'pending')
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform public.assert_admin();
  return coalesce((select jsonb_agg(jsonb_build_object('user_id', r.user_id, 'name', u.display_name, 'status', r.status, 'note', r.note,
            'admin_note', r.admin_note, 'created_at', r.created_at, 'customers', (select count(*) from public.users c where c.referred_by = r.user_id)) order by r.created_at desc)
           from public.seller_requests r join public.users u on u.id = r.user_id where r.status = p_status), '[]'::jsonb);
end $$;

create or replace function public.admin_seller_decide(p_user uuid, p_approve boolean, p_note text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public.assert_admin();
  update public.seller_requests set status = case when p_approve then 'approved' else 'rejected' end, admin_note = left(p_note, 300),
         decided_at = now(), decided_by = auth.uid() where user_id = p_user and status = 'pending';
  if not found then raise exception 'NOT_FOUND'; end if;
  if p_approve then update public.users set seller_since = coalesce(seller_since, now()) where id = p_user; end if;
end $$;

create or replace function public.admin_seller_revoke(p_user uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public.assert_admin();
  update public.users set seller_since = null where id = p_user;
  update public.seller_requests set status = 'rejected', admin_note = 'ยกเลิกสถานะเซลล์', decided_at = now(), decided_by = auth.uid() where user_id = p_user;
end $$;

-- ---------- admin: correct a customer's inviter (always with a reason) ---------------------------------
create table if not exists public.referrer_changes (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.users (id) on delete cascade,
  old_referrer uuid, new_referrer uuid, reason text not null,
  changed_by uuid references public.users (id), created_at timestamptz not null default now()
);
alter table public.referrer_changes enable row level security;
revoke all on public.referrer_changes from anon, authenticated;

create or replace function public.admin_get_referrer(p_user uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_ref uuid;
begin
  perform public.assert_admin();
  select referred_by into v_ref from public.users where id = p_user;
  return jsonb_build_object(
    'referrer_id', v_ref, 'referrer_name', (select display_name from public.users where id = v_ref),
    'referrer_is_seller', case when v_ref is null then null else public.is_seller_at(v_ref, now()) end,
    'history', coalesce((select jsonb_agg(jsonb_build_object('at', c.created_at, 'reason', c.reason,
        'old', (select display_name from public.users where id = c.old_referrer), 'new', (select display_name from public.users where id = c.new_referrer),
        'by', (select display_name from public.users where id = c.changed_by)) order by c.created_at desc)
       from public.referrer_changes c where c.user_id = p_user), '[]'::jsonb));
end $$;

create or replace function public.admin_find_users(p_q text)
returns table (id uuid, display_name text, is_seller boolean) language plpgsql stable security definer set search_path = public as $$
begin
  perform public.assert_admin();
  return query select u.id, u.display_name, public.is_seller_at(u.id, now()) from public.users u
   where u.line_user_id !~ '^(anon|managed):' and btrim(coalesce(p_q, '')) <> '' and u.display_name ilike '%' || btrim(p_q) || '%'
   order by u.last_seen_at desc nulls last limit 15;
end $$;

create or replace function public.admin_set_referrer(p_user uuid, p_referrer uuid, p_reason text)
returns void language plpgsql security definer set search_path = public as $$
declare v_old uuid;
begin
  perform public.assert_admin();
  if char_length(btrim(coalesce(p_reason, ''))) < 3 then raise exception 'REASON_REQUIRED'; end if;
  if p_referrer = p_user then raise exception 'BAD_INPUT'; end if;
  select referred_by into v_old from public.users where id = p_user for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  update public.users set referred_by = p_referrer where id = p_user;
  insert into public.referrer_changes (user_id, old_referrer, new_referrer, reason, changed_by) values (p_user, v_old, p_referrer, left(btrim(p_reason), 300), auth.uid());
end $$;

-- ---------- what a seller / inviter earned ---------------------------------------------------------------------
create or replace function public.my_commission_report()
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'FORBIDDEN'; end if;
  return jsonb_build_object(
    'booking_total', coalesce((select sum(amount) from public.booking_shares where beneficiary = auth.uid() and role = 'sales'), 0),
    'package_total', coalesce((select sum(amount) from public.referral_rewards where beneficiary = auth.uid()), 0),
    'bookings', coalesce((select jsonb_agg(x order by x->>'at' desc) from (
        select jsonb_build_object('at', s.created_at, 'amount', s.amount, 'customer', c.display_name,
               'via', case when j.sales_vendor is not null then 'link' else 'invited' end) as x
          from public.booking_shares s join public.jobs j on j.id = s.job_id join public.users c on c.id = j.customer_id
         where s.beneficiary = auth.uid() and s.role = 'sales' order by s.created_at desc limit 100) q), '[]'::jsonb),
    'packages', coalesce((select jsonb_agg(x order by x->>'at' desc) from (
        select jsonb_build_object('at', r.created_at, 'amount', r.amount, 'customer', p.display_name) as x
          from public.referral_rewards r join public.users p on p.id = r.payer
         where r.beneficiary = auth.uid() order by r.created_at desc limit 100) q), '[]'::jsonb));
end $$;

-- ---------- drafts: temporary province ----------------------------------------------------------------------------
create or replace function public.draft_save(p_id uuid, p_data jsonb)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  r public.application_drafts; d public.application_drafts; v_id uuid;
  v_admin boolean := public.is_admin(); v_agency uuid;
begin
  if auth.uid() is null then raise exception 'FORBIDDEN'; end if;
  if not v_admin then
    select user_id into v_agency from public.agencies where user_id = auth.uid() and status = 'approved';
    if v_agency is null or not public.agency_active(v_agency) then raise exception 'PLAN_INACTIVE'; end if;
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

  select * into d from public.application_drafts where id = p_id and created_by = auth.uid() for update;
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

create or replace function public.sync_managed_profile(p_draft uuid)
returns void language plpgsql security definer set search_path = public as $$
declare d public.application_drafts;
begin
  select * into d from public.application_drafts where id = p_draft;
  if not found or d.managed_user_id is null then return; end if;
  update public.workers set display_name = d.display_name, categories = d.categories, gender = d.gender, age = d.age, height_cm = d.height_cm,
         weight_kg = d.weight_kg, measurements = d.measurements, tags = d.tags, about = d.about, price_options = d.price_options,
         start_rate = d.start_rate, service_mode = d.service_mode, province = coalesce(d.province, province), district = d.district, nearby = d.nearby,
         booking_phone = d.phone, booking_line_id = d.line_id
   where user_id = d.managed_user_id and not claimed;
  delete from public.profile_photos where user_id = d.managed_user_id and state = 'live';
  insert into public.profile_photos (user_id, state, sort_no, public_url, original_path)
    select d.managed_user_id, 'live', p.sort_no, p.public_url, p.original_path from public.draft_photos p where p.draft_id = p_draft order by p.sort_no;
  update public.workers w set profile_image = (select p.public_url from public.draft_photos p where p.draft_id = p_draft order by p.sort_no limit 1),
         original_path = (select p.original_path from public.draft_photos p where p.draft_id = p_draft order by p.sort_no limit 1)
   where w.user_id = d.managed_user_id;
end $$;

revoke all on function public.my_seller_status(), public.seller_apply(text), public.admin_seller_requests(text), public.admin_seller_decide(uuid, boolean, text),
  public.admin_seller_revoke(uuid), public.admin_get_referrer(uuid), public.admin_find_users(text), public.admin_set_referrer(uuid, uuid, text), public.my_commission_report(),
  public.draft_save(uuid, jsonb), public.sync_managed_profile(uuid) from public, anon;
grant execute on function public.my_seller_status(), public.seller_apply(text), public.admin_seller_requests(text), public.admin_seller_decide(uuid, boolean, text),
  public.admin_seller_revoke(uuid), public.admin_get_referrer(uuid), public.admin_find_users(text), public.admin_set_referrer(uuid, uuid, text), public.my_commission_report(),
  public.draft_save(uuid, jsonb) to authenticated;
revoke all on function public.sync_managed_profile(uuid) from authenticated;
