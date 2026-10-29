-- =============================================================================
-- migration_038.sql — run ONCE after migration_037.sql
-- 1) Referral share for a seller's customers, as the platform intended:
--      * PACKAGE payments (20 %): the friend who invited the customer (another customer of the same seller) — else the seller
--      * BOOKING fee split 40 / 40 / 20: the "sales" part always goes to the seller; the recruiter part is unchanged
--    (resolve_referrer = the original 24-hour rule, resolve_sales / resolve_package_referrer sit on top of it)
-- 2) Seller staff ("admins of the seller"): vendor_staff. A seller's customers chat with HIS team, not with the central admins:
--      * support_threads.vendor_id; the central admin inbox / stats / members list only show central customers
--        (a selector shows one seller's customers when needed)
--      * a seller's staff read and answer the threads of his customers (in the seller's own LIFF app)
--      * Flex pushes through the seller's OA: new customer message -> his staff; staff reply -> the customer
--        (at most one per thread per 10 minutes), via the Edge Function notify-chat
-- =============================================================================

create or replace function public.resolve_referrer(p_user uuid)
returns uuid language plpgsql security definer set search_path = public as $$
declare c public.referral_clicks;
begin
  select * into c from public.referral_clicks where user_id = p_user for update;
  if found then
    if c.clicked_at > now() - interval '24 hours' and c.referrer_id <> p_user then
      update public.users set referred_by = c.referrer_id where id = p_user;
    end if;
    delete from public.referral_clicks where user_id = p_user;
  end if;
  return (select referred_by from public.users where id = p_user);
end $$;

create or replace function public.resolve_sales(p_user uuid)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_owner uuid;
begin
  -- a customer of a seller's own OA: the booking "sales" share always goes to that seller
  select v.owner_user_id into v_owner from public.users u join public.vendors v on v.id = u.vendor_id where u.id = p_user;
  if v_owner is not null then return v_owner; end if;
  return public.resolve_referrer(p_user);
end $$;

create or replace function public.resolve_package_referrer(p_user uuid)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_owner uuid; v_vendor text; v_ref uuid; v_ref_vendor text;
begin
  select u.vendor_id, v.owner_user_id into v_vendor, v_owner from public.users u left join public.vendors v on v.id = u.vendor_id where u.id = p_user;
  v_ref := public.resolve_referrer(p_user);
  if v_vendor is null then return v_ref; end if;
  -- a seller's customer: the friend who invited him (another customer of the same seller) gets the package share, else the seller
  select r.vendor_id into v_ref_vendor from public.users r where r.id = v_ref;
  if v_ref is not null and (v_ref_vendor = v_vendor or v_ref = v_owner) then return v_ref; end if;
  return v_owner;
end $$;

create or replace function public.payments_referral()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_sales uuid;
  v_amt   numeric;
  v_id    uuid;
begin
  v_sales := public.resolve_package_referrer(new.user_id);
  if v_sales is null or v_sales = new.user_id or public.is_suspended(v_sales) then return new; end if;
  v_amt := round(new.amount * public.referral_membership_rate(), 2);
  if v_amt <= 0 then return new; end if;

  insert into public.referral_rewards (beneficiary, payer, source_type, source_id, base_amount, amount)
  values (v_sales, new.user_id, 'membership_payment', new.id, new.amount, v_amt)
  on conflict (source_type, source_id) do nothing
  returning id into v_id;
  if v_id is null then return new; end if;

  perform set_config('app.ledger_kind', 'referral_membership', true);
  perform set_config('app.ledger_ref', new.id::text, true);
  update public.users set bonus_balance = bonus_balance + v_amt where id = v_sales;
  return new;
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
  -- a seller's customer can only be invited by another customer of the same seller (or by the seller himself)
  if me.vendor_id is not null and not exists (
       select 1 from public.users r left join public.vendors v on v.id = me.vendor_id
        where r.id = v_ref and (r.vendor_id = me.vendor_id or v.owner_user_id = r.id)) then
    return false;
  end if;

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

