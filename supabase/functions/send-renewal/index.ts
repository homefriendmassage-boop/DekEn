// Supabase Edge Function (ADMIN ONLY): send a membership renewal reminder to customers as a LINE Flex Message.
//
// Deploy: Edge Functions > Deploy a new function > Via Editor, name "send-renewal", turn OFF "Verify JWT"
// (we verify the caller is an admin ourselves).
//
// Secrets (Edge Functions > Secrets):
//   LINE_CHANNEL_ACCESS_TOKEN  long-lived channel access token of your Messaging API channel (the Official Account).
//                              The OA must live in the SAME LINE provider as your LIFF app, otherwise user ids differ.
//   LIFF_ID                    your LIFF id (the button opens https://liff.line.me/<LIFF_ID>?open=plans)
//
// NOTE: this is a LINE *push* message: it counts against the OA's monthly message quota, and only reaches
// users who added the OA as a friend and have not blocked it. Duplicates are suppressed (24h single / 3 days bulk).
//
// Body: { user_id }                       -> one customer
//       { expiring_days: 7 }              -> every active member whose plan ends within N days (max 50 per call)

import { createClient } from 'npm:@supabase/supabase-js@2'

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } })

// ---- BEGIN pure rules (unit-tested without Deno) ----------------------------------------------
const PLAN = { 1: { name: 'Gold', icon: '🥇', color: '#F5B301' }, 2: { name: 'Platinum', icon: '💠', color: '#C9D1DB' }, 3: { name: 'Diamond', icon: '💎', color: '#7DD3FC' } } as Record<number, { name: string; icon: string; color: string }>

