-- =============================================================================
-- migration_012.sql — run ONCE after migration_011.sql
-- 1) Upgrade a running plan by paying only the DIFFERENCE; the expiry date stays the same.
-- 2) Back office: cancel / change a member's plan, suspend an account (until a date or permanently),
--    with an audit trail.
-- =============================================================================

-- ---------- 1) Suspension columns + audit ------------------------------------
alter table public.users add column if not exists suspended_until timestamptz;   -- null = active; 9999-12-31 = permanent
alter table public.users add column if not exists suspend_reason  text;

create table if not exists public.membership_events (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references public.users (id) on delete cascade,
  admin_id    uuid references public.users (id),
  action      text not null,               -- set_membership | cancel_membership | suspend | unsuspend
  old_tier    smallint,
  old_expires timestamptz,
  new_tier    smallint,
  new_expires timestamptz,
  reason      text,
  created_at  timestamptz not null default now()
);
create index if not exists membership_events_user_idx on public.membership_events (user_id, created_at desc);
alter table public.membership_events enable row level security;
revoke all on public.membership_events from anon, authenticated;

create or replace function public.is_suspended(p_user uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select suspended_until > now() from public.users where id = p_user), false)
$$;
revoke all on function public.is_suspended(uuid) from public, anon;
grant execute on function public.is_suspended(uuid) to authenticated;

-- A suspended account has no membership benefits (list/chat/view rules all go through viewer_tier).
create or replace function public.viewer_tier()
returns int language sql stable security definer set search_path = public as $$
  select coalesce((select case when vip_expires_at > now() and coalesce(suspended_until, '-infinity') <= now()
                               then vip_tier else 0 end
                     from public.users where id = auth.uid()), 0)
$$;

-- Suspended users cannot book or send chat messages (separate triggers: no existing function is rewritten).
create or replace function public.block_suspended_job()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if public.is_suspended(new.customer_id) then raise exception 'SUSPENDED'; end if;
  return new;
end $$;
drop trigger if exists jobs_block_suspended on public.jobs;
create trigger jobs_block_suspended before insert on public.jobs
  for each row execute function public.block_suspended_job();

create or replace function public.block_suspended_message()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if public.is_suspended(new.sender_id) then raise exception 'SUSPENDED'; end if;
  return new;
end $$;
drop trigger if exists chat_messages_block_suspended on public.chat_messages;
create trigger chat_messages_block_suspended before insert on public.chat_messages
  for each row execute function public.block_suspended_message();

-- ---------- 2) Upgrade = pay the difference, keep the expiry -----------------
alter table public.payment_intents add column if not exists is_upgrade boolean not null default false;

create or replace function public.create_payment_intent(p_kind text, p_tier int default null, p_amount numeric default null)
returns table (intent_id uuid, intent_amount numeric, intent_expires_at timestamptz)
language plpgsql security definer set search_path = public as $$
declare
  v_base   numeric;
  v_amount numeric;
  v_id     uuid;
  v_exp    timestamptz := now() + interval '30 minutes';
  v_tries  int := 0;
  v_cur    int := 0;
  v_upg    boolean := false;
  e        public.payment_intents;
