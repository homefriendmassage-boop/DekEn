-- =============================================================================
-- migration_009.sql — run ONCE after migration_008.sql
-- 1) Payment reviews: a genuine slip to OUR account whose amount doesn't match is sent to the admin.
-- 2) Support chat between any user and the admin team (in-app; no LINE push cost).
-- Fake / duplicate / wrong-receiver slips are still rejected outright by the Edge Function.
-- =============================================================================

-- ---------- Support chat -----------------------------------------------------
create table if not exists public.support_threads (
  id              uuid primary key default gen_random_uuid(),
  user_id         uuid not null unique references public.users (id) on delete cascade,
  created_at      timestamptz not null default now(),
  last_message_at timestamptz,
  user_last_read  timestamptz not null default 'epoch',
  admin_last_read timestamptz not null default 'epoch'
);
create table if not exists public.support_messages (
  id         uuid primary key default gen_random_uuid(),
  thread_id  uuid not null references public.support_threads (id) on delete cascade,
  sender_id  uuid not null references public.users (id) on delete cascade,
  from_admin boolean not null default false,
  kind       text not null default 'text' check (kind in ('text', 'system')),
  body       text not null check (char_length(body) between 1 and 1000),
  created_at timestamptz not null default now()
);
create index if not exists support_messages_thread_idx on public.support_messages (thread_id, created_at);
create index if not exists support_messages_sender_idx on public.support_messages (sender_id, created_at desc);

alter table public.support_threads  enable row level security;
alter table public.support_messages enable row level security;
revoke all on public.support_threads, public.support_messages from anon, authenticated;
grant select on public.support_threads, public.support_messages to authenticated;   -- writes only via functions

drop policy if exists support_threads_select on public.support_threads;
create policy support_threads_select on public.support_threads
  for select to authenticated using (user_id = auth.uid() or public.is_admin());
drop policy if exists support_messages_select on public.support_messages;
create policy support_messages_select on public.support_messages
  for select to authenticated using (exists (
    select 1 from public.support_threads t
     where t.id = thread_id and (t.user_id = auth.uid() or public.is_admin())));

do $$ begin
  alter publication supabase_realtime add table public.support_messages;
exception when duplicate_object then null; end $$;

create or replace function public.support_open()
returns uuid language plpgsql security definer set search_path = public as $$
declare v uuid;
begin
  if auth.uid() is null then raise exception 'FORBIDDEN'; end if;
  insert into public.support_threads (user_id) values (auth.uid()) on conflict (user_id) do nothing;
  select id into v from public.support_threads where user_id = auth.uid();
  return v;
end $$;

-- Customer or admin. The sender role is decided here (is_admin()), never by the client.
create or replace function public.support_send(p_thread uuid, p_body text)
returns void language plpgsql security definer set search_path = public as $$
declare
  t   public.support_threads;
  adm boolean := public.is_admin();
  b   text := btrim(p_body);
begin
  select * into t from public.support_threads where id = p_thread and (user_id = auth.uid() or adm);
  if not found then raise exception 'FORBIDDEN'; end if;
  if b is null or char_length(b) not between 1 and (case when adm then 1000 else 500 end) then
    raise exception 'BAD_MESSAGE';
  end if;
  if not adm and (select count(*) from public.support_messages
                   where sender_id = auth.uid() and created_at > now() - interval '1 minute') >= 10 then
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
         admin_last_read = case when public.is_admin() then now() else admin_last_read end
   where id = p_thread and (user_id = auth.uid() or public.is_admin());
$$;

-- My support thread (if any) and how many admin messages I haven't read.
create or replace function public.my_support()
returns table (thread_id uuid, unread int)
language sql stable security definer set search_path = public as $$
  select t.id,
         (select count(*)::int from public.support_messages m
           where m.thread_id = t.id and m.from_admin and m.created_at > t.user_last_read)
    from public.support_threads t where t.user_id = auth.uid()
$$;

create or replace function public.admin_support_threads()
returns table (thread_id uuid, user_id uuid, user_name text, picture_url text,
               last_body text, last_message_at timestamptz, unread int)
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.assert_admin();
  return query
    select t.id, t.user_id, u.display_name, u.picture_url,
           (select m.body from public.support_messages m where m.thread_id = t.id order by m.created_at desc limit 1),
           t.last_message_at,
           (select count(*)::int from public.support_messages m
             where m.thread_id = t.id and not m.from_admin and m.created_at > t.admin_last_read)
      from public.support_threads t join public.users u on u.id = t.user_id
     where t.last_message_at is not null
     order by t.last_message_at desc
     limit 100;
end $$;

-- ---------- Payment reviews --------------------------------------------------
create table if not exists public.payment_reviews (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references public.users (id) on delete cascade,
  intent_id     uuid references public.payment_intents (id) on delete set null,
  trans_ref     text not null unique,                 -- one slip can only ever be reviewed once
  paid_amount   numeric(12,2) not null,
  expected      numeric[] not null default '{}',
  detail        jsonb,
  status        text not null default 'pending' check (status in ('pending', 'approved', 'rejected')),
  reject_reason text,
  created_at    timestamptz not null default now(),
  resolved_by   uuid references public.users (id),
  resolved_at   timestamptz,
  payment_id    uuid references public.payments (id)
);
create index if not exists payment_reviews_status_idx on public.payment_reviews (status, created_at desc);
alter table public.payment_reviews enable row level security;
revoke all on public.payment_reviews from anon, authenticated;

