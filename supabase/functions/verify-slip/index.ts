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
  | { ok: true; transRef: string; amount: number; receiverBank: string | null; receiverName: string | null; receiver: unknown; uncertain?: boolean; slipAt?: number | null }
  | { ok: false; code: string; receiverBank?: string | null; receiverName?: string | null; receiver?: unknown }

const norm = (s: unknown) =>
  String(s ?? '').toLowerCase().replace(/[\s.*\-_,]/g, '')

// Collect every string holding digits found inside an object (account numbers are masked, e.g. "045-3-xxx109").
function digitStrings(v: unknown, out: string[] = []): string[] {
  if (v == null) return out
  if (typeof v === 'string' || typeof v === 'number') {
    const s = String(v)
    if (/\d/.test(s)) out.push(s)
  } else if (typeof v === 'object') {
    for (const x of Object.values(v as object)) digitStrings(x, out)
  }
  return out
}

// Compare our account digits (full number or the last few) with a masked number: x / * are wildcards,
// digits are aligned from the END, and at least 3 real digits must agree so an all-masked value never passes.
function accountMatches(account: unknown, want: string): boolean {
  return digitStrings(account).some((s) => {
    const p = s.toLowerCase().replace(/[^0-9x*]/g, '')
    if (p.length < want.length) return false
    const tail = p.slice(p.length - want.length)
    let real = 0
    for (let i = 0; i < want.length; i++) {
      if (tail[i] === 'x' || tail[i] === '*') continue
      if (tail[i] !== want[i]) return false
      real++
    }
    return real >= Math.min(3, want.length)
  })
}

// Thunder may shorten the receiver name ("นาง สำราญ อ" = first name + surname initial): ignore the title and
// accept when one side contains the other (min 3 chars so a stray letter never matches).
const TITLE = /^(นางสาว|นส|นาง|นาย|mrs|mr|ms|miss)/
// ณ and ญ are treated as the same letter: people mistype one for the other (a bank holds "สำราณ", the shop typed "สำราญ").
const unify = (x: string) => x.replace(/ณ/g, 'ญ')
function nameMatches(slipName: unknown, want: string): boolean {
  const s = unify(norm(slipName).replace(TITLE, ''))
  const w = unify(norm(want).replace(TITLE, ''))
  if (s.length < 3 || w.length < 3) return false
  return s.includes(w) || w.includes(s)
}

