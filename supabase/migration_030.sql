-- =============================================================================
-- migration_030.sql — run ONCE after migration_029.sql
-- Chat moderation:
--   * every refused contact attempt is recorded; the thread's flag goes 1 (noted) -> 2 yellow -> 3 orange -> 4 red;
--     red suspends the thread ("ห้องนี้ถูกระงับโดยผู้ดูแล"): nobody can send, no push, held chat fees stay frozen
--   * users can report a chat; admins may read ONLY flagged / reported / suspended chats, must give a reason, and every
--     opening is logged (chat_admin_views)
--   * the admin decides: suspend, unblock (flag reset, held fee deadline extended) or close for good (held fee refunded)
--   * customers accept the customer terms once (20+, chats may be reviewed when there is a complaint, fraud or a rule breach)
-- send_message now RETURNS text: 'OK', 'CONTACT_BLOCKED:<n>' or 'THREAD_SUSPENDED' (a refusal must not roll the log back).
-- =============================================================================

alter table public.chat_threads
  add column if not exists status text not null default 'open',
  add column if not exists flag_level int not null default 0,
  add column if not exists flag_reset_at timestamptz,
  add column if not exists suspended_at timestamptz,
  add column if not exists suspended_reason text,
  add column if not exists reviewed_by uuid,
  add column if not exists reviewed_at timestamptz,
  add column if not exists review_note text;
do $$ begin
  alter table public.chat_threads add constraint chat_threads_status_check check (status in ('open', 'suspended', 'closed'));
exception when duplicate_object then null; end $$;

create table if not exists public.chat_flag_events (
  id uuid primary key default gen_random_uuid(),
  thread_id uuid not null references public.chat_threads (id) on delete cascade,
  sender_id uuid not null references public.users (id) on delete cascade,
  reason text not null,                -- NUMBER | LINK | HANDLE | WORD | SPLIT_NUMBER
  body text,                           -- what was refused (first 200 characters), for the admin
  created_at timestamptz not null default now()
);
create index if not exists chat_flag_events_idx on public.chat_flag_events (thread_id, sender_id, created_at desc);

create table if not exists public.chat_reports (
  id uuid primary key default gen_random_uuid(),
  thread_id uuid not null references public.chat_threads (id) on delete cascade,
  reporter_id uuid not null references public.users (id) on delete cascade,
  reason text not null, note text,
  status text not null default 'open',
  created_at timestamptz not null default now(), handled_by uuid, handled_at timestamptz
);
create index if not exists chat_reports_idx on public.chat_reports (thread_id, status);

create table if not exists public.chat_admin_views (
  id uuid primary key default gen_random_uuid(),
  admin_id uuid not null, thread_id uuid not null, reason text not null, created_at timestamptz not null default now()
);

alter table public.chat_flag_events enable row level security;
alter table public.chat_reports enable row level security;
alter table public.chat_admin_views enable row level security;
revoke all on public.chat_flag_events, public.chat_reports, public.chat_admin_views from anon, authenticated;

do $$ begin
  alter publication supabase_realtime add table public.chat_threads;
exception when duplicate_object then null; end $$;

alter table public.users add column if not exists customer_terms_at timestamptz;
create or replace function public.accept_customer_terms()
returns void language sql security definer set search_path = public as $$
  update public.users set customer_terms_at = coalesce(customer_terms_at, now()) where id = auth.uid()
$$;

-- ---------- fees stay frozen while a thread is not open ----------------------------------
create or replace function public.release_chat_holds(p_customer uuid default null, p_thread uuid default null)
returns int language plpgsql security definer set search_path = public as $$
declare f public.chat_fees; n int := 0;
begin
  for f in select * from public.chat_fees
            where status = 'held' and hold_expires_at <= now()
              and (p_customer is null or customer_id = p_customer)
              and (p_thread is null or thread_id = p_thread)
              and not exists (select 1 from public.chat_threads th where th.id = thread_id and th.status <> 'open')   -- frozen while an admin decides
            for update skip locked loop
    update public.chat_fees set status = 'released', released_at = now() where id = f.id;
    perform set_config('app.ledger_kind', 'chat_hold_release', true);
    perform set_config('app.ledger_ref', f.id::text, true);
    update public.users set wallet_balance = wallet_balance + f.amount where id = f.customer_id;
    n := n + 1;
  end loop;
  return n;
