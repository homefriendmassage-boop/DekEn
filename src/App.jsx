import { useCallback, useEffect, useRef, useState } from 'react'
import { supabase } from './supabaseClient'
import { signIn, takeOpenIntent, getAgencyCode } from './lib/auth'
import { getPosition } from './lib/geo'
import { CATEGORIES, PLAN_META, canViewWorker, suspensionOf, tierOf } from './config'
import { useI18n } from './i18n'
import Header from './components/Header'
import Landing from './components/Landing'
import CategoryPicker from './components/CategoryPicker'
import HomeFeed from './components/HomeFeed'
import BookingModal from './components/BookingModal'
import MembershipModal from './components/MembershipModal'
import WorkerApply from './components/WorkerApply'
import WorkerDashboard from './components/WorkerDashboard'
import ChatModal from './components/ChatModal'
import PaymentModal from './components/PaymentModal'
import WalletModal from './components/WalletModal'
import SupportChat from './components/SupportChat'
import AgencyArea from './components/agency/AgencyArea'
import ThreadList from './components/ThreadList'

// Mock mode only, when the workers table is empty: lets you click through the UI
// before running seed SQL. Rank within a category = order in this list.
const DEMO_WORKERS = CATEGORIES.flatMap((category, ci) =>
  Array.from({ length: category === 'ent' ? 12 : 4 }, (_, i) => ({
    user_id: `demo-${category}-${i}`,
    display_name: `Demo ${ci * 10 + i + 1}`,
    category,
    categories: [category],
    price: 1500 + i * 250,
    profile_image: `https://picsum.photos/seed/${category}${i}/600/800`,
    is_online: i % 4 !== 3,
    is_boosted: i === 0,
    rank: i + 1,
    province: i % 2 ? 'เชียงใหม่' : 'กรุงเทพมหานคร',
    district: i % 2 ? 'เมือง' : 'บางรัก',
    demo: true,
  })),
)

// A plain reload would reuse the stale ?code=/&state= in the URL and the broken
// cached LIFF token. Wipe both and restart from the clean app URL.
function resetAndRetry() {
  try {
    Object.keys(localStorage).filter((k) => k.startsWith('LIFF_STORE')).forEach((k) => localStorage.removeItem(k))
  } catch { /* storage blocked */ }
  window.location.replace(window.location.origin + window.location.pathname)
}

