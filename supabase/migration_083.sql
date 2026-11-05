-- =============================================================================
-- migration_083.sql — run ONCE after migration_082.sql  (then deploy the Edge Function notify-chat again)
-- The admin can now SEE whether the LINE Flex of an admin message reached the member: support_messages.push_status
-- (pending / SENT / FAILED / NO_LINE_ID) is written by notify-chat; admin_last_push() reads it for the Compose window.
-- (LINE OA Manager never lists messages sent through the API, so it cannot be used to check.)
-- =============================================================================

alter table public.support_messages add column if not exists push_status text, add column if not exists push_detail text;

CREATE OR REPLACE FUNCTION public.admin_send_message(p_user uuid, p_body text, p_push boolean DEFAULT true)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_thread uuid; v_msg uuid; v_body text := left(btrim(coalesce(p_body, '')), 1000);
begin
  if p_user is null or v_body = '' then return null; end if;
  insert into public.support_threads (user_id) values (p_user) on conflict (user_id) do nothing;
  select id into v_thread from public.support_threads where user_id = p_user;
  insert into public.support_messages (thread_id, sender_id, from_admin, kind, body, push_status)
    values (v_thread, coalesce(auth.uid(), p_user), true, 'text', v_body, case when p_push then 'pending' end) returning id into v_msg;
  update public.support_threads set last_message_at = now(), admin_last_read = now() where id = v_thread;
  if p_push then
    perform public.push_notify(jsonb_build_object('type', 'admin_msg', 'user_id', p_user, 'detail', left(v_body, 90), 'thread_id', v_thread, 'message_id', v_msg));
  end if;
  return v_thread;
end $function$;

create or replace function public.admin_last_push(p_user uuid)
returns table (push_status text, push_detail text, created_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.assert_admin();
  return query
    select m.push_status, m.push_detail, m.created_at
      from public.support_messages m join public.support_threads t on t.id = m.thread_id
     where t.user_id = p_user and m.from_admin and m.push_status is not null
     order by m.created_at desc limit 1;
end $$;
revoke all on function public.admin_last_push(uuid) from public, anon;
grant execute on function public.admin_last_push(uuid) to authenticated;
