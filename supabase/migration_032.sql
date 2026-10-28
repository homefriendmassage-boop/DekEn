-- =============================================================================
-- migration_032.sql — run ONCE after migration_031.sql
-- 1) Report a provider's PROFILE (button on the details page) + admin queue: dismiss / hide the profile / show it again.
--    A hidden profile (workers.admin_hidden) disappears from every list; the provider sees a notice on her dashboard.
-- 2) Room notices instead of push: when a chat is suspended, unblocked or closed a system message appears IN the chat
--    (chat_messages.kind = 'sys_suspended' | 'sys_unblocked' | 'sys_closed'); system messages never trigger a push.
-- 3) Closing a chat for good settles the held chat fee by who caused the flags:
--      worker side  -> the fee is refunded to the customer (paying the worker is refused: WORKER_CULPRIT)
--      customer side or unclear -> the admin chooses: refund the customer ('refund') or pay the worker ('pay_worker')
-- =============================================================================

alter table public.chat_messages add column if not exists kind text not null default 'user';

-- who caused the flags: more refused attempts wins; equal -> null
create or replace function public.chat_culprit(p_thread uuid)
returns text language sql stable security definer set search_path = public as $$
  select case when c > w then 'customer' when w > c then 'worker' else null end
    from (select count(*) filter (where e.sender_id = t.customer_id) c, count(*) filter (where e.sender_id = t.worker_id) w
            from public.chat_threads t left join public.chat_flag_events e on e.thread_id = t.id
           where t.id = p_thread group by t.id) x
$$;

-- ---------- profile reports ---------------------------------------------------------------
alter table public.workers add column if not exists admin_hidden boolean not null default false;
alter table public.workers add column if not exists admin_hidden_at timestamptz;

create table if not exists public.profile_reports (
  id uuid primary key default gen_random_uuid(),
  worker_id uuid not null references public.workers (user_id) on delete cascade,
  reporter_id uuid not null references public.users (id) on delete cascade,
  reason text not null, note text,
  status text not null default 'open',
  created_at timestamptz not null default now(), handled_by uuid, handled_at timestamptz, action text
);
create index if not exists profile_reports_idx on public.profile_reports (worker_id, status);
alter table public.profile_reports enable row level security;
revoke all on public.profile_reports from anon, authenticated;

