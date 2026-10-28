import { useCallback, useEffect, useRef, useState } from 'react'
import { supabase } from '../supabaseClient'
import { PLAN_META, PLANS } from '../config'
import SupportChat from '../components/SupportChat'
import { baht, fmtDateTime } from './format'

const FILTERS = [['pending', 'รอตรวจ'], ['approved', 'อนุมัติแล้ว'], ['rejected', 'ไม่อนุมัติ']]
const newId = () =>
  globalThis.crypto?.randomUUID?.() ??
  'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, (c) => { const r = (Math.random() * 16) | 0; return (c === 'x' ? r : (r & 0x3) | 0x8).toString(16) })
const ERRORS = {
  DUPLICATE_REQUEST: 'รายการนี้ถูกบันทึกไปแล้ว (กดซ้ำ) ระบบไม่บันทึกซ้ำ',
  NOT_FOUND: 'รายการนี้ถูกจัดการไปแล้ว',
  DUPLICATE_REFERENCE: 'เลขอ้างอิงสลิปนี้ถูกบันทึกในบัญชีรับเงินแล้ว',
}
const errText = (m = '') => Object.entries(ERRORS).find(([k]) => m.includes(k))?.[1] ?? 'ทำรายการไม่สำเร็จ'

// Slips that were genuine and paid to our account, but whose amount matched no open request.
export default function Reviews({ onChanged, toast }) {
  const [status, setStatus] = useState('pending')
  const [rows, setRows] = useState(null)
  const [chat, setChat] = useState(null)

  const load = useCallback(async () => {
    setRows(null)
    const { data, error } = await supabase.rpc('admin_list_reviews', { p_status: status })
    if (error) { toast('โหลดไม่สำเร็จ'); return setRows([]) }
    setRows(data ?? [])
  }, [status, toast])
  useEffect(() => { load() }, [load])

  return (
    <div className="space-y-4">
      <p className="text-xs text-neutral-500">สลิปจริงที่โอนเข้าบัญชีเรา แต่ยอดไม่ตรงกับรายการที่ลูกค้าสร้างไว้ (สลิปปลอม/ซ้ำ/ผู้รับผิด ระบบปฏิเสธเองแล้ว ไม่มาที่นี่)</p>
      <div className="flex gap-2">
        {FILTERS.map(([id, label]) => (
          <button key={id} onClick={() => setStatus(id)} className={`rounded-full px-3 py-1 text-sm ${status === id ? 'bg-white text-black' : 'bg-white/10'}`}>{label}</button>
        ))}
      </div>
      {rows === null ? <p className="py-10 text-center text-neutral-500">กำลังโหลด…</p>
        : rows.length === 0 ? <p className="rounded-2xl bg-white/5 p-6 text-center text-neutral-500">ไม่มีรายการ</p>
        : <ul className="grid gap-3 md:grid-cols-2">{rows.map((r) => <Card key={r.id} r={r} toast={toast} onDone={() => { load(); onChanged() }} onChat={() => setChat(r)} />)}</ul>}
      {chat && <SupportChat threadId={chat.thread_id} title={chat.user_name ?? 'ลูกค้า'} isAdmin onClose={() => setChat(null)} />}
    </div>
  )
}

