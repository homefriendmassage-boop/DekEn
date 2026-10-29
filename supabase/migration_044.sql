-- =============================================================================
-- migration_044.sql — run ONCE after migration_043.sql
-- Sellers pay: 500 THB per 30 days from the Wallet, active at once (no admin approval) — like a modelling agency's plan, but a plain
-- seller cannot add girls: he only shares links and earns the 40 % booking share (and the 20 % package share, which never needed a plan).
--   * users.seller_since / seller_until; providers and sellers with their own OA are sellers without paying (unchanged)
--   * buy_seller_plan(): pays from the Wallet, extends 30 days, and sends the "you are a seller" Flex (notify-chat, type 'seller')
--   * admin: grant free days / revoke on the member page
--   * the approval flow of migration_040 (seller_apply and friends) is removed
-- =============================================================================

alter table public.users add column if not exists seller_until timestamptz;

drop function if exists public.seller_apply(text);
drop function if exists public.admin_seller_requests(text);
drop function if exists public.admin_seller_decide(uuid, boolean, text);

create or replace function public.seller_plan_price() returns numeric language sql immutable as $$ select 500::numeric $$;
create or replace function public.seller_plan_days()  returns int     language sql immutable as $$ select 30 $$;

-- a seller without paying: a provider, or the owner of a seller OA
create or replace function public.seller_free_via(p_user uuid)
returns text language sql stable security definer set search_path = public as $$
  select case when exists (select 1 from public.vendors v where v.owner_user_id = p_user and v.status = 'active') then 'vendor'
              when exists (select 1 from public.workers w where w.user_id = p_user) then 'provider' end
$$;

create or replace function public.is_seller_at(p_user uuid, p_at timestamptz)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.vendors v where v.owner_user_id = p_user and v.status = 'active' and v.created_at <= p_at)
      or exists (select 1 from public.workers w where w.user_id = p_user and w.created_at <= p_at)
      or exists (select 1 from public.users u where u.id = p_user and u.seller_since <= p_at and u.seller_until >= p_at)
$$;
drop function if exists public.seller_since_of(uuid);
revoke all on function public.seller_free_via(uuid), public.is_seller_at(uuid, timestamptz) from public, anon, authenticated;

create or replace function public.my_seller_status()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare u public.users; v_via text;
begin
  if auth.uid() is null then raise exception 'FORBIDDEN'; end if;
  select * into u from public.users where id = auth.uid();
  v_via := public.seller_free_via(auth.uid());
  return jsonb_build_object('is_seller', v_via is not null or coalesce(u.seller_until > now(), false),
    'via', coalesce(v_via, case when u.seller_until > now() then 'paid' end), 'until', u.seller_until,
    'expired', v_via is null and u.seller_until is not null and u.seller_until <= now(),
    'price', public.seller_plan_price(), 'days', public.seller_plan_days(), 'wallet', u.wallet_balance);
end $$;

create or replace function public.seller_notify(p_user uuid, p_event text)
returns void language plpgsql security definer set search_path = public as $$
declare v_url text; v_secret text;
begin
  select value into v_url from public.private_config where key = 'chat_notify_url';
  select value into v_secret from public.private_config where key = 'chat_notify_secret';
  if v_url is null or v_secret is null then return; end if;
  execute format('select net.http_post(url := %L, headers := %L::jsonb, body := %L::jsonb)', v_url,
    jsonb_build_object('Content-Type', 'application/json', 'x-webhook-secret', v_secret)::text,
    jsonb_build_object('type', 'seller', 'event', p_event, 'user_id', p_user)::text);
exception when others then
  return;
end $$;

create or replace function public.buy_seller_plan()
returns timestamptz language plpgsql security definer set search_path = public as $$
declare u public.users; v_price numeric := public.seller_plan_price(); v_exp timestamptz; v_was_active boolean;
begin
  if auth.uid() is null then raise exception 'FORBIDDEN'; end if;
  if public.is_suspended(auth.uid()) then raise exception 'SUSPENDED'; end if;
  if public.seller_free_via(auth.uid()) is not null then raise exception 'ALREADY_SELLER'; end if;
  select * into u from public.users where id = auth.uid() for update;
  if u.wallet_balance < v_price then raise exception 'INSUFFICIENT_BALANCE'; end if;
  v_was_active := coalesce(u.seller_until > now(), false);
  v_exp := greatest(now(), coalesce(u.seller_until, now())) + make_interval(days => public.seller_plan_days());
  perform set_config('app.ledger_kind', 'seller_plan', true);
  perform set_config('app.ledger_ref', u.id::text, true);
  update public.users set wallet_balance = wallet_balance - v_price, seller_since = coalesce(seller_since, now()), seller_until = v_exp where id = u.id;
  perform public.seller_notify(u.id, case when v_was_active then 'renewed' else 'activated' end);
  return v_exp;
end $$;

-- admin: free days / revoke
create or replace function public.admin_seller_grant(p_user uuid, p_days int)
returns timestamptz language plpgsql security definer set search_path = public as $$
declare v_exp timestamptz; v_was boolean;
begin
  perform public.assert_admin();
  if p_days is null or p_days not between 1 and 365 then raise exception 'BAD_INPUT'; end if;
  select coalesce(seller_until > now(), false) into v_was from public.users where id = p_user;
  if not found then raise exception 'NOT_FOUND'; end if;
  update public.users set seller_since = coalesce(seller_since, now()),
         seller_until = greatest(now(), coalesce(seller_until, now())) + make_interval(days => p_days)
   where id = p_user returning seller_until into v_exp;
  perform public.seller_notify(p_user, case when v_was then 'renewed' else 'activated' end);
  return v_exp;
end $$;

create or replace function public.admin_seller_revoke(p_user uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public.assert_admin();
  update public.users set seller_until = null, seller_since = null where id = p_user;
end $$;

create or replace function public.admin_get_seller(p_user uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare u public.users;
begin
  perform public.assert_admin();
  select * into u from public.users where id = p_user;
  return jsonb_build_object('via', public.seller_free_via(p_user), 'until', u.seller_until, 'active', coalesce(u.seller_until > now(), false));
end $$;

revoke all on function public.my_seller_status(), public.seller_notify(uuid, text), public.buy_seller_plan(), public.admin_seller_grant(uuid, int),
  public.admin_seller_revoke(uuid), public.admin_get_seller(uuid), public.seller_plan_price(), public.seller_plan_days() from public, anon;
grant execute on function public.my_seller_status(), public.buy_seller_plan(), public.admin_seller_grant(uuid, int), public.admin_seller_revoke(uuid), public.admin_get_seller(uuid) to authenticated;
revoke all on function public.seller_notify(uuid, text), public.seller_plan_price(), public.seller_plan_days() from authenticated;
