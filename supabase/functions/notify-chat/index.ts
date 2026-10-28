// Supabase Edge Function: LINE push (Flex) from the database. Two kinds of calls:
//   { thread_id, recipient_id, sender_id }          a new chat message is waiting -> the button opens that chat room
//   { type: 'booking', event, job_id }              a booking event (new / accepted / declined / expired / arrived / completed / ...)
//                                                    -> the button opens that booking (LIFF ?job=<id>)
//
// Called by the database (trigger notify_chat_message on chat_messages, through pg_net), NOT by the browser:
// it is protected by a shared secret header instead of a login. Deploy with "Verify JWT" OFF.
//
// Secrets (Edge Functions > Secrets):
//   LINE_CHANNEL_ACCESS_TOKEN  channel access token of the Official Account (same one send-renewal uses)
//   LIFF_ID                    your LIFF id
//   CHAT_NOTIFY_SECRET         any long random text; the SAME text is given to the database (configure_chat_notify)
//   APP_URL                    (optional) https://<user>.github.io/<repo> so the card can show the logo
//
// A LINE push counts against the OA's monthly quota; the database sends at most one per chat per 10 minutes.

import { createClient } from 'npm:@supabase/supabase-js@2'

const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } })

// ---- BEGIN pure rules ---------------------------------------------------------------------------
export function buildChatFlex(o: { senderName: string; liffId: string; threadId: string; logo?: string }) {
  const url = `https://liff.line.me/${o.liffId}?chat=${o.threadId}`
  const header = o.logo
    ? [{ type: 'image', url: o.logo, size: '40px', aspectMode: 'cover', aspectRatio: '1:1', flex: 0 }]
    : []
  return {
    type: 'flex',
    altText: `💬 มีข้อความใหม่จาก ${o.senderName}`,
    contents: {
      type: 'bubble', size: 'kilo',
      styles: { body: { backgroundColor: '#161616' }, footer: { backgroundColor: '#161616' } },
      body: {
        type: 'box', layout: 'vertical', spacing: 'md', paddingAll: 'xl',
        contents: [
          { type: 'box', layout: 'horizontal', spacing: 'md', alignItems: 'center', contents: [
            ...header,
            { type: 'text', text: '💬 ข้อความใหม่', weight: 'bold', size: 'md', color: '#F472B6', gravity: 'center' },
          ] },
          { type: 'text', text: `${o.senderName} ส่งข้อความถึงคุณ`, weight: 'bold', size: 'lg', color: '#FFFFFF', wrap: true },
          { type: 'text', text: 'กดปุ่มเพื่อเปิดห้องแชตและตอบกลับ', size: 'sm', color: '#BBBBBB', wrap: true },
        ],
      },
      footer: {
        type: 'box', layout: 'vertical', paddingAll: 'lg',
        contents: [{ type: 'button', style: 'primary', color: '#EC4899', height: 'md', action: { type: 'uri', label: 'เปิดห้องแชต', uri: url } }],
      },
    },
  }
}

const RATE: Record<string, string> = { '1h': 'รายชั่วโมง', '@4h': '4 ชั่วโมง', '@6h': '6 ชั่วโมง', '@60': '60 นาที', '@90': '90 นาที', '@120': '120 นาที' }
const baht = (n: number) => `${Number(n).toLocaleString('en-US')} บาท`
const when = (v: string) => new Date(v).toLocaleString('th-TH', { timeZone: 'Asia/Bangkok', dateStyle: 'medium', timeStyle: 'short' })

