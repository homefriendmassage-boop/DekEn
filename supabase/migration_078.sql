-- =============================================================================
-- migration_078.sql — run ONCE after migration_077.sql
-- Admin <-> members chat, appeals and re-opening chat rooms:
--   * the admin can message ANY member at any time (warnings, notices) from the admin pages; the message lands in the member's "แชทกับแอดมิน"
--     and a LINE Flex ("📢 ข้อความจากแอดมิน") tells him; he can answer there
--   * when the admin suspends / closes a chat room both sides are told why in that chat (with a Flex), and what they can do (appeal / answer)
--   * a ROOM THAT WAS CLOSED FOR GOOD can be opened again by the admin ("reopen") after he and the member agreed
--   * a member of a suspended / closed room can APPEAL ("ขออุทธรณ์"): the admin sees it first in the chat queue and in the member's support chat,
--     and either opens the room again or declines with a reason (the member is told)
-- =============================================================================
create table if not exists public.chat_appeals (
  id         uuid primary key default gen_random_uuid(),
  thread_id  uuid not null references public.chat_threads (id) on delete cascade,
  user_id    uuid not null,
  text       text not null check (char_length(text) between 3 and 500),
  status     text not null default 'open' check (status in ('open', 'granted', 'declined')),
  created_at timestamptz not null default now(),
  decided_by uuid, decided_at timestamptz, note text
);
create unique index if not exists chat_appeals_one_open on public.chat_appeals (thread_id, user_id) where status = 'open';
alter table public.chat_appeals enable row level security;
revoke all on public.chat_appeals from anon, authenticated;

-- ---------- the admin writes to a member (internal helper + the RPCs) ---------------------------------------------------------------------
create or replace function public.admin_send_message(p_user uuid, p_body text, p_push boolean default true)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_thread uuid; v_body text := left(btrim(coalesce(p_body, '')), 1000);
begin
  if p_user is null or v_body = '' then return null; end if;
  insert into public.support_threads (user_id) values (p_user) on conflict (user_id) do nothing;
  select id into v_thread from public.support_threads where user_id = p_user;
  insert into public.support_messages (thread_id, sender_id, from_admin, kind, body) values (v_thread, coalesce(auth.uid(), p_user), true, 'text', v_body);
  update public.support_threads set last_message_at = now(), admin_last_read = now() where id = v_thread;
  if p_push then
    perform public.push_notify(jsonb_build_object('type', 'admin_msg', 'user_id', p_user, 'detail', left(v_body, 90), 'thread_id', v_thread));
  end if;
  return v_thread;
end $$;
revoke all on function public.admin_send_message(uuid, text, boolean) from public, anon, authenticated;

create or replace function public.admin_message_user(p_user uuid, p_body text, p_push boolean default true)
returns uuid language plpgsql security definer set search_path = public as $$
begin
  perform public.assert_admin();
  if char_length(btrim(coalesce(p_body, ''))) not between 1 and 1000 then raise exception 'BAD_MESSAGE'; end if;
  if not exists (select 1 from public.users u where u.id = p_user) then raise exception 'NOT_FOUND'; end if;
  return public.admin_send_message(p_user, p_body, coalesce(p_push, true));
end $$;

-- open (or create) the support chat of a member so the admin can read / continue it
create or replace function public.admin_support_open(p_user uuid)
returns uuid language plpgsql security definer set search_path = public as $$
declare v uuid;
begin
  perform public.assert_admin();
  if not exists (select 1 from public.users u where u.id = p_user) then raise exception 'NOT_FOUND'; end if;
  insert into public.support_threads (user_id) values (p_user) on conflict (user_id) do nothing;
  select id into v from public.support_threads where user_id = p_user;
  return v;
end $$;

