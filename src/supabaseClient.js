import { createClient } from '@supabase/supabase-js'

// Keep only the origin: pasting ".../rest/v1" (from the Data API page) would
// otherwise produce broken paths like /rest/v1/functions/v1/line-auth.
const rawUrl = import.meta.env.VITE_SUPABASE_URL
const url = rawUrl ? new URL(rawUrl).origin : rawUrl
const anonKey = import.meta.env.VITE_SUPABASE_ANON_KEY

if (!url || !anonKey) {
  // Fail loudly in dev instead of silently sending requests to "undefined".
  throw new Error('Missing VITE_SUPABASE_URL / VITE_SUPABASE_ANON_KEY. Copy .env.example to .env.local.')
}

// The anon key is safe to ship in the browser: access is enforced by RLS +
// column grants (see supabase/schema.sql). NEVER expose the service_role key.
export const supabase = createClient(url, anonKey, {
  auth: {
    persistSession: true,        // keep the session in localStorage between opens
    autoRefreshToken: true,
    detectSessionInUrl: false,   // LIFF uses the URL for its own params
  },
})