// One booking event -> { to: 'worker' | 'customer', flex } (null when nobody needs to hear about it)
export function buildBookingFlex(o: { event: string; jobId: string; liffId: { worker: string; customer: string }; customer: string; worker: string; rate: string; price: number; at: string; place?: string; source?: string; logo?: string }) {
  const rate = RATE[o.rate] ?? o.rate
  const line = (text: string, extra: Record<string, unknown> = {}) => ({ type: 'text', text, wrap: true, size: 'sm', color: '#DDDDDD', ...extra })
  const card = (to: 'worker' | 'customer', head: string, title: string, lines: string[], button: string, color = '#EC4899') => ({
    to, url: `https://liff.line.me/${o.liffId[to]}?job=${o.jobId}`,
    flex: {
      type: 'flex', altText: `${head} ${title}`,
      contents: {
        type: 'bubble', size: 'kilo',
        styles: { body: { backgroundColor: '#161616' }, footer: { backgroundColor: '#161616' } },
        body: { type: 'box', layout: 'vertical', spacing: 'md', paddingAll: 'xl', contents: [
          { type: 'box', layout: 'horizontal', spacing: 'md', alignItems: 'center', contents: [
            ...(o.logo ? [{ type: 'image', url: o.logo, size: '40px', aspectMode: 'cover', aspectRatio: '1:1', flex: 0 }] : []),
            { type: 'text', text: head, weight: 'bold', size: 'md', color, gravity: 'center' },
          ] },
          { type: 'text', text: title, weight: 'bold', size: 'lg', color: '#FFFFFF', wrap: true },
          ...lines.map((l) => line(l)),
        ] },
        footer: { type: 'box', layout: 'vertical', paddingAll: 'lg', contents: [{ type: 'button', style: 'primary', color, height: 'md', action: { type: 'uri', label: button, uri: `https://liff.line.me/${o.liffId[to]}?job=${o.jobId}` } }] },
      },
    },
  })
  const when1 = `นัด: ${when(o.at)}`
  switch (o.event) {
    case 'new': return card('worker', '🔔 มีการจองใหม่', `${o.customer} จอง ${rate}`, [...(o.source ? [`ลูกค้าจาก: ${o.source}`] : []), when1, `ค่าบริการที่คุณได้รับ (เงินสด): ${baht(o.price)}`, ...(o.place ? [`สถานที่: ${o.place}`] : []), 'ตอบรับภายใน 30 นาที ไม่เช่นนั้นงานจะถูกยกเลิก', 'เบอร์และตำแหน่งลูกค้าจะแสดงหลังคุณกดรับงาน'], 'เปิดดูและตอบรับ')
    case 'accepted': return card('customer', '✅ น้องรับงานแล้ว', `${o.worker} รับงานของคุณแล้ว`, [when1, `เรท: ${rate}`, `จ่ายตรงให้น้องเมื่อพบกัน: ${baht(o.price)}`, 'ดูเบอร์ติดต่อและสถานะได้ที่หน้าการจอง'], 'ดูรายละเอียดการจอง', '#06C755')
    case 'declined': return card('customer', '❌ น้องปฏิเสธงาน', `${o.worker} ไม่สะดวกรับงานนี้`, ['ค่าธรรมเนียมแพลตฟอร์ม 500 บาท คืนเข้า Wallet ของคุณแล้ว'], 'ดูการจอง', '#F59E0B')
    case 'expired': return card('customer', '⏰ งานถูกยกเลิก', `${o.worker} ไม่ได้ตอบภายใน 30 นาที`, ['ค่าธรรมเนียมแพลตฟอร์ม 500 บาท คืนเข้า Wallet ของคุณแล้ว', 'เลือกคนใหม่ได้เลย'], 'ดูการจอง', '#F59E0B')
    case 'missed': return card('worker', '⏰ งานถูกยกเลิก', `คุณไม่ได้ตอบรับงานของ ${o.customer} ภายใน 30 นาที`, ['ครั้งต่อไปกรุณาตอบรับหรือปฏิเสธให้เร็วขึ้น'], 'เปิดแอป', '#F59E0B')
    case 'customer': return card('worker', '↩️ ลูกค้ายกเลิกคำขอ', `${o.customer} ยกเลิกการจอง`, [when1], 'เปิดแอป', '#F59E0B')
    case 'arrived': return card('customer', '📍 น้องถึงแล้ว', `${o.worker} ถึงจุดนัดหมายแล้ว`, [when1], 'ดูรายละเอียดการจอง', '#06C755')
    case 'completed': return card('customer', '🎉 งานเสร็จสิ้น', 'ขอบคุณที่ใช้บริการ', [`งานกับ ${o.worker} เสร็จสิ้นแล้ว`], 'ดูการจอง', '#06C755')
    case 'worker_cancelled': return card('customer', '⚠️ น้องยกเลิกงาน', `${o.worker} ยกเลิกงานหลังรับแล้ว`, ['กรุณาติดต่อแอดมินเพื่อขอคืนค่าธรรมเนียม'], 'ดูการจอง', '#EF4444')
    default: return null
  }
}
// ---- END pure rules -----------------------------------------------------------------------------

// Who gets the push and through which OA: a vendor's customer is reached by the vendor's OA (his token and LIFF), everybody else by ours.
async function recipient(admin: ReturnType<typeof createClient>, userId: string, central: { token: string; liffId: string }) {
  const { data: u } = await admin.from('users').select('line_user_id, vendor_id').eq('id', userId).maybeSingle()
  if (!u?.line_user_id) return null
  if (!u.vendor_id) return { lineId: u.line_user_id as string, token: central.token, liffId: central.liffId }
  const { data: tok } = await admin.rpc('vendor_token', { p_vendor: u.vendor_id })
  const { data: v } = await admin.from('vendors').select('liff_id').eq('id', u.vendor_id).maybeSingle()
  if (!tok || !v) return null
  return { lineId: String(u.line_user_id).split(':').pop() as string, token: tok as string, liffId: v.liff_id as string }
}

