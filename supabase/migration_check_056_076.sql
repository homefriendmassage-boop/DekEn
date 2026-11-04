-- ตรวจว่ารัน migration ถึงไหนแล้ว (056 → 076)
-- Supabase → SQL Editor → New query → วาง → Run  (อ่านอย่างเดียว ไม่แก้ข้อมูล)
-- ผลลัพธ์: คอลัมน์ ok = true แปลว่ารันแล้ว, false = ยังไม่ได้รัน (ให้รันตัวที่ false ตามลำดับเลขจากน้อยไปมาก)
with c(mig, what, ok) as (values
  ('056', 'ตาราง agency_edit_requests',
    to_regclass('public.agency_edit_requests') is not null),
  ('057', 'ตาราง worker_alive',
    to_regclass('public.worker_alive') is not null),
  ('058', 'ฟังก์ชัน agency_directory',
    exists (select 1 from pg_proc where proname = 'agency_directory' and pronamespace = 'public'::regnamespace)),
  ('059', 'ตาราง agency_boosts',
    to_regclass('public.agency_boosts') is not null),
  ('060', 'list_workers ซ่อนรายละเอียดนวด/สปา (locked)',
    coalesce((select bool_or(pg_get_functiondef(oid) like '%locked%') from pg_proc where proname = 'list_workers' and pronamespace = 'public'::regnamespace), false)),
  ('061', 'ฟังก์ชัน provider_alive',
    exists (select 1 from pg_proc where proname = 'provider_alive' and pronamespace = 'public'::regnamespace)),
  ('062', 'คอลัมน์ withdrawals.fee_percent',
    exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'withdrawals' and column_name = 'fee_percent')),
  ('063', 'ฟังก์ชัน withdraw_min_gross',
    exists (select 1 from pg_proc where proname = 'withdraw_min_gross' and pronamespace = 'public'::regnamespace)),
  ('064', 'worker_listed ไม่ผูกกับการจ่ายแพ็กเกจสังกัด',
    coalesce((select bool_and(pg_get_functiondef(oid) not like '%agency_active%') from pg_proc where proname = 'worker_listed' and pronamespace = 'public'::regnamespace), false)),
  ('065', 'ฟังก์ชัน agency_recruiter_eligible',
    exists (select 1 from pg_proc where proname = 'agency_recruiter_eligible' and pronamespace = 'public'::regnamespace)),
  ('066', 'ฟังก์ชัน seller_only_via_agency',
    exists (select 1 from pg_proc where proname = 'seller_only_via_agency' and pronamespace = 'public'::regnamespace)),
  ('067', 'booking_recruiter (สังกัดที่จ่ายแล้วก่อน) หรือเวอร์ชันใหม่กว่า',
    coalesce((select bool_or(pg_get_functiondef(oid) like '%1) her agency%' or pg_get_functiondef(oid) like '%agency_earns_on%') from pg_proc where proname = 'booking_recruiter' and pronamespace = 'public'::regnamespace), false)),
  ('068', 'normalize_worker_profile มีรายการแท็กใหม่',
    coalesce((select bool_or(pg_get_functiondef(oid) like '%ordination%') from pg_proc where proname = 'normalize_worker_profile' and pronamespace = 'public'::regnamespace), false)),
  ('069', 'ตาราง agency_seats (ที่นั่งสังกัด)',
    to_regclass('public.agency_seats') is not null),
  ('070', 'agency_earns_on ให้สังกัดที่จ่ายแล้วได้ทุกน้อง',
    coalesce((select bool_or(pg_get_functiondef(oid) like '%PAID agency (and a girl besides its owner): every girl%') from pg_proc where proname = 'agency_earns_on' and pronamespace = 'public'::regnamespace), false)),
  ('071', 'ตาราง help_videos (คลิปวิธีใช้งาน)',
    to_regclass('public.help_videos') is not null),
  ('072', 'หน้าชัดฟรี ชงเหล้า 4 / ENT 4 / หมอนวด 2',
    coalesce((select bool_or(pg_get_functiondef(oid) like '%when ''bartender'' then 4 when ''ent'' then 4%') from pg_proc where proname = 'ranked_workers' and pronamespace = 'public'::regnamespace), false)),
  ('073', 'จัดอันดับน้องในหน้าสังกัด (คอลัมน์ agency_sort)',
    exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'workers' and column_name = 'agency_sort')),
  ('074', 'ตรวจรูปตัวอย่าง (ตาราง teaser_flags)',
    to_regclass('public.teaser_flags') is not null),
  ('075', 'กติกาการจองใหม่ (ตาราง job_events)',
    to_regclass('public.job_events') is not null),
  ('076', 'สังกัดแก้รูปน้อง (คอลัมน์ requested_by)',
    exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'profile_edit_requests' and column_name = 'requested_by'))
)
select mig as migration, what as ตรวจอะไร, ok
  from c
union all
select 'สรุป', 'รันถึงเลขล่าสุดที่ ok ต่อเนื่องจาก 056', true
 where false
union all
select 'สรุป',
       coalesce('ยังไม่ได้รัน: ' || (select string_agg(mig, ', ' order by mig) from c where not ok), 'ครบทุกตัว'),
       not exists (select 1 from c where not ok)
order by 1;