// When the transfer was made (ms since epoch) as the bank reports it; null if the field is missing. The bank's time has no zone in some
// answers: those are Thailand time (+07:00).
export function slipTimeMs(d: any): number | null {
  const raw = d?.date ?? d?.transTimestamp ?? d?.dateTime ?? d?.transDate
  if (typeof raw !== 'string' && typeof raw !== 'number') return null
  let str = String(raw).trim()
  if (/^\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}(:\d{2}(\.\d+)?)?$/.test(str)) str = str.replace(' ', 'T') + '+07:00'
  const ms = typeof raw === 'number' ? raw : Date.parse(str)
  return Number.isFinite(ms) ? ms : null
}
// A slip made BEFORE the payment request was created cannot be the payment for it (an old transfer for something else).
// The bank prints the time to the minute, so allow 2 minutes of rounding / clock difference and nothing more.
export const SLIP_EARLY_TOLERANCE_MS = 120_000
export const slipBeforeRequest = (slipAt: number | null, requestAt: number | null) =>
  slipAt != null && requestAt != null && slipAt < requestAt - SLIP_EARLY_TOLERANCE_MS

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

  // A PromptPay slip names a proxy (phone / ID), not a bank: when the slip carries no bank, the name and digits checks below decide.
  if (cfg.receiverBank && receiverBank && norm(receiverBank) !== norm(cfg.receiverBank)) {
    return { ok: false, code: 'WRONG_RECEIVER', receiverBank, receiverName, receiver }
  }
  const names = [d.receiver?.account?.name?.th, d.receiver?.account?.name?.en]
  // RECEIVER_NAME_CONTAINS / RECEIVER_ACCOUNT_DIGITS may hold several values separated by commas (e.g. "0887,4479": the account and the PromptPay phone)
  const list = (v?: string) => String(v ?? '').split(/[,;]+/).map((x) => x.trim()).filter(Boolean)
  const wantNames = list(cfg.receiverNameContains)
  if (wantNames.length && !wantNames.some((w) => names.some((n) => nameMatches(n, w)))) {
    return { ok: false, code: 'WRONG_RECEIVER', receiverBank, receiverName, receiver }
  }
  const wantDigits = list(cfg.receiverAccountDigits).map((x) => x.replace(/\D/g, '')).filter(Boolean)
  // Some banks print too few digits of the receiving account (fewer than 3 visible): the digits can neither confirm nor refuse it.
  // The name matched above, so the slip is not refused and not credited by itself: it goes to an admin (uncertain = true).
  const visible = Math.max(0, ...digitStrings(d.receiver?.account).map((x) => x.toLowerCase().replace(/[^0-9]/g, '').length))
  let uncertain = false
  if (wantDigits.length) {
    if (visible < 3) uncertain = true
    else if (!wantDigits.some((w) => accountMatches(d.receiver?.account, w))) return { ok: false, code: 'WRONG_RECEIVER', receiverBank, receiverName, receiver }
  }
  return { ok: true, transRef, amount: Math.round(amount * 100) / 100, receiverBank, receiverName, receiver, uncertain, slipAt: slipTimeMs(d) }
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
    const { data: pending } = await admin.from('payment_intents').select('amount, created_at')
      .eq('user_id', userId).eq('status', 'pending').gt('expires_at', new Date().toISOString())
    const expected = (pending ?? []).map((p: any) => Number(p.amount))
    if (!pending?.length) {
      // No open request. Someone who paid and came back after it expired still gets a hearing (admin review),
      // but only if they created a request in the last 24h, so strangers can't burn Thunder quota.
      const { count: recent } = await admin.from('payment_intents').select('id', { count: 'exact', head: true })
        .eq('user_id', userId).gte('created_at', new Date(Date.now() - 24 * 3600_000).toISOString())
      if (!recent) {
        await log('NO_PENDING_INTENT')
        return json({ ok: false, code: 'NO_PENDING_INTENT' })
      }
    }

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

    // 5a) A slip made before the payment request existed is an old transfer for something else: refuse it (the slip stays unused).
    //     The request it pays = the one with the same amount, else the newest request of the last 24 h.
    {
      const { data: recentIntents } = await admin.from('payment_intents').select('amount, created_at')
        .eq('user_id', userId).gte('created_at', new Date(Date.now() - 24 * 3600_000).toISOString()).order('created_at', { ascending: false })
      const list = (recentIntents ?? []) as { amount: number; created_at: string }[]
      const ref = list.find((p) => Math.abs(Number(p.amount) - check.amount) < 0.005) ?? list[0]
      if (slipBeforeRequest(check.slipAt ?? null, ref ? Date.parse(ref.created_at) : null)) {
        await log('SLIP_TOO_OLD', check.transRef, { slip_at: check.slipAt ? new Date(check.slipAt).toISOString() : null, request_at: ref?.created_at })
        return json({ ok: false, code: 'SLIP_TOO_OLD' })
      }
    }

    // 5b) The bank hid too much of the receiving account to confirm it: a human decides (admin "ตรวจสลิป").
    if (check.uncertain) {
      const { error: uerr } = await admin.rpc('submit_payment_review', {
        p_user: userId, p_trans_ref: check.transRef, p_amount: check.amount,
        p_detail: { receiver: receiverInfo, reason: 'RECEIVER_UNVERIFIED' },
      })
      if (uerr) {
        const code = uerr.message.includes('ALREADY_UNDER_REVIEW') ? 'ALREADY_UNDER_REVIEW' : uerr.message.includes('DUPLICATE_SLIP') ? 'DUPLICATE_SLIP' : 'SERVER_ERROR'
        await log(code, check.transRef, { paid: check.amount, receiver: receiverInfo })
        return json({ ok: false, code })
      }
      await log('REVIEW_RECEIVER', check.transRef, { paid: check.amount, receiver: receiverInfo })
      return json({ ok: false, code: 'REVIEW_RECEIVER', paid: check.amount })
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

    await log('OK', check.transRef, { paid: check.amount, slip_at: check.slipAt ? new Date(check.slipAt).toISOString() : null })   // null = the bank's answer had no readable time
    const row = Array.isArray(applied) ? applied[0] : applied
    return json({ ok: true, code: 'OK', kind: row?.kind, tier: row?.tier, days: row?.days, paid: row?.paid })
  } catch (e) {
    console.error(e)
    await log('SERVER_ERROR', null, { message: String((e as Error)?.message ?? e) })
    return json({ ok: false, code: 'SERVER_ERROR' }, 500)
  }
})
