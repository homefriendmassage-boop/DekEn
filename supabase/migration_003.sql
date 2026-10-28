-- =============================================================================
-- migration_003.sql — run ONCE after migration_002.sql
-- 1) Categories: remove "ENT แรง", rename "สปา VIP" -> "สปา"
-- 2) Service area (province / district / nearby) for providers
-- 3) In-app chat, members-only (no LINE push => no OA message cost)
-- =============================================================================

-- ---------- 1) Categories ----------------------------------------------------
alter table public.workers             drop constraint if exists workers_category_check;
alter table public.worker_applications drop constraint if exists worker_applications_category_check;

-- Anything left in the removed category is folded into 'ent' (review these rows manually).
update public.workers             set category = 'ent' where category = 'ent_hard';
update public.workers             set category = 'spa' where category = 'spa_vip';
update public.worker_applications set category = 'ent' where category = 'ent_hard';
update public.worker_applications set category = 'spa' where category = 'spa_vip';

alter table public.workers add constraint workers_category_check
  check (category in ('bartender','ent','masseuse','spa'));
alter table public.worker_applications add constraint worker_applications_category_check
  check (category in ('bartender','ent','masseuse','spa'));

-- masseuse needs VIP 200, spa needs VIP 300, bartender + ent are the free categories.
create or replace function public.can_view_category(p_cat text, p_rank int, p_tier int)
returns boolean language sql immutable as $$
  select p_tier >= (case p_cat when 'masseuse' then 2 when 'spa' then 3 else 0 end)
     and (p_tier > 0 or p_rank <= 10)
$$;

-- ---------- 2) Service area --------------------------------------------------
alter table public.workers
  add column if not exists province text,
  add column if not exists district text,
  add column if not exists nearby   text;
alter table public.worker_applications
  add column if not exists province text,
  add column if not exists district text,
  add column if not exists nearby   text;

grant update (province, district, nearby) on public.workers to authenticated;
grant insert (province, district, nearby) on public.worker_applications to authenticated;

create or replace function public.approve_worker(p_app uuid)
returns void language plpgsql security definer set search_path = public as $$
declare a public.worker_applications;
begin
  select * into a from public.worker_applications where id = p_app and status = 'pending';
  if not found then raise exception 'NOT_FOUND'; end if;
  update public.users set role = 'worker' where id = a.user_id;
  insert into public.workers (user_id, display_name, category, price, province, district, nearby)
  values (a.user_id, a.display_name, a.category, a.price, a.province, a.district, a.nearby)
  on conflict (user_id) do update
    set display_name = excluded.display_name, category = excluded.category, price = excluded.price,
        province = excluded.province, district = excluded.district, nearby = excluded.nearby;
  update public.worker_applications set status = 'approved' where id = p_app;
end $$;
revoke all on function public.approve_worker(uuid) from public, anon, authenticated;

-- list_workers gains the area columns (return type changes => drop + recreate)
drop function if exists public.list_workers(text);
create function public.list_workers(p_category text default null)
returns table (
  user_id uuid, display_name text, category text, price numeric,
  profile_image text, original_path text,
  is_online boolean, is_boosted boolean, rank int, can_view boolean,
  province text, district text, nearby text
) language sql stable security definer set search_path = public as $$
  with tier as (select public.viewer_tier() as t),
  r as (
    select w.*, row_number() over (partition by w.category
             order by w.is_boosted desc, w.is_online desc, w.created_at, w.user_id)::int as rk
      from public.workers w
  )
  select r.user_id, r.display_name, r.category, r.price, r.profile_image,
         case when public.can_view_category(r.category, r.rk, tier.t) then r.original_path end,
         r.is_online, r.is_boosted, r.rk,
         public.can_view_category(r.category, r.rk, tier.t),
         r.province, r.district, r.nearby
    from r, tier
   where p_category is null or r.category = p_category
   order by r.category, r.rk
$$;
revoke all on function public.list_workers(text) from public, anon;
grant execute on function public.list_workers(text) to authenticated;

