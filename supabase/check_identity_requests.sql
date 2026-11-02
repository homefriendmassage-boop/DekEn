-- ดูคำขอยืนยันตัวตนทั้งหมด (อ่านอย่างเดียว) — Supabase → SQL Editor → New query → วาง → Run
select p.full_name as ชื่อในบัตร, u.display_name as ชื่อใน_LINE, p.status as สถานะ,
       p.id_last4 as บัตรลงท้าย, p.reject_reason as เหตุผลปฏิเสธ,
       to_char(p.created_at at time zone 'Asia/Bangkok', 'DD/MM/YY HH24:MI') as ส่งเมื่อ,
       to_char(p.verified_at at time zone 'Asia/Bangkok', 'DD/MM/YY HH24:MI') as ตรวจเมื่อ
  from public.payout_profiles p
  join public.users u on u.id = p.user_id
 order by p.created_at desc
 limit 20;
