// Supabase Edge Function: verify a bank-transfer slip with Thunder and open the paid plan / credit the wallet.
//
// The browser reads the QR code printed on the slip and sends ONLY that text ("payload").
// The Thunder API key never leaves this function.
//
// Deploy (dashboard: Edge Functions > Deploy a new function > Via Editor, name "verify-slip",
// turn OFF "Verify JWT" — we verify the user ourselves below):
//
// Secrets (Edge Functions > Secrets):
//   THUNDER_API_KEY         your Thunder API key
//   RECEIVER_NAME_CONTAINS  text that must appear in the receiver name on the slip (e.g. the surname)
//   RECEIVER_ACCOUNT_DIGITS (optional) digits of your account number that Thunder shows (e.g. the last 4)
//   RECEIVER_BANK           (optional) receiver bank short code, e.g. SCB / KBANK
//   RECEIVER_NAME_CONTAINS or RECEIVER_ACCOUNT_DIGITS is REQUIRED. The bank code alone is NOT enough:
//   it would accept a slip paid to ANY account at that bank (e.g. the buyer's own other account).
//
// Outcomes (HTTP 200, { ok, code }):
//   OK                  paid + amount matches an open request  -> plan opened / wallet credited
//   REVIEW_SUBMITTED    genuine slip to our account, amount matches nothing -> sent to the admin
//   SLIP_REJECTED / WRONG_RECEIVER / DUPLICATE_SLIP / ALREADY_UNDER_REVIEW  -> refused, customer attaches again
// Only crashes return 5xx.

import { createClient } from 'npm:@supabase/supabase-js@2'

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } })

// ---- BEGIN pure rules (unit-tested without Deno) ----------------------------------------------
export type SlipCheck =
  | { ok: true; transRef: string; amount: number; receiverBank: string | null; receiverName: string | null; receiver: unknown }
  | { ok: false; code: string; receiverBank?: string | null; receiverName?: string | null; receiver?: unknown }

const norm = (s: unknown) =>
  String(s ?? '').toLowerCase().replace(/[\s.*\-_,]/g, '')

// Collect every digit string found inside an object (account numbers may be masked, e.g. "xxx-x-x1234-x").
function digitStrings(v: unknown, out: string[] = []): string[] {
  if (v == null) return out
  if (typeof v === 'string' || typeof v === 'number') {
    const d = String(v).replace(/\D/g, '')
    if (d) out.push(d)
  } else if (typeof v === 'object') {
    for (const x of Object.values(v as object)) digitStrings(x, out)
  }
  return out
}

// The slip fields may sit directly under `data` or one level deeper (e.g. data.rawSlip): find the object holding transRef.
function findSlip(v: any, depth = 0): any | null {
  if (!v || typeof v !== 'object' || depth > 4) return null
  if (typeof v.transRef === 'string') return v
  for (const x of Object.values(v)) {
    const f = findSlip(x, depth + 1)
    if (f) return f
  }
  return null
}

