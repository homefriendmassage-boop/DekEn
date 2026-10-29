-- =============================================================================
-- เพิ่มน้องจำนวนมาก (ต้องรัน migration_046.sql ก่อน)   Supabase → SQL Editor → New query
--
-- ขั้นที่ 1: แก้ใบนี้ แล้วกด Run  → ระบบสร้าง "แบบร่าง" ให้น้องทุกแถว (ยังไม่แสดงลูกค้า)
--   - แทน <ADMIN-ID> ด้วยรหัสแอดมินของคุณ (หาได้จาก: select id, display_name from public.users where id in (select user_id from public.admins);)
--   - 1 แถว = น้อง 1 คน  ลำดับคอลัมน์ต้องตามหัวตารางด้านล่าง  ไม่มีข้อมูล ใส่ null
--   - grp = 'night' (ชงเหล้า/ENT)  หรือ 'spa' (หมอนวด/สปา)
--   - category: night = bartender หรือ ent  |  spa = masseuse หรือ spa   (ใส่หลายอย่างคั่น , ได้ เช่น 'bartender,ent')
--   - gender: female | male | lgbt     อายุต้อง 20 ปีขึ้นไป
--   - ราคา (เงินสดที่น้องได้รับ): night = p4h, p6h, p1h  |  spa = p60, p90, p120  ใส่เฉพาะที่มี อย่างน้อย 1 ช่อง
--     (ช่องแรกที่ใส่ จะเป็นราคาเริ่มต้นอัตโนมัติ)
--   - tags: night = playful,fun_talk,not_picky,sing,dance,drinks,friendly
--           spa   = thai_massage,oil,foot,aroma,sports,scrub,polite,punctual,experienced
--   - mode (เฉพาะ spa): shop (ที่ร้าน) | outcall (ไปหาลูกค้า) | both
--   - province: ชื่อจังหวัดแบบเต็มตามรายการ เช่น 'กรุงเทพมหานคร', 'จันทบุรี'  (ต้องใส่ ถึงจะเผยแพร่ได้)
--   - ห้ามใส่เบอร์โทร/ไอดี/ลิงก์ในช่อง name, about, district, nearby
--   - phone / line_id = ช่องทางติดต่อที่น้องจะให้ลูกค้าหลังกดรับงาน (ใส่หรือไม่ใส่ก็ได้)
-- =============================================================================
select * from public.bulk_create_drafts('<ADMIN-ID>'::uuid, (
  select jsonb_agg(to_jsonb(t)) from (values
    ('มายด์',  'night', 'bartender',   'female', 25, 165, 50, '34-24-35', 'จันทบุรี', 'เมือง', null, 'คุยสนุก ไม่หวงตัว', 'playful,sing', 3000, 5000, 800,  null, null, null, null,   '0812345678', null, null),
    ('พลอย',   'night', 'ent',         'female', 27, 168, 52, null,       'กรุงเทพมหานคร', 'ห้วยขวาง', null, 'ร้องเพลงเพราะ', 'sing,dance', 3500, null, null, null, null, null, null, null, 'ploy_line', null),
    ('นุ่น',   'spa',   'masseuse',    'female', 30, 160, 48, null,       'เชียงใหม่', 'เมือง', 'ใกล้ถนนนิมมาน', 'นวดแผนไทย มือหนัก', 'thai_massage,polite', null, null, null, 600, 900, 1200, 'both', null, null, null)
  ) as t(name, grp, category, gender, age, height, weight, measurements, province, district, nearby, about, tags, p4h, p6h, p1h, p60, p90, p120, mode, phone, line_id, note)
));
-- ผลลัพธ์จะแสดงรายชื่อแบบร่างที่สร้างแล้ว

-- =============================================================================
-- ขั้นที่ 2 (ในแอป ไม่ใช่ SQL): Admin → แท็บ "➕ แบบร่างให้น้อง" → เปิดแบบร่างของน้องแต่ละคน → เพิ่มรูป (ลากวงกลมปิดหน้า) → บันทึก
--          ไม่ต้องกด "เปิดโปรไฟล์ทันที" ในแอป
--
-- ขั้นที่ 3: เมื่อใส่รูปครบแล้ว รันอันนี้ครั้งเดียว → เผยแพร่ทุกแบบร่างที่มีรูปและมีจังหวัด
--   - 'photo' = ตรวจอายุจากรูป | 'video_call' | 'in_person' | 'id_card'   (ต้องตรวจจริง ระบบบันทึกชื่อแอดมินและเวลา)
--   - ข้อความ consent = ช่องทางที่ได้รับความยินยอมจากน้อง (อย่างน้อย 3 ตัวอักษร)
-- =============================================================================
-- select * from public.bulk_publish_drafts('<ADMIN-ID>'::uuid, 'video_call', 'ได้รับความยินยอมจากน้องทาง LINE วิดีโอคอล');