-- A slip counts as used as soon as it is under review (so it can't also be auto-approved elsewhere).
create or replace function public.apply_slip_payment(p_user uuid, p_amount numeric, p_trans_ref text)
returns table (kind text, tier int, days int, paid numeric)
language plpgsql security definer set search_path = public as $$
declare
  i     public.payment_intents;
  v_pay uuid;
begin
  if exists (select 1 from public.payment_reviews where trans_ref = p_trans_ref) then
    raise exception 'DUPLICATE_SLIP';
  end if;

  select * into i from public.payment_intents
   where user_id = p_user and status = 'pending' and expires_at > now() and amount = p_amount
   order by created_at desc limit 1
   for update;
  if not found then raise exception 'NO_MATCHING_INTENT'; end if;

  begin
    insert into public.payments (user_id, kind, tier, days, amount, method, reference, note, recorded_by, source)
    values (p_user, i.kind, i.tier, i.days, i.amount, 'promptpay', p_trans_ref, 'auto: slip verified', null, 'slip_auto')
    returning id into v_pay;
  exception when unique_violation then
    raise exception 'DUPLICATE_SLIP';
  end;

  update public.payment_intents set status = 'paid', paid_at = now(), payment_id = v_pay where id = i.id;

  if i.kind = 'membership' then
    perform public.set_membership(p_user, i.tier, i.days);
  else
    update public.users set wallet_balance = wallet_balance + i.amount where id = p_user;
  end if;

  return query select i.kind, i.tier::int, i.days, i.amount;
end $$;

-- Edge Function (service role): a genuine slip to our account but with an amount that matches no open request.
create or replace function public.submit_payment_review(p_user uuid, p_trans_ref text, p_amount numeric, p_detail jsonb)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_review uuid;
  v_intent public.payment_intents;
  v_thread uuid;
  v_exp    numeric[];
begin
  if exists (select 1 from public.payments where reference = p_trans_ref) then raise exception 'DUPLICATE_SLIP'; end if;
  if exists (select 1 from public.payment_reviews where trans_ref = p_trans_ref) then
    if exists (select 1 from public.payment_reviews where trans_ref = p_trans_ref and user_id = p_user and status = 'pending')
      then raise exception 'ALREADY_UNDER_REVIEW'; end if;
    raise exception 'DUPLICATE_SLIP';
  end if;

  select * into v_intent from public.payment_intents
   where user_id = p_user and status = 'pending' and expires_at > now() order by created_at desc limit 1;
  select coalesce(array_agg(amount order by created_at desc), '{}') into v_exp
    from public.payment_intents where user_id = p_user and status = 'pending' and expires_at > now();

  begin
    insert into public.payment_reviews (user_id, intent_id, trans_ref, paid_amount, expected, detail)
    values (p_user, v_intent.id, p_trans_ref, p_amount, v_exp, p_detail)
    returning id into v_review;
  exception when unique_violation then
    raise exception 'DUPLICATE_SLIP';
  end;

  insert into public.support_threads (user_id) values (p_user) on conflict (user_id) do nothing;
  select id into v_thread from public.support_threads where user_id = p_user;
  insert into public.support_messages (thread_id, sender_id, from_admin, kind, body)
  values (v_thread, p_user, false, 'system',
          '📎 ส่งสลิปให้แอดมินตรวจสอบ — ยอดในสลิป ' || to_char(p_amount, 'FM999G990D00')
          || ' บาท, ยอดที่ต้องโอน ' || coalesce(to_char(v_intent.amount, 'FM999G990D00'), '-') || ' บาท (ref ' || p_trans_ref || ')');
  update public.support_threads set last_message_at = now(), user_last_read = now() where id = v_thread;
  return v_review;
end $$;

create or replace function public.admin_list_reviews(p_status text default 'pending')
returns table (id uuid, user_id uuid, user_name text, picture_url text, thread_id uuid, created_at timestamptz,
               trans_ref text, paid_amount numeric, expected numeric[], intent_kind text, intent_tier int,
               intent_days int, status text, reject_reason text)
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.assert_admin();
  return query
    select r.id, r.user_id, u.display_name, u.picture_url, st.id, r.created_at, r.trans_ref, r.paid_amount,
           r.expected, i.kind, i.tier::int, i.days, r.status, r.reject_reason
      from public.payment_reviews r
      join public.users u on u.id = r.user_id
      left join public.payment_intents i on i.id = r.intent_id
      left join public.support_threads st on st.user_id = r.user_id
     where p_status is null or r.status = p_status
     order by r.created_at desc
     limit 100;
end $$;

-- Approve: credit exactly what the slip shows, as the admin chose (plan or wallet). Reject: say why.
-- Either way the customer gets a message in their support chat.
create or replace function public.admin_resolve_review(
  p_review uuid, p_approve boolean, p_kind text, p_tier int, p_days int, p_request_id uuid, p_reason text default null)
returns void language plpgsql security definer set search_path = public as $$
declare
  r        public.payment_reviews;
  v_pay    uuid;
  v_thread uuid;
  v_idx    text;
  v_msg    text;
begin
  perform public.assert_admin();
  select * into r from public.payment_reviews where id = p_review and status = 'pending' for update;
  if not found then raise exception 'NOT_FOUND'; end if;

  if p_approve then
    if p_request_id is null then raise exception 'BAD_INPUT'; end if;
    if p_kind not in ('membership', 'wallet_topup')
       or (p_kind = 'membership' and (coalesce(p_tier, 0) not between 1 and 3 or coalesce(p_days, 0) not between 1 and 365)) then
      raise exception 'BAD_INPUT';
    end if;
    if exists (select 1 from public.payments where request_id = p_request_id) then raise exception 'DUPLICATE_REQUEST'; end if;

    begin
      insert into public.payments (user_id, kind, tier, days, amount, method, reference, note, recorded_by, request_id)
      values (r.user_id, p_kind,
              case when p_kind = 'membership' then p_tier end,
              case when p_kind = 'membership' then p_days end,
              r.paid_amount, 'bank_transfer', r.trans_ref, 'approved from slip review', auth.uid(), p_request_id)
      returning id into v_pay;
    exception when unique_violation then
      get stacked diagnostics v_idx = constraint_name;
      if v_idx = 'payments_request_unique' then raise exception 'DUPLICATE_REQUEST'; end if;
      raise exception 'DUPLICATE_REFERENCE';
    end;

    if p_kind = 'membership' then
      perform public.set_membership(r.user_id, p_tier, p_days);
    else
      update public.users set wallet_balance = wallet_balance + r.paid_amount where id = r.user_id;
    end if;

    update public.payment_reviews set status = 'approved', resolved_by = auth.uid(), resolved_at = now(), payment_id = v_pay
     where id = p_review;
    update public.payment_intents set status = 'expired' where user_id = r.user_id and status = 'pending';
    v_msg := '✅ แอดมินตรวจสลิปแล้ว: อนุมัติ' || case when p_kind = 'membership' then ' เปิดสิทธิ์สมาชิกให้เรียบร้อย' else ' เติมเงินเข้า Wallet เรียบร้อย' end;
  else
    update public.payment_reviews
       set status = 'rejected', reject_reason = left(nullif(btrim(p_reason), ''), 300),
           resolved_by = auth.uid(), resolved_at = now()
     where id = p_review;
    v_msg := '❌ แอดมินตรวจสลิปแล้ว: ไม่อนุมัติ' || coalesce(' — ' || left(nullif(btrim(p_reason), ''), 300), '');
  end if;

  insert into public.support_threads (user_id) values (r.user_id) on conflict (user_id) do nothing;
  select id into v_thread from public.support_threads where user_id = r.user_id;
  insert into public.support_messages (thread_id, sender_id, from_admin, kind, body)
  values (v_thread, auth.uid(), true, 'system', v_msg);
  update public.support_threads set last_message_at = now(), admin_last_read = now() where id = v_thread;
end $$;

-- Stats gain two counters (return type changed => drop + recreate)
drop function if exists public.admin_stats();
create function public.admin_stats()
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
      where exists (select 1 from public.support_messages m
                     where m.thread_id = t.id and not m.from_admin and m.created_at > t.admin_last_read));
