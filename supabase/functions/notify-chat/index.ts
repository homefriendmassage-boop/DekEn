// Supabase Edge Function: LINE push (Flex) from the database. Two kinds of calls:
//   { thread_id, recipient_id, sender_id }          a new chat message is waiting -> the button opens that chat room
//   { type: 'booking', event, job_id }              a booking event (new / accepted / declined / expired / arrived / completed / ...)
//                                                    -> the button opens that booking (LIFF ?job=<id>)
//   { type: 'support', event: 'incoming' | 'reply', thread_id }   a seller's customer wrote to the seller's staff / the staff answered
//                                                    (sent through the SELLER's OA with his token; the button opens ?support=<thread>)
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
export function buildBookingFlex(o: { event: string; jobId: string; liffId: { worker: string; customer: string }; customer: string; worker: string; rate: string; price: number; at: string; place?: string; source?: string; logo?: string; fee?: number; travel?: string; workerPlace?: string }) {
  const fee = o.fee ?? 500
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
    case 'new': return card('worker', '🔔 มีการจองใหม่', `${o.customer} จอง ${rate}`, [...(o.source ? [`ลูกค้าจาก: ${o.source}`] : []), when1, `ค่าบริการที่คุณได้รับ (เงินสด): ${baht(o.price)}`, ...(o.travel === 'customer_goes' ? ['ลูกค้าจะเดินทางไปหาคุณ: กรุณากรอกชื่อสถานที่/เลขห้องตอนกดรับงาน'] : o.place ? [`สถานที่: ${o.place}`] : []), 'ตอบรับภายใน 30 นาที ไม่เช่นนั้นงานจะถูกยกเลิก', 'เบอร์และตำแหน่งลูกค้าจะแสดงหลังคุณกดรับงาน'], 'เปิดดูและตอบรับ')
    case 'accepted': return card('customer', '✅ น้องรับงานแล้ว', `${o.worker} รับงานของคุณแล้ว`, [when1, `เรท: ${rate}`, `จ่ายตรงให้น้องเมื่อพบกัน: ${baht(o.price)}`, ...(o.workerPlace ? [`สถานที่ที่น้องแจ้ง: ${o.workerPlace}`] : []), 'ดูเบอร์ติดต่อและสถานะได้ที่หน้าการจอง'], 'ดูรายละเอียดการจอง', '#06C755')
    case 'declined': return card('customer', '❌ น้องปฏิเสธงาน', `${o.worker} ไม่สะดวกรับงานนี้`, [`ค่าธรรมเนียมแพลตฟอร์ม ${fee} บาท คืนเข้า Wallet ของคุณแล้ว`], 'ดูการจอง', '#F59E0B')
    case 'expired': return card('customer', '⏰ งานถูกยกเลิก', `${o.worker} ไม่ได้ตอบภายใน 30 นาที`, [`ค่าธรรมเนียมแพลตฟอร์ม ${fee} บาท คืนเข้า Wallet ของคุณแล้ว`, 'เลือกคนใหม่ได้เลย'], 'ดูการจอง', '#F59E0B')
    case 'missed': return card('worker', '⏰ งานถูกยกเลิก', `คุณไม่ได้ตอบรับงานของ ${o.customer} ภายใน 30 นาที`, ['ครั้งต่อไปกรุณาตอบรับหรือปฏิเสธให้เร็วขึ้น'], 'เปิดแอป', '#F59E0B')
    case 'customer': return card('worker', '↩️ ลูกค้ายกเลิกคำขอ', `${o.customer} ยกเลิกการจอง`, [when1], 'เปิดแอป', '#F59E0B')
    case 'arrived': return card('customer', '📍 น้องถึงแล้ว', `${o.worker} ถึงจุดนัดหมายแล้ว`, [when1], 'ดูรายละเอียดการจอง', '#06C755')
    case 'completed': return card('customer', '🎉 งานเสร็จสิ้น', 'ขอบคุณที่ใช้บริการ', [`งานกับ ${o.worker} เสร็จสิ้นแล้ว`], 'ดูการจอง', '#06C755')
    case 'worker_cancelled': return card('customer', '⚠️ น้องยกเลิกงาน', `${o.worker} ยกเลิกงานหลังรับแล้ว`, ['กรุณาติดต่อแอดมินเพื่อขอคืนค่าธรรมเนียม'], 'ดูการจอง', '#EF4444')
    default: return null
  }
}