export default function App() {
  const { t, catName, money } = useI18n()
  const [phase, setPhase] = useState('loading') // loading | ready | error
  const [error, setError] = useState(null)
  const [session, setSession] = useState(null)  // { profile, isMock, refCode }
  const [me, setMe] = useState(null)            // row from public.users

  const [workerTab, setWorkerTab] = useState('self')   // inside the provider side: self | agency
  const [view, setView] = useState('landing')   // landing | categories | feed | worker | agency
  const [category, setCategory] = useState(null)
  const [workers, setWorkers] = useState([])
  const [signedUrls, setSignedUrls] = useState({})     // original_path -> signed URL
  const [feedLoading, setFeedLoading] = useState(false)
  const nearRef = useRef(null)                            // { lat, lng } while "near me" is on (used for this query only, never stored)
  const [nearOn, setNearOn] = useState(false)
  const [nearBusy, setNearBusy] = useState(false)
  const [selected, setSelected] = useState(null)       // worker being booked
  const [showMembership, setShowMembership] = useState(false)
  const [toast, setToast] = useState(null)
  const [previewTier, setPreviewTier] = useState(null) // mock-mode UI override (null = real)
  const [chat, setChat] = useState(null)              // { id, other_name } of the open chat
  const [showThreads, setShowThreads] = useState(false)
  const [chatUnread, setChatUnread] = useState(0)
  const [support, setSupport] = useState(null)       // { threadId } while the admin chat is open
  const [supportUnread, setSupportUnread] = useState(0)
  const [showWallet, setShowWallet] = useState(false)
  const [invitedBy, setInvitedBy] = useState(null)       // agency name when the app was opened from an agency invitation
  const [walletPaying, setWalletPaying] = useState(false)
  const [pay, setPay] = useState(null)               // { kind: 'membership', tier } | { kind: 'wallet_topup' }

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

  // ---- Boot: login -> profile row ----
  useEffect(() => {
    let cancelled = false
    ;(async () => {
      try {
        const s = await signIn()
        if (cancelled) return
        setSession(s)
        try { await supabase.rpc('release_my_expired_holds') } catch { /* optional */ }   // chat holds that ran out go back to the Wallet
        await loadMe()
        const inv = getAgencyCode()
        if (inv) {
          const { data } = await supabase.rpc('agency_public', { p_code: inv })
          if (data?.[0]) { setInvitedBy(data[0].name); setView('worker') }   // straight to the application form
        }
        if (takeOpenIntent() === 'plans') { setView('categories'); setShowMembership(true) } // opened from a renewal reminder
        if (!cancelled) setPhase('ready')
      } catch (e) {
        console.error(e)
        if (!cancelled) { setError(e.message ?? String(e)); setPhase('error') }
      }
    })()
    return () => { cancelled = true }
  }, [loadMe])

  // ---- Realtime: wallet top-ups / membership changes appear instantly ----
  useEffect(() => {
    if (!me?.id) return
    const ch = supabase
      .channel('me')
      .on('postgres_changes', { event: 'UPDATE', schema: 'public', table: 'users', filter: `id=eq.${me.id}` },
        (p) => setMe(p.new))
      .subscribe()
    return () => { supabase.removeChannel(ch) }
  }, [me?.id])

  // Admin replies: unread badge on the support button (RLS limits these events to my own thread)
  const loadSupportUnread = useCallback(async () => {
    const { data } = await supabase.rpc('my_support')
    setSupportUnread(data?.[0]?.unread ?? 0)
  }, [])
  useEffect(() => {
    if (!me?.id) return
    loadSupportUnread()
    const ch = supabase.channel('support-badge')
      .on('postgres_changes', { event: 'INSERT', schema: 'public', table: 'support_messages' }, loadSupportUnread)
      .subscribe()
    return () => { supabase.removeChannel(ch) }
  }, [me?.id, loadSupportUnread])

  async function payWithWallet(planTier, price) {
    if (walletPaying) return
    if (!window.confirm(t('payWalletConfirm', { plan: PLAN_META[planTier].name, amount: money(price) }))) return
    setWalletPaying(true)
    const { error } = await supabase.rpc('buy_membership_with_wallet', { p_tier: planTier })
    setWalletPaying(false)
    if (error) {
      if (error.message.includes('DUPLICATE_REQUEST')) return
      const code = ['INSUFFICIENT_BALANCE', 'ALREADY_HIGHER', 'SUSPENDED'].find((c) => error.message.includes(c))
      return showToast(t(code ? `payErr_${code}` : 'errGeneric'))
    }
    setShowMembership(false)
    showToast(t('paySuccessMembership', { plan: PLAN_META[planTier].name }))
    await loadMe()
    if (view === 'feed') loadFeed(category)
  }

  async function openSupport() {
    const { data, error } = await supabase.rpc('support_open')
    if (error || !data) return showToast(t('errGeneric'))
    setSupport({ threadId: data })
  }

  const tier = session?.isMock && previewTier !== null ? previewTier : tierOf(me)

  // ---- Feed: the server decides what we may see (list_workers); then we fetch
  //      signed URLs for the full photos of the workers we are allowed to view. ----
  const loadFeed = useCallback(async (cat) => {
    setFeedLoading(true)
    setWorkers([])
    try {
      const pos = nearRef.current
      const { data, error } = pos
        ? await supabase.rpc('list_workers_near', { p_lat: pos.lat, p_lng: pos.lng, p_radius_km: 50, p_category: cat })
        : await supabase.rpc('list_workers', { p_category: cat })
      if (error) throw error
      let rows = data ?? []
      if (rows.length === 0 && session?.isMock && !pos) rows = DEMO_WORKERS.filter((w) => w.category === cat)

      const paths = rows.filter((w) => w.can_view && w.original_path).map((w) => w.original_path)
      const signed = {}
      if (paths.length) {
        const { data: urls } = await supabase.storage.from('worker-originals').createSignedUrls(paths, 3600)
        urls?.forEach((u) => { if (u.signedUrl) signed[u.path] = u.signedUrl })
      }
      setSignedUrls(signed)
      setWorkers(rows)
    } catch (e) {
      console.error(e)
      showToast(t('errGeneric'))
    }
    setFeedLoading(false)
  }, [session?.isMock]) // eslint-disable-line react-hooks/exhaustive-deps

  async function toggleNear() {
    if (nearOn) { nearRef.current = null; setNearOn(false); return loadFeed(category) }
    setNearBusy(true)
    try {
      nearRef.current = await getPosition()
      setNearOn(true)
      await loadFeed(category)
    } catch {
      nearRef.current = null
      showToast(t('nearDenied'))
    }
    setNearBusy(false)
  }

  // Open (or create) the chat with a provider. The DB enforces: paid member + may view that provider.
  async function askWorker(w) {
    const { data, error } = await supabase.rpc('open_thread', { p_worker: w.user_id })
    if (error) {
      if (error.message.includes('MEMBERS_ONLY')) return setShowMembership(true)      // not a paid member
      if (error.message.includes('SELF_CHAT')) return showToast(t('errSelfChat'))
      if (error.message.includes('LOCKED')) return showToast(t('errLocked'))
      return showToast(t('errGeneric'))
    }
    setChat({ id: data, other_name: w.display_name })
  }

  function openCategory(cat) {
    setCategory(cat)
    setView('feed')
    loadFeed(cat)
  }

  // Real rows carry can_view from the DB; demo rows use the UI-side copy of the rule.
  const feedRows = workers.map((w) => {
    const canView = w.can_view ?? canViewWorker(w.category, w.rank, tier)
    const full = canView && w.original_path ? signedUrls[w.original_path] : null
    return { ...w, canView, image: full ?? w.profile_image }
  })

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
        <p className="text-lg font-semibold">{t('startFail')}</p>
        <p className="max-w-sm break-words text-sm text-neutral-400">{error}</p>
        <button onClick={resetAndRetry} className="rounded-full bg-line px-5 py-2 font-semibold text-black">{t('retry')}</button>
      </div>
    )
  }

  const suspension = suspensionOf(me)
  if (suspension) {
    return (
      <div className="flex min-h-screen flex-col items-center justify-center gap-3 p-6 text-center">
        <p className="text-5xl">⛔</p>
        <p className="text-lg font-bold">{t('suspendedTitle')}</p>
        <p className="text-sm text-neutral-300">
          {suspension.forever ? t('suspendedForever') : t('suspendedUntil', { date: suspension.until.toLocaleDateString() })}
          {me.suspend_reason ? ` · ${me.suspend_reason}` : ''}
        </p>
        <p className="max-w-sm text-sm text-neutral-400">{t('suspendedBody')}</p>
        <button onClick={openSupport} className="rounded-full bg-line px-5 py-2 font-semibold text-black">{t('chatAdmin')}</button>
        {support && <SupportChat threadId={support.threadId} onClose={() => { setSupport(null); loadSupportUnread() }} />}
      </div>
    )
  }

  const headerProps = {
    displayName: session.profile.displayName,
    tier,
    expiresAt: me?.vip_expires_at,
    walletBalance: me?.wallet_balance ?? 0,
    onTierClick: () => setShowMembership(true),
    onWalletClick: () => setShowWallet(true),
    onSupportClick: openSupport,
    supportUnread,
    // chat icon only for paid members (others have no chat to show)
    onChatClick: tier >= 1 ? () => setShowThreads(true) : undefined,
    chatUnread,
  }

  return (
    <div className="mx-auto min-h-screen w-full max-w-3xl pb-[env(safe-area-inset-bottom)]">
      {/* Dev bar: only rendered in mock mode */}
      {session.isMock && (
        <div className="flex flex-wrap items-center gap-x-3 gap-y-1 bg-amber-400 px-3 py-1.5 text-xs font-medium text-black">
          <span>MOCK · ref: {session.refCode ?? '—'}</span>
          <label className="ml-auto flex items-center gap-1">
            tier (UI preview)
            <select value={previewTier ?? ''} onChange={(e) => setPreviewTier(e.target.value === '' ? null : Number(e.target.value))}>
              <option value="">real</option>
              {[0, 1, 2, 3].map((n) => <option key={n} value={n}>{n}</option>)}
            </select>
          </label>
        </div>
      )}

      {view === 'landing' && (
        <Landing
          displayName={session.profile.displayName}
          role={me?.role}
          onCustomer={() => setView('categories')}
          onWorker={() => setView('worker')}
          invitedBy={invitedBy}
        />
      )}

      {view === 'categories' && (
        <>
          <Header {...headerProps} title={t('categories')} onBack={() => setView('landing')} />
          <CategoryPicker tier={tier} onPick={openCategory} onLocked={() => setShowMembership(true)} />
        </>
      )}

      {view === 'feed' && (
        <>
          <Header {...headerProps} title={catName(category)} onBack={() => setView('categories')} />
          <HomeFeed
            workers={feedRows}
            category={category}
            tier={tier}
            loading={feedLoading}
            onBook={setSelected}
            onUnlock={() => setShowMembership(true)}
            nearOn={nearOn} nearBusy={nearBusy} onToggleNear={toggleNear}
            onAsk={askWorker}
            meId={me?.id}
          />
        </>
      )}

      {view === 'worker' && (
        <>
          <Header
            displayName={session.profile.displayName}
            title={t('providerSide')}
            onBack={() => setView('landing')}
          />
          {/* One place for everything on the provider side: on my own, or through a modelling agency */}
          <nav className="grid grid-cols-2 gap-2 px-4 pt-3">
            {[['self', me?.role === 'worker' ? t('tabMyProfile') : t('tabSelf')], ['agency', t('tabAgency')]].map(([id, label]) => (
              <button key={id} onClick={() => setWorkerTab(id)} aria-pressed={workerTab === id}
                className={`rounded-xl py-2.5 text-sm font-bold active:scale-95 ${workerTab === id ? 'bg-line text-black' : 'bg-white/10 text-neutral-200'}`}>{label}</button>
            ))}
          </nav>
          {workerTab === 'agency'
            ? <AgencyArea embedded me={me} onChanged={loadMe} onTopUp={() => setPay({ kind: 'wallet_topup' })} onWallet={() => setShowWallet(true)} />
            : me?.role === 'worker'
              ? <WorkerDashboard userId={me.id} onTopUp={() => setPay({ kind: 'wallet_topup' })} />
              : <WorkerApply userId={me.id} defaultName={session.profile.displayName} />}
        </>
      )}

      {selected && (
        <BookingModal
          worker={selected}
          customerId={me.id}
          walletBalance={me?.wallet_balance ?? 0}
          onClose={() => setSelected(null)}
          onTopUp={() => { setSelected(null); setPay({ kind: 'wallet_topup' }) }}
          onBooked={async () => {
            setSelected(null)
            await loadMe() // refresh balance immediately (realtime is a backup)
            showToast(t('booked'))
          }}
        />
      )}

      {showThreads && (
        <div className="fixed inset-0 z-40 flex items-end justify-center bg-black/70 sm:items-center sm:p-4" onClick={() => setShowThreads(false)}>
          <div onClick={(e) => e.stopPropagation()} className="max-h-[80vh] w-full max-w-md overflow-y-auto rounded-t-3xl bg-neutral-900 p-5 sm:rounded-3xl">
            <h2 className="mb-3 text-lg font-bold">💬 {t('messages')}</h2>
            <ThreadList role="customer" onOpen={(th) => { setShowThreads(false); setChat(th) }} onChange={(rows) => setChatUnread(rows.reduce((n, r) => n + r.unread, 0))} />
            <button onClick={() => setShowThreads(false)} className="mt-4 w-full rounded-xl bg-white/10 py-3 font-semibold active:scale-95">{t('close')}</button>
          </div>
        </div>
      )}

      {chat && view !== 'worker' && <ChatModal threadId={chat.id} title={chat.other_name} meId={me.id} onClose={() => setChat(null)}
          onTopUp={() => { setChat(null); setPay({ kind: 'wallet_topup' }) }} />}

      {showMembership && (
        <MembershipModal tier={tier} walletBalance={Number(me?.wallet_balance ?? 0)} onPayWallet={payWithWallet} onClose={() => setShowMembership(false)}
          onPay={(planTier) => { setShowMembership(false); setPay({ kind: 'membership', tier: planTier, upgrade: tier > 0 && planTier > tier }) }}
          onSupport={() => { setShowMembership(false); openSupport() }} />
      )}

      {showWallet && (
        <WalletModal me={me} onClose={() => setShowWallet(false)} onChanged={loadMe}
          onTopUp={() => { setShowWallet(false); setPay({ kind: 'wallet_topup' }) }} />
      )}

      {pay && (
        <PaymentModal kind={pay.kind} tier={pay.tier} upgrade={pay.upgrade} onClose={() => setPay(null)} onOpenSupport={openSupport}
          onPaid={() => { loadMe(); if (view === 'feed') loadFeed(category) }} />
      )}

      {support && (
        <SupportChat threadId={support.threadId} onClose={() => { setSupport(null); loadSupportUnread() }} />
      )}

      {toast && (
        <div className="fixed inset-x-4 bottom-6 z-[60] mx-auto max-w-sm rounded-xl bg-line px-4 py-3 text-center text-sm font-semibold text-black shadow-lg">
          {toast}
        </div>
      )}
    </div>
  )
}