-- ---------- appeals ---------------------------------------------------------------------------------------------------------------------------
create or replace function public.chat_appeal(p_thread uuid, p_text text)
returns void language plpgsql security definer set search_path = public as $$
declare t public.chat_threads; v_text text := left(btrim(coalesce(p_text, '')), 500); v_name text; v_support uuid;
begin
  if auth.uid() is null then raise exception 'FORBIDDEN'; end if;
  select * into t from public.chat_threads where id = p_thread and auth.uid() in (customer_id, worker_id);
  if not found then raise exception 'FORBIDDEN'; end if;
  if t.status = 'open' then raise exception 'NOT_BLOCKED'; end if;
  if char_length(v_text) < 3 then raise exception 'BAD_MESSAGE'; end if;
  if exists (select 1 from public.chat_appeals where thread_id = p_thread and user_id = auth.uid() and status = 'open') then raise exception 'ALREADY_APPEALED'; end if;
  insert into public.chat_appeals (thread_id, user_id, text) values (p_thread, auth.uid(), v_text);
  -- the same words go to the admin's inbox with this member, so he can answer in the same chat
  insert into public.support_threads (user_id) values (auth.uid()) on conflict (user_id) do nothing;
  select id into v_support from public.support_threads where user_id = auth.uid();
  insert into public.support_messages (thread_id, sender_id, from_admin, kind, body) values (v_support, auth.uid(), false, 'text', '⚖️ ขออุทธรณ์ห้องแชต: ' || v_text);
  update public.support_threads set last_message_at = now(), user_last_read = now() where id = v_support;
  select display_name into v_name from public.users where id = auth.uid();
  perform public.admin_notify('appeal', v_name);
end $$;

create or replace function public.chat_appeal_status(p_thread uuid)
returns table (status text, text text, created_at timestamptz, note text)
language sql stable security definer set search_path = public as $$
  select a.status, a.text, a.created_at, a.note from public.chat_appeals a
   where a.thread_id = p_thread and a.user_id = auth.uid() order by a.created_at desc limit 1
$$;

-- ---------- the admin's room tools: reopen a closed room, answer an appeal ---------------------------------------------------------------------
create or replace function public.admin_chat_action(p_thread uuid, p_action text, p_note text default null, p_settle text default null)
returns void language plpgsql security definer set search_path = public as $$
declare t public.chat_threads; f public.chat_fees; v_note text := left(nullif(btrim(coalesce(p_note, '')), ''), 300); v_c text; v_cu text; v_wk text; v_who uuid; v_txt text;
begin
  perform public.assert_admin();
  select * into t from public.chat_threads where id = p_thread for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if t.status = 'closed' and p_action <> 'reopen' then raise exception 'ALREADY_CLOSED'; end if;
  v_c := public.chat_culprit(p_thread);
  select u.display_name into v_cu from public.users u where u.id = t.customer_id;
  select w.display_name into v_wk from public.workers w where w.user_id = t.worker_id;
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
  elsif p_action = 'reopen' then
    if t.status <> 'closed' then raise exception 'NOT_CLOSED'; end if;
    update public.chat_threads set status = 'open', flag_level = 0, flag_reset_at = now(), suspended_at = null, suspended_reason = null,
           reviewed_by = auth.uid(), reviewed_at = now(), review_note = v_note, last_message_at = now() where id = p_thread;
    update public.chat_reports set status = 'handled', handled_by = auth.uid(), handled_at = now() where thread_id = p_thread and status = 'open';
    insert into public.chat_messages (thread_id, sender_id, body, kind) values (p_thread, auth.uid(), 'ผู้ดูแลเปิดห้องนี้ให้ใหม่แล้ว คุยต่อได้ตามปกติ', 'sys_unblocked');
  elsif p_action = 'decline_appeal' then
    null;
  else
    raise exception 'BAD_ACTION';
  end if;
  -- appeals of this room are answered, and everybody involved is told in the support chat (with a LINE push)
  if p_action in ('unblock', 'reopen') then
    for v_who in select distinct user_id from public.chat_appeals where thread_id = p_thread and status = 'open' loop
      v_txt := '✅ แอดมินเปิดห้องแชต' || coalesce(' กับ ' || case when v_who = t.worker_id then v_cu else v_wk end, '') || ' ให้แล้ว คุยต่อได้ตามปกติ' || coalesce(' — ' || v_note, '');
      perform public.admin_send_message(v_who, v_txt, true);
    end loop;
    update public.chat_appeals set status = 'granted', decided_by = auth.uid(), decided_at = now(), note = v_note where thread_id = p_thread and status = 'open';
  elsif p_action = 'decline_appeal' then
    for v_who in select distinct user_id from public.chat_appeals where thread_id = p_thread and status = 'open' loop
      v_txt := '❌ แอดมินยังไม่เปิดห้องแชต' || coalesce(' กับ ' || case when v_who = t.worker_id then v_cu else v_wk end, '') || coalesce(' — ' || v_note, '') || ' หากต้องการชี้แจงเพิ่ม พิมพ์ตอบข้อความนี้ได้เลย';
      perform public.admin_send_message(v_who, v_txt, true);
    end loop;
    update public.chat_appeals set status = 'declined', decided_by = auth.uid(), decided_at = now(), note = v_note where thread_id = p_thread and status = 'open';
  elsif p_action in ('suspend', 'close') then
    -- tell both sides why (the admin can talk to them afterwards in the same chat)
    perform public.admin_send_message(t.worker_id, '🚫 ห้องแชตกับ ' || coalesce(v_cu, 'ลูกค้า') || (case p_action when 'suspend' then ' ถูกระงับชั่วคราว' else ' ถูกปิดถาวร' end) || ' โดยแอดมิน' || coalesce(' — ' || v_note, '') || ' หากไม่เห็นด้วยหรือต้องการชี้แจง กด "ขออุทธรณ์" ในห้องแชต หรือพิมพ์ตอบข้อความนี้ แอดมินจะพิจารณาเปิดห้องให้หลังตกลงกัน', true);
    perform public.admin_send_message(t.customer_id, '🚫 ห้องแชตกับ ' || coalesce(v_wk, 'น้อง') || (case p_action when 'suspend' then ' ถูกระงับชั่วคราว' else ' ถูกปิดถาวร' end) || ' โดยแอดมิน' || coalesce(' — ' || v_note, '') || ' หากต้องการชี้แจง กด "ขออุทธรณ์" ในห้องแชต หรือพิมพ์ตอบข้อความนี้', true);
  end if;
