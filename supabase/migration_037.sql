-- =============================================================================
-- migration_037.sql — run ONCE after migration_036.sql
-- Sellers with their own LINE OA ("vendors"), phase 1 (customers):
--   * a vendor = one seller: his own LINE Provider holding his OA (Messaging API) and a LIFF app whose endpoint is our app
--     with ?vendor=<id>. We store the LIFF ID (public) and the OA's channel access token (in Supabase Vault, never in the browser).
--   * customers who open the vendor's LIFF link get an account scoped to that vendor (users.vendor_id, line_user_id
--     '<vendor>:<LINE id>'): their own Wallet and membership. Providers stay in the central account.
--   * every booking / membership of a vendor customer pays the sales share to the vendor's owner (resolve_sales).
--   * pushes to a vendor customer are sent by the vendor's OA (the Edge Functions read the token with vendor_token()).
--   * jobs.source_label = "customer from <seller>", shown to the provider in the booking Flex and in her inbox.
-- =============================================================================

do $$ begin
  create extension if not exists supabase_vault;
exception when others then
  raise notice 'Supabase Vault could not be enabled (%): enable it under Database > Extensions, then run this file again', sqlerrm;
end $$;

create table if not exists public.vendors (
  id text primary key default lower(substr(md5(random()::text || clock_timestamp()::text), 1, 8)),
  name text not null check (char_length(btrim(name)) between 2 and 60),
  owner_user_id uuid references public.users (id),
  liff_id text not null unique check (liff_id ~ '^[0-9]+-[A-Za-z0-9]+$'),
  status text not null default 'active' check (status in ('active', 'disabled')),
  token_secret_id uuid,                       -- the channel access token lives in Vault
  oa_basic_id text, oa_name text, add_friend_url text,
  created_at timestamptz not null default now()
);
alter table public.vendors enable row level security;
revoke all on public.vendors from anon, authenticated;

alter table public.users add column if not exists vendor_id text references public.vendors (id);
alter table public.users add column if not exists seller_label text;
create index if not exists users_vendor_idx on public.users (vendor_id) where vendor_id is not null;
alter table public.jobs add column if not exists source_label text;

-- ---------- public lookups (needed before login) ------------------------------------------------
create or replace function public.vendor_public(p_vendor text)
returns table (id text, name text, liff_id text, add_friend_url text)
language sql stable security definer set search_path = public as $$
  select v.id, v.name, v.liff_id, v.add_friend_url from public.vendors v where v.id = p_vendor and v.status = 'active'
$$;
create or replace function public.vendor_by_channel(p_channel text)
returns table (id text, name text, liff_id text, add_friend_url text)
language sql stable security definer set search_path = public as $$
  select v.id, v.name, v.liff_id, v.add_friend_url from public.vendors v where split_part(v.liff_id, '-', 1) = p_channel and v.status = 'active'
$$;
revoke all on function public.vendor_public(text), public.vendor_by_channel(text) from public;
grant execute on function public.vendor_public(text), public.vendor_by_channel(text) to anon, authenticated;

-- ---------- admin ----------------------------------------------------------------------------------
create or replace function public.admin_vendor_save(p_id text, p_name text, p_owner uuid, p_liff_id text, p_token text default null)
returns text language plpgsql security definer set search_path = public as $$
declare v public.vendors; v_id text := nullif(btrim(coalesce(p_id, '')), ''); v_sec uuid;
begin
  perform public.assert_admin();
  if p_owner is null or not exists (select 1 from public.users where id = p_owner) then raise exception 'OWNER_REQUIRED'; end if;
  if v_id is null then
    insert into public.vendors (name, owner_user_id, liff_id) values (btrim(p_name), p_owner, btrim(p_liff_id)) returning id into v_id;
  else
    select * into v from public.vendors where id = v_id for update;
    if not found then raise exception 'NOT_FOUND'; end if;
    update public.vendors set name = btrim(p_name), owner_user_id = p_owner, liff_id = btrim(p_liff_id) where id = v_id;
  end if;
  if nullif(btrim(coalesce(p_token, '')), '') is not null then
    select token_secret_id into v_sec from public.vendors where id = v_id;
    if v_sec is null then
      v_sec := vault.create_secret(btrim(p_token), 'vendor_token_' || v_id, 'LINE channel access token of vendor ' || v_id);
      update public.vendors set token_secret_id = v_sec where id = v_id;
    else
      perform vault.update_secret(v_sec, btrim(p_token));
    end if;
  end if;
  return v_id;
end $$;

create or replace function public.admin_vendor_list()
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform public.assert_admin();
  return coalesce((select jsonb_agg(jsonb_build_object(
      'id', v.id, 'name', v.name, 'owner_id', v.owner_user_id, 'owner_name', (select u.display_name from public.users u where u.id = v.owner_user_id),
      'liff_id', v.liff_id, 'status', v.status, 'has_token', v.token_secret_id is not null, 'oa_basic_id', v.oa_basic_id, 'oa_name', v.oa_name,
      'add_friend_url', v.add_friend_url, 'customers', (select count(*) from public.users c where c.vendor_id = v.id), 'created_at', v.created_at)
    order by v.created_at desc) from public.vendors v), '[]'::jsonb);
end $$;

