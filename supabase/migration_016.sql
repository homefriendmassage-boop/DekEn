-- =============================================================================
-- migration_016.sql — run ONCE after migration_015.sql
-- Step 3 of the revenue-sharing plan: paid chat.
--   * The customer's first message of a conversation sets aside 40 THB from the Wallet (a "hold").
--   * The provider's first valid reply (>= 2 letters, not one repeated character) within 3 hours settles it:
--     30 THB to the provider's bonus wallet, 10 THB stays with the platform. A paid conversation stays free for 24 hours.
--   * No valid reply within 3 hours -> the 40 THB goes back to the customer's Wallet automatically.
--   * A booking that the provider accepts opens the chat for 72 hours at no extra charge
--     (a pending hold counts as settled by that acceptance).
-- The customer must tick the consent popup; the server refuses to hold money without it.
-- Releasing expired holds: runs lazily whenever the chat/wallet is opened, and every 10 minutes if
-- the pg_cron extension is enabled (Database > Extensions > pg_cron).
-- =============================================================================

create or replace function public.chat_fee_amount()     returns numeric language sql immutable as $$ select 40::numeric $$;
create or replace function public.chat_fee_to_worker()  returns numeric language sql immutable as $$ select 30::numeric $$;
create or replace function public.chat_hold_hours()     returns int     language sql immutable as $$ select 3 $$;
create or replace function public.chat_window_hours()   returns int     language sql immutable as $$ select 24 $$;
create or replace function public.chat_booking_window_hours() returns int language sql immutable as $$ select 72 $$;

alter table public.chat_threads add column if not exists paid_until timestamptz;   -- conversation is free until then

create table if not exists public.chat_fees (
  id              uuid primary key default gen_random_uuid(),
  thread_id       uuid not null references public.chat_threads (id) on delete cascade,
  customer_id     uuid not null references public.users (id),
  worker_id       uuid not null references public.users (id),
  amount          numeric(12,2) not null,
  worker_amount   numeric(12,2) not null,
  platform_amount numeric(12,2) not null,
  status          text not null default 'held' check (status in ('held', 'captured', 'released')),
  created_at      timestamptz not null default now(),
  hold_expires_at timestamptz not null,
  captured_at     timestamptz,
  released_at     timestamptz,
  reply_message_id uuid
);
create unique index if not exists chat_fees_one_held on public.chat_fees (thread_id) where status = 'held';
create index if not exists chat_fees_customer_idx on public.chat_fees (customer_id, created_at desc);
create index if not exists chat_fees_worker_idx   on public.chat_fees (worker_id, created_at desc);
alter table public.chat_fees enable row level security;
revoke all on public.chat_fees from anon, authenticated;
grant select on public.chat_fees to authenticated;
drop policy if exists chat_fees_own on public.chat_fees;
create policy chat_fees_own on public.chat_fees for select to authenticated using (auth.uid() in (customer_id, worker_id));

-- A reply that earns the fee: at least 2 letters/digits (Thai tone marks and combining vowels, emoji, spaces and
-- punctuation are ignored) and not one character repeated.
create or replace function public.chat_reply_valid(p text)
returns boolean language sql immutable as $$
  select char_length(s) >= 2 and (select count(distinct c) from regexp_split_to_table(s, '') c) >= 2
    from (select regexp_replace(
                   regexp_replace(coalesce(p, ''), '[ัิ-ฺ็-๎]', '', 'g'),
                   '[^0-9A-Za-zก-ะาำเ-ๆ]', '', 'g') as s) x
$$;

-- ---------- Settle / return ----------------------------------------------------
create or replace function public.capture_chat_fee(p_thread uuid, p_message uuid)
returns boolean language plpgsql security definer set search_path = public as $$
declare f public.chat_fees;
begin
  select * into f from public.chat_fees
   where thread_id = p_thread and status = 'held' and hold_expires_at > now() for update;
  if not found then return false; end if;
  update public.chat_fees set status = 'captured', captured_at = now(), reply_message_id = p_message where id = f.id;
  update public.chat_threads
     set paid_until = greatest(coalesce(paid_until, '-infinity'), now() + make_interval(hours => public.chat_window_hours()))
   where id = p_thread;
  perform set_config('app.ledger_kind', 'chat_income', true);
  perform set_config('app.ledger_ref', f.id::text, true);
  update public.users set bonus_balance = bonus_balance + f.worker_amount where id = f.worker_id;
  return true;
end $$;

-- Returns expired holds to the customer's Wallet. p_customer / p_thread narrow it down (null = everything).
create or replace function public.release_chat_holds(p_customer uuid default null, p_thread uuid default null)
returns int language plpgsql security definer set search_path = public as $$
declare f public.chat_fees; n int := 0;
begin
  for f in select * from public.chat_fees
            where status = 'held' and hold_expires_at <= now()
              and (p_customer is null or customer_id = p_customer)
              and (p_thread is null or thread_id = p_thread)
            for update skip locked loop
    update public.chat_fees set status = 'released', released_at = now() where id = f.id;
    perform set_config('app.ledger_kind', 'chat_hold_release', true);
    perform set_config('app.ledger_ref', f.id::text, true);
    update public.users set wallet_balance = wallet_balance + f.amount where id = f.customer_id;
    n := n + 1;
  end loop;
  return n;
