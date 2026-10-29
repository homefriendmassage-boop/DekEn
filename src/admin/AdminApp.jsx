import { useCallback, useEffect, useState } from 'react'
import { supabase } from '../supabaseClient'
import { signIn } from '../lib/auth'
import Applications from './Applications'
import Payments from './Payments'
import Members from './Members'
import Reviews from './Reviews'
import Support from './Support'
import Agencies from './Agencies'
import ProfileEdits from './ProfileEdits'
import Chats from './Chats'
import Vendors from './Vendors'
import SellerRequests from './SellerRequests'
import VendorSelect from './VendorSelect'
import DraftsPanel from '../components/DraftsPanel'
import { baht } from './format'

// Separate back office (admin.html). Access is decided by the DATABASE: every admin_* function
// checks public.admins, so a non-admin who finds this URL can load the page but nothing else.
export default function AdminApp() {
  const [phase, setPhase] = useState('loading') // loading | denied | ready | error
  const [error, setError] = useState(null)
  const [adminName, setAdminName] = useState('')
  const [tab, setTab] = useState('apps')
  const [stats, setStats] = useState(null)
  const [editCount, setEditCount] = useState(0)   // pending profile changes + removal requests
  const [draftCount, setDraftCount] = useState(0)    // agency drafts waiting for review
  const [supportVendor, setSupportVendor] = useState(null)   // null = central customers
  const [supportVendorName, setSupportVendorName] = useState(null)
  const [chatCount, setChatCount] = useState(0)    // flagged / reported / suspended chats waiting for a decision
  const [prefill, setPrefill] = useState(null)   // { user, tier } from "renew" on the Members tab
  const [toast, setToast] = useState(null)

  const showToast = (msg) => { setToast(msg); setTimeout(() => setToast(null), 3500) }

  const loadStats = useCallback(async () => {
    const { data } = await supabase.rpc('admin_stats')
    setStats(data?.[0] ?? null)
    const [e, d] = await Promise.all([supabase.rpc('admin_list_profile_edits', { p_status: 'pending' }), supabase.rpc('admin_list_deletions')])
    setEditCount((e.data?.length ?? 0) + (d.data?.length ?? 0))
    const dr = await supabase.rpc('admin_drafts_list', { p_filter: 'review' })
    setDraftCount(Array.isArray(dr.data) ? dr.data.length : 0)
    const c = await supabase.rpc('admin_chat_pending_count')
    setChatCount(typeof c.data === 'number' ? c.data : 0)
  }, [])

  // A new customer message or a new slip review refreshes the counters (admins can read all support messages)
  useEffect(() => {
    if (phase !== 'ready') return
    const ch = supabase.channel('admin-counters')
      .on('postgres_changes', { event: 'INSERT', schema: 'public', table: 'support_messages' }, loadStats)
      .subscribe()
    return () => { supabase.removeChannel(ch) }
  }, [phase, loadStats])

  useEffect(() => {          // chat flags cannot be pushed to admins (RLS), so look again once a minute
    if (phase !== 'ready') return
    const id = setInterval(loadStats, 60000)
    return () => clearInterval(id)
  }, [phase, loadStats])

  useEffect(() => {
    ;(async () => {
      try {
        const s = await signIn()
        setAdminName(s.profile.displayName)
        const { data } = await supabase.rpc('is_admin')
        if (data !== true) return setPhase('denied')
        await loadStats()
        setPhase('ready')
      } catch (e) {
        console.error(e)
        setError(e.message ?? String(e))
        setPhase('error')
      }
    })()
  }, [loadStats])

  if (phase === 'loading') {
    return <div className="flex min-h-screen items-center justify-center"><div className="h-10 w-10 animate-spin rounded-full border-4 border-neutral-700 border-t-line" /></div>
  }
  if (phase === 'denied' || phase === 'error') {
    return (
      <div className="flex min-h-screen flex-col items-center justify-center gap-2 p-6 text-center">
        <p className="text-lg font-semibold">{phase === 'denied' ? 'ไม่มีสิทธิ์เข้าถึงหน้านี้' : 'เริ่มต้นไม่สำเร็จ'}</p>
        {error && <p className="max-w-sm break-words text-sm text-neutral-400">{error}</p>}
      </div>
    )
  }

  const tabs = [
    ['apps', `📝 ใบสมัคร${stats?.pending_apps ? ` (${stats.pending_apps})` : ''}`],
    ['reviews', `🔎 ตรวจสลิป${stats?.pending_reviews ? ` (${stats.pending_reviews})` : ''}`],
    ['support', `💬 แชท${stats?.support_unread ? ` (${stats.support_unread})` : ''}`],
    ['pay', '💳 รับชำระเงิน'],
    ['drafts', `➕ แบบร่างให้น้อง${draftCount ? ` (${draftCount})` : ''}`],
    ['chats', `🚩 ธง/รายงาน${chatCount ? ` (${chatCount})` : ''}`],
    ['edits', `✏️ แก้ไข/ลบโปรไฟล์${editCount ? ` (${editCount})` : ''}`],
    ['agencies', '🏢 สังกัด'],
    ['vendors', '🏪 เซลล์/OA'],
    ['members', '👑 สมาชิก'],
  ]

  return (
    <div className="mx-auto min-h-screen w-full max-w-5xl pb-10">
      <header className="sticky top-0 z-30 border-b border-white/10 bg-neutral-950/95 px-4 py-3 backdrop-blur">
        <div className="flex items-center justify-between">
          <h1 className="text-lg font-bold">🛠️ Admin</h1>
          <span className="text-xs text-neutral-400">{adminName}</span>
        </div>
        <nav className="mt-2 flex gap-2 overflow-x-auto">
          {tabs.map(([id, label]) => (
            <button key={id} onClick={() => setTab(id)}
              className={`shrink-0 rounded-full px-4 py-1.5 text-sm font-semibold ${tab === id ? 'bg-line text-black' : 'bg-white/10 text-neutral-200'}`}>
              {label}
            </button>
          ))}
        </nav>
      </header>

      {stats && (
        <section className="grid grid-cols-2 gap-2 p-4 sm:grid-cols-4">
          <Stat label="รอจัดการ: ใบสมัคร / สลิป / แชทใหม่" value={`${stats.pending_apps} / ${stats.pending_reviews} / ${stats.support_unread}`}
            warn={stats.pending_apps + stats.pending_reviews + stats.support_unread > 0} />
          <Stat label="สมาชิก Gold / Plat. / Diamond" value={`${stats.gold} / ${stats.platinum} / ${stats.diamond}`} />
          <Stat label="ใกล้หมดอายุ (7 วัน)" value={stats.expiring_7d} warn={stats.expiring_7d > 0} />
          <Stat label="รายรับสมาชิกเดือนนี้" value={baht(stats.membership_month)} sub={`เติม Wallet ${baht(stats.topup_month)}`} />
        </section>
      )}

      <main className="px-4">
        {tab === 'apps' && <Applications onChanged={loadStats} toast={showToast} />}
        {tab === 'reviews' && <Reviews onChanged={loadStats} toast={showToast} />}
        {tab === 'support' && (
          <div className="space-y-3">
            <VendorSelect value={supportVendor} onChange={(id, name) => { setSupportVendor(id); setSupportVendorName(name) }} />
            <Support key={supportVendor ?? 'central'} vendor={supportVendor} vendorLabel={supportVendorName} onChanged={loadStats} />
          </div>
        )}
        {tab === 'pay' && <Payments prefill={prefill} clearPrefill={() => setPrefill(null)} onChanged={loadStats} toast={showToast} />}
        {tab === 'drafts' && <DraftsPanel mode="admin" toast={showToast} />}
        {tab === 'chats' && <Chats onChanged={loadStats} toast={showToast} />}
        {tab === 'edits' && <ProfileEdits onChanged={loadStats} toast={showToast} />}
        {tab === 'vendors' && <><SellerRequests toast={showToast} /><Vendors toast={showToast} /></>}
        {tab === 'agencies' && <Agencies onChanged={loadStats} toast={showToast} />}
        {tab === 'members' && <Members toast={showToast} onRenew={(user) => { setPrefill({ user, tier: user.vip_tier }); setTab('pay') }} />}
      </main>

      {toast && (
        <div className="fixed inset-x-4 bottom-6 z-[60] mx-auto max-w-sm rounded-xl bg-line px-4 py-3 text-center text-sm font-semibold text-black shadow-lg">{toast}</div>
      )}
    </div>
  )
}

function Stat({ label, value, sub, warn }) {
  return (
    <div className={`rounded-2xl p-3 ring-1 ${warn ? 'bg-amber-400/10 ring-amber-400/40' : 'bg-white/5 ring-white/10'}`}>
      <p className="text-[11px] text-neutral-400">{label}</p>
      <p className="mt-1 text-lg font-bold">{value}</p>
      {sub && <p className="text-[11px] text-neutral-500">{sub}</p>}
    </div>
  )
}