create or replace function public.worker_listed(p_worker uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select not public.is_suspended(p_worker)
     and coalesce((select w.deleted_at is null and w.delete_requested_at is null and not w.admin_hidden
                          and (w.agency_id is null or public.agency_active(w.agency_id))
                     from public.workers w where w.user_id = p_worker), false)
$$;

create or replace function public.report_worker(p_worker uuid, p_reason text, p_note text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null or p_worker = auth.uid() then raise exception 'FORBIDDEN'; end if;
  if p_reason not in ('fake_photo', 'underage', 'contact', 'fraud', 'other') then raise exception 'BAD_REASON'; end if;
  if not public.worker_listed(p_worker) then raise exception 'NOT_FOUND'; end if;
  if exists (select 1 from public.profile_reports where worker_id = p_worker and reporter_id = auth.uid() and status = 'open') then
    raise exception 'ALREADY_REPORTED';
  end if;
  if (select count(*) from public.profile_reports where reporter_id = auth.uid() and created_at > now() - interval '24 hours') >= 10 then
    raise exception 'RATE_LIMIT';
  end if;
  insert into public.profile_reports (worker_id, reporter_id, reason, note) values (p_worker, auth.uid(), p_reason, left(nullif(btrim(coalesce(p_note, '')), ''), 500));
end $$;

create or replace function public.admin_profile_reports(p_filter text default 'open')
returns table (worker_id uuid, display_name text, admin_hidden boolean, reports int, last_at timestamptz, details jsonb)
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.assert_admin();
  return query
    select w.user_id, w.display_name, w.admin_hidden,
           (count(*) filter (where r.status = 'open'))::int, max(r.created_at),
           jsonb_agg(jsonb_build_object('id', r.id, 'reason', r.reason, 'note', r.note, 'status', r.status, 'created_at', r.created_at, 'action', r.action)
                     order by r.created_at desc)
      from public.workers w join public.profile_reports r on r.worker_id = w.user_id
     where case p_filter when 'hidden' then w.admin_hidden
                         when 'all' then true
                         else exists (select 1 from public.profile_reports o where o.worker_id = w.user_id and o.status = 'open') end
     group by w.user_id, w.display_name, w.admin_hidden
     order by 5 desc limit 100;
end $$;

-- dismiss | hide | unhide
create or replace function public.admin_profile_report_action(p_worker uuid, p_action text, p_note text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public.assert_admin();
  if not exists (select 1 from public.workers where user_id = p_worker) then raise exception 'NOT_FOUND'; end if;
  if p_action = 'hide' then
    update public.workers set admin_hidden = true, admin_hidden_at = now() where user_id = p_worker;
    update public.profile_reports set status = 'handled', handled_by = auth.uid(), handled_at = now(), action = 'hidden' where worker_id = p_worker and status = 'open';
  elsif p_action = 'unhide' then
    update public.workers set admin_hidden = false, admin_hidden_at = null where user_id = p_worker;
  elsif p_action = 'dismiss' then
    update public.profile_reports set status = 'handled', handled_by = auth.uid(), handled_at = now(), action = 'dismissed' where worker_id = p_worker and status = 'open';
  else
    raise exception 'BAD_ACTION';
  end if;
end $$;

-- ---------- chat: system notices, no push, culprit-based settlement -------------------------------
drop function if exists public.send_message(uuid, text, boolean);
create or replace function public.send_message(p_thread uuid, p_body text, p_accept_fee boolean default false)
returns text language plpgsql security definer set search_path = public as $$
declare
  t   public.chat_threads;
  b   text := btrim(p_body);
  v_msg uuid;
  v_bal numeric;
  v_fee uuid;
  v_worker_side boolean;
  v_digits int;
  v_prior int;
  v_reason text;
  v_n int;
begin
  select * into t from public.chat_threads
   where id = p_thread and (auth.uid() in (customer_id, worker_id) or public.is_agency_of(auth.uid(), worker_id)) for update;
  if not found then raise exception 'FORBIDDEN'; end if;
  v_worker_side := auth.uid() <> t.customer_id;
  if b is null or char_length(b) not between 1 and 500 then raise exception 'BAD_MESSAGE'; end if;
  -- Thread suspended / closed by an admin (or by the red flag below)
  if t.status <> 'open' then raise exception 'THREAD_SUSPENDED'; end if;
  -- Contact details (numbers, links, IDs, "line" ...) are refused BEFORE any fee is held. Every attempt is recorded and
  -- raises the thread's flag: 1 = noted, 2 = yellow, 3 = orange, 4 = red (the thread is suspended until an admin decides).
  v_reason := public.contact_problem(b);
  if v_reason is null and public.is_number_only(b) then
    -- a number sent in pieces: this message plus the sender's earlier number-only messages of the last 30 minutes
    select coalesce(sum(char_length(regexp_replace(public.contact_numbers(m.body), '[^0-9]', '', 'g'))), 0) into v_prior
      from (select body from public.chat_messages
             where thread_id = p_thread and sender_id = auth.uid() and created_at > now() - interval '30 minutes'
             order by created_at desc limit 8) m
     where public.is_number_only(m.body);
    v_digits := v_prior + char_length(regexp_replace(public.contact_numbers(b), '[^0-9]', '', 'g'));
    if v_prior > 0 and v_digits >= 9 then v_reason := 'SPLIT_NUMBER'; end if;
  end if;
  if v_reason is not null then
    insert into public.chat_flag_events (thread_id, sender_id, reason, body) values (p_thread, auth.uid(), v_reason, left(b, 200));
    select count(*) into v_n from public.chat_flag_events
     where thread_id = p_thread and sender_id = auth.uid() and created_at > coalesce(t.flag_reset_at, '-infinity');
    update public.chat_threads set flag_level = greatest(flag_level, least(v_n, 4)) where id = p_thread;
    if v_n >= 4 then
      update public.chat_threads set status = 'suspended', suspended_at = now(), suspended_reason = 'auto_flag', last_message_at = now() where id = p_thread;
      insert into public.chat_messages (thread_id, sender_id, body, kind) values (p_thread, auth.uid(), 'ห้องนี้ถูกระงับโดยผู้ดูแล', 'sys_suspended');
      return 'THREAD_SUSPENDED';
    end if;
    return 'CONTACT_BLOCKED:' || v_n;
  end if;
  if not v_worker_side and public.viewer_tier() < 1 then raise exception 'MEMBERS_ONLY'; end if;
  if (select count(*) from public.chat_messages
       where sender_id = auth.uid() and created_at > now() - interval '1 minute') >= 10 then
    raise exception 'RATE_LIMIT';
  end if;

  perform public.release_chat_holds(null, p_thread);

  if not v_worker_side
     and coalesce(t.paid_until, '-infinity') <= now()
     and not exists (select 1 from public.chat_fees where thread_id = p_thread and status = 'held') then
    if not p_accept_fee then raise exception 'FEE_CONSENT_REQUIRED'; end if;
    select wallet_balance into v_bal from public.users where id = t.customer_id for update;
    if v_bal < public.chat_fee_amount() then raise exception 'INSUFFICIENT_BALANCE'; end if;
    insert into public.chat_fees (thread_id, customer_id, worker_id, amount, worker_amount, platform_amount, hold_expires_at)
    values (p_thread, t.customer_id, t.worker_id, public.chat_fee_amount(), public.chat_fee_to_worker(),
            public.chat_fee_amount() - public.chat_fee_to_worker(), now() + make_interval(hours => public.chat_hold_hours()))
    returning id into v_fee;
    perform set_config('app.ledger_kind', 'chat_hold', true);
    perform set_config('app.ledger_ref', v_fee::text, true);
    update public.users set wallet_balance = wallet_balance - public.chat_fee_amount() where id = t.customer_id;
  end if;

  insert into public.chat_messages (thread_id, sender_id, body) values (p_thread, auth.uid(), b) returning id into v_msg;
  update public.chat_threads
     set last_message_at = now(),
         customer_last_read = case when not v_worker_side then now() else customer_last_read end,
         worker_last_read   = case when v_worker_side     then now() else worker_last_read end
   where id = p_thread;

  if v_worker_side and public.chat_reply_valid(b) then
    perform public.capture_chat_fee(p_thread, v_msg);
  end if;
  return 'OK';
end $$;
revoke all on function public.send_message(uuid, text, boolean) from public, anon;
grant execute on function public.send_message(uuid, text, boolean) to authenticated;

create or replace function public.notify_chat_message()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  t public.chat_threads; v_to uuid; v_url text; v_secret text;
begin
  if new.kind <> 'user' then return new; end if;     -- room notices are shown in the chat, never pushed
  select value into v_url from public.private_config where key = 'chat_notify_url';
  select value into v_secret from public.private_config where key = 'chat_notify_secret';
  if v_url is null or v_secret is null then return new; end if;
  select * into t from public.chat_threads where id = new.thread_id;
  if t.status <> 'open' then return new; end if;     -- a suspended room sends no push
  v_to := case when new.sender_id = t.customer_id then t.worker_id else t.customer_id end;
  if exists (select 1 from public.chat_push_log where thread_id = new.thread_id and recipient_id = v_to
                and sent_at > now() - interval '24 hours') then return new; end if;
  insert into public.chat_push_log (thread_id, recipient_id) values (new.thread_id, v_to);
  execute format('select net.http_post(url := %L, headers := %L::jsonb, body := %L::jsonb)',
    v_url, jsonb_build_object('Content-Type', 'application/json', 'x-webhook-secret', v_secret)::text,
    jsonb_build_object('thread_id', new.thread_id, 'recipient_id', v_to, 'sender_id', new.sender_id)::text);
  return new;
exception when others then
  return new;
end $$;

create or replace function public.admin_open_chat(p_thread uuid, p_reason text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare t public.chat_threads; v_reason text := left(btrim(coalesce(p_reason, '')), 200);
begin
  perform public.assert_admin();
  select * into t from public.chat_threads where id = p_thread;
  if not found then raise exception 'NOT_FOUND'; end if;
  if t.flag_level = 0 and t.status = 'open' and not exists (select 1 from public.chat_reports r where r.thread_id = p_thread) then
    raise exception 'NOT_FLAGGED';
  end if;
  if char_length(v_reason) < 3 then raise exception 'REASON_REQUIRED'; end if;
  insert into public.chat_admin_views (admin_id, thread_id, reason) values (auth.uid(), p_thread, v_reason);
  return jsonb_build_object(
    'thread', jsonb_build_object('id', t.id, 'status', t.status, 'flag_level', t.flag_level, 'customer_id', t.customer_id, 'worker_id', t.worker_id,
                                 'suspended_at', t.suspended_at, 'suspended_reason', t.suspended_reason, 'review_note', t.review_note,
                                 'culprit', public.chat_culprit(t.id), 'held', (select jsonb_build_object('amount', f.amount, 'worker_amount', f.worker_amount) from public.chat_fees f where f.thread_id = t.id and f.status = 'held' limit 1)),
    'messages', coalesce((select jsonb_agg(jsonb_build_object('id', m.id, 'sender_id', m.sender_id, 'body', m.body, 'created_at', m.created_at,
                          'kind', m.kind, 'who', case when m.kind <> 'user' then 'system' when m.sender_id = t.customer_id then 'customer' when m.sender_id = t.worker_id then 'worker' else 'agency' end)
                          order by m.created_at)
                            from (select * from public.chat_messages where thread_id = p_thread order by created_at desc limit 300) m), '[]'::jsonb),
    'events', coalesce((select jsonb_agg(jsonb_build_object('id', e.id, 'reason', e.reason, 'body', e.body, 'created_at', e.created_at,
                          'who', case when e.sender_id = t.customer_id then 'customer' else 'worker' end) order by e.created_at)
                          from public.chat_flag_events e where e.thread_id = p_thread), '[]'::jsonb),
    'reports', coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'reason', r.reason, 'note', r.note, 'status', r.status, 'created_at', r.created_at,
                          'who', case when r.reporter_id = t.customer_id then 'customer' else 'worker' end) order by r.created_at)
                          from public.chat_reports r where r.thread_id = p_thread), '[]'::jsonb),
    'views', coalesce((select jsonb_agg(jsonb_build_object('admin', u.display_name, 'reason', v.reason, 'created_at', v.created_at) order by v.created_at desc)
                          from (select * from public.chat_admin_views where thread_id = p_thread order by created_at desc limit 10) v
                          left join public.users u on u.id = v.admin_id), '[]'::jsonb));
