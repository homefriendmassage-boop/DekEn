import { useEffect, useState } from 'react'
import { supabase } from '../supabaseClient'
import { PLAN_META } from '../config'
import { baht, fmtDate, fmtDateTime } from './format'

const ERRORS = {
  REASON_REQUIRED: 'ต้องระบุเหตุผล (เก็บเป็นประวัติ)',
  CANNOT_SUSPEND_ADMIN: 'ระงับบัญชีแอดมินไม่ได้',
  BAD_INPUT: 'ข้อมูลไม่ถูกต้อง (วันหมดอายุต้องเป็นอนาคตและไม่เกิน 400 วัน)',
  USER_NOT_FOUND: 'ไม่พบผู้ใช้',
  FORBIDDEN: 'ไม่มีสิทธิ์',
}
const errText = (m = '') => Object.entries(ERRORS).find(([k]) => m.includes(k))?.[1] ?? 'ทำรายการไม่สำเร็จ'
const ACTIONS = { set_membership: 'ตั้งแพ็กเกจ', cancel_membership: 'ยกเลิกแพ็กเกจ', suspend: 'ระงับบัญชี', unsuspend: 'ปลดระงับ' }
const isForever = (v) => v && new Date(v).getFullYear() >= 9000
const inDays = (n) => new Date(Date.now() + n * 86400000).toISOString()
const toLocalDate = (iso) => new Date(iso).toLocaleDateString('en-CA') // yyyy-mm-dd