end $$;

drop function if exists public.admin_chat_queue(text);
create function public.admin_chat_queue(p_filter text default 'pending')
returns table (id uuid, customer_name text, worker_name text, status text, flag_level int, attempts int, reports int,
               last_event_at timestamptz, suspended_at timestamptz, suspended_reason text, review_note text,
               customer_id uuid, worker_id uuid, appeal_text text, appeal_at timestamptz, appeal_by text)
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.assert_admin();
  return query
    select t.id, cu.display_name, w.display_name, t.status, t.flag_level,
           (select count(*)::int from public.chat_flag_events e where e.thread_id = t.id and e.created_at > coalesce(t.flag_reset_at, '-infinity')),
           (select count(*)::int from public.chat_reports r where r.thread_id = t.id and r.status = 'open'),
           greatest((select max(e.created_at) from public.chat_flag_events e where e.thread_id = t.id),
                    (select max(r.created_at) from public.chat_reports r where r.thread_id = t.id)),
           t.suspended_at, t.suspended_reason, t.review_note, t.customer_id, t.worker_id,
           ap.text, ap.created_at, case when ap.user_id = t.worker_id then 'worker' when ap.user_id is not null then 'customer' end
      from public.chat_threads t
      join public.users cu on cu.id = t.customer_id
      join public.workers w on w.user_id = t.worker_id
      left join lateral (select a.text, a.created_at, a.user_id from public.chat_appeals a where a.thread_id = t.id and a.status = 'open' order by a.created_at desc limit 1) ap on true
     where case p_filter
             when 'closed' then t.status = 'closed'
             when 'appeals' then ap.user_id is not null
             when 'all' then t.flag_level > 0 or t.status <> 'open' or exists (select 1 from public.chat_reports r where r.thread_id = t.id)
             else ap.user_id is not null or (t.status <> 'closed' and (t.status = 'suspended' or t.flag_level > 0
                  or exists (select 1 from public.chat_reports r where r.thread_id = t.id and r.status = 'open'))) end
     order by (ap.user_id is not null) desc, (t.status = 'suspended') desc, t.flag_level desc, 8 desc nulls last
     limit 100;
end $$;

create or replace function public.admin_chat_pending_count()
returns int language plpgsql stable security definer set search_path = public as $$
begin
  perform public.assert_admin();
  return (select count(*)::int from public.chat_threads t where (t.status <> 'closed' and (t.status = 'suspended' or t.flag_level > 0
            or exists (select 1 from public.chat_reports r where r.thread_id = t.id and r.status = 'open')))
            or exists (select 1 from public.chat_appeals a where a.thread_id = t.id and a.status = 'open'))
       + (select count(distinct worker_id)::int from public.profile_reports where status = 'open');
end $$;

revoke all on function public.admin_message_user(uuid, text, boolean), public.admin_support_open(uuid), public.chat_appeal(uuid, text), public.chat_appeal_status(uuid),
  public.admin_chat_action(uuid, text, text, text), public.admin_chat_queue(text), public.admin_chat_pending_count() from public, anon;
grant execute on function public.admin_message_user(uuid, text, boolean), public.admin_support_open(uuid), public.chat_appeal(uuid, text), public.chat_appeal_status(uuid),
  public.admin_chat_action(uuid, text, text, text), public.admin_chat_queue(text), public.admin_chat_pending_count() to authenticated;