end $$;

create or replace function public.admin_chat_pending_count()
returns int language plpgsql stable security definer set search_path = public as $$
begin
  perform public.assert_admin();
  return (select count(*)::int from public.chat_threads t where t.status <> 'closed' and (t.status = 'suspended' or t.flag_level > 0
            or exists (select 1 from public.chat_reports r where r.thread_id = t.id and r.status = 'open')))
       + (select count(distinct worker_id)::int from public.profile_reports where status = 'open');
end $$;

drop function if exists public.admin_chat_action(uuid, text, text);
-- suspend | unblock | close. close: p_settle = 'refund' (default) or 'pay_worker' (refused when the worker side caused the flags)
create or replace function public.admin_chat_action(p_thread uuid, p_action text, p_note text default null, p_settle text default null)
returns void language plpgsql security definer set search_path = public as $$
declare t public.chat_threads; f public.chat_fees; v_note text := left(nullif(btrim(coalesce(p_note, '')), ''), 300); v_c text;
begin
  perform public.assert_admin();
  select * into t from public.chat_threads where id = p_thread for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if t.status = 'closed' then raise exception 'ALREADY_CLOSED'; end if;
  v_c := public.chat_culprit(p_thread);
  if p_action = 'suspend' then
    update public.chat_threads set status = 'suspended', suspended_at = coalesce(suspended_at, now()), suspended_reason = 'admin',
           reviewed_by = auth.uid(), reviewed_at = now(), review_note = v_note, last_message_at = now() where id = p_thread;
    insert into public.chat_messages (thread_id, sender_id, body, kind) values (p_thread, auth.uid(), 'ห้องนี้ถูกระงับโดยผู้ดูแล', 'sys_suspended');
  elsif p_action = 'unblock' then
    if t.status = 'suspended' then   -- the held fee deadline moves by the time the room was frozen
      update public.chat_fees set hold_expires_at = hold_expires_at + (now() - coalesce(t.suspended_at, now()))
       where thread_id = p_thread and status = 'held';
    end if;
    update public.chat_threads set status = 'open', flag_level = 0, flag_reset_at = now(), suspended_at = null, suspended_reason = null,
           reviewed_by = auth.uid(), reviewed_at = now(), review_note = v_note, last_message_at = now() where id = p_thread;
    update public.chat_reports set status = 'handled', handled_by = auth.uid(), handled_at = now() where thread_id = p_thread and status = 'open';
    insert into public.chat_messages (thread_id, sender_id, body, kind) values (p_thread, auth.uid(), 'ผู้ดูแลปลดบล็อกห้องนี้แล้ว คุยต่อได้ตามปกติ', 'sys_unblocked');
  elsif p_action = 'close' then
    if coalesce(p_settle, 'refund') not in ('refund', 'pay_worker') then raise exception 'BAD_SETTLE'; end if;
    if p_settle = 'pay_worker' and v_c = 'worker' then raise exception 'WORKER_CULPRIT'; end if;
    for f in select * from public.chat_fees where thread_id = p_thread and status = 'held' for update loop
      perform set_config('app.ledger_ref', f.id::text, true);
      if p_settle = 'pay_worker' then
        update public.chat_fees set status = 'captured', captured_at = now() where id = f.id;
        perform set_config('app.ledger_kind', 'chat_income', true);
        update public.users set bonus_balance = bonus_balance + f.worker_amount where id = f.worker_id;
      else
        update public.chat_fees set status = 'released', released_at = now() where id = f.id;
        perform set_config('app.ledger_kind', 'chat_hold_release', true);
        update public.users set wallet_balance = wallet_balance + f.amount where id = f.customer_id;
      end if;
    end loop;
    update public.chat_threads set status = 'closed', suspended_at = coalesce(suspended_at, now()),
           reviewed_by = auth.uid(), reviewed_at = now(), review_note = v_note, last_message_at = now() where id = p_thread;
    update public.chat_reports set status = 'handled', handled_by = auth.uid(), handled_at = now() where thread_id = p_thread and status = 'open';
    insert into public.chat_messages (thread_id, sender_id, body, kind) values (p_thread, auth.uid(), 'ห้องนี้ถูกปิดถาวรโดยผู้ดูแล', 'sys_closed');
  else
    raise exception 'BAD_ACTION';
  end if;
end $$;

revoke all on function public.chat_culprit(uuid), public.report_worker(uuid, text, text), public.admin_profile_reports(text),
  public.admin_profile_report_action(uuid, text, text), public.admin_chat_action(uuid, text, text, text),
  public.admin_open_chat(uuid, text), public.admin_chat_pending_count() from public, anon;
grant execute on function public.report_worker(uuid, text, text), public.admin_profile_reports(text),
  public.admin_profile_report_action(uuid, text, text), public.admin_chat_action(uuid, text, text, text),
  public.admin_open_chat(uuid, text), public.admin_chat_pending_count() to authenticated;
-- =============================================================================