end $$;

-- ---------- sending ----------------------------------------------------------------------
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
      update public.chat_threads set status = 'suspended', suspended_at = now(), suspended_reason = 'auto_flag' where id = p_thread;
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

-- ---------- no push from a suspended room -------------------------------------------------
create or replace function public.notify_chat_message()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  t public.chat_threads; v_to uuid; v_url text; v_secret text;
begin
  select value into v_url from public.private_config where key = 'chat_notify_url';
  select value into v_secret from public.private_config where key = 'chat_notify_secret';
  if v_url is null or v_secret is null then return new; end if;
  select * into t from public.chat_threads where id = new.thread_id;
  if t.status <> 'open' then return new; end if;     -- a suspended room sends no push
  v_to := case when new.sender_id = t.customer_id then t.worker_id else t.customer_id end;
  if exists (select 1 from public.chat_push_log where thread_id = new.thread_id and recipient_id = v_to
                and sent_at > now() - interval '10 minutes') then return new; end if;
  insert into public.chat_push_log (thread_id, recipient_id) values (new.thread_id, v_to);
  execute format('select net.http_post(url := %L, headers := %L::jsonb, body := %L::jsonb)',
    v_url, jsonb_build_object('Content-Type', 'application/json', 'x-webhook-secret', v_secret)::text,
    jsonb_build_object('thread_id', new.thread_id, 'recipient_id', v_to, 'sender_id', new.sender_id)::text);
  return new;
exception when others then
  return new;
end $$;

-- ---------- reports ----------------------------------------------------------------------
create or replace function public.report_thread(p_thread uuid, p_reason text, p_note text default null)
returns void language plpgsql security definer set search_path = public as $$
declare t public.chat_threads;
begin
  select * into t from public.chat_threads where id = p_thread and auth.uid() in (customer_id, worker_id);
  if not found then raise exception 'FORBIDDEN'; end if;
  if p_reason not in ('contact', 'fraud', 'harassment', 'underage', 'other') then raise exception 'BAD_REASON'; end if;
  if exists (select 1 from public.chat_reports where thread_id = p_thread and reporter_id = auth.uid() and status = 'open') then
    raise exception 'ALREADY_REPORTED';
  end if;
  insert into public.chat_reports (thread_id, reporter_id, reason, note) values (p_thread, auth.uid(), p_reason, left(nullif(btrim(coalesce(p_note, '')), ''), 500));
end $$;

-- ---------- admin ------------------------------------------------------------------------
-- Needs attention: red/suspended, any flag, or an open report.
create or replace function public.admin_chat_queue(p_filter text default 'pending')
returns table (id uuid, customer_name text, worker_name text, status text, flag_level int, attempts int, reports int,
               last_event_at timestamptz, suspended_at timestamptz, suspended_reason text, review_note text)
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.assert_admin();
  return query
    select t.id, cu.display_name, w.display_name, t.status, t.flag_level,
           (select count(*)::int from public.chat_flag_events e where e.thread_id = t.id and e.created_at > coalesce(t.flag_reset_at, '-infinity')),
           (select count(*)::int from public.chat_reports r where r.thread_id = t.id and r.status = 'open'),
           greatest((select max(e.created_at) from public.chat_flag_events e where e.thread_id = t.id),
                    (select max(r.created_at) from public.chat_reports r where r.thread_id = t.id)),
           t.suspended_at, t.suspended_reason, t.review_note
      from public.chat_threads t
      join public.users cu on cu.id = t.customer_id
      join public.workers w on w.user_id = t.worker_id
     where case p_filter
             when 'closed' then t.status = 'closed'
             when 'all' then t.flag_level > 0 or t.status <> 'open' or exists (select 1 from public.chat_reports r where r.thread_id = t.id)
             else t.status <> 'closed' and (t.status = 'suspended' or t.flag_level > 0
                  or exists (select 1 from public.chat_reports r where r.thread_id = t.id and r.status = 'open')) end
     order by (t.status = 'suspended') desc, t.flag_level desc, 8 desc nulls last
     limit 100;
