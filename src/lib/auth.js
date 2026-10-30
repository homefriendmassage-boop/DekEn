import liff from '@line/liff'
import { supabase } from '../supabaseClient'
import { LIFF_ID, USE_MOCK_LIFF } from '../config'
import { getVendor, getActiveLiffId, resolveVendor, sessionMatches } from './vendor'

const REF_KEY = 'partner_ref'
const AGENCY_KEY = 'agency_code'
const REF_PATTERN = /^[A-Za-z0-9_-]{1,32}$/ // reject anything odd before it reaches the DB

// Deep link from the renewal reminder: https://liff.line.me/<id>?open=plans  ->  open the plan picker once.
// LINE tucks the query into `liff.state` on first open, so look there too, and remember it across the login redirect.
export function captureOpenParam() {
  const params = new URLSearchParams(window.location.search)
  let open = params.get('open')
  if (!open) {
    const state = params.get('liff.state')
    if (state) {
      const q = state.indexOf('?')
      open = new URLSearchParams(q >= 0 ? state.slice(q) : state).get('open')
    }
  }
  try { if (open === 'plans' || open === 'share' || open === 'seller' || open === 'agency' || open === 'worker') sessionStorage.setItem('open_intent', open) } catch { /* storage blocked */ }
}
export function takeOpenIntent() {
  try {
    const v = sessionStorage.getItem('open_intent')
    sessionStorage.removeItem('open_intent')
    return v
  } catch { return null }
}

// Shared profile: https://liff.line.me/<id>?worker=<provider uuid>  -> open that provider once after login.
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
export function captureWorkerParam() {
  const params = new URLSearchParams(window.location.search)
  let id = params.get('worker')
  if (!id) {
    const state = params.get('liff.state')
    if (state) {
      const q = state.indexOf('?')
      id = new URLSearchParams(q >= 0 ? state.slice(q) : state).get('worker')
    }
  }
  try { if (id && UUID.test(id)) sessionStorage.setItem('open_worker', id) } catch { /* storage blocked */ }
}
export function takeWorkerIntent() {
  try {
    const v = sessionStorage.getItem('open_worker')
    sessionStorage.removeItem('open_worker')
    return v && UUID.test(v) ? v : null
  } catch { return null }
}
// Opened from a link an admin / modelling agency issued for her: https://liff.line.me/<id>?draft=<64 hex>
const DRAFT = /^[0-9a-f]{64}$/i
export function captureDraftParam() {
  const params = new URLSearchParams(window.location.search)
  let tok = params.get('draft')
  if (!tok) {
    const state = params.get('liff.state')
    if (state) {
      const q = state.indexOf('?')
      tok = new URLSearchParams(q >= 0 ? state.slice(q) : state).get('draft')
    }
  }
  try { if (tok && DRAFT.test(tok)) sessionStorage.setItem('open_draft', tok) } catch { /* storage blocked */ }
}
export function takeDraftIntent() {
  try {
    const v = sessionStorage.getItem('open_draft')
    sessionStorage.removeItem('open_draft')
    return v && DRAFT.test(v) ? v : null
  } catch { return null }
}

// Opened from a support push: https://liff.line.me/<id>?support=<thread uuid | open>
export function captureSupportParam() {
  const params = new URLSearchParams(window.location.search)
  let v = params.get('support')
  if (!v) {
    const state = params.get('liff.state')
    if (state) { const q = state.indexOf('?'); v = new URLSearchParams(q >= 0 ? state.slice(q) : state).get('support') }
  }
  try { if (v && (v === 'open' || UUID.test(v))) sessionStorage.setItem('open_support', v) } catch { /* storage blocked */ }
}
export function takeSupportIntent() {
  try { const v = sessionStorage.getItem('open_support'); sessionStorage.removeItem('open_support'); return v } catch { return null }
}

// Opened from a booking push: https://liff.line.me/<id>?job=<job uuid>
export function captureJobParam() {
  const params = new URLSearchParams(window.location.search)
  let id = params.get('job')
  if (!id) {
    const state = params.get('liff.state')
    if (state) {
      const q = state.indexOf('?')
      id = new URLSearchParams(q >= 0 ? state.slice(q) : state).get('job')
    }
  }
  try { if (id && UUID.test(id)) sessionStorage.setItem('open_job', id) } catch { /* storage blocked */ }
}
export function takeJobIntent() {
  try {
    const v = sessionStorage.getItem('open_job')
    sessionStorage.removeItem('open_job')
    return v && UUID.test(v) ? v : null
  } catch { return null }
}

// Opened from the "new message" LINE push: https://liff.line.me/<id>?chat=<thread uuid>
export function captureChatParam() {
  const params = new URLSearchParams(window.location.search)
  let id = params.get('chat')
  if (!id) {
    const state = params.get('liff.state')
    if (state) {
      const q = state.indexOf('?')
      id = new URLSearchParams(q >= 0 ? state.slice(q) : state).get('chat')
    }
  }
  try { if (id && UUID.test(id)) sessionStorage.setItem('open_chat', id) } catch { /* storage blocked */ }
}
export function takeChatIntent() {
  try {
    const v = sessionStorage.getItem('open_chat')
    sessionStorage.removeItem('open_chat')
    return v && UUID.test(v) ? v : null
  } catch { return null }
}

// LINE login tickets expire (the app was left open for a long time): sign out of LIFF and log in again instead of failing.
const isExpired = (e) => /expired|invalid.*token|token.*invalid|unauthorized/i.test(`${e?.message ?? ''} ${e?.code ?? ''} ${e?.error ?? ''}`)
function relogin() {
  try { liff.logout() } catch { /* ignore */ }
  liff.login({ redirectUri: window.location.href })   // leaves the page
  return new Promise(() => {})
}

