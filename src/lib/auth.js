import liff from '@line/liff'
import { supabase } from '../supabaseClient'
import { LIFF_ID, USE_MOCK_LIFF } from '../config'

const REF_KEY = 'partner_ref'
const REF_PATTERN = /^[A-Za-z0-9_-]{1,32}$/ // reject anything odd before it reaches the DB

/**
 * Read the partner code from the URL, e.g. https://liff.line.me/<id>?ref=sales01
 *
 * Gotcha: on first open LINE rewrites the URL and tucks the original query into
 * `liff.state` (e.g. "?ref=sales01"), so we check both. Call this before AND
 * after liff.init(). First-touch wins: a stored code is never overwritten.
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
    if (ref && REF_PATTERN.test(ref) && !localStorage.getItem(REF_KEY)) {
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

  const refCode = captureRefCode() // URL is clean again after init(); re-check
  if (refCode) {
    // Idempotent + first-touch enforced server-side. Failure must not block login.
    try { await supabase.rpc('attribute_referrer', { p_code: refCode }) } catch { /* ignore */ }
  }

  return { profile, isMock: USE_MOCK_LIFF, refCode }
}