end $$;

create or replace function public.admin_chat_pending_count()
returns int language plpgsql stable security definer set search_path = public as $$
begin
  perform public.assert_admin();
  return (select count(*)::int from public.chat_threads t where t.status <> 'closed' and (t.status = 'suspended' or t.flag_level > 0
            or exists (select 1 from public.chat_reports r where r.thread_id = t.id and r.status = 'open')));
end $$;

-- Reading a chat: only flagged / reported / suspended ones, with a written reason, and it is logged.
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
                                 'suspended_at', t.suspended_at, 'suspended_reason', t.suspended_reason, 'review_note', t.review_note),
    'messages', coalesce((select jsonb_agg(jsonb_build_object('id', m.id, 'sender_id', m.sender_id, 'body', m.body, 'created_at', m.created_at,
                          'who', case when m.sender_id = t.customer_id then 'customer' when m.sender_id = t.worker_id then 'worker' else 'agency' end)
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

-- suspend | unblock | close. Closing is permanent and refunds the fee that is held for this thread.
create or replace function public.admin_chat_action(p_thread uuid, p_action text, p_note text default null)
returns void language plpgsql security definer set search_path = public as $$
declare t public.chat_threads; f public.chat_fees; v_note text := left(nullif(btrim(coalesce(p_note, '')), ''), 300);
begin
  perform public.assert_admin();
  select * into t from public.chat_threads where id = p_thread for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if t.status = 'closed' then raise exception 'ALREADY_CLOSED'; end if;
  if p_action = 'suspend' then
    update public.chat_threads set status = 'suspended', suspended_at = coalesce(suspended_at, now()), suspended_reason = 'admin',
           reviewed_by = auth.uid(), reviewed_at = now(), review_note = v_note where id = p_thread;
  elsif p_action = 'unblock' then
    if t.status = 'suspended' then   -- the held fee deadline moves by the time the room was frozen
      update public.chat_fees set hold_expires_at = hold_expires_at + (now() - coalesce(t.suspended_at, now()))
       where thread_id = p_thread and status = 'held';
    end if;
    update public.chat_threads set status = 'open', flag_level = 0, flag_reset_at = now(), suspended_at = null, suspended_reason = null,
           reviewed_by = auth.uid(), reviewed_at = now(), review_note = v_note where id = p_thread;
    update public.chat_reports set status = 'handled', handled_by = auth.uid(), handled_at = now() where thread_id = p_thread and status = 'open';
  elsif p_action = 'close' then
    for f in select * from public.chat_fees where thread_id = p_thread and status = 'held' for update loop
      update public.chat_fees set status = 'released', released_at = now() where id = f.id;
      perform set_config('app.ledger_kind', 'chat_hold_release', true);
      perform set_config('app.ledger_ref', f.id::text, true);
      update public.users set wallet_balance = wallet_balance + f.amount where id = f.customer_id;
    end loop;
    update public.chat_threads set status = 'closed', suspended_at = coalesce(suspended_at, now()),
           reviewed_by = auth.uid(), reviewed_at = now(), review_note = v_note where id = p_thread;
    update public.chat_reports set status = 'handled', handled_by = auth.uid(), handled_at = now() where thread_id = p_thread and status = 'open';
  else
    raise exception 'BAD_ACTION';
  end if;
end $$;

revoke all on function public.report_thread(uuid, text, text), public.accept_customer_terms(), public.admin_chat_queue(text),
  public.admin_chat_pending_count(), public.admin_open_chat(uuid, text), public.admin_chat_action(uuid, text, text) from public, anon;
grant execute on function public.report_thread(uuid, text, text), public.accept_customer_terms(), public.admin_chat_queue(text),
  public.admin_chat_pending_count(), public.admin_open_chat(uuid, text), public.admin_chat_action(uuid, text, text) to authenticated;
-- =============================================================================