// true when the user already follows the official account. Unknown (no bot linked, mock mode) counts as a friend so nobody is locked out.
export async function isOaFriend() {
  if (USE_MOCK_LIFF) return true
  try { return !!(await liff.getFriendship()).friendFlag } catch { return true }
}

// Invitation from a modelling agency: https://liff.line.me/<id>?agency=<code>  (same liff.state gotcha as ref).
export function captureAgencyCode() {
  const params = new URLSearchParams(window.location.search)
  let code = params.get('agency')
  if (!code) {
    const state = params.get('liff.state')
    if (state) {
      const q = state.indexOf('?')
      code = new URLSearchParams(q >= 0 ? state.slice(q) : state).get('agency')
    }
  }
  try {
    if (code && REF_PATTERN.test(code)) localStorage.setItem(AGENCY_KEY, code)
    return localStorage.getItem(AGENCY_KEY)
  } catch {
    return code && REF_PATTERN.test(code) ? code : null
  }
}
export const getAgencyCode = () => { try { return localStorage.getItem(AGENCY_KEY) } catch { return null } }
export const clearAgencyCode = () => { try { localStorage.removeItem(AGENCY_KEY) } catch { /* storage blocked */ } }

/**
 * Read the share code from the URL, e.g. https://liff.line.me/<id>?ref=k3m9x2ab
 *
 * Gotcha: on first open LINE rewrites the URL and tucks the original query into
 * `liff.state` (e.g. "?ref=k3m9x2ab"), so we check both. Call this before AND
 * after liff.init(). The LATEST link wins (it overwrites a stored one); the stored copy only
 * survives the login redirect and is consumed by signIn() once it has been reported to the server.
 */
export function captureRefCode() {
  const params = new URLSearchParams(window.location.search)
  let ref = params.get('ref')

  if (!ref) {
    const state = params.get('liff.state')
    if (state) {
      const q = state.indexOf('?')
      ref = new URLSearchParams(q >= 0 ? state.slice(q) : state).get('ref')
    }
  }

  try {
    if (ref && REF_PATTERN.test(ref)) {
      localStorage.setItem(REF_KEY, ref)
    }
    return localStorage.getItem(REF_KEY)
  } catch {
    return ref && REF_PATTERN.test(ref) ? ref : null // storage blocked
  }
}

/**
 * Sign in and return { profile, isMock, refCode }.
 *  - Mock mode: anonymous Supabase user + fake LINE profile (browser testing).
 *    Requires Auth > Providers > "Allow anonymous sign-ins" in Supabase.
 *  - Real mode: LIFF login -> ID token -> `line-auth` Edge Function -> session.
 */
export async function signIn() {
  captureRefCode()
  captureOpenParam()
  captureWorkerParam()
  captureChatParam()
  captureDraftParam()
  captureJobParam()
  captureSupportParam()
  captureAgencyCode()

  let profile
  if (USE_MOCK_LIFF) {
    profile = { userId: 'U_mock_' + Math.random().toString(36).slice(2, 10), displayName: 'Mock User', pictureUrl: null }
    const { data } = await supabase.auth.getSession()
    if (!data.session) {
      const { error } = await supabase.auth.signInAnonymously({
        options: { data: { line_user_id: profile.userId } }, // read by handle_new_user()
      })
      if (error) throw error
    }
  } else {
    await resolveVendor()                          // a seller's own LIFF, or ours
    await liff.init({ liffId: getActiveLiffId() })
    if (!liff.isLoggedIn()) {
      liff.login({ redirectUri: window.location.href }) // leaves the page
      return new Promise(() => {})                       // never resolves; page reloads
    }
    try { profile = await liff.getProfile() } catch (e) { if (isExpired(e)) return relogin(); throw e }

    let { data: existing } = await supabase.auth.getSession()
    if (existing.session && !sessionMatches(existing.session)) {   // a session of another vendor / the central app: start fresh
      await supabase.auth.signOut()
      existing = { session: null }
    }
    if (!existing.session) {
      const { data, error } = await supabase.functions.invoke('line-auth', {
        body: { idToken: liff.getIDToken(), vendor: getVendor()?.id ?? null },
      })
      if (error || !data?.session) {
        const detail = `${error?.message ?? ''} ${await (error?.context?.text?.().catch(() => '') ?? '')}`
        if (isExpired({ message: detail })) return relogin()
        throw error ?? new Error('LINE auth failed')
      }
      await supabase.auth.setSession({
        access_token: data.session.access_token,
        refresh_token: data.session.refresh_token,
      })
    }
  }

  // Cosmetic: lets providers see who booked them. Failure must not block login.
  try { await supabase.rpc('touch_profile', { p_name: profile.displayName, p_picture: profile.pictureUrl ?? null }) } catch { /* ignore */ }

  captureOpenParam()
  captureWorkerParam()
  captureChatParam()
  captureDraftParam()
  captureJobParam()
  captureSupportParam()
  captureAgencyCode()
  const refCode = captureRefCode() // URL is clean again after init(); re-check
  if (refCode) {
    // The server decides who counts as this customer's sales (see migration_015). Failure must not block login.
    try { await supabase.rpc('register_referral_click', { p_code: refCode }) } catch { /* ignore */ }
    try { localStorage.removeItem(REF_KEY) } catch { /* storage blocked */ }
  }

  return { profile, isMock: USE_MOCK_LIFF, refCode, vendor: getVendor() }
}