export function buildRenewalFlex(o: { tier: number; expiresAt: string; now?: number; liffId: string }) {
  const plan = PLAN[o.tier] ?? PLAN[1]
  const exp = new Date(o.expiresAt)
  const daysLeft = Math.ceil((exp.getTime() - (o.now ?? Date.now())) / 86400000)
  const date = exp.toLocaleDateString('th-TH', { day: 'numeric', month: 'long', year: 'numeric', timeZone: 'Asia/Bangkok' })
  const title = daysLeft > 0 ? `สมาชิก ${plan.name} ใกล้หมดอายุ` : `สมาชิก ${plan.name} หมดอายุแล้ว`
  const detail = daysLeft > 0 ? `หมดอายุ ${date} (เหลือ ${daysLeft} วัน)` : `หมดอายุเมื่อ ${date}`
  const url = `https://liff.line.me/${o.liffId}?open=plans`
  return {
    type: 'flex',
    altText: `${title} — ต่ออายุได้เลย`,
    contents: {
      type: 'bubble',
      size: 'kilo',
      styles: { body: { backgroundColor: '#161616' }, footer: { backgroundColor: '#161616' } },
      body: {
        type: 'box', layout: 'vertical', spacing: 'md', paddingAll: 'xl',
        contents: [
          { type: 'text', text: `${plan.icon} ${plan.name}`, weight: 'bold', size: 'sm', color: plan.color },
          { type: 'text', text: title, weight: 'bold', size: 'lg', color: '#FFFFFF', wrap: true },
          { type: 'text', text: detail, size: 'sm', color: '#BBBBBB', wrap: true },
          { type: 'text', text: 'ต่ออายุเพื่อแชตตรงกับน้องๆ และดูโปรไฟล์ได้ต่อเนื่อง', size: 'sm', color: '#DDDDDD', wrap: true },
        ],
      },
      footer: {
        type: 'box', layout: 'vertical', paddingAll: 'lg',
        contents: [{
          type: 'button', style: 'primary', color: '#06C755', height: 'md',
          action: { type: 'uri', label: 'เลือกแผนต่ออายุ', uri: url },
        }],
      },
    },
  }
}
// ---- END pure rules ---------------------------------------------------------------------------

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors })
  const admin = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!)

  try {
    // 1) Caller must be an admin (checked against public.admins with the service role)
    const jwt = (req.headers.get('Authorization') ?? '').replace(/^Bearer\s+/i, '')
    const { data: auth } = await admin.auth.getUser(jwt)
    if (!auth?.user) return json({ ok: false, code: 'UNAUTHORIZED' }, 401)
    const { data: isAdmin } = await admin.from('admins').select('user_id').eq('user_id', auth.user.id).maybeSingle()
    if (!isAdmin) return json({ ok: false, code: 'FORBIDDEN' }, 403)

    const token = Deno.env.get('LINE_CHANNEL_ACCESS_TOKEN')
    const liffId = Deno.env.get('LIFF_ID')
    if (!token || !liffId) return json({ ok: false, code: 'CONFIG_MISSING' })

    // 2) Who to remind
    const { user_id, expiring_days } = await req.json().catch(() => ({}))
    const nowIso = new Date().toISOString()
    let q = admin.from('users').select('id, line_user_id, vendor_id, vip_tier, vip_expires_at').gt('vip_tier', 0)
    let dedupeMs = 24 * 3600_000
    if (user_id) {
      q = q.eq('id', user_id)
    } else if (Number.isInteger(expiring_days) && expiring_days >= 1 && expiring_days <= 14) {
      q = q.gt('vip_expires_at', nowIso).lt('vip_expires_at', new Date(Date.now() + expiring_days * 86400_000).toISOString()).limit(50)
      dedupeMs = 3 * 86400_000
    } else {
      return json({ ok: false, code: 'BAD_INPUT' })
    }
    const { data: targets } = await q
    if (!targets?.length) return json({ ok: true, sent: 0, skipped: 0, failed: 0, results: [] })

    // 3) Send, one by one
    const results: { user_id: string; status: string; detail?: string }[] = []
    for (const u of targets) {
      if (!u.vip_expires_at || !u.line_user_id || !/^U[0-9a-f]{32}$/.test(String(u.line_user_id).split(':').pop() ?? '')) {
        results.push({ user_id: u.id, status: 'NO_LINE_ID' }); continue   // mock / anonymous accounts
      }
      const { count } = await admin.from('renewal_notices').select('id', { count: 'exact', head: true })
        .eq('user_id', u.id).eq('result', 'SENT').gte('created_at', new Date(Date.now() - dedupeMs).toISOString())
      if ((count ?? 0) > 0) { results.push({ user_id: u.id, status: 'SKIPPED_RECENT' }); continue }

      // a vendor's customer is reminded by the vendor's own OA (his token and LIFF)
      let pushToken = token, pushLiff = liffId, pushTo = u.line_user_id as string
      if (u.vendor_id) {
        const { data: vt } = await admin.rpc('vendor_token', { p_vendor: u.vendor_id })
        const { data: vv } = await admin.from('vendors').select('liff_id').eq('id', u.vendor_id).maybeSingle()
        if (!vt || !vv) { results.push({ user_id: u.id, status: 'NO_VENDOR_TOKEN' }); continue }
        pushToken = vt as string; pushLiff = vv.liff_id as string; pushTo = pushTo.split(':').pop() as string
      }
      const message = buildRenewalFlex({ tier: u.vip_tier, expiresAt: u.vip_expires_at, liffId: pushLiff })
      const r = await fetch('https://api.line.me/v2/bot/message/push', {
        method: 'POST',
        headers: { Authorization: `Bearer ${pushToken}`, 'Content-Type': 'application/json', 'X-Line-Retry-Key': crypto.randomUUID() },
        body: JSON.stringify({ to: pushTo, messages: [message] }),
      })
      if (r.ok) {
        await admin.from('renewal_notices').insert({ user_id: u.id, sent_by: auth.user.id, result: 'SENT' })
        results.push({ user_id: u.id, status: 'SENT' })
      } else {
        const body = await r.json().catch(() => null)
        const detail = String(body?.message ?? r.status).slice(0, 200)
        await admin.from('renewal_notices').insert({ user_id: u.id, sent_by: auth.user.id, result: 'FAILED', detail })
        results.push({ user_id: u.id, status: 'FAILED', detail })
      }
    }
    const count = (s: string) => results.filter((x) => x.status === s).length
    return json({ ok: true, sent: count('SENT'), skipped: count('SKIPPED_RECENT') + count('NO_LINE_ID'), failed: count('FAILED'), results })
  } catch (e) {
    console.error(e)
    return json({ ok: false, code: 'SERVER_ERROR' }, 500)
  }
})
