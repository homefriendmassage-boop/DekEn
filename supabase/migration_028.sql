-- =============================================================================
-- migration_028.sql — run ONCE after migration_027.sql
-- Contact details can no longer be exchanged through the platform:
--   * chat messages (send_message) and the public profile text (about / name / nearby / district) are checked
--   * blocked: phone numbers and account numbers (9+ digits, also written in Thai digits, full-width digits or as words
--     in Thai / English, with spaces . - _ between them), links of any kind EXCEPT Google Maps, @handles and e-mail,
--     and words such as "line id", whatsapp, telegram, wechat, "เบอร์โทร", "เลขบัญชี", promptpay
--   * a blocked chat message raises CONTACT_BLOCKED before any chat fee is held
-- =============================================================================

create or replace function public.contact_problem(p_text text)
returns text language plpgsql immutable set search_path = public as $$
declare
  s text := lower(coalesce(p_text, ''));
  w text;
begin
  -- Google Maps links are allowed: take them out first (the host must END there, so maps.google.com.evil.com stays)
  s := regexp_replace(s, '(https?://)?(www\.)?(maps\.app\.goo\.gl|maps\.google\.(com|co\.th)|google\.(com|co\.th)/maps|goo\.gl/maps)(/[^\s]*|\?[^\s]*|#[^\s]*)?(?=\s|$)', ' ', 'g');

  if s ~ 'https?://' or s ~ 'www\.' or s ~ '[a-z0-9-]+\.(com|net|org|info|biz|co|th|me|io|app|link|ly|gl|ee|be|xyz|cc|tv|bz|asia|shop|site|online|store)(\M|/)'
     or s ~ '(line\.me|lin\.ee|t\.me|wa\.me|bit\.ly|tinyurl|fb\.com|youtu\.be)' then
    return 'LINK';
  end if;
  if s ~ '[a-z0-9._%+-]+@[a-z0-9.-]+' or s ~ '(^|[^a-z0-9])@[a-z0-9._-]{3,}' then return 'HANDLE'; end if;

  foreach w in array array['line id', 'lineid', 'id line', 'add line', 'whatsapp', 'whats app', 'telegram', 'wechat', 'instagram',
                           'facebook', 'promptpay', 'วีแชท', 'พร้อมเพย์', 'ไลน์ไอดี', 'ไอดีไลน์', 'แอดไลน์', 'เบอร์โทร', 'ขอเบอร์',
                           'เบอร์ไลน์', 'เลขบัญชี', 'เลขที่บัญชี'] loop
    if position(w in s) > 0 then return 'WORD'; end if;
  end loop;

  -- numbers: Thai / full-width digits and number words become plain digits, then look for 9+ digits in a row
  s := translate(s, '๐๑๒๓๔๕๖๗๘๙０１２３４５６７８９', '01234567890123456789');
  s := regexp_replace(s, '\m(zero|oh)\M', '0', 'g');
  s := regexp_replace(s, '\mone\M', '1', 'g');
  s := regexp_replace(s, '\mtwo\M', '2', 'g');
  s := regexp_replace(s, '\mthree\M', '3', 'g');
  s := regexp_replace(s, '\mfour\M', '4', 'g');
  s := regexp_replace(s, '\mfive\M', '5', 'g');
  s := regexp_replace(s, '\msix\M', '6', 'g');
  s := regexp_replace(s, '\mseven\M', '7', 'g');
  s := regexp_replace(s, '\meight\M', '8', 'g');
  s := regexp_replace(s, '\mnine\M', '9', 'g');
  s := replace(replace(replace(replace(replace(s, 'ศูนย์', '0'), 'หนึ่ง', '1'), 'สอง', '2'), 'สาม', '3'), 'สี่', '4');
  s := replace(replace(replace(replace(replace(s, 'ห้า', '5'), 'หก', '6'), 'เจ็ด', '7'), 'แปด', '8'), 'เก้า', '9');
  s := regexp_replace(s, '(?<=[0-9])o(?=[0-9o])', '0', 'g');
  if s ~ '([0-9][\s._()+-]*){9,}' then return 'NUMBER'; end if;
  return null;
end $$;
revoke all on function public.contact_problem(text) from public, anon;
grant execute on function public.contact_problem(text) to authenticated;

create or replace function public.send_message(p_thread uuid, p_body text, p_accept_fee boolean default false)
returns void language plpgsql security definer set search_path = public as $$
declare
  t   public.chat_threads;
  b   text := btrim(p_body);
  v_msg uuid;
  v_bal numeric;
  v_fee uuid;
  v_worker_side boolean;
begin
  select * into t from public.chat_threads
   where id = p_thread and (auth.uid() in (customer_id, worker_id) or public.is_agency_of(auth.uid(), worker_id)) for update;
  if not found then raise exception 'FORBIDDEN'; end if;
  v_worker_side := auth.uid() <> t.customer_id;
  if b is null or char_length(b) not between 1 and 500 then raise exception 'BAD_MESSAGE'; end if;
  -- no phone numbers, bank accounts, IDs or links (Google Maps links are fine): checked BEFORE any fee is held
  if public.contact_problem(b) is not null then raise exception 'CONTACT_BLOCKED'; end if;
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
end $$;

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
  -- contact details must not hide in the public profile text either (only checked when the text is new or changed)
  if tg_op = 'INSERT' or new.about is distinct from old.about or new.display_name is distinct from old.display_name
     or new.nearby is distinct from old.nearby or new.district is distinct from old.district then
    if public.contact_problem(concat_ws(' | ', new.display_name, new.about, new.nearby, new.district)) is not null then
      raise exception 'CONTACT_IN_PROFILE';
    end if;
  end if;

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
-- =============================================================================