function Card({ r, toast, onDone, onChat }) {
  const [kind, setKind] = useState(r.intent_kind ?? 'membership')
  const [tier, setTier] = useState(r.intent_tier ?? 1)
  const [days, setDays] = useState(r.intent_days ?? 30)
  const [rejecting, setRejecting] = useState(false)
  const [reason, setReason] = useState('')
  const [busy, setBusy] = useState(false)
  const requestId = useRef(newId())
  const guard = useRef(false)
  const input = 'w-full rounded-xl bg-white/10 px-3 py-2 text-sm outline-none ring-1 ring-white/10 focus:ring-line'

  async function resolve(approve) {
    if (guard.current) return
    if (approve && !window.confirm(`อนุมัติ ${r.user_name ?? 'ผู้ใช้'}\nรับยอดตามสลิป ${baht(r.paid_amount)}\n${kind === 'membership' ? `เปิดสิทธิ์ ${PLAN_META[tier].name} ${days} วัน` : 'เติมเข้า Wallet'}\n\nยืนยัน?`)) return
    guard.current = true
    setBusy(true)
    const { error } = await supabase.rpc('admin_resolve_review', {
      p_review: r.id, p_approve: approve, p_kind: approve ? kind : null, p_tier: approve && kind === 'membership' ? Number(tier) : null,
      p_days: approve && kind === 'membership' ? Number(days) : null, p_request_id: approve ? requestId.current : null, p_reason: approve ? null : reason,
    })
    setBusy(false)
    guard.current = false
    if (error) { toast(errText(error.message)); if (error.message.includes('NOT_FOUND') || error.message.includes('DUPLICATE_REQUEST')) onDone(); return }
    toast(approve ? 'อนุมัติแล้ว' : 'ปฏิเสธแล้ว')
    onDone()
  }

  return (
    <li className="space-y-3 rounded-2xl bg-white/5 p-4 ring-1 ring-white/10">
      <div className="flex items-center gap-3">
        {r.picture_url
          ? <img src={r.picture_url} alt="" referrerPolicy="no-referrer" className="h-10 w-10 shrink-0 rounded-full object-cover" />
          : <span className="flex h-10 w-10 shrink-0 items-center justify-center rounded-full bg-white/10 font-bold">{(r.user_name ?? '?').slice(0, 1)}</span>}
        <div className="min-w-0 flex-1">
          <p className="truncate font-bold">{r.user_name ?? '—'}</p>
          <p className="text-[11px] text-neutral-500">{fmtDateTime(r.created_at)} · ref {r.trans_ref}</p>
        </div>
      </div>

      <div className="grid grid-cols-2 gap-2 text-sm">
        <div className="rounded-xl bg-amber-400/10 p-2 ring-1 ring-amber-400/30">
          <p className="text-[11px] text-amber-200">ยอดในสลิป</p>
          <p className="font-extrabold text-amber-300">{baht(r.paid_amount)}</p>
        </div>
        <div className="rounded-xl bg-white/5 p-2">
          <p className="text-[11px] text-neutral-400">ยอดที่ต้องโอน</p>
          <p className="font-bold">{r.expected?.length ? r.expected.map(baht).join(' / ') : '—'}</p>
        </div>
      </div>
      {r.intent_kind && (
        <p className="text-xs text-neutral-400">
          ลูกค้าขอ: {r.intent_kind === 'membership' ? `สมาชิก ${PLAN_META[r.intent_tier]?.name ?? ''} ${r.intent_days ?? ''} วัน` : 'เติม Wallet'}
        </p>
      )}

      {r.status === 'pending' ? (
        <>
          <div className="space-y-2 rounded-xl bg-white/5 p-3">
            <p className="text-xs text-neutral-400">อนุมัติแล้วจะให้สิ่งนี้ (ปรับได้):</p>
            <div className="flex gap-2">
              {[['membership', 'สมาชิก'], ['wallet_topup', 'เติม Wallet']].map(([id, label]) => (
                <button key={id} type="button" onClick={() => setKind(id)} className={`flex-1 rounded-lg py-1.5 text-sm font-semibold ${kind === id ? 'bg-white text-black' : 'bg-white/10'}`}>{label}</button>
              ))}
            </div>
            {kind === 'membership' && (
              <div className="grid grid-cols-2 gap-2">
                <select value={tier} onChange={(e) => setTier(Number(e.target.value))} className={input}>
                  {PLANS.map((p) => <option key={p.tier} value={p.tier} className="text-black">{PLAN_META[p.tier].icon} {PLAN_META[p.tier].name} ({p.price})</option>)}
                </select>
                <input type="number" min="1" max="365" value={days} onChange={(e) => setDays(e.target.value)} className={input} />
              </div>
            )}
          </div>

          {rejecting ? (
            <div className="space-y-2">
              <textarea rows={2} maxLength={300} value={reason} onChange={(e) => setReason(e.target.value)} placeholder="เหตุผล (ลูกค้าจะเห็นในแชท)" className={input} />
              <div className="grid grid-cols-2 gap-2">
                <button onClick={() => setRejecting(false)} className="rounded-xl bg-white/10 py-2 text-sm font-semibold">ยกเลิก</button>
                <button disabled={busy} onClick={() => resolve(false)} className="rounded-xl bg-red-500 py-2 text-sm font-bold disabled:opacity-50">ยืนยันไม่อนุมัติ</button>
              </div>
            </div>
          ) : (
            <div className="grid grid-cols-3 gap-2">
              <button onClick={onChat} className="rounded-xl bg-white/10 py-2.5 text-sm font-semibold active:scale-95">💬 แชท</button>
              <button onClick={() => setRejecting(true)} className="rounded-xl bg-white/10 py-2.5 text-sm font-semibold active:scale-95">ไม่อนุมัติ</button>
              <button disabled={busy} onClick={() => resolve(true)} className="rounded-xl bg-line py-2.5 text-sm font-bold text-black active:scale-95 disabled:opacity-50">อนุมัติ</button>
            </div>
          )}
        </>
      ) : (
        <>
          {r.reject_reason && <p className="text-sm text-red-300">เหตุผล: {r.reject_reason}</p>}
          <button onClick={onChat} className="w-full rounded-xl bg-white/10 py-2 text-sm font-semibold">💬 เปิดแชท</button>
        </>
      )}
    </li>
  )
}