// Thunder v2 /verify/bank answers HTTP 200 + a message like "Bank slip verified successfully" for a verified slip.
export function evaluateSlip(
  resp: any,
  cfg: { receiverBank?: string; receiverNameContains?: string; receiverAccountDigits?: string },
  httpStatus?: number,
): SlipCheck {
  // The bank alone identifies a whole bank, not your account: require the name or the account digits.
  if (!cfg.receiverNameContains && !cfg.receiverAccountDigits) return { ok: false, code: 'CONFIG_MISSING' }
  // Success = explicit success:true, or no success flag at all with HTTP 200 and no error object.
  const okFlag = resp && (resp.success === true || (resp.success === undefined && resp.error === undefined && httpStatus === 200))
  if (!okFlag) return { ok: false, code: 'SLIP_REJECTED' }
  const d = findSlip(resp.data ?? resp)
  if (!d) return { ok: false, code: 'SLIP_REJECTED' }
  const transRef = d.transRef.length >= 6 ? d.transRef : null
  const amount = Number(d.amount?.amount ?? d.amount)
  if (!transRef || !Number.isFinite(amount) || amount <= 0) return { ok: false, code: 'SLIP_REJECTED' }

  const receiver = d.receiver ?? null
  const receiverBank = d.receiver?.bank?.short ?? null
  const receiverName = d.receiver?.account?.name?.th ?? d.receiver?.account?.name?.en ?? null

  if (cfg.receiverBank && norm(receiverBank) !== norm(cfg.receiverBank)) {
    return { ok: false, code: 'WRONG_RECEIVER', receiverBank, receiverName, receiver }
  }
  if (cfg.receiverNameContains && !norm(receiverName).includes(norm(cfg.receiverNameContains))) {
    return { ok: false, code: 'WRONG_RECEIVER', receiverBank, receiverName, receiver }
  }
  const wantDigits = String(cfg.receiverAccountDigits ?? '').replace(/\D/g, '')
  if (wantDigits && !digitStrings(d.receiver?.account).some((x) => x.includes(wantDigits))) {
    return { ok: false, code: 'WRONG_RECEIVER', receiverBank, receiverName, receiver }
  }
  return { ok: true, transRef, amount: Math.round(amount * 100) / 100, receiverBank, receiverName, receiver }
}
// ---- END pure rules ---------------------------------------------------------------------------

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors })

  const admin = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!)
  let userId: string | null = null
  const log = (result: string, transRef: string | null = null, detail: unknown = null) =>
    userId
      ? admin.from('slip_attempts').insert({ user_id: userId, result, trans_ref: transRef, detail })
      : Promise.resolve()

  try {
    // 1) Who is calling? (verify_jwt is off for this function, so check the token ourselves)
    const jwt = (req.headers.get('Authorization') ?? '').replace(/^Bearer\s+/i, '')
    const { data: auth } = await admin.auth.getUser(jwt)
    if (!auth?.user) return json({ ok: false, code: 'UNAUTHORIZED' }, 401)
    userId = auth.user.id

    const { payload } = await req.json().catch(() => ({}))
    if (typeof payload !== 'string' || payload.length < 20 || payload.length > 600) {
      return json({ ok: false, code: 'BAD_PAYLOAD' })
    }

    // 2) Rate limit (protects the Thunder quota): 8 attempts / hour / user.
    //    "The bank hasn't released the slip yet" retries are expected, so they get their own, larger allowance (20).
    const since = new Date(Date.now() - 3600_000).toISOString()
    const { count } = await admin.from('slip_attempts').select('id', { count: 'exact', head: true })
      .eq('user_id', userId).gte('created_at', since).neq('result', 'SLIP_PENDING')
    const { count: pendingCount } = await admin.from('slip_attempts').select('id', { count: 'exact', head: true })
      .eq('user_id', userId).gte('created_at', since).eq('result', 'SLIP_PENDING')
    if ((count ?? 0) >= 8 || (pendingCount ?? 0) >= 20) return json({ ok: false, code: 'RATE_LIMIT' })

    // 3) Only spend a Thunder call if the user actually has an open payment request
    const { data: pending } = await admin.from('payment_intents').select('amount')
      .eq('user_id', userId).eq('status', 'pending').gt('expires_at', new Date().toISOString())
    if (!pending?.length) {
      await log('NO_PENDING_INTENT')
      return json({ ok: false, code: 'NO_PENDING_INTENT' })
    }
    const expected = pending.map((p: any) => Number(p.amount))

    // 4) Ask Thunder
    const apiKey = Deno.env.get('THUNDER_API_KEY')
    if (!apiKey) { await log('CONFIG_MISSING'); return json({ ok: false, code: 'CONFIG_MISSING' }) }

    let status = 0
    let body: any = null
    try {
      const r = await fetch('https://api.thunder.in.th/v2/verify/bank', {
        method: 'POST',
        headers: { Authorization: `Bearer ${apiKey}`, 'Content-Type': 'application/json' },
        body: JSON.stringify({ payload }),
      })
      status = r.status
      body = await r.json().catch(() => null)
    } catch {
      await log('UPSTREAM_ERROR', null, { reason: 'network' })
      return json({ ok: false, code: 'UPSTREAM_ERROR' })
    }

    // What Thunder said, trimmed, so the admin can see the real reason (no secrets in it).
    const snippet = JSON.stringify(body)?.slice(0, 1000) ?? null

    // The bank hasn't published this slip to Thunder yet (seen with Bangkok Bank): not a bad slip, just retry shortly.
    if ((body?.error?.code ?? body?.code) === 'SLIP_PENDING') {
      await log('SLIP_PENDING', null, { status, response: snippet })
      return json({ ok: false, code: 'SLIP_PENDING' })
    }

    // Our key / credit / rate problem: not the customer's fault, so don't blame the slip.
    if (status === 401 || status === 402 || status === 403 || status === 429 || status >= 500) {
      await log('UPSTREAM_ERROR', null, { status, response: snippet })
      return json({ ok: false, code: 'UPSTREAM_ERROR' })
    }

    // 5) Is this a real slip, to OUR account?
    const check = evaluateSlip(body, {
      receiverBank: Deno.env.get('RECEIVER_BANK') ?? undefined,
      receiverNameContains: Deno.env.get('RECEIVER_NAME_CONTAINS') ?? undefined,
      receiverAccountDigits: Deno.env.get('RECEIVER_ACCOUNT_DIGITS') ?? undefined,
    }, status)
    // our own receiving account as Thunder reads it (for tuning the checks)
    const receiverInfo = (check as { receiver?: unknown }).receiver ?? body?.data?.receiver ?? null
    if (!check.ok) {
      await log(check.code, null, { status, receiver: receiverInfo, response: snippet })
      return json({ ok: false, code: check.code })
    }

    // 6) Atomic: amount must equal one of this user's pending requests; the transfer ref can be used once.
    const { data: applied, error } = await admin.rpc('apply_slip_payment', {
      p_user: userId, p_amount: check.amount, p_trans_ref: check.transRef,
    })
    if (error) {
      if (error.message.includes('NO_MATCHING_INTENT')) {
        // A genuine slip, paid to OUR account, but the amount matches no open request:
        // the only case that goes to a human. (Fake / duplicate / wrong receiver were rejected above.)
        const { error: rerr } = await admin.rpc('submit_payment_review', {
          p_user: userId, p_trans_ref: check.transRef, p_amount: check.amount,
          p_detail: { receiver: receiverInfo, expected },
        })
        if (rerr) {
          const code = rerr.message.includes('ALREADY_UNDER_REVIEW') ? 'ALREADY_UNDER_REVIEW'
            : rerr.message.includes('DUPLICATE_SLIP') ? 'DUPLICATE_SLIP' : 'SERVER_ERROR'
          await log(code, check.transRef, { paid: check.amount, expected })
          return json({ ok: false, code })
        }
        await log('REVIEW_SUBMITTED', check.transRef, { paid: check.amount, expected })
        return json({ ok: false, code: 'REVIEW_SUBMITTED', paid: check.amount, expected })
      }
      const code = error.message.includes('DUPLICATE_SLIP') ? 'DUPLICATE_SLIP' : 'SERVER_ERROR'
      await log(code, check.transRef, { paid: check.amount, expected, receiver: receiverInfo })
      return json({ ok: false, code })
    }

    await log('OK', check.transRef, { paid: check.amount })
    const row = Array.isArray(applied) ? applied[0] : applied
    return json({ ok: true, code: 'OK', kind: row?.kind, tier: row?.tier, days: row?.days, paid: row?.paid })
  } catch (e) {
    console.error(e)
    await log('SERVER_ERROR', null, { message: String((e as Error)?.message ?? e) })
    return json({ ok: false, code: 'SERVER_ERROR' }, 500)
  }
})
