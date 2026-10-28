import { useCallback, useEffect, useState } from 'react'
import { supabase } from './supabaseClient'
import { signIn } from './lib/auth'
import HomeFeed from './components/HomeFeed'
import BookingModal from './components/BookingModal'

// Shown only in mock mode when the workers table is empty, so the UI is testable
// before you run supabase/seed.sql. Booking these will fail (fake ids) by design.
const DEMO_WORKERS = [
  { user_id: 'demo-1', display_name: 'Mild', service_types: ['massage'], price: 2000, is_online: true, is_boosted: true, profile_image: 'https://picsum.photos/seed/w1/600/800' },
  { user_id: 'demo-2', display_name: 'Ploy', service_types: ['singer', 'mc'], price: 3500, is_online: true, is_boosted: false, profile_image: 'https://picsum.photos/seed/w2/600/800' },
  { user_id: 'demo-3', display_name: 'Fah', service_types: ['massage', 'spa'], price: 1800, is_online: false, is_boosted: false, profile_image: 'https://picsum.photos/seed/w3/600/800' },
  { user_id: 'demo-4', display_name: 'Nook', service_types: ['dancer'], price: 2500, is_online: true, is_boosted: true, profile_image: 'https://picsum.photos/seed/w4/600/800' },
]

// A plain reload would reuse the stale ?code=/&state= in the URL and the broken
// cached LIFF token. Wipe both and restart from the clean app URL.
function resetAndRetry() {
  try {
    Object.keys(localStorage).filter((k) => k.startsWith('LIFF_STORE')).forEach((k) => localStorage.removeItem(k))
  } catch { /* storage blocked */ }
  window.location.replace(window.location.origin + window.location.pathname)
}

export default function App() {
  const [phase, setPhase] = useState('loading') // loading | ready | error
  const [error, setError] = useState(null)
  const [session, setSession] = useState(null)  // { profile, isMock, refCode }
  const [me, setMe] = useState(null)            // row from public.users
  const [workers, setWorkers] = useState([])
  const [selected, setSelected] = useState(null) // worker being booked
  const [toast, setToast] = useState(null)
  const [previewVip, setPreviewVip] = useState(false) // mock-mode UI toggle only

  const showToast = (msg) => {
    setToast(msg)
    setTimeout(() => setToast(null), 3500)
  }

  const loadMe = useCallback(async () => {
    const { data: auth } = await supabase.auth.getUser()
    if (!auth.user) return null
    const { data, error } = await supabase.from('users').select('*').eq('id', auth.user.id).single()
    if (error) throw error
    setMe(data)
    return data
  }, [])

  const loadWorkers = useCallback(async (isMock) => {
    const { data, error } = await supabase
      .from('workers')
      .select('*')
      .order('is_boosted', { ascending: false }) // boosted first
      .order('is_online', { ascending: false })  // then online
    if (error) throw error
    setWorkers(isMock && data.length === 0 ? DEMO_WORKERS : data)
  }, [])

  // ---- Boot: login -> profile row -> workers ----
  useEffect(() => {
    let cancelled = false
    ;(async () => {
      try {
        const s = await signIn()
        if (cancelled) return
        setSession(s)
        await Promise.all([loadMe(), loadWorkers(s.isMock)])
        if (!cancelled) setPhase('ready')
      } catch (e) {
        console.error(e)
        if (!cancelled) { setError(e.message ?? String(e)); setPhase('error') }
      }
    })()
    return () => { cancelled = true }
  }, [loadMe, loadWorkers])

  // ---- Realtime: wallet top-ups / VIP changes / worker status appear instantly ----
  useEffect(() => {
    if (!me?.id) return
    const ch = supabase
      .channel('live')
      .on('postgres_changes', { event: 'UPDATE', schema: 'public', table: 'users', filter: `id=eq.${me.id}` },
        (p) => setMe(p.new))
      .on('postgres_changes', { event: '*', schema: 'public', table: 'workers' },
        () => loadWorkers(session?.isMock))
      .subscribe()
    return () => { supabase.removeChannel(ch) }
  }, [me?.id, session?.isMock, loadWorkers])

  if (phase === 'loading') {
    return (
      <div className="flex min-h-screen items-center justify-center">
        <div className="h-10 w-10 animate-spin rounded-full border-4 border-neutral-700 border-t-line" />
      </div>
    )
  }

  if (phase === 'error') {
    return (
      <div className="flex min-h-screen flex-col items-center justify-center gap-3 p-6 text-center">
        <p className="text-lg font-semibold">Couldn't start the app</p>
        <p className="max-w-sm break-words text-sm text-neutral-400">{error}</p>
        <button onClick={resetAndRetry} className="rounded-full bg-line px-5 py-2 font-semibold text-black">Retry</button>
      </div>
    )
  }

  const isVip = Boolean(me?.is_vip) || (session.isMock && previewVip)

  return (
    <div className="mx-auto min-h-screen w-full max-w-3xl pb-[env(safe-area-inset-bottom)]">
      {/* Dev bar: only rendered in mock mode */}
      {session.isMock && (
        <div className="flex flex-wrap items-center gap-x-3 gap-y-1 bg-amber-400 px-3 py-1.5 text-xs font-medium text-black">
          <span>MOCK LOGIN · {session.profile.displayName}</span>
          <span>ref: {session.refCode ?? '—'}</span>
          <label className="ml-auto flex items-center gap-1">
            <input type="checkbox" checked={previewVip} onChange={(e) => setPreviewVip(e.target.checked)} />
            Preview as VIP
          </label>
        </div>
      )}

      <HomeFeed
        workers={workers}
        isVip={isVip}
        walletBalance={me?.wallet_balance ?? 0}
        displayName={session.profile.displayName}
        onBook={setSelected}
      />

      {selected && (
        <BookingModal
          worker={selected}
          customerId={me.id}
          walletBalance={me?.wallet_balance ?? 0}
          onClose={() => setSelected(null)}
          onBooked={async () => {
            setSelected(null)
            await loadMe() // refresh balance immediately (realtime is a backup)
            showToast('Booking confirmed! The worker has been notified.')
          }}
        />
      )}

      {toast && (
        <div className="fixed inset-x-4 bottom-6 z-[60] mx-auto max-w-sm rounded-xl bg-line px-4 py-3 text-center text-sm font-semibold text-black shadow-lg">
          {toast}
        </div>
      )}
    </div>
  )
}