-- ---------- 3) Chat (members only) -------------------------------------------
-- Why in-app instead of LINE push: a LINE OA *push* message counts against the OA's
-- monthly quota (and is billed beyond it); only *reply* messages are free. A customer
-- action can't use a reply token for a provider, so alerts would be push. In-app chat
-- costs nothing per message. Providers see unread counts when they open the app.
create table if not exists public.chat_threads (
  id                  uuid primary key default gen_random_uuid(),
  customer_id         uuid not null references public.users (id) on delete cascade,
  worker_id           uuid not null references public.workers (user_id) on delete cascade,
  created_at          timestamptz not null default now(),
  last_message_at     timestamptz,
  customer_last_read  timestamptz not null default 'epoch',
  worker_last_read    timestamptz not null default 'epoch',
  unique (customer_id, worker_id)
);
create table if not exists public.chat_messages (
  id          uuid primary key default gen_random_uuid(),
  thread_id   uuid not null references public.chat_threads (id) on delete cascade,
  sender_id   uuid not null references public.users (id) on delete cascade,
  body        text not null check (char_length(body) between 1 and 500),
  created_at  timestamptz not null default now()
);
create index if not exists chat_messages_thread_idx on public.chat_messages (thread_id, created_at);
create index if not exists chat_messages_sender_idx on public.chat_messages (sender_id, created_at desc);

alter table public.chat_threads  enable row level security;
alter table public.chat_messages enable row level security;
revoke all on public.chat_threads, public.chat_messages from anon, authenticated;
grant select on public.chat_threads, public.chat_messages to authenticated; -- writes only via RPC

drop policy if exists threads_select on public.chat_threads;
create policy threads_select on public.chat_threads
  for select to authenticated using (auth.uid() in (customer_id, worker_id));
drop policy if exists messages_select on public.chat_messages;
create policy messages_select on public.chat_messages
  for select to authenticated using (exists (
    select 1 from public.chat_threads t
     where t.id = thread_id and auth.uid() in (t.customer_id, t.worker_id)));

do $$ begin
  alter publication supabase_realtime add table public.chat_messages;
exception when duplicate_object then null; end $$;

-- Only a PAID, unexpired member who is allowed to view that provider can open a chat.
create or replace function public.open_thread(p_worker uuid)
returns uuid language plpgsql security definer set search_path = public as $$
declare v uuid;
begin
  if auth.uid() is null then raise exception 'FORBIDDEN'; end if;
  if public.viewer_tier() < 1 then raise exception 'MEMBERS_ONLY'; end if;
  if p_worker = auth.uid() or not public.can_view_worker(p_worker) then raise exception 'LOCKED'; end if;
  insert into public.chat_threads (customer_id, worker_id) values (auth.uid(), p_worker)
  on conflict (customer_id, worker_id) do nothing;
  select id into v from public.chat_threads where customer_id = auth.uid() and worker_id = p_worker;
  return v;
end $$;

create or replace function public.send_message(p_thread uuid, p_body text)
returns void language plpgsql security definer set search_path = public as $$
declare
  t public.chat_threads;
  b text := btrim(p_body);
begin
  select * into t from public.chat_threads
   where id = p_thread and auth.uid() in (customer_id, worker_id);
  if not found then raise exception 'FORBIDDEN'; end if;
  if b is null or char_length(b) not between 1 and 500 then raise exception 'BAD_MESSAGE'; end if;
  -- A customer whose membership lapsed can read history but not send.
  if auth.uid() = t.customer_id and public.viewer_tier() < 1 then raise exception 'MEMBERS_ONLY'; end if;
  if (select count(*) from public.chat_messages
       where sender_id = auth.uid() and created_at > now() - interval '1 minute') >= 10 then
    raise exception 'RATE_LIMIT';
  end if;

  insert into public.chat_messages (thread_id, sender_id, body) values (p_thread, auth.uid(), b);
  update public.chat_threads
     set last_message_at = now(),
         customer_last_read = case when auth.uid() = customer_id then now() else customer_last_read end,
         worker_last_read   = case when auth.uid() = worker_id   then now() else worker_last_read end
   where id = p_thread;
end $$;

create or replace function public.mark_read(p_thread uuid)
returns void language sql security definer set search_path = public as $$
  update public.chat_threads
     set customer_last_read = case when auth.uid() = customer_id then now() else customer_last_read end,
         worker_last_read   = case when auth.uid() = worker_id   then now() else worker_last_read end
   where id = p_thread and auth.uid() in (customer_id, worker_id);
$$;

create or replace function public.my_threads()
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
   where auth.uid() in (t.customer_id, t.worker_id)
   order by t.last_message_at desc nulls last
   limit 50
$$;

revoke all on function public.open_thread(uuid), public.send_message(uuid, text),
  public.mark_read(uuid), public.my_threads() from public, anon;
grant execute on function public.open_thread(uuid), public.send_message(uuid, text),
  public.mark_read(uuid), public.my_threads() to authenticated;
