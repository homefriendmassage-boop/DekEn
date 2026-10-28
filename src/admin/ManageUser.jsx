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
  const [susp, setSusp] = useState('7')            // '3' | '7' | '30' | 'forever'

  const load = () => supabase.rpc('admin_user_detail', { p_user: userId }).then(({ data }) => {
    const row = data?.[0] ?? null
    setU(row)
    if (row && row.vip_tier > 0) setTier(row.vip_tier)
    if (row?.vip_expires_at && new Date(row.vip_expires_at) > new Date()) setExpires(toLocalDate(row.vip_expires_at))
  })
  useEffect(() => { load() }, [userId]) // eslint-disable-line react-hooks/exhaustive-deps

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
          <h2 className="text-lg font-bold">{u.display_name ?? '—'}</h2>
          <p className="text-sm text-neutral-400">
            {active ? <>{meta.icon} {meta.name} · หมด {fmtDate(u.vip_expires_at)}</> : 'ไม่มีแพ็กเกจที่ใช้งานอยู่'} · Wallet {baht(u.wallet_balance)}
          </p>
          {suspended && (
            <p className="mt-2 rounded-lg bg-red-500/10 p-2 text-sm text-red-300">
              ⛔ ถูกระงับ {isForever(u.suspended_until) ? 'ถาวร' : `ถึง ${fmtDate(u.suspended_until)}`}{u.suspend_reason ? ` — ${u.suspend_reason}` : ''}
            </p>
          )}
        </div>

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
