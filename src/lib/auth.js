import liff from '@line/liff'
import { supabase } from '../supabaseClient'
import { LIFF_ID, USE_MOCK_LIFF } from '../config'

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
  try { if (open === 'plans') sessionStorage.setItem('open_intent', 'plans') } catch { /* storage blocked */ }
}
export function takeOpenIntent() {
  try {
    const v = sessionStorage.getItem('open_intent')
    sessionStorage.removeItem('open_intent')
    return v
  } catch { return null }
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
    await liff.init({ liffId: LIFF_ID })
    if (!liff.isLoggedIn()) {
      liff.login({ redirectUri: window.location.href }) // leaves the page
      return new Promise(() => {})                       // never resolves; page reloads
    }
    profile = await liff.getProfile()

    const { data: existing } = await supabase.auth.getSession()
    if (!existing.session) {
      const { data, error } = await supabase.functions.invoke('line-auth', {
        body: { idToken: liff.getIDToken() },
      })
      if (error || !data?.session) throw error ?? new Error('LINE auth failed')
      await supabase.auth.setSession({
        access_token: data.session.access_token,
        refresh_token: data.session.refresh_token,
      })
    }
  }

  // Cosmetic: lets providers see who booked them. Failure must not block login.
  try { await supabase.rpc('touch_profile', { p_name: profile.displayName, p_picture: profile.pictureUrl ?? null }) } catch { /* ignore */ }

  captureOpenParam()
  captureAgencyCode()
  const refCode = captureRefCode() // URL is clean again after init(); re-check
  if (refCode) {
    // The server decides who counts as this customer's sales (see migration_015). Failure must not block login.
    try { await supabase.rpc('register_referral_click', { p_code: refCode }) } catch { /* ignore */ }
    try { localStorage.removeItem(REF_KEY) } catch { /* storage blocked */ }
  }

  return { profile, isMock: USE_MOCK_LIFF, refCode }
}
