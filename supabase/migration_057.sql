-- =============================================================================
-- migration_057.sql — run ONCE after migration_056.sql
-- "Is she still working?" check for provider profiles. Days WITHOUT activity (login, going online, answering a chat, accepting / finishing
-- a job) -> 30: Flex "confirm you are still working" · 45: last warning Flex · 60: hidden from the feed, chat and booking closed
-- (one Flex) · 90: profile + photos deleted for good. Any activity brings her back at once (the clock restarts, a hidden profile shows again).
-- Money: the 90-day forfeiture of the Wallet / Bonus balance is a SWITCH that is OFF until an admin turns it on (admin tab "😴 ไม่ใช้งาน").
-- Everybody who is a provider today gets a fresh 90-day start when this runs.
-- =============================================================================

create table if not exists public.worker_alive (
  user_id uuid primary key references public.users (id) on delete cascade,
  last_active_at timestamptz not null default now(),
  stage smallint not null default 0,            -- 0 fine · 1 confirm Flex sent (30 d) · 2 last warning sent (45 d) · 3 hidden (60 d)
  hidden boolean not null default false,
  hidden_at timestamptz,
  exempt boolean not null default false         -- an admin excuses her (long break)
);
alter table public.worker_alive enable row level security;
revoke all on public.worker_alive from anon, authenticated;

create table if not exists public.inactive_forfeits (
  id bigint generated always as identity primary key,
  user_id uuid not null, name text, wallet numeric not null default 0, bonus numeric not null default 0,
  created_at timestamptz not null default now()
);
alter table public.inactive_forfeits enable row level security;
revoke all on public.inactive_forfeits from anon, authenticated;

insert into public.worker_alive (user_id) select w.user_id from public.workers w where w.deleted_at is null on conflict do nothing;
insert into public.app_settings (key, value) values ('inactive_forfeit', 'off') on conflict (key) do nothing;

