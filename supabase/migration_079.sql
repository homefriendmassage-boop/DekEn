-- =============================================================================
-- migration_079.sql — run ONCE after migration_078.sql
-- Chat filter: more code words people use to move the conversation to another channel
--   (บ้านฟ้า / บ้านเขียว / บ้านดำ / บ้านแดง, ช่องเขียว / ช่องฟ้า / ช่องแดง / ช่องดำ, แอดลาย). A message with one of them is blocked and counts
--   like any other contact attempt (flags, suspension). The app answers the sender with the official LINE (@deken) to use instead.
-- =============================================================================
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
                           'promptpay', 'lineid', 'idline', 'addline', 'kakao', 'viber',
                           -- code words for the colour of a LINE chat / OA / "add line" (tone marks are removed before the check)
                           'บานฟา', 'บานเขียว', 'บานดำ', 'บานแดง', 'ชองเขียว', 'ชองฟา', 'ชองแดง', 'ชองดำ', 'แอดลาย'] loop
    if position(w in c) > 0 then return 'WORD'; end if;
  end loop;
  if s ~ '(^|[^a-z0-9])(line|ig|fb|id)([^a-z0-9]|$)' then return 'WORD'; end if;

  -- numbers: 9+ digits in a row, separators allowed
  s := public.contact_numbers(s);
  if s ~ '([0-9][\s._()+-]*){9,}' then return 'NUMBER'; end if;
  return null;
end $$;

revoke all on function public.contact_problem(text) from public, anon;
grant execute on function public.contact_problem(text) to authenticated;
