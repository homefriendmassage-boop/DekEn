// Supabase Edge Function (ADMIN ONLY): checks a vendor's LINE Official Account connection.
//
// Deploy: Edge Functions > Deploy a new function > name "vendor-admin", turn OFF "Verify JWT" (we verify the caller is an admin).
// No extra secrets: the vendor's channel access token is read from Supabase Vault through the database function vendor_token().
//
// Body: { action: 'test', vendor_id }  -> asks LINE "who is this token?" (GET /v2/bot/info). A good answer proves the token is valid;
//                                         the OA's basic id / name are saved on the vendor so the add-friend link can be shown.

import { createClient } from 'npm:@supabase/supabase-js@2'

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } })

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors })
  const admin = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!)
  try {
    const jwt = (req.headers.get('Authorization') ?? '').replace(/^Bearer\s+/i, '')
    const { data: auth } = await admin.auth.getUser(jwt)
    if (!auth?.user) return json({ ok: false, code: 'UNAUTHORIZED' }, 401)
    const { data: isAdmin } = await admin.from('admins').select('user_id').eq('user_id', auth.user.id).maybeSingle()
    if (!isAdmin) return json({ ok: false, code: 'FORBIDDEN' }, 403)

    const { action, vendor_id } = await req.json().catch(() => ({}))
    if (action !== 'test' || !/^[a-z0-9]{4,16}$/.test(String(vendor_id ?? ''))) return json({ ok: false, code: 'BAD_INPUT' })

    const { data: token } = await admin.rpc('vendor_token', { p_vendor: vendor_id })
    if (!token) return json({ ok: false, code: 'NO_TOKEN' })
    const r = await fetch('https://api.line.me/v2/bot/info', { headers: { Authorization: `Bearer ${token}` } })
    if (!r.ok) {
      const body = await r.json().catch(() => null)
      return json({ ok: false, code: 'LINE_REJECTED', detail: String(body?.message ?? r.status).slice(0, 200) })
    }
    const info = await r.json()
    await admin.rpc('vendor_set_oa_info', { p_id: vendor_id, p_basic_id: info.basicId ?? null, p_name: info.displayName ?? null })
    return json({ ok: true, basicId: info.basicId ?? null, displayName: info.displayName ?? null })
  } catch (e) {
    return json({ ok: false, code: 'ERROR', detail: String((e as Error)?.message ?? e).slice(0, 200) })
  }
})
