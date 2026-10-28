-- =============================================================================
-- migration_029.sql — run ONCE after migration_028.sql
-- Stricter and fuzzier contact filter:
--   * misspelled / shortened words are caught: "ขอเบอ", "เบอ", "ไอดี", "ไลน์", "ไลน", "ทักไลน์", "line", "ig", "fb" ...
--     (tone marks and spaces/dots between the letters are ignored: "เ บ อ ร์", "ไ ล น์")
--   * a number sent in pieces is caught: "089" then "748" then "6543" -> the message that makes 9 digits is refused
-- =============================================================================

-- Thai / full-width digits and number words -> plain digits
create or replace function public.contact_numbers(p_text text)
returns text language plpgsql immutable set search_path = public as $$
declare s text := lower(coalesce(p_text, ''));
begin
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
  return s;
end $$;

-- true when the text is only digits / number words and separators
create or replace function public.is_number_only(p_text text)
returns boolean language sql immutable set search_path = public as $$
  select regexp_replace(public.contact_numbers(p_text), '[0-9\s._()+,-]', '', 'g') = ''
     and public.contact_numbers(p_text) ~ '[0-9]'
$$;

create or replace function public.contact_problem(p_text text)
returns text language plpgsql immutable set search_path = public as $$
declare
  s text := lower(coalesce(p_text, ''));
  c text;
  w text;
begin
  -- Google Maps links are allowed: take them out first (the host must END there, so maps.google.com.evil.com stays)
  s := regexp_replace(s, '(https?://)?(www\.)?(maps\.app\.goo\.gl|maps\.google\.(com|co\.th)|google\.(com|co\.th)/maps|goo\.gl/maps)(/[^\s]*|\?[^\s]*|#[^\s]*)?(?=\s|$)', ' ', 'g');

  if s ~ 'https?://' or s ~ 'www\.' or s ~ '[a-z0-9-]+\.(com|net|org|info|biz|co|th|me|io|app|link|ly|gl|ee|be|xyz|cc|tv|bz|asia|shop|site|online|store)(\M|/)'
     or s ~ '(line\.me|lin\.ee|t\.me|wa\.me|bit\.ly|tinyurl|fb\.com|youtu\.be)' then
    return 'LINK';
  end if;
  if s ~ '[a-z0-9._%+-]+@[a-z0-9.-]+' or s ~ '(^|[^a-z0-9])@[a-z0-9._-]{3,}' then return 'HANDLE'; end if;

  -- words: ignore tone marks and the spaces / dots / dashes people put between letters
  c := regexp_replace(s, '[\s.\-_*,~`|/\\''"()่้๊๋์็]', '', 'g');
  c := replace(replace(replace(c, 'ออนไลน', ''), 'ออฟไลน', ''), 'เบอรเกอ', '');
  foreach w in array array['เบอ', 'ไอดี', 'ไลน', 'ไอจี', 'อินสตา', 'เฟสบุค', 'เฟซบุค', 'เฟสบุก', 'วีแชท', 'พร้อมเพย', 'เลขบัญ', 'บัญชีธนาคาร',
                           'โทรหา', 'โทรมา', 'โทรกลับ', 'ติดต่อส่วนตัว', 'whatsapp', 'telegram', 'wechat', 'instagram', 'facebook',
                           'promptpay', 'lineid', 'idline', 'addline', 'kakao', 'viber'] loop
    if position(w in c) > 0 then return 'WORD'; end if;
  end loop;
  if s ~ '(^|[^a-z0-9])(line|ig|fb|id)([^a-z0-9]|$)' then return 'WORD'; end if;

  -- numbers: 9+ digits in a row, separators allowed
  s := public.contact_numbers(s);
  if s ~ '([0-9][\s._()+-]*){9,}' then return 'NUMBER'; end if;
  return null;
end $$;
revoke all on function public.contact_numbers(text), public.is_number_only(text), public.contact_problem(text) from public, anon;
grant execute on function public.contact_numbers(text), public.is_number_only(text), public.contact_problem(text) to authenticated;

create or replace function public.send_message(p_thread uuid, p_body text, p_accept_fee boolean default false)
returns void language plpgsql security definer set search_path = public as $$
declare
  t   public.chat_threads;
  b   text := btrim(p_body);
  v_msg uuid;
  v_bal numeric;
  v_fee uuid;
  v_worker_side boolean;
  v_digits int;
  v_prior int;
begin
  select * into t from public.chat_threads
   where id = p_thread and (auth.uid() in (customer_id, worker_id) or public.is_agency_of(auth.uid(), worker_id)) for update;
  if not found then raise exception 'FORBIDDEN'; end if;
  v_worker_side := auth.uid() <> t.customer_id;
  if b is null or char_length(b) not between 1 and 500 then raise exception 'BAD_MESSAGE'; end if;
  -- no phone numbers, bank accounts, IDs or links (Google Maps links are fine): checked BEFORE any fee is held
  if public.contact_problem(b) is not null then raise exception 'CONTACT_BLOCKED'; end if;
  -- a number sent in pieces ("089", then "748", ...): this message plus the sender's earlier number-only messages of the last 30 minutes
  if public.is_number_only(b) then
    select coalesce(sum(char_length(regexp_replace(public.contact_numbers(m.body), '[^0-9]', '', 'g'))), 0) into v_prior
      from (select body from public.chat_messages
             where thread_id = p_thread and sender_id = auth.uid() and created_at > now() - interval '30 minutes'
             order by created_at desc limit 8) m
     where public.is_number_only(m.body);
    v_digits := v_prior + char_length(regexp_replace(public.contact_numbers(b), '[^0-9]', '', 'g'));
    if v_prior > 0 and v_digits >= 9 then raise exception 'CONTACT_BLOCKED'; end if;
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
end $$;
-- =============================================================================
