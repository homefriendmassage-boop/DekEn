import { useState } from 'react'
import { supabase } from '../supabaseClient'
import { CANCEL_REASONS, PROBLEM_KINDS, cancelOutcome, jobErr, useJobRules } from '../lib/jobRules'

function Sheet({ title, onClose, children }) {
  return (
    <div className="fixed inset-0 z-[60] flex items-end justify-center bg-black/70 sm:items-center sm:p-4" onClick={(e) => { e.stopPropagation(); onClose() }} role="dialog" aria-modal="true">
      <div onClick={(e) => e.stopPropagation()} className="max-h-[90vh] w-full max-w-md space-y-3 overflow-y-auto rounded-t-3xl bg-neutral-900 p-5 pb-[calc(1.25rem+env(safe-area-inset-bottom))] shadow-2xl sm:rounded-3xl">
        <div className="flex items-center justify-between"><h3 className="text-lg font-bold">{title}</h3><button onClick={onClose} className="rounded-full bg-white/10 px-3 py-1 text-sm">✕</button></div>
        {children}
      </div>
    </div>
  )
}
const input = 'w-full rounded-xl bg-white/10 px-3 py-2.5 text-base outline-none ring-1 ring-white/10 focus:ring-line'

// The customer cancels: a reason (the provider is told), what happens to the fee, and an optional compensation (goes to the platform, which decides what the provider gets)
export function CancelSheet({ job, onClose, onDone, flash }) {
  const rules = useJobRules()
  const [reason, setReason] = useState(CANCEL_REASONS[0])
  const [note, setNote] = useState('')
  const [comp, setComp] = useState('')
  const [busy, setBusy] = useState(false)
  const out = cancelOutcome(job, rules)
  const matched = job.status === 'matched'
  async function go() {
    setBusy(true)
    const { error } = await supabase.rpc('customer_cancel_job', { p_job: job.id, p_reason: reason, p_note: note.trim() || null, p_comp: matched ? Number(comp) || 0 : 0 })
    setBusy(false)
    if (error) return flash(jobErr(error.message))
    flash('ยกเลิกแล้ว'); onDone()
  }
  return (
    <Sheet title="ยกเลิกการจอง" onClose={onClose}>
      <p className={`rounded-xl p-3 text-sm font-semibold ${out.refund >= Number(job.booking_fee) ? 'bg-green-500/10 text-green-200' : 'bg-amber-400/10 text-amber-200'}`}>{out.text}</p>
      <label className="block text-sm">เหตุผล{matched ? ' (น้องจะเห็น)' : ''}
        <select className={`${input} mt-1`} value={reason} onChange={(e) => setReason(e.target.value)}>{CANCEL_REASONS.map((r) => <option key={r} value={r} className="text-black">{r}</option>)}</select></label>
      <label className="block text-sm">รายละเอียดเพิ่มเติม (ไม่บังคับ ห้ามใส่เบอร์/LINE)
        <textarea className={`${input} mt-1`} rows={2} maxLength={200} value={note} onChange={(e) => setNote(e.target.value)} /></label>
      {matched && (
        <label className="block text-sm">ค่าชดเชย (ไม่บังคับ) 0–{rules.comp_max} บาท
          <input type="number" inputMode="numeric" min="0" max={rules.comp_max} className={`${input} mt-1`} value={comp} placeholder="0" onChange={(e) => setComp(e.target.value)} />
          <span className="mt-1 block text-[11px] text-neutral-400">หักจาก Wallet ของคุณ เป็นค่าชดเชยที่ให้แพลตฟอร์มพิจารณามอบให้น้อง (ไม่การันตียอดที่น้องจะได้รับ)</span></label>
      )}
      <div className="grid grid-cols-2 gap-2 pt-1">
        <button onClick={onClose} className="rounded-xl bg-white/10 py-2.5 text-sm">ไม่ยกเลิก</button>
        <button onClick={go} disabled={busy} className="rounded-xl bg-red-500 py-2.5 text-sm font-bold disabled:opacity-50">{busy ? '…' : 'ยืนยันยกเลิก'}</button>
      </div>
    </Sheet>
  )
}

