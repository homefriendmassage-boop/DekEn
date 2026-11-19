import { supabase } from '../supabaseClient'

// Signed URLs of the private originals. A new URL (new token) is a new file for the browser cache, so asking for fresh ones every time
// downloads the same pictures again and again. Keep each one in memory and reuse it until it is close to expiry: the browser then
// serves the picture from its cache and Supabase Storage sends it only once.
const TTL = 7200          // seconds a URL stays valid
const KEEP = 600          // stop reusing it this many seconds before it expires
const cache = new Map()   // path -> { url, exp (ms) }

export async function signedUrls(paths, bucket = 'worker-originals') {
  const now = Date.now()
  const out = {}
  const need = []
  for (const p of new Set((paths ?? []).filter(Boolean))) {
    const hit = cache.get(`${bucket}/${p}`)
    if (hit && hit.exp - now > KEEP * 1000) out[p] = hit.url
    else need.push(p)
  }
  if (need.length) {
    const { data } = await supabase.storage.from(bucket).createSignedUrls(need, TTL)
    data?.forEach((u) => {
      if (!u.signedUrl) return
      out[u.path] = u.signedUrl
      cache.set(`${bucket}/${u.path}`, { url: u.signedUrl, exp: now + TTL * 1000 })
    })
  }
  return out
}

// on sign-out / account switch nothing may be reused
export const clearSignedUrls = () => cache.clear()