-- ---------- seller staff ------------------------------------------------------------------------
create table if not exists public.vendor_staff (
  vendor_id text not null references public.vendors (id) on delete cascade,
  user_id uuid not null references public.users (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (vendor_id, user_id)
);
alter table public.vendor_staff enable row level security;
revoke all on public.vendor_staff from anon, authenticated;

alter table public.support_threads add column if not exists vendor_id text references public.vendors (id);
update public.support_threads t set vendor_id = u.vendor_id from public.users u where u.id = t.user_id and t.vendor_id is distinct from u.vendor_id;
create or replace function public.support_threads_vendor()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  select u.vendor_id into new.vendor_id from public.users u where u.id = new.user_id;
  return new;
end $$;
drop trigger if exists support_threads_vendor on public.support_threads;
create trigger support_threads_vendor before insert on public.support_threads for each row execute function public.support_threads_vendor();

-- am I a staff member of this seller (null = of any seller)?
create or replace function public.is_vendor_staff(p_vendor text default null)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.vendor_staff s join public.vendors v on v.id = s.vendor_id
                  where s.user_id = auth.uid() and v.status = 'active' and (p_vendor is null or s.vendor_id = p_vendor))
$$;
create or replace function public.my_vendor_staff()
returns text language sql stable security definer set search_path = public as $$
  select s.vendor_id from public.vendor_staff s join public.vendors v on v.id = s.vendor_id where s.user_id = auth.uid() and v.status = 'active' limit 1
$$;

-- who may read / answer a thread: its owner, a central admin, or the staff of the seller the customer belongs to
create or replace function public.support_can_staff(p_vendor text)
returns boolean language sql stable security definer set search_path = public as $$
  select public.is_admin() or (p_vendor is not null and public.is_vendor_staff(p_vendor))
$$;

drop policy if exists support_threads_select on public.support_threads;
create policy support_threads_select on public.support_threads
  for select to authenticated using (user_id = auth.uid() or public.support_can_staff(vendor_id));
drop policy if exists support_messages_select on public.support_messages;
create policy support_messages_select on public.support_messages
  for select to authenticated using (exists (
    select 1 from public.support_threads t where t.id = thread_id and (t.user_id = auth.uid() or public.support_can_staff(t.vendor_id))));

create or replace function public.support_send(p_thread uuid, p_body text)
returns void language plpgsql security definer set search_path = public as $$
declare
  t   public.support_threads;
  adm boolean;
  b   text := btrim(p_body);
begin
  select * into t from public.support_threads where id = p_thread;
  if not found then raise exception 'FORBIDDEN'; end if;
  adm := t.user_id <> auth.uid() and public.support_can_staff(t.vendor_id);
  if t.user_id <> auth.uid() and not adm then raise exception 'FORBIDDEN'; end if;
  if b is null or char_length(b) not between 1 and (case when adm then 1000 else 500 end) then raise exception 'BAD_MESSAGE'; end if;
  if not adm and (select count(*) from public.support_messages where sender_id = auth.uid() and created_at > now() - interval '1 minute') >= 10 then
    raise exception 'RATE_LIMIT';
  end if;
  insert into public.support_messages (thread_id, sender_id, from_admin, body) values (p_thread, auth.uid(), adm, b);
  update public.support_threads
     set last_message_at = now(),
         user_last_read  = case when not adm then now() else user_last_read end,
         admin_last_read = case when adm then now() else admin_last_read end
   where id = p_thread;
end $$;

create or replace function public.support_mark_read(p_thread uuid)
returns void language sql security definer set search_path = public as $$
  update public.support_threads
     set user_last_read  = case when user_id = auth.uid() then now() else user_last_read end,
         admin_last_read = case when user_id <> auth.uid() and public.support_can_staff(vendor_id) then now() else admin_last_read end
   where id = p_thread and (user_id = auth.uid() or public.support_can_staff(vendor_id));
$$;

-- inbox: p_vendor null = the central customers (central admins only); a seller id = that seller's customers (his staff or a central admin)
drop function if exists public.admin_support_threads();
create or replace function public.support_threads_for(p_vendor text default null)
returns table (thread_id uuid, user_id uuid, user_name text, picture_url text,
               last_body text, last_message_at timestamptz, unread int)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.support_can_staff(p_vendor) then raise exception 'FORBIDDEN'; end if;
  return query
    select t.id, t.user_id, u.display_name, u.picture_url,
           (select m.body from public.support_messages m where m.thread_id = t.id order by m.created_at desc limit 1),
           t.last_message_at,
           (select count(*)::int from public.support_messages m where m.thread_id = t.id and not m.from_admin and m.created_at > t.admin_last_read)
      from public.support_threads t join public.users u on u.id = t.user_id
     where t.last_message_at is not null and t.vendor_id is not distinct from p_vendor
     order by t.last_message_at desc
     limit 100;
