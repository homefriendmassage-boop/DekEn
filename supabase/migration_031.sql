-- =============================================================================
-- migration_031.sql — run ONCE after migration_030.sql
-- Chat push: at most ONE push per chat room (and recipient) per 24 hours. A message in a room with someone else
-- (a different chat room) still pushes straight away. A suspended room sends no push (migration_030).
-- =============================================================================

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
                and sent_at > now() - interval '24 hours') then return new; end if;
  insert into public.chat_push_log (thread_id, recipient_id) values (new.thread_id, v_to);
  execute format('select net.http_post(url := %L, headers := %L::jsonb, body := %L::jsonb)',
    v_url, jsonb_build_object('Content-Type', 'application/json', 'x-webhook-secret', v_secret)::text,
    jsonb_build_object('thread_id', new.thread_id, 'recipient_id', v_to, 'sender_id', new.sender_id)::text);
  return new;
exception when others then
  return new;
end $$;
-- =============================================================================