// The customer reports a problem; anything but a plain no-show waits for an admin
export function ProblemSheet({ job, onClose, onDone, flash }) {
  const rules = useJobRules()
  const [kind, setKind] = useState(null)
  const [note, setNote] = useState('')
  const [busy, setBusy] = useState(false)
  const start = job.scheduled_at ? new Date(job.scheduled_at).getTime() : 0
  const noshowOk = Date.now() >= start + Number(rules.noshow_wait_minutes) * 60000
  const otherOk = Date.now() >= start
  async function go() {
    setBusy(true)
    const { data, error } = await supabase.rpc('customer_report_problem', { p_job: job.id, p_kind: kind, p_note: note.trim() || null })
    setBusy(false)
    if (error) return flash(jobErr(error.message))
    flash(data === 'settled' ? 'บันทึกแล้ว คืนค่าจองเข้า Wallet' : 'ส่งเรื่องให้แอดมินตรวจสอบแล้ว (พักเงินไว้จนกว่าแอดมินตัดสิน)'); onDone()
  }
  return (
    <Sheet title="แจ้งปัญหางานนี้" onClose={onClose}>
      <ul className="space-y-2">
        {PROBLEM_KINDS.map(([k, label]) => {
          const ok = k === 'worker_noshow' ? noshowOk : otherOk
          return (
            <li key={k}><button disabled={!ok} onClick={() => setKind(k)} className={`w-full rounded-xl px-3 py-2.5 text-left text-sm font-semibold disabled:opacity-40 ${kind === k ? 'bg-amber-400 text-black' : 'bg-white/10'}`}>
              {label}{!ok && <span className="block text-[11px] font-normal opacity-80">{k === 'worker_noshow' ? `กดได้หลังเวลานัด ${rules.noshow_wait_minutes} นาที` : 'กดได้เมื่อถึงเวลานัด'}</span>}</button></li>
          )
        })}
      </ul>
      {kind && kind !== 'worker_noshow' && <p className="rounded-xl bg-white/5 p-3 text-xs text-neutral-300">เรื่องนี้ต้องให้แอดมินตรวจสอบ ระบบจะพักเงินไว้ ไม่มีการคืนเงินอัตโนมัติ แอดมินจะตัดสินและแจ้งผลทาง LINE</p>}
      {kind === 'worker_noshow' && !job.arrived_at && <p className="rounded-xl bg-green-500/10 p-3 text-xs text-green-200">คืนค่าจองเต็มจำนวนทันที (น้องยังไม่ได้กด "ถึงแล้ว")</p>}
      {kind === 'worker_noshow' && job.arrived_at && <p className="rounded-xl bg-white/5 p-3 text-xs text-neutral-300">น้องกด "ถึงแล้ว" ไว้ เรื่องนี้จึงให้แอดมินตรวจสอบ</p>}
      <label className="block text-sm">อธิบายเพิ่มเติม (ห้ามใส่เบอร์/LINE)
        <textarea className={`${input} mt-1`} rows={3} maxLength={300} value={note} onChange={(e) => setNote(e.target.value)} /></label>
      <p className="text-[11px] text-neutral-400">การรายงานเท็จจะถูกบันทึกในประวัติของคุณ</p>
      <button onClick={go} disabled={!kind || busy} className="w-full rounded-xl bg-amber-400 py-2.5 text-sm font-bold text-black disabled:opacity-40">{busy ? '…' : 'ส่งรายงาน'}</button>
    </Sheet>
  )
}

// Ask the other side to move the date. If they agree the job is finished (fee kept), so both are told so.
export function ReschedSheet({ job, role, onClose, onDone, flash }) {
  const rules = useJobRules()
  const [at, setAt] = useState('')
  const [busy, setBusy] = useState(false)
  const min = new Date(Date.now() + 3600e3 - new Date().getTimezoneOffset() * 60000).toISOString().slice(0, 16)
  async function go() {
    setBusy(true)
    const { error } = await supabase.rpc('job_request_reschedule', { p_job: job.id, p_new: new Date(at).toISOString() })
    setBusy(false)
    if (error) return flash(jobErr(error.message))
    flash('ส่งคำขอเลื่อนนัดแล้ว รออีกฝ่ายตอบ'); onDone()
  }
  return (
    <Sheet title="ขอเลื่อนนัด" onClose={onClose}>
      <div className="space-y-1 rounded-xl bg-amber-400/10 p-3 text-xs text-amber-100">
        <p>• เลื่อนได้ <b>1 ครั้งต่องาน</b> และต้องขอก่อนเวลานัดอย่างน้อย {rules.resched_notice_hours} ชม.</p>
        <p>• ถ้าอีกฝ่ายรับ ถือว่า <b>งานนี้เสร็จสิ้น ค่าจองไม่คืน</b> และนัดใหม่ <b>อยู่นอกการคุ้มครองของแพลตฟอร์ม</b></p>
        <p>• ถ้าอีกฝ่ายปฏิเสธ นัดเดิมยังอยู่</p>
      </div>
      <label className="block text-sm">วันเวลานัดใหม่
        <input type="datetime-local" min={min} className={`${input} mt-1`} value={at} onChange={(e) => setAt(e.target.value)} /></label>
      <button onClick={go} disabled={!at || busy} className="w-full rounded-xl bg-line py-2.5 text-sm font-bold text-black disabled:opacity-40">{busy ? '…' : 'ส่งคำขอเลื่อนนัด'}</button>
      {role === 'worker' && <p className="text-[11px] text-neutral-400">หากลูกค้าไม่รับและคุณไม่ไปตามนัด จะนับเป็นผิดนัดตามปกติ</p>}
    </Sheet>
  )
}

// The other side answers a reschedule request (also reached from the LINE Flex)
export async function answerResched(job, accept, role, flash) {
  if (accept) {
    const msg = role === 'customer'
      ? 'ถ้ารับเลื่อนนัด งานนี้ถือว่าเสร็จสิ้น ค่าจองไม่คืน และนัดใหม่อยู่นอกการคุ้มครองของแพลตฟอร์ม (ไม่มีการรายงานไม่มา/ขอคืนเงิน) ยืนยันรับเลื่อนนัด?'
      : 'ถ้ารับเลื่อนนัด งานนี้ถือว่าเสร็จสิ้น และนัดใหม่อยู่นอกการคุ้มครองของแพลตฟอร์ม ยืนยันรับเลื่อนนัด?'
    if (!window.confirm(msg)) return false
  }
  const { error } = await supabase.rpc('job_answer_reschedule', { p_job: job.id, p_accept: accept })
  if (error) { flash(jobErr(error.message)); return false }
  flash(accept ? 'รับเลื่อนนัดแล้ว งานนี้เสร็จสิ้น' : 'ปฏิเสธแล้ว นัดเดิมยังอยู่')
  return true
}
