import { supabase } from '../supabaseClient'
import { LIFF_ID, USE_MOCK_LIFF } from '../config'

// A "vendor" is a seller with his own LINE Official Account + LIFF app. His LIFF endpoint is our app with ?vendor=<id>, so every
// customer who opens HIS link is logged in through HIS LIFF (and becomes his customer). Without the parameter we are the central app.
const KEY = 'vendor_id'
const PATTERN = /^[a-z0-9]{4,16}$/

let current = null   // { id, name, liff_id, add_friend_url } | null

function fromUrl(name) {
  const params = new URLSearchParams(window.location.search)
  let v = params.get(name)
  if (!v) {
    const state = params.get('liff.state')           // LINE tucks the original query into liff.state on first open
    if (state) { const q = state.indexOf('?'); v = new URLSearchParams(q >= 0 ? state.slice(q) : state).get(name) }
  }
  return v
}

export async function resolveVendor() {
  if (USE_MOCK_LIFF) return (current = null)
  let id = fromUrl('vendor')
  try {
    if (id && PATTERN.test(id)) sessionStorage.setItem(KEY, id)
    else id = sessionStorage.getItem(KEY)
  } catch { /* storage blocked */ }
  let row = null
  if (id && PATTERN.test(id)) {
    const { data } = await supabase.rpc('vendor_public', { p_vendor: id })
    row = data?.[0] ?? null
  }
  if (!row) {                                          // fallback: LIFF adds the channel id of the LIFF app it opened
    const channel = fromUrl('liffClientId')
    if (channel && /^\d+$/.test(channel)) {
      const { data } = await supabase.rpc('vendor_by_channel', { p_channel: channel })
      row = data?.[0] ?? null
    }
  }
  return (current = row)
}

export const getVendor = () => current
export const getActiveLiffId = () => current?.liff_id ?? LIFF_ID
// One LINE Provider for every seller: the same account works in every seller's LIFF. Only sessions made by the old per-seller
// accounts ('<seller>:<LINE id>') have to be replaced.
export function sessionMatches(session) {
  return !String(session?.user?.user_metadata?.line_user_id ?? '').includes(':')
}
