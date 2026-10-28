// Supabase Edge Function: LINE push (Flex) telling someone a new chat message is waiting. The button opens that chat room.
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
// ---- END pure rules -----------------------------------------------------------------------------

Deno.serve(async (req) => {
  const secret = Deno.env.get('CHAT_NOTIFY_SECRET')
  const token = Deno.env.get('LINE_CHANNEL_ACCESS_TOKEN')
  const liffId = Deno.env.get('LIFF_ID')
  if (!secret || !token || !liffId) return json({ ok: false, code: 'CONFIG_MISSING' }, 500)
  if (req.headers.get('x-webhook-secret') !== secret) return json({ ok: false, code: 'FORBIDDEN' }, 403)

  const { thread_id, recipient_id, sender_id } = await req.json().catch(() => ({}))
  if (!thread_id || !recipient_id || !sender_id) return json({ ok: false, code: 'BAD_INPUT' }, 400)

  const admin = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!)
  const { data: to } = await admin.from('users').select('line_user_id').eq('id', recipient_id).maybeSingle()
  if (!to?.line_user_id || !/^U[0-9a-f]{32}$/.test(to.line_user_id)) return json({ ok: true, status: 'NO_LINE_ID' })   // mock / anonymous accounts

  // Providers are known by their stage name, customers by their LINE name
  const { data: w } = await admin.from('workers').select('display_name').eq('user_id', sender_id).maybeSingle()
  const { data: u } = await admin.from('users').select('display_name').eq('id', sender_id).maybeSingle()
  const senderName = String(w?.display_name ?? u?.display_name ?? 'สมาชิก').slice(0, 40)

  const appUrl = Deno.env.get('APP_URL')?.replace(/\/$/, '')
  const message = buildChatFlex({ senderName, liffId, threadId: thread_id, logo: appUrl ? `${appUrl}/dekn-logo.jpg?v=2` : undefined })
  const r = await fetch('https://api.line.me/v2/bot/message/push', {
    method: 'POST',
    headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json', 'X-Line-Retry-Key': crypto.randomUUID() },
    body: JSON.stringify({ to: to.line_user_id, messages: [message] }),
  })
  if (r.ok) return json({ ok: true, status: 'SENT' })
  const body = await r.json().catch(() => null)
  return json({ ok: false, status: 'FAILED', detail: String(body?.message ?? r.status).slice(0, 200) })
})