// Per-user controls. Every action needs a reason and is written to the audit trail (membership_events).
export default function ManageUser({ userId, onClose, onChanged, toast }) {
  const [u, setU] = useState(null)
  const [busy, setBusy] = useState(false)
  const [tier, setTier] = useState(1)
  const [expires, setExpires] = useState(toLocalDate(inDays(30)))
  const [reason, setReason] = useState('')
  const [vendorName, setVendorName] = useState(null)
  const [susp, setSusp] = useState('7')            // '3' | '7' | '30' | 'forever'

  const load = () => supabase.rpc('admin_user_detail', { p_user: userId }).then(({ data }) => {
    const row = data?.[0] ?? null
    setU(row)
    if (row && row.vip_tier > 0) setTier(row.vip_tier)
    if (row?.vip_expires_at && new Date(row.vip_expires_at) > new Date()) setExpires(toLocalDate(row.vip_expires_at))
  })
  useEffect(() => { load() }, [userId]) // eslint-disable-line react-hooks/exhaustive-deps
  useEffect(() => { supabase.rpc('admin_user_vendor', { p_user: userId }).then(({ data }) => setVendorName(data ?? null)) }, [userId])

  async function run(fn, okMsg) {
    if (busy) return
    if (reason.trim().length < 2) return toast('กรุณาระบุเหตุผล')
    setBusy(true)
    const { error } = await fn()
    setBusy(false)
    if (error) return toast(errText(error.message))
    toast(okMsg)
    setReason('')
    await load()
    onChanged?.()
  }

  if (!u) return null
  const active = u.vip_expires_at && new Date(u.vip_expires_at) > new Date() && u.vip_tier > 0
  const suspended = u.suspended_until && new Date(u.suspended_until) > new Date()
  const meta = PLAN_META[u.vip_tier]

  const setMembership = (t, exp, label) => {
    if (!window.confirm(`${label} — ${u.display_name ?? 'ผู้ใช้'}\nยืนยัน?`)) return
    run(() => supabase.rpc('admin_set_membership', { p_user: u.id, p_tier: t, p_expires: exp, p_reason: reason }), 'บันทึกแล้ว')
  }
  const suspend = () => {
    const until = susp === 'forever' ? '9999-12-31T00:00:00Z' : inDays(Number(susp))
    if (!window.confirm(`ระงับบัญชี ${u.display_name ?? 'ผู้ใช้'} ${susp === 'forever' ? 'ถาวร' : `${susp} วัน`}?\nเข้าใช้งานไม่ได้ จองไม่ได้ แชตกับน้องไม่ได้ (ยังแชตกับแอดมินได้)${u.role === 'worker' ? '\nและถูกซ่อนจากหน้าฟีด' : ''}`)) return
    run(() => supabase.rpc('admin_set_suspension', { p_user: u.id, p_until: until, p_reason: reason }), 'ระงับบัญชีแล้ว')
  }
  const unsuspend = () => run(() => supabase.rpc('admin_set_suspension', { p_user: u.id, p_until: null, p_reason: reason }), 'ปลดระงับแล้ว')

  return (
    <div className="fixed inset-0 z-50 flex items-end justify-center bg-black/70 sm:items-center sm:p-4" onClick={onClose} role="dialog" aria-modal="true">
      <div onClick={(e) => e.stopPropagation()} className="max-h-[92vh] w-full max-w-md space-y-4 overflow-y-auto rounded-t-3xl bg-neutral-900 p-5 shadow-2xl sm:rounded-3xl">
        <div>
          <h2 className="text-lg font-bold">{u.display_name ?? '—'}{vendorName && <span className="ml-2 rounded-full bg-amber-400/20 px-2 py-0.5 text-xs font-semibold text-amber-300">🏪 {vendorName}</span>}</h2>
          <p className="text-sm text-neutral-400">
            {active ? <>{meta.icon} {meta.name} · หมด {fmtDate(u.vip_expires_at)}</> : 'ไม่มีแพ็กเกจที่ใช้งานอยู่'} · Wallet {baht(u.wallet_balance)}
          </p>
          {suspended && (
            <p className="mt-2 rounded-lg bg-red-500/10 p-2 text-sm text-red-300">
              ⛔ ถูกระงับ {isForever(u.suspended_until) ? 'ถาวร' : `ถึง ${fmtDate(u.suspended_until)}`}{u.suspend_reason ? ` — ${u.suspend_reason}` : ''}
            </p>
          )}
        </div>

        <SellerLabel userId={u.id} toast={toast} />
        <ReferrerSection userId={u.id} toast={toast} />
        <SellerSection userId={u.id} toast={toast} />

        <label className="block text-sm">
          <span className="text-neutral-300">เหตุผล (จำเป็น · เก็บเป็นประวัติ)</span>
          <input value={reason} onChange={(e) => setReason(e.target.value)} maxLength={200} placeholder="เช่น ลูกค้ากดอัปเกรดผิด / สแปมแชต"
            className="mt-1 w-full rounded-xl bg-white/10 px-3 py-2 outline-none focus:ring-2 focus:ring-line" />
        </label>

        <section className="space-y-2 rounded-2xl bg-white/5 p-3">
          <p className="text-sm font-semibold">แพ็กเกจ</p>
          <div className="grid grid-cols-2 gap-2">
            <select value={tier} onChange={(e) => setTier(Number(e.target.value))} className="rounded-xl bg-white/10 px-3 py-2">
              {[1, 2, 3].map((n) => <option key={n} value={n}>{PLAN_META[n].name}</option>)}
            </select>
            <input type="date" value={expires} onChange={(e) => setExpires(e.target.value)} className="rounded-xl bg-white/10 px-3 py-2" />
          </div>
          <button disabled={busy} onClick={() => setMembership(tier, new Date(`${expires}T23:59:59`).toISOString(), `ตั้งเป็น ${PLAN_META[tier].name} หมด ${expires}`)}
            className="w-full rounded-xl bg-line py-2 text-sm font-bold text-black active:scale-95 disabled:opacity-50">ตั้งแพ็กเกจ / แก้วันหมดอายุ</button>
          {active && (
            <button disabled={busy} onClick={() => setMembership(0, null, 'ยกเลิกแพ็กเกจทันที')}
              className="w-full rounded-xl bg-red-500/20 py-2 text-sm font-bold text-red-300 active:scale-95 disabled:opacity-50">ยกเลิกแพ็กเกจทันที</button>
          )}
          <p className="text-[11px] text-neutral-500">ยกเลิก/แก้ไขไม่คืนเงินอัตโนมัติ — โอนคืนเองแล้วบันทึกเหตุผลไว้</p>
        </section>

        <section className="space-y-2 rounded-2xl bg-white/5 p-3">
          <p className="text-sm font-semibold">{u.role === 'worker' ? 'ระงับผู้ให้บริการ' : 'ระงับบัญชี'}</p>
          {u.role === 'worker' && <p className="text-[11px] text-neutral-400">ซ่อนจากหน้าฟีด ลูกค้าจองและแชตด้วยไม่ได้ (คนอื่นขยับอันดับขึ้น) · ปลดระงับแล้วกลับมาแสดงเอง</p>}
          {suspended ? (
            <button disabled={busy} onClick={unsuspend} className="w-full rounded-xl bg-line py-2 text-sm font-bold text-black active:scale-95 disabled:opacity-50">ปลดระงับ</button>
          ) : (
            <>
              <select value={susp} onChange={(e) => setSusp(e.target.value)} className="w-full rounded-xl bg-white/10 px-3 py-2">
                <option value="3">ชั่วคราว 3 วัน</option>
                <option value="7">ชั่วคราว 7 วัน</option>
                <option value="30">ชั่วคราว 30 วัน</option>
                <option value="forever">ถาวร (ปลดได้ภายหลัง)</option>
              </select>
              <button disabled={busy} onClick={suspend} className="w-full rounded-xl bg-red-500/20 py-2 text-sm font-bold text-red-300 active:scale-95 disabled:opacity-50">ระงับบัญชี</button>
            </>
          )}
        </section>

        {u.events?.length > 0 && (
          <section>
            <p className="mb-1 text-sm font-semibold">ประวัติล่าสุด</p>
            <ul className="space-y-1 text-xs text-neutral-400">
              {u.events.map((e, i) => (
                <li key={i}>{fmtDateTime(e.created_at)} · {ACTIONS[e.action] ?? e.action}{e.reason ? ` — ${e.reason}` : ''}{e.admin_name ? ` (${e.admin_name})` : ''}</li>
              ))}
            </ul>
          </section>
        )}

        <button onClick={onClose} className="w-full rounded-xl bg-white/10 py-3 font-semibold active:scale-95">ปิด</button>
      </div>
    </div>
  )
}