begin
  if auth.uid() is null then raise exception 'FORBIDDEN'; end if;
  if public.is_suspended(auth.uid()) then raise exception 'SUSPENDED'; end if;

  if p_kind = 'membership' then
    if coalesce(p_tier, 0) not between 1 and 3 then raise exception 'BAD_INPUT'; end if;
    -- Active plan right now (0 = none). A lower plan cannot be bought on top of a higher one.
    select coalesce((select vip_tier from public.users where id = auth.uid() and vip_expires_at > now()), 0) into v_cur;
    if p_tier < v_cur then raise exception 'ALREADY_HIGHER'; end if;
    v_upg  := v_cur > 0 and p_tier > v_cur;
    v_base := public.plan_price(p_tier) - case when v_upg then public.plan_price(v_cur) else 0 end;
  elsif p_kind = 'wallet_topup' then
    if p_amount is null or p_amount < 100 or p_amount > 10000 or p_amount <> trunc(p_amount) then
      raise exception 'BAD_INPUT';
    end if;
    v_base := p_amount;
  else
    raise exception 'BAD_INPUT';
  end if;

  select * into e from public.payment_intents
   where user_id = auth.uid() and status = 'pending' and expires_at > now()
     and kind = p_kind and base_amount = v_base and is_upgrade = v_upg
     and tier is not distinct from (case when p_kind = 'membership' then p_tier::smallint end)
   order by created_at desc limit 1;
  if found then
    return query select e.id, e.amount, e.expires_at;
    return;
  end if;

  update public.payment_intents set status = 'expired' where status = 'pending' and expires_at < now();
  update public.payment_intents set status = 'expired'
   where id in (select id from public.payment_intents
                 where user_id = auth.uid() and status = 'pending'
                 order by created_at desc offset 2);

  loop
    v_amount := v_base + (1 + floor(random() * 99))::int / 100.0;
    begin
      insert into public.payment_intents (user_id, kind, tier, days, base_amount, amount, expires_at, is_upgrade)
      values (auth.uid(), p_kind,
              case when p_kind = 'membership' then p_tier end,
              case when p_kind = 'membership' then 30 end,
              v_base, v_amount, v_exp, v_upg)
      returning id into v_id;
      exit;
    exception when unique_violation then
      v_tries := v_tries + 1;
      if v_tries > 25 then raise exception 'BUSY'; end if;
    end;
  end loop;

  return query select v_id, v_amount, v_exp;
end $$;

create or replace function public.apply_slip_payment(p_user uuid, p_amount numeric, p_trans_ref text)
returns table (kind text, tier int, days int, paid numeric)
language plpgsql security definer set search_path = public as $$
declare
  i     public.payment_intents;
  v_pay uuid;
  v_cur int;
begin
  if exists (select 1 from public.payment_reviews where trans_ref = p_trans_ref) then
    raise exception 'DUPLICATE_SLIP';
  end if;

  select * into i from public.payment_intents
   where user_id = p_user and status = 'pending' and expires_at > now() and amount = p_amount
   order by created_at desc limit 1
   for update;
  if not found then raise exception 'NO_MATCHING_INTENT'; end if;

  -- An upgrade only makes sense while the lower plan is still running; otherwise the admin decides.
  if i.is_upgrade then
    select coalesce((select vip_tier from public.users where id = p_user and vip_expires_at > now()), 0) into v_cur;
    if v_cur = 0 or v_cur >= i.tier then raise exception 'NO_MATCHING_INTENT'; end if;
  end if;

  begin
    insert into public.payments (user_id, kind, tier, days, amount, method, reference, note, recorded_by, source)
    values (p_user, i.kind, i.tier, i.days, i.amount, 'promptpay', p_trans_ref,
            case when i.is_upgrade then 'auto: upgrade (difference), expiry unchanged' else 'auto: slip verified' end,
            null, 'slip_auto')
    returning id into v_pay;
  exception when unique_violation then
    raise exception 'DUPLICATE_SLIP';
  end;

  update public.payment_intents set status = 'paid', paid_at = now(), payment_id = v_pay where id = i.id;

  if i.kind = 'membership' then
    if i.is_upgrade then
      update public.users set vip_tier = i.tier where id = p_user;          -- same expiry date
      insert into public.membership_events (user_id, action, old_tier, new_tier, new_expires, reason)
      select p_user, 'set_membership', v_cur, i.tier, vip_expires_at, 'upgrade (paid difference)'
        from public.users where id = p_user;
    else
      perform public.set_membership(p_user, i.tier, i.days);
    end if;
  else
    update public.users set wallet_balance = wallet_balance + i.amount where id = p_user;
  end if;

  return query select i.kind, i.tier::int, i.days, i.amount;
end $$;