export function buildSupportFlex(o: { event: 'incoming' | 'reply'; name: string; liffId: string; threadId: string; logo?: string }) {
  const incoming = o.event === 'incoming'
  const url = `https://liff.line.me/${o.liffId}?support=${incoming ? o.threadId : 'open'}`
  return {
    type: 'flex',
    altText: incoming ? `💬 ${o.name} ส่งข้อความถึงแอดมิน` : '💬 แอดมินตอบข้อความของคุณแล้ว',
    contents: {
      type: 'bubble', size: 'kilo',
      styles: { body: { backgroundColor: '#161616' }, footer: { backgroundColor: '#161616' } },
      body: { type: 'box', layout: 'vertical', spacing: 'md', paddingAll: 'xl', contents: [
        { type: 'box', layout: 'horizontal', spacing: 'md', alignItems: 'center', contents: [
          ...(o.logo ? [{ type: 'image', url: o.logo, size: '40px', aspectMode: 'cover', aspectRatio: '1:1', flex: 0 }] : []),
          { type: 'text', text: incoming ? '💬 ข้อความจากลูกค้า' : '💬 แอดมินตอบแล้ว', weight: 'bold', size: 'md', color: '#F472B6', gravity: 'center' },
        ] },
        { type: 'text', text: incoming ? `${o.name} ส่งข้อความหาแอดมิน` : 'แอดมินตอบข้อความของคุณแล้ว', weight: 'bold', size: 'lg', color: '#FFFFFF', wrap: true },
        { type: 'text', text: incoming ? 'กดเพื่อเปิดกล่องข้อความและตอบกลับ' : 'กดเพื่อเปิดอ่านและตอบกลับ', size: 'sm', color: '#BBBBBB', wrap: true },
      ] },
      footer: { type: 'box', layout: 'vertical', paddingAll: 'lg', contents: [{ type: 'button', style: 'primary', color: '#EC4899', height: 'md', action: { type: 'uri', label: incoming ? 'เปิดกล่องข้อความ' : 'เปิดอ่าน', uri: url } }] },
    },
  }
}
// Plan Flex for a seller (500 THB / 30 days) or an agency: activated | renewed | expiring (3 days before the end)
export function buildPlanFlex(o: { kind: 'seller' | 'agency'; event: string; until: string; liffId: string; logo?: string; now?: number }) {
  const base = `https://liff.line.me/${o.liffId}`
  const exp = new Date(o.until)
  const day = exp.toLocaleDateString('th-TH', { timeZone: 'Asia/Bangkok', dateStyle: 'medium' })
  const left = Math.max(0, Math.ceil((exp.getTime() - (o.now ?? Date.now())) / 86400000))
  const text = (t: string, extra: Record<string, unknown> = {}) => ({ type: 'text', text: t, wrap: true, size: 'sm', color: '#DDDDDD', ...extra })
  const seller = o.kind === 'seller'
  const name = seller ? 'เซลล์' : 'สังกัด'
  const head = o.event === 'expiring' ? `⏰ แพ็กเกจ${name}ใกล้หมดอายุ` : o.event === 'renewed' ? `✅ ต่ออายุ${name}แล้ว` : seller ? '🎉 คุณเป็นเซลล์แล้ว' : '🎉 เปิดใช้งานสังกัดแล้ว'
  const title = o.event === 'expiring' ? `หมดอายุ ${day} (เหลือ ${left} วัน)` : `ใช้งานได้ถึง ${day}`
  const lines = o.event === 'expiring'
    ? [seller ? 'ต่ออายุก่อนหมด เพื่อรับส่วนแบ่ง 40% ของค่าจองจากลูกค้าที่คุณชวนต่อเนื่อง (วันที่เหลือบวกต่อให้)' : 'ต่ออายุก่อนหมด เพื่อให้น้องในสังกัดยังแสดงในหน้าลูกค้า (วันที่เหลือบวกต่อให้)']
    : seller
      ? ['ลูกค้าที่คุณชวนจองน้อง คุณได้ส่วนแบ่ง 40% ของค่าธรรมเนียม และ 20% ของค่าแพ็กเกจที่เขาซื้อ', 'วิธีหาลูกค้า: เลือกน้อง กดดูรูป แล้วกดปุ่มแชร์ ส่งให้ลูกค้าได้เลย หรือส่งข้อความชวนเพื่อนๆ']
      : ['ส่งลิงก์ชวนน้องเข้าสังกัด และดูรูปกับรายละเอียดของน้องในสังกัดได้ที่หลังบ้านสังกัด', 'น้องในสังกัดได้รับการแสดงในหน้าลูกค้าตามปกติ']
  const buttons = o.event === 'expiring'
    ? [{ type: 'button', style: 'primary', color: '#EC4899', height: 'md', action: { type: 'uri', label: `ต่ออายุ${name}`, uri: `${base}?open=${o.kind}` } }]
    : seller
      ? [{ type: 'button', style: 'primary', color: '#EC4899', height: 'md', action: { type: 'uri', label: 'ดูรูปน้องแล้วแชร์', uri: base } },
         { type: 'button', style: 'secondary', height: 'md', action: { type: 'uri', label: 'ส่งข้อความชวนเพื่อน/ลูกค้า', uri: `${base}?open=share` } }]
      : [{ type: 'button', style: 'primary', color: '#EC4899', height: 'md', action: { type: 'uri', label: 'เปิดหลังบ้านสังกัด', uri: `${base}?open=agency` } }]
  return {
    type: 'flex',
    altText: `${head} ${title}`,
    contents: {
      type: 'bubble', size: 'kilo',
      styles: { body: { backgroundColor: '#161616' }, footer: { backgroundColor: '#161616' } },
      body: { type: 'box', layout: 'vertical', spacing: 'md', paddingAll: 'xl', contents: [
        { type: 'box', layout: 'horizontal', spacing: 'md', alignItems: 'center', contents: [
          ...(o.logo ? [{ type: 'image', url: o.logo, size: '40px', aspectMode: 'cover', aspectRatio: '1:1', flex: 0 }] : []),
          { type: 'text', text: head, weight: 'bold', size: 'md', color: o.event === 'expiring' ? '#F59E0B' : '#06C755', gravity: 'center', wrap: true },
        ] },
        { type: 'text', text: title, weight: 'bold', size: 'lg', color: '#FFFFFF', wrap: true },
        ...lines.map((l) => text(l)),
      ] },
      footer: { type: 'box', layout: 'vertical', spacing: 'sm', paddingAll: 'lg', contents: buttons },
    },
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
  const isSupport = input.type === 'support'
  const isSeller = input.type === 'seller' || input.type === 'agency'     // plan Flex (seller / agency): input.type tells which
  if (!isBooking && !isSupport && !isSeller && (!thread_id || !recipient_id || !sender_id)) return json({ ok: false, code: 'BAD_INPUT' }, 400)
  if (isSupport && !input.thread_id) return json({ ok: false, code: 'BAD_INPUT' }, 400)
  if (isSeller && !input.user_id) return json({ ok: false, code: 'BAD_INPUT' }, 400)
  if (isBooking && (!input.job_id || !input.event)) return json({ ok: false, code: 'BAD_INPUT' }, 400)

  const admin = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!)

  const central = { token, liffId }
  if (isSeller) {
    // plan Flex: the member is reached through the OA he is a friend of (his seller's OA, else ours)
    const agency = input.type === 'agency'
    const { data: until } = agency
      ? await admin.from('agencies').select('plan_expires_at').eq('user_id', input.user_id).maybeSingle()
      : await admin.from('users').select('seller_until').eq('id', input.user_id).maybeSingle()
    const exp = (agency ? (until as { plan_expires_at?: string } | null)?.plan_expires_at : (until as { seller_until?: string } | null)?.seller_until) ?? null
    const rs = await recipient(admin, input.user_id, central)
    if (!exp || !rs || !/^U[0-9a-f]{32}$/.test(rs.lineId)) return json({ ok: true, status: 'NO_LINE_ID' })
    const appUrl = Deno.env.get('APP_URL')?.replace(/\/$/, '')
    const ev = input.event === 'renewed' ? 'renewed' : input.event === 'expiring' ? 'expiring' : 'activated'
    const message = buildPlanFlex({ kind: agency ? 'agency' : 'seller', event: ev, until: exp, liffId: rs.liffId, logo: appUrl ? `${appUrl}/dekn-logo.jpg?v=2` : undefined })
    const r = await fetch('https://api.line.me/v2/bot/message/push', {
      method: 'POST',
      headers: { Authorization: `Bearer ${rs.token}`, 'Content-Type': 'application/json', 'X-Line-Retry-Key': crypto.randomUUID() },
      body: JSON.stringify({ to: rs.lineId, messages: [message] }),
    })
    return json({ ok: r.ok, status: r.ok ? 'SENT' : 'FAILED' })
  }
  if (isSupport) {
    // only a seller's customers have a seller's staff; the push leaves through the seller's own OA
    const { data: th } = await admin.from('support_threads').select('id, user_id, vendor_id').eq('id', input.thread_id).maybeSingle()
    if (!th?.vendor_id) return json({ ok: true, status: 'NOT_A_VENDOR_THREAD' })
    const { data: vtoken } = await admin.rpc('vendor_token', { p_vendor: th.vendor_id })
    const { data: vv } = await admin.from('vendors').select('liff_id').eq('id', th.vendor_id).maybeSingle()
    if (!vtoken || !vv) return json({ ok: true, status: 'NO_VENDOR_TOKEN' })
    const { data: cust } = await admin.from('users').select('display_name, line_user_id').eq('id', th.user_id).maybeSingle()
    const appUrl = Deno.env.get('APP_URL')?.replace(/\/$/, '')
    const message = buildSupportFlex({ event: input.event === 'reply' ? 'reply' : 'incoming', name: String(cust?.display_name ?? 'ลูกค้า').slice(0, 40), liffId: vv.liff_id as string, threadId: th.id, logo: appUrl ? `${appUrl}/dekn-logo.jpg?v=2` : undefined })
    let targets: string[] = []
    if (input.event === 'reply') targets = [String(cust?.line_user_id ?? '').split(':').pop() ?? '']
    else { const { data: ids } = await admin.rpc('vendor_staff_line_ids', { p_vendor: th.vendor_id }); targets = (ids ?? []) as string[] }
    const results: unknown[] = []
    for (const to of targets.filter((x) => /^U[0-9a-f]{32}$/.test(x))) {
      const r = await fetch('https://api.line.me/v2/bot/message/push', {
        method: 'POST',
        headers: { Authorization: `Bearer ${vtoken}`, 'Content-Type': 'application/json', 'X-Line-Retry-Key': crypto.randomUUID() },
        body: JSON.stringify({ to, messages: [message] }),
      })
      results.push({ status: r.ok ? 'SENT' : 'FAILED' })
    }
    return json({ ok: true, results })
  }
  if (isBooking) {
    const { data: job } = await admin.from('jobs').select('id, customer_id, worker_id, rate_label, service_price, scheduled_at, place_note, source_label, booking_fee, travel_mode').eq('id', input.job_id).maybeSingle()
    if (!job) return json({ ok: false, code: 'NOT_FOUND' }, 404)
    const { data: cu } = await admin.from('users').select('display_name').eq('id', job.customer_id).maybeSingle()
    const { data: ww } = await admin.from('workers').select('display_name').eq('user_id', job.worker_id).maybeSingle()
    const { data: jp } = await admin.from('job_private').select('worker_place').eq('job_id', job.id).maybeSingle()
    const rw = await recipient(admin, job.worker_id, central)
    const rc = await recipient(admin, job.customer_id, central)
    const appUrl = Deno.env.get('APP_URL')?.replace(/\/$/, '')
    const results: unknown[] = []
    // a missed / expired booking tells both sides
    const events = input.event === 'expired' ? ['expired', 'missed'] : [input.event]
    for (const ev of events) {
      const card = buildBookingFlex({ event: ev, jobId: job.id, liffId: { worker: rw?.liffId ?? liffId, customer: rc?.liffId ?? liffId }, customer: cu?.display_name ?? 'ลูกค้า', worker: ww?.display_name ?? 'น้อง', rate: job.rate_label ?? '', price: Number(job.service_price), at: job.scheduled_at, place: job.place_note ?? undefined, source: job.source_label ?? undefined, fee: Number(job.booking_fee), travel: job.travel_mode, workerPlace: jp?.worker_place ?? undefined, logo: appUrl ? `${appUrl}/dekn-logo.jpg?v=2` : undefined })
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
