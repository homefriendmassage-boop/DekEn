// Supabase Edge Function: exchanges a LINE LIFF ID token for a Supabase session.
//
// Why: Supabase Auth has no native "LINE LIFF" provider, and RLS needs a real
// auth.uid(). We verify the ID token with LINE, then create/sign-in a Supabase
// user whose password is an HMAC only this function can compute.
//
// Vendors (sellers with their own LINE OA): the browser also sends { vendor: '<vendor id>' }; the token is then verified
// against THAT vendor's LINE Login channel (the first part of its LIFF ID). All seller OAs live in ONE LINE Provider, so the
// LINE id is the same everywhere: one account (and one Wallet) per person. users.vendor_id records the seller the customer
// FIRST came through and is never changed afterwards.
//
// Deploy:
//   supabase functions deploy line-auth --no-verify-jwt
//   supabase secrets set LINE_CHANNEL_ID=<LINE Login channel id> PASSWORD_PEPPER=<long random string>
// (SUPABASE_URL, SUPABASE_ANON_KEY, SUPABASE_SERVICE_ROLE_KEY are injected automatically.)

import { createClient } from 'npm:@supabase/supabase-js@2'

const cors = {
  'Access-Control-Allow-Origin': '*', // tighten to your GitHub Pages origin in production
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

async function hmacHex(key: string, msg: string) {
  const k = await crypto.subtle.importKey('raw', new TextEncoder().encode(key),
    { name: 'HMAC', hash: 'SHA-256' }, false, ['sign'])
  const sig = await crypto.subtle.sign('HMAC', k, new TextEncoder().encode(msg))
  return [...new Uint8Array(sig)].map((b) => b.toString(16).padStart(2, '0')).join('')
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors })
  try {
    const { idToken, vendor } = await req.json()
    if (!idToken) throw new Error('idToken required')

    const url = Deno.env.get('SUPABASE_URL')!
    const admin = createClient(url, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!)
    const anon = createClient(url, Deno.env.get('SUPABASE_ANON_KEY')!)

    // Which LINE Login channel issued the token: ours, or a vendor's
    let channelId = Deno.env.get('LINE_CHANNEL_ID')!
    let vendorId: string | null = null
    if (vendor) {
      if (!/^[a-z0-9]{4,16}$/.test(String(vendor))) throw new Error('Unknown vendor')
      const { data: v } = await admin.from('vendors').select('id, liff_id, status').eq('id', vendor).maybeSingle()
      if (!v || v.status !== 'active') throw new Error('Unknown vendor')
      channelId = String(v.liff_id).split('-')[0]
      vendorId = v.id
    }

    // 1) Let LINE verify the token (signature, expiry, audience).
    const verify = await fetch('https://api.line.me/oauth2/v2.1/verify', {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({ id_token: idToken, client_id: channelId }),
    })
    if (!verify.ok) throw new Error('Invalid LINE token')
    const { sub, name } = await verify.json()

    // 2) Deterministic credentials per LINE user (the same account through every seller's LIFF).
    const lineUserId = sub
    const email = `${sub}@line.invalid`
    const password = await hmacHex(Deno.env.get('PASSWORD_PEPPER')!, lineUserId)

    // 3) Sign in; on first visit create the user then sign in.
    let { data, error } = await anon.auth.signInWithPassword({ email, password })
    if (error) {
      const created = await admin.auth.admin.createUser({
        email, password, email_confirm: true,
        user_metadata: { line_user_id: lineUserId, display_name: name },
      })
      if (created.error) throw created.error
      ;({ data, error } = await anon.auth.signInWithPassword({ email, password }))
      if (error) throw error
      if (vendorId) await admin.from('users').update({ vendor_id: vendorId }).eq('line_user_id', lineUserId).is('vendor_id', null)
    }

    return new Response(JSON.stringify({ session: data.session }), {
      headers: { ...cors, 'Content-Type': 'application/json' },
    })
  } catch (e) {
    return new Response(JSON.stringify({ error: String(e?.message ?? e) }), {
      status: 400, headers: { ...cors, 'Content-Type': 'application/json' },
    })
  }
})
