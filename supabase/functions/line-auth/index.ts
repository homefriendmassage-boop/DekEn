// Supabase Edge Function: exchanges a LINE LIFF ID token for a Supabase session.
//
// Why: Supabase Auth has no native "LINE LIFF" provider, and RLS needs a real
// auth.uid(). We verify the ID token with LINE, then create/sign-in a Supabase
// user whose password is an HMAC only this function can compute.
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
    const { idToken } = await req.json()
    if (!idToken) throw new Error('idToken required')

    // 1) Let LINE verify the token (signature, expiry, audience).
    const verify = await fetch('https://api.line.me/oauth2/v2.1/verify', {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({ id_token: idToken, client_id: Deno.env.get('LINE_CHANNEL_ID')! }),
    })
    if (!verify.ok) throw new Error('Invalid LINE token')
    const { sub: lineUserId, name } = await verify.json()

    // 2) Deterministic credentials per LINE user.
    const email = `${lineUserId}@line.invalid`
    const password = await hmacHex(Deno.env.get('PASSWORD_PEPPER')!, lineUserId)

    const url = Deno.env.get('SUPABASE_URL')!
    const admin = createClient(url, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!)
    const anon = createClient(url, Deno.env.get('SUPABASE_ANON_KEY')!)

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