Deno.serve(async (req) => {
  const secret = Deno.env.get('CHAT_NOTIFY_SECRET')
  const token = Deno.env.get('LINE_CHANNEL_ACCESS_TOKEN')
  const liffId = Deno.env.get('LIFF_ID')
  if (!secret || !token || !liffId) return json({ ok: false, code: 'CONFIG_MISSING' }, 500)
  if (req.headers.get('x-webhook-secret') !== secret) return json({ ok: false, code: 'FORBIDDEN' }, 403)

  const input = await req.json().catch(() => ({}))
  const { thread_id, recipient_id, sender_id } = input
  const isBooking = input.type === 'booking'
  if (!isBooking && (!thread_id || !recipient_id || !sender_id)) return json({ ok: false, code: 'BAD_INPUT' }, 400)
  if (isBooking && (!input.job_id || !input.event)) return json({ ok: false, code: 'BAD_INPUT' }, 400)

  const admin = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!)

  const central = { token, liffId }
  if (isBooking) {
    const { data: job } = await admin.from('jobs').select('id, customer_id, worker_id, rate_label, service_price, scheduled_at, place_note, source_label').eq('id', input.job_id).maybeSingle()
    if (!job) return json({ ok: false, code: 'NOT_FOUND' }, 404)
    const { data: cu } = await admin.from('users').select('display_name').eq('id', job.customer_id).maybeSingle()
    const { data: ww } = await admin.from('workers').select('display_name').eq('user_id', job.worker_id).maybeSingle()
    const rw = await recipient(admin, job.worker_id, central)
    const rc = await recipient(admin, job.customer_id, central)
    const appUrl = Deno.env.get('APP_URL')?.replace(/\/$/, '')
    const results: unknown[] = []
    // a missed / expired booking tells both sides
    const events = input.event === 'expired' ? ['expired', 'missed'] : [input.event]
    for (const ev of events) {
      const card = buildBookingFlex({ event: ev, jobId: job.id, liffId: { worker: rw?.liffId ?? liffId, customer: rc?.liffId ?? liffId }, customer: cu?.display_name ?? 'ลูกค้า', worker: ww?.display_name ?? 'น้อง', rate: job.rate_label ?? '', price: Number(job.service_price), at: job.scheduled_at, place: job.place_note ?? undefined, source: job.source_label ?? undefined, logo: appUrl ? `${appUrl}/dekn-logo.jpg?v=2` : undefined })
      if (!card) { results.push({ event: ev, status: 'SKIPPED' }); continue }
      const rcp = card.to === 'worker' ? rw : rc
      if (!rcp || !/^U[0-9a-f]{32}$/.test(rcp.lineId)) { results.push({ event: ev, status: 'NO_LINE_ID' }); continue }
      const r = await fetch('https://api.line.me/v2/bot/message/push', {
        method: 'POST',
        headers: { Authorization: `Bearer ${rcp.token}`, 'Content-Type': 'application/json', 'X-Line-Retry-Key': crypto.randomUUID() },
        body: JSON.stringify({ to: rcp.lineId, messages: [card.flex] }),
      })
      results.push({ event: ev, status: r.ok ? 'SENT' : 'FAILED' })
    }
    return json({ ok: true, results })
  }
  const to = await recipient(admin, recipient_id, central)
  if (!to || !/^U[0-9a-f]{32}$/.test(to.lineId)) return json({ ok: true, status: 'NO_LINE_ID' })   // mock / anonymous accounts

  // Providers are known by their stage name, customers by their LINE name
  const { data: w } = await admin.from('workers').select('display_name').eq('user_id', sender_id).maybeSingle()
  const { data: u } = await admin.from('users').select('display_name').eq('id', sender_id).maybeSingle()
  const senderName = String(w?.display_name ?? u?.display_name ?? 'สมาชิก').slice(0, 40)

  const appUrl = Deno.env.get('APP_URL')?.replace(/\/$/, '')
  const message = buildChatFlex({ senderName, liffId: to.liffId, threadId: thread_id, logo: appUrl ? `${appUrl}/dekn-logo.jpg?v=2` : undefined })
  const r = await fetch('https://api.line.me/v2/bot/message/push', {
    method: 'POST',
    headers: { Authorization: `Bearer ${to.token}`, 'Content-Type': 'application/json', 'X-Line-Retry-Key': crypto.randomUUID() },
    body: JSON.stringify({ to: to.lineId, messages: [message] }),
  })
  if (r.ok) return json({ ok: true, status: 'SENT' })
  const body = await r.json().catch(() => null)
  return json({ ok: false, status: 'FAILED', detail: String(body?.message ?? r.status).slice(0, 200) })
})