// The name the providers see in "customer from <seller>" when a customer came through this person's link.
function SellerLabel({ userId, toast }) {
  const [label, setLabel] = useState('')
  useEffect(() => { supabase.rpc('admin_get_seller_label', { p_user: userId }).then(({ data }) => setLabel(data ?? '')) }, [userId])
  async function save() {
    const { error } = await supabase.rpc('admin_set_seller_label', { p_user: userId, p_label: label })
    toast(error ? 'บันทึกไม่สำเร็จ' : 'บันทึกชื่อเรียกเซลล์แล้ว')
  }
  return (
    <section className="space-y-2 rounded-2xl bg-white/5 p-3">
      <p className="text-sm font-semibold">🏪 ชื่อเรียกเซลล์</p>
      <p className="text-[11px] text-neutral-400">ถ้าบัญชีนี้เป็นเซลล์ น้องจะเห็นชื่อนี้ใน Flex และหน้างานว่า "ลูกค้าจาก: …" (ไม่ตั้ง = ใช้ชื่อ LINE)</p>
      <div className="flex gap-2">
        <input value={label} onChange={(e) => setLabel(e.target.value)} maxLength={40} placeholder="เช่น เซลล์เอ / ทีมโอ๋" className="min-w-0 flex-1 rounded-xl bg-white/10 px-3 py-2 text-sm" />
        <button onClick={save} className="rounded-xl bg-white/10 px-4 text-sm font-semibold active:scale-95">บันทึก</button>
      </div>
    </section>
  )
}

