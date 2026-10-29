-- =============================================================================
-- migration_039.sql — run ONCE after migration_038.sql
-- One LINE Provider for every seller OA => one LINE id per person everywhere => ONE account / Wallet per customer.
--   * accounts: users.line_user_id = the plain LINE id (no '<seller>:' prefix). users.vendor_id = the seller the customer
--     FIRST arrived through ("home seller"); it is never changed afterwards. Top-ups always go to the platform's own account.
--   * PACKAGE payments (20 %): the person who invited the customer the FIRST time (users.referred_by), else the home seller.
--   * BOOKING fee split: the "sales" part goes to the seller whose link the customer booked through (jobs.sales_vendor,
--     set by create_booking), else the customer's 24 h referrer, else the home seller; the recruiter / platform parts are unchanged.
--   * a seller's staff can be any account (not only accounts created through his LIFF).
-- =============================================================================

alter table public.jobs add column if not exists sales_vendor text references public.vendors (id);

-- ---------- existing seller accounts: drop the '<seller>:' prefix --------------------------------------
do $$
declare u record; v_sub text; v_twin uuid;
begin
  for u in select id, line_user_id from public.users where line_user_id like '%:%' and line_user_id !~ '^(anon|managed):' and vendor_id is not null loop
    v_sub := split_part(u.line_user_id, ':', 2);
    select id into v_twin from public.users where line_user_id = v_sub;
    if v_twin is null then
      update auth.users set email = v_sub || '@line.invalid',
             raw_user_meta_data = coalesce(raw_user_meta_data, '{}'::jsonb) || jsonb_build_object('line_user_id', v_sub) where id = u.id;
      update public.users set line_user_id = v_sub where id = u.id;
    else
      -- the same person already has a central account: keep that one (staff rows move over), drop the empty duplicate
      begin
        update public.vendor_staff set user_id = v_twin where user_id = u.id and not exists (
          select 1 from public.vendor_staff x where x.vendor_id = vendor_staff.vendor_id and x.user_id = v_twin);
        delete from public.vendor_staff where user_id = u.id;
        delete from auth.users where id = u.id;
        raise notice 'merged duplicate seller account % into %', u.id, v_twin;
      exception when others then
        raise notice 'could not merge seller account % (has data?): %', u.id, sqlerrm;
      end;
    end if;
  end loop;
end $$;

-- ---------- sales / referral rules -----------------------------------------------------------------------
create or replace function public.resolve_sales(p_user uuid)
returns uuid language sql security definer set search_path = public as $$
  select public.resolve_referrer(p_user)
$$;

create or replace function public.resolve_sales(p_user uuid, p_vendor text)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_owner uuid; v_ref uuid;
begin
  -- the seller whose link was used for this booking
  if p_vendor is not null then
    select owner_user_id into v_owner from public.vendors where id = p_vendor;
    if v_owner is not null then return v_owner; end if;
  end if;
  -- booked in our own app: the person whose link he used within 24 h, else the seller he first came from
  v_ref := public.resolve_referrer(p_user);
  if v_ref is not null then return v_ref; end if;
  return (select v.owner_user_id from public.users u join public.vendors v on v.id = u.vendor_id where u.id = p_user);
end $$;

-- package payments: whoever invited him the first time, else the seller he first came from (later links do not take over)
create or replace function public.resolve_package_referrer(p_user uuid)
returns uuid language sql security definer set search_path = public as $$
  select coalesce(u.referred_by, (select v.owner_user_id from public.vendors v where v.id = u.vendor_id))
    from public.users u where u.id = p_user
$$;

revoke all on function public.resolve_sales(uuid), public.resolve_sales(uuid, text), public.resolve_package_referrer(uuid) from public, anon, authenticated;

-- ---------- booking remembers the seller link it was made through ----------------------------------------
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

