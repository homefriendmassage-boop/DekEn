-- =============================================================================
-- migration_027.sql — run ONCE after migration_026.sql
-- 1) Prices: only ONE rate has to be filled in. All rates (1 hour / 4 h / 6 h / own rows) live in price_options, the
--    starting rate is one of them and workers.price always mirrors it (bookings and the feed keep reading `price`).
-- 2) Chat push: when a message arrives, the recipient gets a LINE Flex message whose button opens that chat room
--    (at most one push per chat per 10 minutes). Needs the Edge Function `notify-chat` and one setup call (README).
-- =============================================================================

-- ---------- 1) prices -----------------------------------------------------
create or replace function public.normalize_worker_profile()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  e jsonb; v_out jsonb := '[]'::jsonb; v_label text; v_price numeric; v_n int := 0;
  v_tags text[]; v_moved boolean;
begin
  if tg_table_name = 'worker_applications' and tg_op = 'INSERT' then
    if new.accepted_terms is not true then raise exception 'TERMS_REQUIRED'; end if;
    new.terms_accepted_at := now();
  end if;

  select coalesce(array_agg(distinct x), '{}') into v_tags
    from unnest(coalesce(new.tags, '{}')) x
   where x = any (array['playful', 'fun_talk', 'not_picky', 'sing', 'dance', 'drinks', 'friendly']);
  new.tags := v_tags;
  new.about := nullif(btrim(coalesce(new.about, '')), '');
  new.measurements := nullif(btrim(coalesce(new.measurements, '')), '');

  if jsonb_typeof(coalesce(new.price_options, '[]'::jsonb)) <> 'array' then raise exception 'BAD_PRICE'; end if;
  for e in select * from jsonb_array_elements(coalesce(new.price_options, '[]'::jsonb)) loop
    exit when v_n >= 8;
    v_label := left(btrim(coalesce(e->>'label', '')), 30);
    begin v_price := (e->>'price')::numeric; exception when others then raise exception 'BAD_PRICE'; end;
    if v_label = '' then continue; end if;
    if v_price is null or v_price < 0 or v_price > 1000000 then raise exception 'BAD_PRICE'; end if;
    v_out := v_out || jsonb_build_object('label', v_label, 'price', round(v_price));
    v_n := v_n + 1;
  end loop;
  new.price_options := v_out;

  v_moved := (tg_op = 'INSERT' and new.loc_lat is not null)
             or (tg_op = 'UPDATE' and (new.loc_lat is distinct from old.loc_lat or new.loc_lng is distinct from old.loc_lng));
  if v_moved then
    if new.loc_lat is null or new.loc_lng is null or public.province_for(new.loc_lat, new.loc_lng) is null then
      raise exception 'BAD_LOCATION';
    end if;
    if coalesce(current_setting('app.no_fuzz', true), '') <> 'on' then
      new.loc_lat := round((new.loc_lat / 0.005)::numeric) * 0.005 + (random() - 0.5) * 0.004;
      new.loc_lng := round((new.loc_lng / 0.005)::numeric) * 0.005 + (random() - 0.5) * 0.004;
      new.loc_verified_at := now();
    end if;
    new.province := coalesce(public.province_for(new.loc_lat, new.loc_lng), new.province);
  elsif tg_op = 'UPDATE' and new.province is distinct from old.province
        and coalesce(current_setting('app.no_fuzz', true), '') <> 'on' then
    -- a province typed by hand replaces a GPS-confirmed one: the old point no longer applies, the profile is self-declared
    new.loc_lat := null; new.loc_lng := null; new.loc_verified_at := null;
  end if;
  -- Every rate lives in price_options ('1h', '@4h', '@6h' or her own rows); the starting rate must be one of them and
  -- `price` always mirrors it (bookings and the feed read that column). Legacy rows only had `price` = hourly.
  new.start_rate := nullif(btrim(coalesce(new.start_rate, '')), '');
  if (new.start_rate is null or new.start_rate = '1h') and coalesce(new.price, 0) > 0
     and not exists (select 1 from jsonb_array_elements(new.price_options) o where o->>'label' = '1h')
     and (new.start_rate = '1h' or jsonb_array_length(new.price_options) = 0) then
    new.price_options := new.price_options || jsonb_build_object('label', '1h', 'price', round(new.price));
    new.start_rate := '1h';
  end if;
  if new.start_rate is null then
    select o->>'label' into new.start_rate from jsonb_array_elements(new.price_options) o
     order by case o->>'label' when '@4h' then 1 when '@6h' then 2 when '1h' then 3 else 4 end limit 1;
  end if;
  select (o->>'price')::numeric into v_price from jsonb_array_elements(new.price_options) o where o->>'label' = new.start_rate limit 1;
  if new.start_rate is null or v_price is null then raise exception 'BAD_START_RATE'; end if;
  new.price := v_price;
  return new;
end $$;

-- existing rows: move the hourly price into price_options as the '1h' row
update public.workers w set price_options = price_options || jsonb_build_object('label', '1h', 'price', round(w.price))
 where w.price > 0 and not exists (select 1 from jsonb_array_elements(w.price_options) o where o->>'label' = '1h');
