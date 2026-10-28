-- =============================================================================
-- migration_010.sql — run ONCE after migration_009.sql
-- 1) Chat lists are per role (a user who is both customer and provider no longer mixes them).
-- 2) Chatting with yourself is a distinct error (SELF_CHAT), not "locked".
-- 3) Renewal reminders: ledger of notices sent (the Edge Function `send-renewal` writes it).
-- =============================================================================

-- ---------- 1) my_threads(role) ----------------------------------------------
drop function if exists public.my_threads();
create function public.my_threads(p_role text default null)
returns table (id uuid, worker_id uuid, other_name text, last_body text,
               last_message_at timestamptz, unread int)
language sql stable security definer set search_path = public as $$
  select t.id, t.worker_id,
         case when t.customer_id = auth.uid() then w.display_name else coalesce(cu.display_name, '—') end,
         (select m.body from public.chat_messages m where m.thread_id = t.id order by m.created_at desc limit 1),
         t.last_message_at,
         (select count(*)::int from public.chat_messages m
           where m.thread_id = t.id and m.sender_id <> auth.uid()
             and m.created_at > case when t.customer_id = auth.uid() then t.customer_last_read else t.worker_last_read end)
    from public.chat_threads t
    join public.workers w  on w.user_id = t.worker_id
    join public.users   cu on cu.id = t.customer_id
   where case p_role
           when 'worker'   then t.worker_id   = auth.uid()   -- chats customers started with me
           when 'customer' then t.customer_id = auth.uid()   -- chats I started with providers
           else auth.uid() in (t.customer_id, t.worker_id) end
   order by t.last_message_at desc nulls last
   limit 50
$$;
revoke all on function public.my_threads(text) from public, anon;
grant execute on function public.my_threads(text) to authenticated;

-- ---------- 2) open_thread: self chat gets its own error ---------------------
create or replace function public.open_thread(p_worker uuid)
returns uuid language plpgsql security definer set search_path = public as $$
declare v uuid;
begin
  if auth.uid() is null then raise exception 'FORBIDDEN'; end if;
  if p_worker = auth.uid() then raise exception 'SELF_CHAT'; end if;
  if public.viewer_tier() < 1 then raise exception 'MEMBERS_ONLY'; end if;
  if not public.can_view_worker(p_worker) then raise exception 'LOCKED'; end if;
  insert into public.chat_threads (customer_id, worker_id) values (auth.uid(), p_worker)
  on conflict (customer_id, worker_id) do nothing;
  select id into v from public.chat_threads where customer_id = auth.uid() and worker_id = p_worker;
  return v;
end $$;

-- ---------- 3) Renewal notices -----------------------------------------------
create table if not exists public.renewal_notices (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references public.users (id) on delete cascade,
  sent_by    uuid references public.users (id),
  result     text not null,                    -- SENT | FAILED
  detail     text,
  created_at timestamptz not null default now()
);
create index if not exists renewal_notices_user_idx on public.renewal_notices (user_id, created_at desc);
alter table public.renewal_notices enable row level security;
revoke all on public.renewal_notices from anon, authenticated;

drop function if exists public.admin_list_members();
create function public.admin_list_members()
returns table (id uuid, display_name text, line_user_id text, vip_tier smallint,
               vip_expires_at timestamptz, wallet_balance numeric, picture_url text, last_notice_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.assert_admin();
  return query
    select u.id, u.display_name, u.line_user_id, u.vip_tier, u.vip_expires_at, u.wallet_balance, u.picture_url,
           (select max(n.created_at) from public.renewal_notices n where n.user_id = u.id and n.result = 'SENT')
      from public.users u
     where u.vip_tier > 0 and u.vip_expires_at > now()
     order by u.vip_expires_at;
end $$;
revoke all on function public.admin_list_members() from public, anon;
grant execute on function public.admin_list_members() to authenticated;