// Who invited this customer (first link wins). Admin can correct it, always with a reason that is kept as history.
function ReferrerSection({ userId, toast }) {
  const [info, setInfo] = useState(null)
  const [q, setQ] = useState('')
  const [found, setFound] = useState([])
  const [pick, setPick] = useState(null)      // { id, name } | 'none'
  const [reason, setReason] = useState('')
  const load = () => supabase.rpc('admin_get_referrer', { p_user: userId }).then(({ data }) => setInfo(data ?? null))
  useEffect(() => { load() }, [userId])
  useEffect(() => {
    const h = setTimeout(() => supabase.rpc('admin_find_users', { p_q: q }).then(({ data }) => setFound(data ?? [])), 250)
    return () => clearTimeout(h)
  }, [q])

  async function save() {
    if (reason.trim().length < 3) return toast('ใส่เหตุผลก่อน')
    const { error } = await supabase.rpc('admin_set_referrer', { p_user: userId, p_referrer: pick === 'none' ? null : pick.id, p_reason: reason })
    if (error) return toast('บันทึกไม่สำเร็จ')
    toast('แก้ผู้แนะนำแล้ว'); setPick(null); setReason(''); setQ(''); load()
  }

  return (
    <section className="space-y-2 rounded-2xl bg-white/5 p-3">
      <p className="text-sm font-semibold">🤝 ผู้แนะนำ</p>
      <p className="text-sm">{info?.referrer_id ? <>{info.referrer_name ?? '—'} <span className={`text-xs ${info.referrer_is_seller ? 'text-green-300' : 'text-neutral-400'}`}>{info.referrer_is_seller ? '(เป็นเซลล์ — ได้ 40% ค่าจอง)' : '(ไม่ใช่เซลล์ — ได้แค่ค่าแพ็กเกจ 20%)'}</span></> : <span className="text-neutral-400">ไม่มีผู้แนะนำ</span>}</p>
      <input value={q} onChange={(e) => setQ(e.target.value)} placeholder="🔍 ค้นชื่อคนที่จะเป็นผู้แนะนำใหม่" className="w-full rounded-xl bg-white/10 px-3 py-2 text-sm" />
      <ul className="space-y-1">
        {found.filter((f) => f.id !== userId).map((f) => (
          <li key={f.id}><button onClick={() => setPick({ id: f.id, name: f.display_name })} className="w-full rounded-xl bg-white/5 px-3 py-1.5 text-left text-sm active:scale-95">{f.display_name ?? '—'}{f.is_seller ? ' · เซลล์' : ''}</button></li>
        ))}
      </ul>
      {info?.referrer_id && <button onClick={() => setPick('none')} className="text-xs text-red-300 underline">เอาผู้แนะนำออก</button>}
      {pick && (
        <div className="space-y-2 rounded-xl bg-amber-400/10 p-2">
          <p className="text-xs text-amber-200">เปลี่ยนผู้แนะนำเป็น: <b>{pick === 'none' ? 'ไม่มี' : pick.name}</b></p>
          <input value={reason} onChange={(e) => setReason(e.target.value)} maxLength={300} placeholder="เหตุผล (จำเป็น เก็บเป็นประวัติ)" className="w-full rounded-xl bg-white/10 px-3 py-2 text-sm" />
          <button onClick={save} className="w-full rounded-xl bg-line py-2 text-sm font-bold text-black active:scale-95">ยืนยันการแก้</button>
        </div>
      )}
      {info?.history?.length > 0 && (
        <ul className="space-y-1 text-[11px] text-neutral-400">
          {info.history.map((h, i) => <li key={i}>{new Date(h.at).toLocaleString('th-TH')} · {h.old ?? 'ไม่มี'} → {h.new ?? 'ไม่มี'} · {h.reason} ({h.by ?? '—'})</li>)}
        </ul>
      )}
    </section>
  )
}

// Seller plan (500 THB / 30 days from the Wallet). The admin can give free days or cancel it.
function SellerSection({ userId, toast }) {
  const [info, setInfo] = useState(null)
  const load = () => supabase.rpc('admin_get_seller', { p_user: userId }).then(({ data }) => setInfo(data ?? null))
  useEffect(() => { load() }, [userId])
  async function grant() {
    const days = Number(window.prompt('ให้เป็นเซลล์ฟรีกี่วัน (1-365)', '30'))
    if (!days) return
    const { error } = await supabase.rpc('admin_seller_grant', { p_user: userId, p_days: days })
    toast(error ? 'ไม่สำเร็จ' : `ให้เป็นเซลล์ ${days} วันแล้ว`); load()
  }
  async function revoke() {
    if (!window.confirm('ยกเลิกสถานะเซลล์ที่ชำระ/ให้ไว้? (ไม่คืนเงินอัตโนมัติ)')) return
    const { error } = await supabase.rpc('admin_seller_revoke', { p_user: userId })
    toast(error ? 'ไม่สำเร็จ' : 'ยกเลิกสถานะเซลล์แล้ว'); load()
  }
  return (
    <section className="space-y-2 rounded-2xl bg-white/5 p-3">
      <p className="text-sm font-semibold">🤝 สถานะเซลล์</p>
      <p className="text-sm">{info?.via ? <span className="text-green-300">เป็นเซลล์อยู่แล้ว ({info.via === 'vendor' ? 'เซลล์ที่มี OA' : 'ผู้ให้บริการ'})</span>
        : info?.active ? <span className="text-green-300">เป็นเซลล์ ใช้ได้ถึง {new Date(info.until).toLocaleDateString('th-TH')}</span>
        : <span className="text-neutral-400">ไม่ได้เป็นเซลล์</span>}</p>
      {!info?.via && (
        <div className="grid grid-cols-2 gap-2">
          <button onClick={grant} className="rounded-xl bg-line py-2 text-sm font-bold text-black active:scale-95">ให้ฟรี (วัน)</button>
          <button onClick={revoke} disabled={!info?.active} className="rounded-xl bg-red-500/20 py-2 text-sm font-bold text-red-300 active:scale-95 disabled:opacity-40">ยกเลิก</button>
        </div>
      )}
    </section>
  )
}