update public.worker_applications a set price_options = price_options || jsonb_build_object('label', '1h', 'price', round(a.price))
 where coalesce(a.price, 0) > 0 and not exists (select 1 from jsonb_array_elements(a.price_options) o where o->>'label' = '1h');

create or replace function public.submit_profile_edit(p_changes jsonb, p_remove uuid[] default '{}')
returns uuid language plpgsql security definer set search_path = public as $$
declare
  w public.workers; v_opts jsonb; v_sr text; v_id uuid; v_fee numeric := 0; v_bal numeric; v_used int; v_adds int; v_live int; v_rm int;
begin
  if auth.uid() is null then raise exception 'FORBIDDEN'; end if;
  if public.is_suspended(auth.uid()) then raise exception 'SUSPENDED'; end if;
  select * into w from public.workers where user_id = auth.uid() and deleted_at is null and delete_requested_at is null for update;
  if not found then raise exception 'NOT_A_WORKER'; end if;
  if exists (select 1 from public.profile_edit_requests where user_id = auth.uid() and status = 'pending') then raise exception 'REQUEST_PENDING'; end if;
  perform public.check_profile_changes(coalesce(p_changes, '{}'::jsonb));
  -- the starting rate must still exist after the change
  v_opts := case when p_changes ? 'price_options' then p_changes->'price_options' else w.price_options end;
  if jsonb_typeof(v_opts) <> 'array' then raise exception 'BAD_PRICE'; end if;
  v_sr := coalesce(nullif(btrim(p_changes->>'start_rate'), ''), w.start_rate);
  if not exists (select 1 from jsonb_array_elements(v_opts) o where btrim(o->>'label') = v_sr) then raise exception 'BAD_START_RATE'; end if;
  select count(*) into v_adds from public.profile_photos where user_id = auth.uid() and state = 'pending_add' and request_id is null;
  select count(*) into v_rm from public.profile_photos where user_id = auth.uid() and state = 'live' and id = any (coalesce(p_remove, '{}'));
  select count(*) into v_live from public.profile_photos where user_id = auth.uid() and state = 'live';
  if coalesce(p_changes, '{}'::jsonb) = '{}'::jsonb and v_adds = 0 and v_rm = 0 then raise exception 'NOTHING_TO_CHANGE'; end if;
  if v_live - v_rm + v_adds > public.profile_max_photos() then raise exception 'TOO_MANY_PHOTOS'; end if;
  if v_live - v_rm + v_adds < 1 then raise exception 'NO_PHOTO'; end if;

  -- the first approved request is free; later ones cost money up front (returned if it is not approved)
  select count(*) into v_used from public.profile_edit_requests where user_id = auth.uid() and status in ('approved', 'pending');
  if v_used >= 1 then
    v_fee := public.profile_edit_fee();
    select wallet_balance into v_bal from public.users where id = auth.uid() for update;
    if v_bal < v_fee then raise exception 'INSUFFICIENT_BALANCE'; end if;
  end if;
  insert into public.profile_edit_requests (user_id, changes, remove_photos, fee)
  values (auth.uid(), coalesce(p_changes, '{}'::jsonb), coalesce(p_remove, '{}'), v_fee) returning id into v_id;
  if v_fee > 0 then
    perform set_config('app.ledger_kind', 'profile_edit_fee', true);
    perform set_config('app.ledger_ref', v_id::text, true);
    update public.users set wallet_balance = wallet_balance - v_fee where id = auth.uid();
  end if;
  update public.profile_photos set request_id = v_id where user_id = auth.uid() and state = 'pending_add' and request_id is null;
  return v_id;
end $$;

-- ---------- 2) chat push --------------------------------------------------
create table if not exists public.private_config (key text primary key, value text not null);
alter table public.private_config enable row level security;
revoke all on public.private_config from anon, authenticated;

create table if not exists public.chat_push_log (
  id uuid primary key default gen_random_uuid(),
  thread_id uuid not null, recipient_id uuid not null, sent_at timestamptz not null default now()
);
create index if not exists chat_push_log_idx on public.chat_push_log (thread_id, recipient_id, sent_at desc);
alter table public.chat_push_log enable row level security;
revoke all on public.chat_push_log from anon, authenticated;

-- Run once in the SQL Editor (never from the app): where the Edge Function lives and the shared secret.
create or replace function public.configure_chat_notify(p_url text, p_secret text)
returns void language plpgsql security definer set search_path = public as $$
begin
  insert into public.private_config (key, value) values ('chat_notify_url', p_url), ('chat_notify_secret', p_secret)
  on conflict (key) do update set value = excluded.value;
end $$;
revoke all on function public.configure_chat_notify(text, text) from public, anon, authenticated;

-- A failure here must never stop a message from being sent.
create or replace function public.notify_chat_message()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  t public.chat_threads; v_to uuid; v_url text; v_secret text;
begin
  select value into v_url from public.private_config where key = 'chat_notify_url';
  select value into v_secret from public.private_config where key = 'chat_notify_secret';
  if v_url is null or v_secret is null then return new; end if;
  select * into t from public.chat_threads where id = new.thread_id;
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

do $$ begin
  begin create extension if not exists pg_net; exception when others then null; end;
end $$;
drop trigger if exists chat_message_notify on public.chat_messages;
create trigger chat_message_notify after insert on public.chat_messages
  for each row execute function public.notify_chat_message();
-- =============================================================================