-- ---------- 3) Admin: change / cancel plan, suspend --------------------------
-- p_tier 0 = cancel the plan now. p_tier 1..3 = set that plan until p_expires (fixes a wrong upgrade, gifts, refunds).
create or replace function public.admin_set_membership(p_user uuid, p_tier int, p_expires timestamptz, p_reason text)
returns void language plpgsql security definer set search_path = public as $$
declare u public.users;
begin
  perform public.assert_admin();
  if char_length(btrim(coalesce(p_reason, ''))) < 2 then raise exception 'REASON_REQUIRED'; end if;
  select * into u from public.users where id = p_user for update;
  if not found then raise exception 'USER_NOT_FOUND'; end if;

  if p_tier = 0 then
    update public.users set vip_tier = 0, vip_expires_at = now() where id = p_user;
    insert into public.membership_events (user_id, admin_id, action, old_tier, old_expires, new_tier, new_expires, reason)
    values (p_user, auth.uid(), 'cancel_membership', u.vip_tier, u.vip_expires_at, 0, now(), btrim(p_reason));
  elsif p_tier between 1 and 3 then
    if p_expires is null or p_expires <= now() or p_expires > now() + interval '400 days' then
      raise exception 'BAD_INPUT';
    end if;
    update public.users set vip_tier = p_tier, vip_expires_at = p_expires where id = p_user;
    insert into public.membership_events (user_id, admin_id, action, old_tier, old_expires, new_tier, new_expires, reason)
    values (p_user, auth.uid(), 'set_membership', u.vip_tier, u.vip_expires_at, p_tier, p_expires, btrim(p_reason));
  else
    raise exception 'BAD_INPUT';
  end if;
end $$;

-- p_until null = lift the suspension; a date = suspended until then; 9999-12-31 = permanent.
create or replace function public.admin_set_suspension(p_user uuid, p_until timestamptz, p_reason text)
returns void language plpgsql security definer set search_path = public as $$
declare u public.users;
begin
  perform public.assert_admin();
  if p_user = auth.uid() or exists (select 1 from public.admins a where a.user_id = p_user) then
    raise exception 'CANNOT_SUSPEND_ADMIN';
  end if;
  if p_until is not null and char_length(btrim(coalesce(p_reason, ''))) < 2 then raise exception 'REASON_REQUIRED'; end if;
  if p_until is not null and p_until <= now() then raise exception 'BAD_INPUT'; end if;
  select * into u from public.users where id = p_user for update;
  if not found then raise exception 'USER_NOT_FOUND'; end if;

  update public.users
     set suspended_until = p_until,
         suspend_reason  = case when p_until is null then null else left(btrim(p_reason), 300) end
   where id = p_user;
  insert into public.membership_events (user_id, admin_id, action, old_tier, old_expires, new_tier, new_expires, reason)
  values (p_user, auth.uid(), case when p_until is null then 'unsuspend' else 'suspend' end,
          u.vip_tier, u.suspended_until, u.vip_tier, p_until, nullif(btrim(coalesce(p_reason, '')), ''));
end $$;

create or replace function public.admin_user_detail(p_user uuid)
returns table (id uuid, display_name text, role public.user_role, vip_tier smallint, vip_expires_at timestamptz,
               wallet_balance numeric, suspended_until timestamptz, suspend_reason text, events jsonb)
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.assert_admin();
  return query
    select u.id, u.display_name, u.role, u.vip_tier, u.vip_expires_at, u.wallet_balance, u.suspended_until, u.suspend_reason,
           coalesce((select jsonb_agg(to_jsonb(x) order by x.created_at desc)
                       from (select e.created_at, e.action, e.old_tier, e.new_tier, e.new_expires, e.reason, a.display_name as admin_name
                               from public.membership_events e left join public.users a on a.id = e.admin_id
                              where e.user_id = u.id order by e.created_at desc limit 10) x), '[]'::jsonb)
      from public.users u where u.id = p_user;
end $$;

revoke all on function public.admin_set_membership(uuid, int, timestamptz, text),
  public.admin_set_suspension(uuid, timestamptz, text), public.admin_user_detail(uuid) from public, anon;
grant execute on function public.admin_set_membership(uuid, int, timestamptz, text),
  public.admin_set_suspension(uuid, timestamptz, text), public.admin_user_detail(uuid) to authenticated;
-- =============================================================================