end $$;
create or replace function public.admin_support_threads()
returns table (thread_id uuid, user_id uuid, user_name text, picture_url text, last_body text, last_message_at timestamptz, unread int)
language sql stable security definer set search_path = public as $$
  select * from public.support_threads_for(null)
$$;

create or replace function public.admin_stats()
returns table (pending_apps int, gold int, platinum int, diamond int, expiring_7d int,
               membership_month numeric, topup_month numeric, pending_reviews int, support_unread int)
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.assert_admin();
  return query select
    (select count(*)::int from public.worker_applications where status = 'pending'),
    (select count(*)::int from public.users where vip_tier = 1 and vip_expires_at > now()),
    (select count(*)::int from public.users where vip_tier = 2 and vip_expires_at > now()),
    (select count(*)::int from public.users where vip_tier = 3 and vip_expires_at > now()),
    (select count(*)::int from public.users where vip_tier > 0 and vip_expires_at > now()
        and vip_expires_at < now() + interval '7 days'),
    coalesce((select sum(amount) from public.payments where kind = 'membership'
               and created_at >= date_trunc('month', now())), 0),
    coalesce((select sum(amount) from public.payments where kind = 'wallet_topup'
               and created_at >= date_trunc('month', now())), 0),
    (select count(*)::int from public.payment_reviews where status = 'pending'),
    (select count(*)::int from public.support_threads t
      where t.vendor_id is null and exists (select 1 from public.support_messages m
                     where m.thread_id = t.id and not m.from_admin and m.created_at > t.admin_last_read));
end $$;