end $$;
create or replace function public.release_expired_chat_holds()
returns int language sql security definer set search_path = public as $$ select public.release_chat_holds(null, null) $$;
create or replace function public.release_my_expired_holds()
returns int language sql security definer set search_path = public as $$ select public.release_chat_holds(auth.uid(), null) $$;

-- ---------- Sending --------------------------------------------------------------
drop function if exists public.send_message(uuid, text);
create or replace function public.send_message(p_thread uuid, p_body text, p_accept_fee boolean default false)
returns void language plpgsql security definer set search_path = public as $$
declare
  t   public.chat_threads;
  b   text := btrim(p_body);
  v_msg uuid;
  v_bal numeric;
  v_fee uuid;
begin
  select * into t from public.chat_threads
   where id = p_thread and auth.uid() in (customer_id, worker_id) for update;
  if not found then raise exception 'FORBIDDEN'; end if;
  if b is null or char_length(b) not between 1 and 500 then raise exception 'BAD_MESSAGE'; end if;
  if auth.uid() = t.customer_id and public.viewer_tier() < 1 then raise exception 'MEMBERS_ONLY'; end if;
  if (select count(*) from public.chat_messages
       where sender_id = auth.uid() and created_at > now() - interval '1 minute') >= 10 then
    raise exception 'RATE_LIMIT';
  end if;

  perform public.release_chat_holds(null, p_thread);   -- a hold that ran out goes back before anything else

  if auth.uid() = t.customer_id
     and coalesce(t.paid_until, '-infinity') <= now()
     and not exists (select 1 from public.chat_fees where thread_id = p_thread and status = 'held') then
    -- new conversation (or the free window ended): set the fee aside, with the customer's consent
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
         customer_last_read = case when auth.uid() = customer_id then now() else customer_last_read end,
         worker_last_read   = case when auth.uid() = worker_id   then now() else worker_last_read end
   where id = p_thread;

  if auth.uid() = t.worker_id and public.chat_reply_valid(b) then
    perform public.capture_chat_fee(p_thread, v_msg);
  end if;
end $$;

-- What the chat screen should tell each side.
create or replace function public.chat_fee_status(p_thread uuid)
returns table (role text, state text, until timestamptz, amount numeric, worker_amount numeric, hold_hours int)
language plpgsql security definer set search_path = public as $$
declare
  t public.chat_threads;
  f public.chat_fees;
  v_role text;
begin
  select * into t from public.chat_threads where id = p_thread and auth.uid() in (customer_id, worker_id);
  if not found then raise exception 'FORBIDDEN'; end if;
  v_role := case when auth.uid() = t.customer_id then 'customer' else 'worker' end;
  perform public.release_chat_holds(null, p_thread);
  select * into f from public.chat_fees where thread_id = p_thread and status = 'held';
  if found then
    return query select v_role, 'held', f.hold_expires_at, f.amount, f.worker_amount, public.chat_hold_hours();
  elsif coalesce(t.paid_until, '-infinity') > now() then
    return query select v_role, 'free', t.paid_until, public.chat_fee_amount(), public.chat_fee_to_worker(), public.chat_hold_hours();
  else
    return query select v_role, case when v_role = 'customer' then 'need_fee' else 'idle' end, null::timestamptz,
                        public.chat_fee_amount(), public.chat_fee_to_worker(), public.chat_hold_hours();
  end if;
end $$;

-- ---------- Accepting a booking opens the chat for free ------------------------------
create or replace function public.jobs_open_chat()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_thread uuid;
begin
  if new.status = 'matched' and old.status is distinct from 'matched' then
    insert into public.chat_threads (customer_id, worker_id) values (new.customer_id, new.worker_id)
    on conflict (customer_id, worker_id) do nothing;
    select id into v_thread from public.chat_threads where customer_id = new.customer_id and worker_id = new.worker_id;
    perform public.release_chat_holds(null, v_thread);
    perform public.capture_chat_fee(v_thread, null);      -- accepting the booking is the reply
    update public.chat_threads
       set paid_until = greatest(coalesce(paid_until, '-infinity'), now() + make_interval(hours => public.chat_booking_window_hours()))
     where id = v_thread;
  end if;
  return new;
end $$;
drop trigger if exists jobs_open_chat on public.jobs;
create trigger jobs_open_chat after update of status on public.jobs
  for each row execute function public.jobs_open_chat();

revoke all on function public.send_message(uuid, text, boolean), public.chat_fee_status(uuid),
  public.release_my_expired_holds(), public.release_expired_chat_holds(), public.release_chat_holds(uuid, uuid),
  public.capture_chat_fee(uuid, uuid), public.chat_reply_valid(text) from public, anon;
grant execute on function public.send_message(uuid, text, boolean), public.chat_fee_status(uuid),
  public.release_my_expired_holds() to authenticated;

-- Every 10 minutes (needs the pg_cron extension; harmless if it is not enabled — holds are also released lazily).
do $$ begin
  create extension if not exists pg_cron;
  perform cron.schedule('release-chat-holds', '*/10 * * * *', 'select public.release_expired_chat_holds()');
exception when others then
  raise notice 'pg_cron is not enabled (%): expired chat holds are released when the chat or wallet is opened', sqlerrm;
end $$;
-- =============================================================================