end $$;

-- Permissions
revoke all on function public.support_open(), public.support_send(uuid, text), public.support_mark_read(uuid),
  public.my_support(), public.admin_support_threads(), public.admin_list_reviews(text),
  public.admin_resolve_review(uuid, boolean, text, int, int, uuid, text), public.admin_stats(),
  public.submit_payment_review(uuid, text, numeric, jsonb) from public, anon;
grant execute on function public.support_open(), public.support_send(uuid, text), public.support_mark_read(uuid),
  public.my_support(), public.admin_support_threads(), public.admin_list_reviews(text),
  public.admin_resolve_review(uuid, boolean, text, int, int, uuid, text), public.admin_stats() to authenticated;
revoke execute on function public.submit_payment_review(uuid, text, numeric, jsonb) from authenticated;
grant execute on function public.submit_payment_review(uuid, text, numeric, jsonb) to service_role;

-- "Sent to admin" is not a failure: keep it out of the failed-attempts list.
create or replace function public.admin_list_slip_attempts(p_limit int default 50)
returns table (id uuid, created_at timestamptz, user_id uuid, user_name text, result text,
               trans_ref text, detail jsonb)
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.assert_admin();
  return query
    select s.id, s.created_at, s.user_id, u.display_name, s.result, s.trans_ref, s.detail
      from public.slip_attempts s join public.users u on u.id = s.user_id
     where s.result not in ('OK', 'REVIEW_SUBMITTED')
     order by s.created_at desc
     limit least(greatest(p_limit, 1), 200);
end $$;