-- ---------- activity ---------------------------------------------------------------------------------------------------------------------------
create or replace function public.touch_worker(p_user uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if p_user is null or not exists (select 1 from public.workers w where w.user_id = p_user and w.deleted_at is null) then return; end if;
  insert into public.worker_alive (user_id) values (p_user)
  on conflict (user_id) do update set last_active_at = now(), stage = 0, hidden = false, hidden_at = null
   where public.worker_alive.last_active_at < now() - interval '30 minutes' or public.worker_alive.stage > 0 or public.worker_alive.hidden;
end $$;
revoke all on function public.touch_worker(uuid) from public, anon, authenticated;

create or replace function public.touch_profile(p_name text, p_picture text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  update public.users
     set display_name = left(p_name, 60),
         picture_url  = case when p_picture ~ '^https://' then left(p_picture, 500) else picture_url end,
         last_seen_at = now()
   where id = auth.uid();
  perform public.touch_worker(auth.uid());
end $$;
revoke all on function public.touch_profile(text, text) from public, anon;
grant execute on function public.touch_profile(text, text) to authenticated;

-- she (or her agency) answers a chat
create or replace function public.trg_alive_chat() returns trigger language plpgsql security definer set search_path = public as $$
declare t public.chat_threads;
begin
  select * into t from public.chat_threads where id = new.thread_id;
  if found and new.sender_id <> t.customer_id then perform public.touch_worker(t.worker_id); end if;
  return new;
end $$;
drop trigger if exists chat_messages_alive on public.chat_messages;
create trigger chat_messages_alive after insert on public.chat_messages for each row execute function public.trg_alive_chat();

-- she goes online
create or replace function public.trg_alive_online() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.is_online and not coalesce(old.is_online, false) then perform public.touch_worker(new.user_id); end if;
  return new;
end $$;
drop trigger if exists workers_alive_online on public.workers;
create trigger workers_alive_online after update of is_online on public.workers for each row execute function public.trg_alive_online();

-- she accepts / finishes a job
create or replace function public.trg_alive_job() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.status in ('matched', 'completed') and new.status is distinct from old.status then perform public.touch_worker(new.worker_id); end if;
  return new;
end $$;
drop trigger if exists jobs_alive on public.jobs;
create trigger jobs_alive after update of status on public.jobs for each row execute function public.trg_alive_job();

-- ---------- hidden = not listed, no new chat, no new booking ------------------------------------------------------------------------------
create or replace function public.worker_listed(p_worker uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select not public.is_suspended(p_worker)
     and not coalesce((select a.hidden from public.worker_alive a where a.user_id = p_worker), false)
     and coalesce((select w.deleted_at is null and w.delete_requested_at is null and not w.admin_hidden and (w.claimed or w.claim_deadline > now())
                          and (w.agency_id is null or public.agency_active(w.agency_id))
                     from public.workers w where w.user_id = p_worker), false)
$$;

create or replace function public.trg_alive_block_chat() returns trigger language plpgsql security definer set search_path = public as $$
declare t public.chat_threads;
begin
  select * into t from public.chat_threads where id = new.thread_id;
  if found and new.sender_id = t.customer_id and coalesce((select a.hidden from public.worker_alive a where a.user_id = t.worker_id), false) then
    raise exception 'WORKER_INACTIVE';
  end if;
  return new;
end $$;
drop trigger if exists chat_messages_block_inactive on public.chat_messages;
create trigger chat_messages_block_inactive before insert on public.chat_messages for each row execute function public.trg_alive_block_chat();

create or replace function public.trg_alive_block_job() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if coalesce((select a.hidden from public.worker_alive a where a.user_id = new.worker_id), false) then raise exception 'WORKER_INACTIVE'; end if;
  return new;
end $$;
drop trigger if exists jobs_block_inactive on public.jobs;
create trigger jobs_block_inactive before insert on public.jobs for each row execute function public.trg_alive_block_job();

-- ---------- the daily sweep ---------------------------------------------------------------------------------------------------------------------
create or replace function public.inactive_sweep()
returns int language plpgsql security definer set search_path = public as $$
declare r record; v_target int; n int := 0; v_forfeit boolean := coalesce(public.app_setting('inactive_forfeit'), 'off') = 'on'; v_w numeric; v_b numeric;
begin
  for r in select a.user_id, a.stage, a.last_active_at, u.display_name, u.wallet_balance, u.bonus_balance
             from public.worker_alive a
             join public.workers w on w.user_id = a.user_id and w.deleted_at is null and w.claimed
             join public.users u on u.id = a.user_id
            where not a.exempt and a.last_active_at < now() - interval '30 days' loop
    v_target := case when r.last_active_at < now() - interval '90 days' then 4 when r.last_active_at < now() - interval '60 days' then 3
                     when r.last_active_at < now() - interval '45 days' then 2 else 1 end;
    if v_target = 4 then
      -- a booking still open keeps the profile until it is closed
      if exists (select 1 from public.jobs j where j.worker_id = r.user_id and j.status in ('pending', 'matched')) then continue; end if;
      if v_forfeit and (r.wallet_balance > 0 or r.bonus_balance > 0) then
        v_w := r.wallet_balance; v_b := r.bonus_balance;
        perform set_config('app.ledger_kind', 'inactive_forfeit', true);
        perform set_config('app.ledger_ref', r.user_id::text, true);
        update public.users set wallet_balance = 0, bonus_balance = 0 where id = r.user_id;
        insert into public.inactive_forfeits (user_id, name, wallet, bonus) values (r.user_id, r.display_name, v_w, v_b);
      end if;
      perform public.finish_profile_deletion(r.user_id);
      delete from public.worker_alive where user_id = r.user_id;
      n := n + 1;
    elsif v_target > r.stage then
      if v_target = 3 then update public.worker_alive set hidden = true, hidden_at = now(), stage = 3 where user_id = r.user_id;
      else update public.worker_alive set stage = v_target where user_id = r.user_id; end if;
      perform public.approval_notify('alive', r.user_id, case v_target when 1 then 'confirm' when 2 then 'final' else 'hidden' end,
                                     case when v_forfeit then 'forfeit' else '' end);
      n := n + 1;
    end if;
  end loop;
  return n;
end $$;
revoke all on function public.inactive_sweep() from public, anon, authenticated;

do $$ begin
  perform cron.schedule('inactive-sweep', '30 2 * * *', 'select public.inactive_sweep()');     -- 09:30 Thailand
exception when others then
  raise notice 'pg_cron is not enabled (%): schedule select public.inactive_sweep() daily yourself', sqlerrm;
end $$;

-- ---------- admin ---------------------------------------------------------------------------------------------------------------------------------
create or replace function public.admin_inactive_list()
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform public.assert_admin();
  return jsonb_build_object(
    'forfeit', coalesce(public.app_setting('inactive_forfeit'), 'off') = 'on',
    'forfeited_total', (select coalesce(sum(wallet + bonus), 0) from public.inactive_forfeits),
    'rows', coalesce((select jsonb_agg(to_jsonb(x) order by x.days desc) from (
       select a.user_id, w.display_name, a.stage, a.hidden, a.exempt, floor(extract(epoch from now() - a.last_active_at) / 86400)::int as days,
              u.wallet_balance, u.bonus_balance
         from public.worker_alive a join public.workers w on w.user_id = a.user_id and w.deleted_at is null
         join public.users u on u.id = a.user_id
        where (a.stage > 0 or a.exempt or a.last_active_at < now() - interval '25 days') limit 200) x), '[]'::jsonb));
end $$;

create or replace function public.admin_alive_reset(p_user uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public.assert_admin();
  update public.worker_alive set last_active_at = now(), stage = 0, hidden = false, hidden_at = null where user_id = p_user;
end $$;

create or replace function public.admin_alive_exempt(p_user uuid, p_on boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public.assert_admin();
  update public.worker_alive set exempt = coalesce(p_on, false) where user_id = p_user;
end $$;

create or replace function public.admin_set_inactive_forfeit(p_on boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public.assert_admin();
  insert into public.app_settings (key, value, updated_at, updated_by) values ('inactive_forfeit', case when p_on then 'on' else 'off' end, now(), auth.uid())
  on conflict (key) do update set value = excluded.value, updated_at = now(), updated_by = auth.uid();
end $$;

revoke all on function public.admin_inactive_list(), public.admin_alive_reset(uuid), public.admin_alive_exempt(uuid, boolean), public.admin_set_inactive_forfeit(boolean) from public, anon;
grant execute on function public.admin_inactive_list(), public.admin_alive_reset(uuid), public.admin_alive_exempt(uuid, boolean), public.admin_set_inactive_forfeit(boolean) to authenticated;
