-- =============================================================================
-- เอาน้อง Demo ออก (ที่มาจาก seed.sql / seed2.sql)   Supabase → SQL Editor → New query
-- =============================================================================

-- 1) ดูก่อนว่ามีกี่คน
select count(*) as demo_accounts from auth.users where email like 'demo%@example.invalid';

-- 2a) วิธีปลอดภัย (แนะนำ): ซ่อนออกจากหน้าลูกค้า แต่ข้อมูลยังอยู่ (ย้อนกลับได้)
update public.workers set admin_hidden = true
 where user_id in (select id from auth.users where email like 'demo%@example.invalid');

-- 2b) วิธีลบถาวร (ถ้าแน่ใจ) — ถ้ามีการจอง/แชตผูกอยู่ ระบบจะไม่ยอมลบและแจ้ง error ให้ใช้วิธี 2a แทน
-- delete from auth.users where email like 'demo%@example.invalid';