create or replace function public.admin_list_members()
returns table (id uuid, display_name text, line_user_id text, vip_tier smallint,
               vip_expires_at timestamptz, wallet_balance numeric, picture_url text, last_notice_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.assert_admin();
  return query
    select u.id, u.display_name, u.line_user_id, u.vip_tier, u.vip_expires_at, u.wallet_balance, u.picture_url,
           (select max(n.created_at) from public.renewal_notices n where n.user_id = u.id and n.result = 'SENT')
      from public.users u
     where u.vip_tier > 0 and u.vip_expires_at > now() and u.vendor_id is null      -- a seller's customers: admin_list_vendor_members()
     order by u.vip_expires_at;
end $$;

create or replace function public.admin_list_vendor_members(p_vendor text)
returns table (id uuid, display_name text, line_user_id text, vip_tier smallint,
               vip_expires_at timestamptz, wallet_balance numeric, picture_url text, last_notice_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.assert_admin();
  return query
    select u.id, u.display_name, u.line_user_id, u.vip_tier, u.vip_expires_at, u.wallet_balance, u.picture_url,
           (select max(n.created_at) from public.renewal_notices n where n.user_id = u.id and n.result = 'SENT')
      from public.users u where u.vip_tier > 0 and u.vip_expires_at > now() and u.vendor_id = p_vendor order by u.vip_expires_at;
end $$;

create or replace function public.admin_user_vendor(p_user uuid)
returns text language plpgsql stable security definer set search_path = public as $$
begin
  perform public.assert_admin();
  return (select v.name from public.users u join public.vendors v on v.id = u.vendor_id where u.id = p_user);
end $$;

-- ---------- admin: manage a seller's staff ---------------------------------------------------------------
create or replace function public.admin_vendor_staff_list(p_vendor text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform public.assert_admin();
  return coalesce((select jsonb_agg(jsonb_build_object('user_id', u.id, 'name', u.display_name,
           'line_id', split_part(u.line_user_id, ':', 2), 'push_ready', split_part(u.line_user_id, ':', 2) ~ '^U[0-9a-f]{32}$') order by s.created_at)
      from public.vendor_staff s join public.users u on u.id = s.user_id where s.vendor_id = p_vendor), '[]'::jsonb);
end $$;
-- search among the customers / accounts of THIS seller (a staff member logs in to the seller's LIFF once, then shows up here)
create or replace function public.admin_search_vendor_users(p_vendor text, p_q text)
returns table (id uuid, display_name text, line_id text)
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.assert_admin();
  return query select u.id, u.display_name, split_part(u.line_user_id, ':', 2)
    from public.users u where u.vendor_id = p_vendor and (btrim(coalesce(p_q, '')) = '' or u.display_name ilike '%' || btrim(p_q) || '%') order by u.last_seen_at desc nulls last limit 20;
end $$;
create or replace function public.admin_vendor_staff_add(p_vendor text, p_user uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public.assert_admin();
  if not exists (select 1 from public.users where id = p_user and vendor_id = p_vendor) then raise exception 'NOT_VENDOR_USER'; end if;
  insert into public.vendor_staff (vendor_id, user_id) values (p_vendor, p_user) on conflict do nothing;
end $$;
create or replace function public.admin_vendor_staff_remove(p_vendor text, p_user uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public.assert_admin();
  delete from public.vendor_staff where vendor_id = p_vendor and user_id = p_user;
end $$;

-- ---------- pushes about support messages (through notify-chat) ---------------------------------------
create table if not exists public.support_push_log (
  id uuid primary key default gen_random_uuid(), thread_id uuid not null, kind text not null, sent_at timestamptz not null default now()
);
create index if not exists support_push_log_idx on public.support_push_log (thread_id, kind, sent_at desc);
alter table public.support_push_log enable row level security;
revoke all on public.support_push_log from anon, authenticated;

create or replace function public.support_notify_push()
returns trigger language plpgsql security definer set search_path = public as $$
declare t public.support_threads; v_url text; v_secret text; v_kind text;
begin
  if new.kind <> 'text' then return new; end if;
  select * into t from public.support_threads where id = new.thread_id;
  if t.vendor_id is null then return new; end if;                        -- central customers: no push (our cost)
  v_kind := case when new.from_admin then 'reply' else 'incoming' end;
  select value into v_url from public.private_config where key = 'chat_notify_url';
  select value into v_secret from public.private_config where key = 'chat_notify_secret';
  if v_url is null or v_secret is null then return new; end if;
  if exists (select 1 from public.support_push_log where thread_id = new.thread_id and kind = v_kind and sent_at > now() - interval '10 minutes') then return new; end if;
  insert into public.support_push_log (thread_id, kind) values (new.thread_id, v_kind);
  execute format('select net.http_post(url := %L, headers := %L::jsonb, body := %L::jsonb)', v_url,
    jsonb_build_object('Content-Type', 'application/json', 'x-webhook-secret', v_secret)::text,
    jsonb_build_object('type', 'support', 'event', v_kind, 'thread_id', new.thread_id)::text);
  return new;
exception when others then
  return new;
end $$;
drop trigger if exists support_messages_push on public.support_messages;
create trigger support_messages_push after insert on public.support_messages for each row execute function public.support_notify_push();

-- Edge Functions (service role): the LINE ids of a seller's staff
create or replace function public.vendor_staff_line_ids(p_vendor text)
returns text[] language sql stable security definer set search_path = public as $$
  select coalesce(array_agg(split_part(u.line_user_id, ':', 2)), '{}')
    from public.vendor_staff s join public.users u on u.id = s.user_id where s.vendor_id = p_vendor
$$;

revoke all on function public.is_vendor_staff(text), public.my_vendor_staff(), public.support_can_staff(text), public.support_send(uuid, text),
  public.support_mark_read(uuid), public.support_threads_for(text), public.admin_support_threads(), public.admin_stats(), public.admin_list_members(),
  public.admin_list_vendor_members(text), public.admin_user_vendor(uuid), public.admin_vendor_staff_list(text), public.admin_search_vendor_users(text, text),
  public.admin_vendor_staff_add(text, uuid), public.admin_vendor_staff_remove(text, uuid), public.vendor_staff_line_ids(text),
  public.resolve_referrer(uuid), public.resolve_package_referrer(uuid), public.resolve_sales(uuid), public.register_referral_click(text) from public, anon;
grant execute on function public.is_vendor_staff(text), public.my_vendor_staff(), public.support_send(uuid, text), public.support_mark_read(uuid),
  public.support_threads_for(text), public.admin_support_threads(), public.admin_stats(), public.admin_list_members(), public.admin_list_vendor_members(text),
  public.admin_user_vendor(uuid), public.admin_vendor_staff_list(text), public.admin_search_vendor_users(text, text), public.admin_vendor_staff_add(text, uuid),
  public.admin_vendor_staff_remove(text, uuid), public.register_referral_click(text) to authenticated;
revoke all on function public.resolve_referrer(uuid), public.resolve_package_referrer(uuid), public.resolve_sales(uuid) from authenticated;
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    grant execute on function public.vendor_staff_line_ids(text) to service_role;
  end if;
end $$;
-- =============================================================================