drop function if exists public.create_booking(uuid, text, timestamptz, text, text, text, double precision, double precision, text);
create or replace function public.create_booking(p_worker uuid, p_rate text, p_scheduled timestamptz, p_place_note text default null,
                                                 p_note text default null, p_phone text default null,
                                                 p_lat double precision default null, p_lng double precision default null, p_url text default null,
                                                 p_vendor text default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_id uuid := gen_random_uuid(); v_digits text; v_url text := nullif(btrim(coalesce(p_url, '')), ''); v_note text := nullif(btrim(coalesce(p_place_note, '')), ''); v_vendor text;
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
  -- the seller whose link the customer is booking through (null = our own app); only an active seller counts
  select id into v_vendor from public.vendors where id = p_vendor and status = 'active';
  insert into public.jobs (id, customer_id, worker_id, booking_fee, rate_label, scheduled_at, place_note, customer_note, sales_vendor)
  values (v_id, auth.uid(), p_worker, 0, nullif(btrim(coalesce(p_rate, '')), ''), p_scheduled, left(v_note, 200), left(nullif(btrim(coalesce(p_note, '')), ''), 300), v_vendor);
  insert into public.job_private (job_id, customer_phone, place_lat, place_lng, place_url)
  values (v_id, v_digits, case when p_lat is not null and p_lng is not null then p_lat end, case when p_lat is not null and p_lng is not null then p_lng end, v_url);
  return v_id;
end $$;
revoke all on function public.pay_booking_shares(uuid) from public, anon, authenticated;
grant execute on function public.create_booking(uuid, text, timestamptz, text, text, text, double precision, double precision, text, text) to authenticated;

-- ---------- seller staff: any account may be added ---------------------------------------------------
create or replace function public.line_id_of(p_line_user_id text)
returns text language sql immutable as $$ select case when position(':' in p_line_user_id) > 0 then split_part(p_line_user_id, ':', 2) else p_line_user_id end $$;

create or replace function public.admin_vendor_staff_list(p_vendor text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform public.assert_admin();
  return coalesce((select jsonb_agg(jsonb_build_object('user_id', u.id, 'name', u.display_name,
           'line_id', public.line_id_of(u.line_user_id), 'push_ready', public.line_id_of(u.line_user_id) ~ '^U[0-9a-f]{32}$') order by s.created_at)
      from public.vendor_staff s join public.users u on u.id = s.user_id where s.vendor_id = p_vendor), '[]'::jsonb);
end $$;

create or replace function public.admin_search_vendor_users(p_vendor text, p_q text)
returns table (id uuid, display_name text, line_id text)
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.assert_admin();
  return query select u.id, u.display_name, public.line_id_of(u.line_user_id)
    from public.users u where u.line_user_id !~ '^(anon|managed):' and btrim(coalesce(p_q, '')) <> '' and u.display_name ilike '%' || btrim(p_q) || '%'
    order by u.last_seen_at desc nulls last limit 20;
end $$;

create or replace function public.admin_vendor_staff_add(p_vendor text, p_user uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public.assert_admin();
  if not exists (select 1 from public.users where id = p_user) then raise exception 'NO_USER'; end if;
  insert into public.vendor_staff (vendor_id, user_id) values (p_vendor, p_user) on conflict do nothing;
end $$;

create or replace function public.vendor_staff_line_ids(p_vendor text)
returns text[] language sql stable security definer set search_path = public as $$
  select coalesce(array_agg(public.line_id_of(u.line_user_id)), '{}')
    from public.vendor_staff s join public.users u on u.id = s.user_id where s.vendor_id = p_vendor
$$;

revoke all on function public.admin_vendor_staff_list(text), public.admin_search_vendor_users(text, text), public.admin_vendor_staff_add(text, uuid), public.vendor_staff_line_ids(text) from public, anon;
grant execute on function public.admin_vendor_staff_list(text), public.admin_search_vendor_users(text, text), public.admin_vendor_staff_add(text, uuid) to authenticated;
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    grant execute on function public.vendor_staff_line_ids(text) to service_role;
  end if;
end $$;
