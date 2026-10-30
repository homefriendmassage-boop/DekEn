---
name: deken-storyboard
description: Turn the DekEn project (LINE LIFF booking platform) into a Thai storyboard, voice-over script and presentation video. Use when the user asks for a DekEn storyboard, presentation video, pitch/demo video, scene list, or voice-over script.
---

# DekEn → Storyboard → Video

Source of truth: `docs/DEKEN_PRESENTATION_BRIEF.md` (read it fully first), then `README.md` for details of any feature you show. Never invent features, prices or results; if the brief and the code disagree, trust the code (`src/config.js`, `supabase/migration_*.sql`) and say so.

## 0. Match the user's existing style
The user made a similar video for another project ("NPX POS"). If a storyboard / video folder of that project exists on this PC (look for `storyboard*.md`, `scenes*`, `remotion`, `video` folders), read it and **copy its structure, scene length, file naming and tooling**. If you cannot find it, ask the user once for its path; otherwise use the template in `storyboard-template.md` next to this file.

## 1. Ask before writing (one short message, Thai)
- ผู้ชม: นักลงทุน / ทีมงาน / ผู้ให้บริการ / สังกัด / ลูกค้า
- ความยาว (แนะนำ 3 นาที พรีเซนต์ภาพรวม, หรือ 60–90 วินาที ตัวย่อ)
- มีเสียงบรรยายไหม และเสียงเพศ/โทน
- ใช้ภาพจริงจากแอปหรือ Mockup (ดูข้อห้ามในหัวข้อ 8 ของ brief)

## 2. Storyboard
Write `video/storyboard.md`. One table row per scene: `# · เวลา · ภาพ/หน้าจอ · ข้อความบนจอ · เสียงบรรยาย (ไทย) · แหล่งภาพ · เอฟเฟกต์/เสียง`.
Suggested arc (adapt to the audience): ปัญหา → DekEn คืออะไร → ลูกค้า (ค้นหา, แชต, จอง) → เงินไหลอย่างไร (40/40/20) → น้อง (สมัคร, รับงาน, ถอน + ใบหัก) → โมเดลลิ่ง (หน้าสังกัด) → เซลล์ → แอดมิน (Flex + หลังบ้าน) → ความปลอดภัย → สรุปและขั้นต่อไป.
Keep each scene 4–10 seconds; one idea per scene; numbers on screen must come from brief section 6.

## 3. Voice-over
Write `video/voiceover.md`: Thai, spoken style, ≤ 2 short sentences per scene, with the scene number and target seconds. Read it aloud mentally for timing (~3 Thai syllables per 0.25 s is a safe pace).

## 4. Screens
Real-looking screens without real data: run the app in mock mode and capture with Playwright (already installed on cloud; on a PC run `npx playwright install chromium` once).
```
VITE_SUPABASE_URL=https://mock.supabase.co VITE_SUPABASE_ANON_KEY=x VITE_USE_MOCK_LIFF=true VITE_LIFF_ID= VITE_PROMPTPAY_ID=0812345678 npx vite build
npx vite preview --port 4173
```
Mock mode has no real backend: use Playwright `page.route('https://mock.supabase.co/**', …)` to return fake rows (see how earlier smoke tests did it: auth `/auth/v1/signup` + `/auth/v1/user`, `/rest/v1/users`, and `/rest/v1/rpc/<function>`), viewport 390×844. Save PNGs to `video/shots/NN-name.png` and list them in the storyboard. Use cartoon/blank avatars; never real people's photos.

## 5. Video
Build from the storyboard with whatever the user already uses (Remotion / ffmpeg slideshow / HTML + screen-record). Default if nothing exists: ffmpeg or Remotion, 1920×1080, 30 fps, Thai captions burned in, background music optional. Put output in `video/out/`. Render a short preview first and show it before the full render.

## 6. Rules
- Follow section 8 of the brief (no real people/photos/IDs/secrets; no claims of real-world results; tax and forfeiture points are "pending accountant/lawyer").
- Thai first; keep brand text "DekEn" in Latin.
- Say what is verified and what is not: features were tested with a simulated database/browser, not yet confirmed with real LINE data.