create or replace function public.admin_vendor_set_status(p_id text, p_status text)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public.assert_admin();
  if p_status not in ('active', 'disabled') then raise exception 'BAD_INPUT'; end if;
  update public.vendors set status = p_status where id = p_id;
  if not found then raise exception 'NOT_FOUND'; end if;
end $$;

create or replace function public.admin_set_seller_label(p_user uuid, p_label text)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public.assert_admin();
  update public.users set seller_label = left(nullif(btrim(coalesce(p_label, '')), ''), 40) where id = p_user;
end $$;

create or replace function public.admin_get_seller_label(p_user uuid)
returns text language plpgsql stable security definer set search_path = public as $$
begin
  perform public.assert_admin();
  return (select u.seller_label from public.users u where u.id = p_user);
end $$;

-- server side only (Edge Functions with the service role): the token and the OA details found by the connection test
create or replace function public.vendor_token(p_vendor text)
returns text language sql stable security definer set search_path = public as $$
  select (select d.decrypted_secret from vault.decrypted_secrets d where d.id = v.token_secret_id)
    from public.vendors v where v.id = p_vendor and v.status = 'active'
$$;
create or replace function public.vendor_set_oa_info(p_id text, p_basic_id text, p_name text)
returns void language sql security definer set search_path = public as $$
  update public.vendors set oa_basic_id = p_basic_id, oa_name = p_name,
         add_friend_url = case when p_basic_id is not null then 'https://line.me/R/ti/p/' || p_basic_id end where id = p_id
$$;

revoke all on function public.admin_vendor_save(text, text, uuid, text, text), public.admin_vendor_list(), public.admin_vendor_set_status(text, text),
  public.admin_set_seller_label(uuid, text), public.admin_get_seller_label(uuid), public.vendor_token(text), public.vendor_set_oa_info(text, text, text) from public, anon, authenticated;
grant execute on function public.admin_vendor_save(text, text, uuid, text, text), public.admin_vendor_list(), public.admin_vendor_set_status(text, text),
  public.admin_set_seller_label(uuid, text), public.admin_get_seller_label(uuid) to authenticated;
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    grant execute on function public.vendor_token(text), public.vendor_set_oa_info(text, text, text) to service_role;
  end if;
end $$;

-- ---------- sales: a vendor's customers belong to the vendor's owner -----------------------------------
create or replace function public.resolve_sales(p_user uuid)
returns uuid language plpgsql security definer set search_path = public as $$
declare c public.referral_clicks; v_owner uuid;
begin
  -- a customer of a seller's own OA always belongs to that seller (no 24-hour takeover)
  select v.owner_user_id into v_owner from public.users u join public.vendors v on v.id = u.vendor_id where u.id = p_user;
  if v_owner is not null then return v_owner; end if;
  select * into c from public.referral_clicks where user_id = p_user for update;
  if found then
    if c.clicked_at > now() - interval '24 hours' and c.referrer_id <> p_user then
      update public.users set referred_by = c.referrer_id where id = p_user;
    end if;
    delete from public.referral_clicks where user_id = p_user;
  end if;
  return (select referred_by from public.users where id = p_user);
end $$;

create or replace function public.register_referral_click(p_code text)
returns boolean language plpgsql security definer set search_path = public as $$
declare
  v_ref uuid;
  me    public.users;
begin
  if auth.uid() is null then raise exception 'FORBIDDEN'; end if;
  select id into v_ref from public.users where partner_ref_code = p_code;
  if v_ref is null or v_ref = auth.uid() then return false; end if;
  select * into me from public.users where id = auth.uid();
  if me.vendor_id is not null then return false; end if;      -- vendor customers belong to their vendor

  -- First registration through a link: that person is the sales immediately.
  if me.referred_by is null and me.created_at > now() - interval '30 minutes' then
    update public.users set referred_by = v_ref where id = me.id;
    return true;
  end if;
  if me.referred_by = v_ref then
    delete from public.referral_clicks where user_id = me.id;   -- already the sales; nothing to take over
    return true;
  end if;
  insert into public.referral_clicks (user_id, referrer_id, clicked_at) values (me.id, v_ref, now())
  on conflict (user_id) do update set referrer_id = excluded.referrer_id, clicked_at = excluded.clicked_at;
  return true;
end $$;

-- ---------- bookings remember where the customer came from --------------------------------------------
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
  select coalesce(v.name, nullif(btrim(s.seller_label), ''), s.display_name) into new.source_label
    from public.users c left join public.vendors v on v.id = c.vendor_id left join public.users s on s.id = c.referred_by
   where c.id = new.customer_id;

  new.booking_fee   := v_fee;
  new.service_price := v_price;
  new.status        := 'pending';
  return new;
end $$;

create or replace function public.job_json(j public.jobs, p_for_worker boolean)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
      'id', j.id, 'status', j.status, 'created_at', j.created_at, 'scheduled_at', j.scheduled_at, 'rate_label', j.rate_label,
      'service_price', j.service_price, 'booking_fee', j.booking_fee, 'place_note', j.place_note, 'customer_note', j.customer_note,
      'accepted_at', j.accepted_at, 'arrived_at', j.arrived_at, 'cancel_reason', j.cancel_reason, 'source_label', j.source_label,
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
-- =============================================================================
