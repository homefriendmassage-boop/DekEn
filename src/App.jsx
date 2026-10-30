import { useCallback, useEffect, useRef, useState } from 'react'
import { supabase } from './supabaseClient'
import { signIn, takeOpenIntent, takeWorkerIntent, takeChatIntent, takeDraftIntent, takeJobIntent, takeSupportIntent, getAgencyCode, isApplyOnly, clearApplyOnly, takeAgencyPageIntent } from './lib/auth'
import { getPosition } from './lib/geo'
import { CATEGORIES, PLAN_META, canViewWorker, suspensionOf, tierOf } from './config'
import { LangSwitcher, useI18n } from './i18n'
import SellerPanel from './components/SellerPanel'
import ShareModal from './components/ShareModal'
import Header from './components/Header'
import logo from './assets/dekn-logo.jpg'
import CategoryPicker from './components/CategoryPicker'
import HomeFeed from './components/HomeFeed'
import BookingModal from './components/BookingModal'
import MembershipModal from './components/MembershipModal'
import { AgencyHeader } from './components/AgencyStrip'
import WorkerApply from './components/WorkerApply'
import WorkerDashboard from './components/WorkerDashboard'
import ChatModal from './components/ChatModal'
import PaymentModal from './components/PaymentModal'
import WalletModal from './components/WalletModal'
import SupportChat from './components/SupportChat'
import AgencyArea from './components/agency/AgencyArea'
import ThreadList from './components/ThreadList'
import WorkerDetail from './components/WorkerDetail'
import ClaimDraft from './components/ClaimDraft'
import MyBookings from './components/MyBookings'
import VendorInbox from './components/VendorInbox'

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
  const [view, setView] = useState('categories')   // categories | feed | worker | agency
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
  const [agDir, setAgDir] = useState({ agencies: [], members: {} })   // agencies a customer may see (active plan) and which girl belongs to which
  const [agencyFilter, setAgencyFilter] = useState(null)             // id of the agency whose page is open
  const [custThreads, setCustThreads] = useState([])    // my chats with providers: who replied and I haven't read
  const [support, setSupport] = useState(null)       // { threadId } while the admin chat is open
  const [supportUnread, setSupportUnread] = useState(0)
  const [showWallet, setShowWallet] = useState(false)
  const [invitedBy, setInvitedBy] = useState(null)       // agency name when the app was opened from an agency invitation
  const [walletPaying, setWalletPaying] = useState(false)
  const [termsBusy, setTermsBusy] = useState(false)
  const [staffVendor, setStaffVendor] = useState(null)   // the seller whose customers' chats I answer (seller's staff only)
  const [inbox, setInbox] = useState(null)                 // null | { thread }
  const [inboxUnread, setInboxUnread] = useState(0)
  const [showBookings, setShowBookings] = useState(false)
  const [showSeller, setShowSeller] = useState(false)
  const [showShare, setShowShare] = useState(false)
  const [sellerSt, setSellerSt] = useState(null)       // my_seller_status: used for the "plan lapsed" notice
  const loadSellerSt = useCallback(() => supabase.rpc('my_seller_status').then(({ data }) => setSellerSt(data ?? null), () => {}), [])
  const [highlightJob, setHighlightJob] = useState(null)   // a booking opened from its push
  const [applyOnly, setApplyOnly] = useState(false)    // opened from a registration-only link: nothing but the application form
  const [claim, setClaim] = useState(null)            // token of an application draft someone filled in for her
  const [openChat, setOpenChat] = useState(null)      // chat to open inside the provider side
  const [shared, setShared] = useState(null)         // { id, friend, worker } when the app was opened from a shared profile link
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
        setApplyOnly(isApplyOnly())
        try { await supabase.rpc('release_my_expired_holds') } catch { /* optional */ }   // chat holds that ran out go back to the Wallet
        const meRow = await loadMe()
        loadSellerSt()
        if (meRow?.role === 'worker') setView('worker')   // providers mostly open the app to take jobs: straight to their own side
        const inv = getAgencyCode()
        if (inv) {
          const { data } = await supabase.rpc('agency_public', { p_code: inv })
          if (data?.[0]) { setInvitedBy(data[0].name); setView('worker') }   // straight to the application form
        }
        const openIntent = takeOpenIntent()
        if (openIntent === 'home') setView('categories')          // customer link: straight to the customer side, even for providers
        if (openIntent === 'plans') { setView('categories'); setShowMembership(true) } // opened from a renewal reminder
        if (openIntent === 'share') { setView('categories'); setShowShare(true) }       // opened from the new seller's Flex
        if (openIntent === 'seller') { setView('categories'); setShowSeller(true) }     // seller plan reminder
        if (['bartender', 'ent', 'masseuse', 'spa'].includes(openIntent)) openCategory(openIntent)     // payment Flex: straight to that group
        if (openIntent === 'wallet') { setView('categories'); setShowWallet(true) }              // withdrawal / identity Flex
        if (openIntent === 'alive') { setView('worker'); setWorkerTab('self'); showToast('ยืนยันแล้ว ขอบคุณค่ะ โปรไฟล์ของคุณแสดงตามปกติ') }   // "still working?" Flex: opening the app is the confirmation
        if (openIntent === 'worker') { setView('worker'); setWorkerTab('self') }     // approval Flex
        if (openIntent === 'agency') { setView('worker'); setWorkerTab('agency') }       // agency plan Flex / reminder
        const chatId = takeChatIntent()        // opened from the "new message" push: go straight to that chat room
        if (chatId && meRow) {
          const { data: ths } = await supabase.rpc('my_threads', { p_role: null })
          const th = (ths ?? []).find((x) => x.id === chatId)
          if (th && th.worker_id === meRow.id) { setView('worker'); setWorkerTab('self'); setOpenChat(th) }
          else if (th) { setView('categories'); setChat(th) }
        }
        let staffOf = null
        if (s.vendor) {      // a seller's staff member opening his seller's app gets the customers' inbox
          const { data: sv } = await supabase.rpc('my_vendor_staff')
          staffOf = sv ?? null
          setStaffVendor(staffOf)
          if (staffOf) { const { data: ths } = await supabase.rpc('support_threads_for', { p_vendor: staffOf }); setInboxUnread((ths ?? []).reduce((n, x) => n + x.unread, 0)) }
        }
        const supportIntent = takeSupportIntent()
        if (supportIntent) {
          if (staffOf) setInbox({ thread: supportIntent === 'open' ? null : supportIntent })
          else { const { data: th } = await supabase.rpc('support_open'); if (th) setSupport({ threadId: th }) }
        }
        const jobId = takeJobIntent()          // a booking push: provider -> her inbox, customer -> my bookings
        if (jobId && meRow) {
          const { data: jb } = await supabase.from('jobs').select('id, customer_id, worker_id').eq('id', jobId).maybeSingle()
          if (jb) {
            setHighlightJob(jb.id)
            if (jb.worker_id === meRow.id) { setView('worker'); setWorkerTab('self') } else { setView('categories'); setShowBookings(true) }
          }
        }
        const draftTok = takeDraftIntent()     // a link an admin / modelling agency issued for her
        if (draftTok) setClaim(draftTok)
        const { data: dir } = await supabase.rpc('agency_directory')
        if (dir?.agencies) setAgDir(dir)
        const agencyPage = takeAgencyPageIntent()      // a link to an agency's page
        if (agencyPage) {
          const ag = dir?.agencies?.find((a) => a.id === agencyPage)
          if (ag) { setAgencyFilter(ag.id); setCategory(ag.cats[0]); setView('feed'); loadFeed(ag.cats[0]) } else showToast(t('agencyNotFound'))
        }
        const sharedId = takeWorkerIntent()
        if (sharedId) { setView('categories'); setShared({ id: sharedId, friend: true, worker: null }) }   // no forced friend-adding for customers
        if (!cancelled) setPhase('ready')
      } catch (e) {
        console.error(e)
        if (!cancelled) { setError(e.message ?? String(e)); setPhase('error') }
      }
    })()
    return () => { cancelled = true }
  }, [loadMe])

  // Shared profile link: once the viewer follows the official account, fetch that provider (the DB decides what the viewer may see).
  useEffect(() => {
    if (!shared || shared.worker !== null) return
    ;(async () => {
      const { data } = await supabase.rpc('get_worker', { p_worker: shared.id })
      const w = data?.[0]
      if (!w) return setShared((x) => x && { ...x, worker: false })
      let full = null
      if (w.can_view && w.original_path) {
        const { data: urls } = await supabase.storage.from('worker-originals').createSignedUrls([w.original_path], 3600)
        full = urls?.[0]?.signedUrl ?? null
      }
      setShared((x) => x && { ...x, worker: { ...w, canView: w.can_view, image: full ?? w.profile_image } })
    })()
  }, [shared?.worker, shared?.id])

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

  const loadThreads = useCallback(async () => {
    const { data } = await supabase.rpc('my_threads', { p_role: 'customer' })
    const rows = data ?? []
    setCustThreads(rows)
    setChatUnread(rows.reduce((n, r) => n + r.unread, 0))
  }, [])
  useEffect(() => {
    if (!me?.id) return
    loadThreads()
    const ch = supabase.channel('cust-threads').on('postgres_changes', { event: 'INSERT', schema: 'public', table: 'chat_messages' }, loadThreads).subscribe()
    return () => { supabase.removeChannel(ch) }
  }, [me?.id, loadThreads])
  useEffect(() => {
    if (!me?.id || (view !== 'feed' && view !== 'categories')) return
    supabase.rpc('agency_directory').then(({ data }) => { if (data?.agencies) setAgDir(data) })
  }, [me?.id, view])
  const unreadByWorker = Object.fromEntries(custThreads.filter((x) => x.unread > 0).map((x) => [x.worker_id, x.unread]))
  const replyNotice = custThreads.some((x) => x.unread > 0) && (
    <div className="space-y-1.5 px-4 pt-3">
      {custThreads.filter((x) => x.unread > 0).slice(0, 3).map((th) => (
        <button key={th.id} onClick={() => { setChat(th) }} className="flex w-full animate-pulse items-center justify-between gap-2 rounded-xl bg-red-500/20 px-3 py-2.5 text-left text-sm font-bold text-red-100 ring-1 ring-red-400/50 active:scale-95">
          <span className="min-w-0 truncate">{t('replyNotice', { name: th.other_name, n: th.unread })}</span>
        </button>
      ))}
    </div>
  )

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

  // Customers accept the terms once (20+, no contact exchange, chats may be reviewed after a complaint)
  async function acceptTerms() {
    setTermsBusy(true)
    await supabase.rpc('accept_customer_terms')
    await loadMe()
    setTermsBusy(false)
  }

  async function openSupport() {
    const { data, error } = await supabase.rpc('support_open')
    if (error || !data) return showToast(t('errGeneric'))
    setSupport({ threadId: data })
    setSupportUnread(0)            // the chat marks everything read as it opens; clear the red number at once
  }

  const tier = session?.isMock && previewTier !== null ? previewTier : tierOf(me)
  // a paid seller (or the owner of a seller OA) sees every group in full so he can share: the database widens what he sees
  const sellerView = !!sellerSt?.is_seller && sellerSt?.via !== 'provider'
  const viewTier = sellerView ? 3 : tier

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
      if (error.message.includes('SUSPENDED')) return showToast(t('errGeneric'))
      if (error.message.includes('SELF_CHAT')) return showToast(t('errSelfChat'))
      if (error.message.includes('UNCLAIMED')) return showToast('น้องคนนี้ยังไม่ได้ยืนยันโปรไฟล์ ยังแชตไม่ได้')
      if (error.message.includes('LOCKED')) return showToast(t('errLocked'))
      return showToast(t('errGeneric'))
    }
    setChat({ id: data, other_name: w.display_name })
  }

  function openAgency(id) {
    const ag = agDir.agencies.find((a) => a.id === id)
    if (!ag) return showToast(t('agencyNotFound'))
    const cat = ag.cats.includes(category) && view === 'feed' ? category : ag.cats[0]
    setAgencyFilter(id)
    setCategory(cat)
    setView('feed')
    loadFeed(cat)
  }
  function openAgencyCategory(cat) { setCategory(cat); loadFeed(cat) }

  function openCategory(cat) {
    setAgencyFilter(null)
    setCategory(cat)
    setView('feed')
    loadFeed(cat)
  }

  // Real rows carry can_view from the DB; demo rows use the UI-side copy of the rule.
  const feedRows = workers.map((w) => {
    const canView = w.can_view ?? canViewWorker(w.category, w.rank, tier)
    const full = canView && w.original_path ? signedUrls[w.original_path] : null
    const agencyId = agDir.members[w.user_id] ?? null
    const ag = agencyId ? agDir.agencies.find((a) => a.id === agencyId) : null
    // the badge shows only when the agency allows it; on an agency's own page it is redundant (the header says it)
    const badge = ag?.show_badge && !agencyFilter
    return { ...w, canView, image: full ?? w.profile_image, agency_id: agencyId, agency_logo: badge ? w.agency_logo : null, agency_name: badge ? w.agency_name : null }
  }).filter((w) => !agencyFilter || w.agency_id === agencyFilter)
  const openedAgency = agencyFilter ? agDir.agencies.find((a) => a.id === agencyFilter) : null

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
        {support && <SupportChat threadId={support.threadId} onClose={async () => { const id = support?.threadId; setSupport(null); if (id) await supabase.rpc('support_mark_read', { p_thread: id }); loadSupportUnread() }} />}
      </div>
    )
  }

  if (applyOnly && me) {
    return (
      <div className="mx-auto min-h-screen w-full max-w-3xl pb-[env(safe-area-inset-bottom)]">
        <header className="flex items-center justify-between gap-3 border-b border-white/10 px-4 py-3">
          <h1 className="text-lg font-bold">📝 {t('providerSide')}</h1>
          <LangSwitcher />
        </header>
        {me.role === 'worker' ? (
          <div className="space-y-3 p-6 text-center">
            <p className="text-lg font-bold">คุณลงทะเบียนเป็นผู้ให้บริการแล้ว</p>
            <p className="text-sm text-neutral-400">ลิงก์นี้ใช้สำหรับสมัครเท่านั้น กดปุ่มด้านล่างเพื่อเข้าหน้าผู้ให้บริการของคุณ</p>
            <button onClick={() => { clearApplyOnly(); setApplyOnly(false); setView('worker'); setWorkerTab('self') }} className="rounded-full bg-line px-6 py-2.5 font-bold text-black active:scale-95">เข้าหน้าผู้ให้บริการ</button>
          </div>
        ) : <WorkerApply userId={me.id} defaultName={session.profile.displayName} />}
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
    onBookingsClick: () => setShowBookings(true),
    supportUnread,
    onChatClick: () => setShowThreads(true),
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

      {view === 'categories' && (
        <>
          <Header {...headerProps} title={t('categories')} />
          {replyNotice}
          <div className="space-y-2 px-4 pt-3">
            {session.vendor && <p className="text-center text-xs font-semibold text-amber-300">🏪 {t('viaVendor', { name: session.vendor.name })}</p>}
            {staffVendor && (
              <button onClick={() => setInbox({ thread: null })} className="relative flex w-full items-center justify-center gap-2 rounded-xl bg-pink-500 py-2.5 text-sm font-bold active:scale-95">
                💬 {t('staffInbox')}
                {inboxUnread > 0 && <span className="rounded-full bg-red-500 px-2 text-xs">{inboxUnread}</span>}
              </button>
            )}
            {sellerSt?.expired && (
              <button onClick={() => setShowSeller(true)} className="w-full rounded-xl bg-red-500/15 px-3 py-2.5 text-left text-xs font-semibold text-red-200 ring-1 ring-red-400/40 active:scale-95">
                ⚠️ แพ็กเกจเซลล์หมดอายุ: ตอนนี้ลูกค้าที่จองผ่านลิงก์ของคุณยังจองได้ปกติ แต่คุณไม่ได้ส่วนแบ่ง (ตกเป็นของแพลตฟอร์ม) กดเพื่อต่ออายุ
              </button>
            )}
            <button onClick={() => setShowSeller(true)} className="w-full rounded-xl bg-white/10 py-2.5 text-sm font-semibold text-neutral-100 ring-1 ring-white/15 active:scale-95">🤝 ส่วนแบ่งของฉัน</button>
            {!session.vendor && (
              <button onClick={() => setView('worker')} className="w-full rounded-xl bg-white/10 py-2.5 text-sm font-semibold text-neutral-100 ring-1 ring-white/15 active:scale-95">
                {me?.role === 'worker' ? `💼 ${t('workerArea')}` : `📝 ${t('applyPartnerHere')}`}
              </button>
            )}
          </div>
          <CategoryPicker tier={viewTier} onPick={openCategory} />
        </>
      )}

      {view === 'feed' && (
        <>
          <Header {...headerProps} title={openedAgency ? openedAgency.name : catName(category)} onBack={() => (agencyFilter ? setAgencyFilter(null) : setView('categories'))} />
          {replyNotice}
          <HomeFeed
            workers={feedRows}
            category={category}
            tier={tier}
            loading={feedLoading}
            onBook={setSelected}
            onUnlock={() => setShowMembership(true)}
            nearOn={nearOn} nearBusy={nearBusy} onToggleNear={toggleNear}
            onAsk={askWorker}
            unreadByWorker={unreadByWorker}
            agencies={agDir.agencies}
            onAgency={openAgency}
            header={openedAgency ? <AgencyHeader agency={openedAgency} category={category} onCategory={openAgencyCategory} catName={catName} /> : null}
            meId={me?.id}
          />
        </>
      )}

      {view === 'worker' && (
        <>
          <Header
            displayName={session.profile.displayName}
            title={t('providerSide')}
            onBack={() => setView('categories')}
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
              ? <WorkerDashboard userId={me.id} me={me} openChat={openChat} highlightJob={highlightJob} onWallet={() => setShowWallet(true)} onTopUp={() => setPay({ kind: 'wallet_topup' })} />
              : <WorkerApply userId={me.id} defaultName={session.profile.displayName} />}
        </>
      )}

      {me && !me.customer_terms_at && (view === 'categories' || view === 'feed') && (
        <div className="fixed inset-0 z-[58] overflow-y-auto bg-neutral-950">
          <div className="mx-auto flex min-h-full max-w-md flex-col justify-center gap-4 px-5 py-6 pb-[calc(1.5rem+env(safe-area-inset-bottom))]">
            <div className="flex justify-end"><LangSwitcher /></div>
            <img src={logo} alt="DekEn" className="mx-auto h-32 w-32 rounded-[2rem] object-cover shadow-lg ring-1 ring-white/10" />
            <h1 className="text-center text-2xl font-extrabold">DekEn</h1>
            <h2 className="text-center text-lg font-bold">📜 {t('custTermsTitle')}</h2>
            <ul className="space-y-2 text-sm text-neutral-200">
              {[1, 2, 3, 4].map((n) => <li key={n} className="flex gap-2 rounded-xl bg-white/5 p-3"><span>✓</span><span>{t(`custTerms${n}`)}</span></li>)}
            </ul>
            <button onClick={acceptTerms} disabled={termsBusy} className="w-full rounded-2xl bg-line py-4 text-lg font-bold text-black active:scale-95 disabled:opacity-50">{t('custTermsOk')}</button>
          </div>
        </div>
      )}

      {showSeller && <SellerPanel walletBalance={me?.wallet_balance ?? 0} onTopUp={() => { setShowSeller(false); setPay({ kind: 'wallet_topup' }) }} onChanged={() => { loadMe(); loadSellerSt() }} onClose={() => setShowSeller(false)} />}
      {showShare && <ShareModal onClose={() => setShowShare(false)} />}

      {claim && <ClaimDraft token={claim} onClose={() => setClaim(null)} onDone={async () => { setClaim(null); setView('worker'); setWorkerTab('self'); await loadMe() }} />}

      {shared && shared.worker === false && (
        <div className="fixed inset-0 z-[55] flex items-center justify-center bg-black/80 p-4" onClick={() => setShared(null)}>
          <p className="rounded-2xl bg-neutral-900 p-5 text-center text-sm">{t('sharedGone')}</p>
        </div>
      )}

      {shared?.worker && (
        <WorkerDetail worker={shared.worker} isMe={shared.worker.user_id === me?.id} onClose={() => setShared(null)}
          onUnlock={() => { setShared(null); setShowMembership(true) }}
          onBook={() => { const w = shared.worker; setShared(null); setSelected(w) }}
          onAsk={() => { const w = shared.worker; setShared(null); askWorker(w) }} />
      )}

      {selected && (
        <BookingModal
          worker={selected}
          walletBalance={me?.wallet_balance ?? 0}
          onClose={() => setSelected(null)}
          onTopUp={() => { setSelected(null); setPay({ kind: 'wallet_topup' }) }}
          onBooked={async () => {
            setSelected(null)
            await loadMe() // refresh balance immediately (realtime is a backup)
            showToast(t('booked'))
            setShowBookings(true)
          }}
        />
      )}

      {inbox && staffVendor && <VendorInbox vendor={staffVendor} openThread={inbox.thread} onChanged={(rows) => setInboxUnread((rows ?? []).reduce((n, x) => n + x.unread, 0))} onClose={() => setInbox(null)} />}

      {showBookings && <MyBookings highlightId={highlightJob} onClose={() => { setShowBookings(false); setHighlightJob(null); loadMe() }} />}

      {showThreads && (
        <div className="fixed inset-0 z-40 flex items-end justify-center bg-black/70 sm:items-center sm:p-4" onClick={() => setShowThreads(false)}>
          <div onClick={(e) => e.stopPropagation()} className="max-h-[80vh] w-full max-w-md overflow-y-auto rounded-t-3xl bg-neutral-900 p-5 sm:rounded-3xl">
            <h2 className="mb-3 text-lg font-bold">💬 {t('messages')}</h2>
            <ThreadList role="customer" onOpen={(th) => { setShowThreads(false); setChat(th) }} onChange={(rows) => { setChatUnread(rows.reduce((n, r) => n + r.unread, 0)); setCustThreads(rows) }} />
            <button onClick={() => setShowThreads(false)} className="mt-4 w-full rounded-xl bg-white/10 py-3 font-semibold active:scale-95">{t('close')}</button>
          </div>
        </div>
      )}

      {chat && view !== 'worker' && <ChatModal threadId={chat.id} title={chat.other_name} meId={me.id} onRead={loadThreads} onClose={() => { setChat(null); loadThreads() }}
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
        <SupportChat threadId={support.threadId} onClose={async () => { const id = support?.threadId; setSupport(null); if (id) await supabase.rpc('support_mark_read', { p_thread: id }); loadSupportUnread() }} />
      )}

      {toast && (
        <div className="fixed inset-x-4 bottom-6 z-[60] mx-auto max-w-sm rounded-xl bg-line px-4 py-3 text-center text-sm font-semibold text-black shadow-lg">
          {toast}
        </div>
      )}
    </div>
  )
}
