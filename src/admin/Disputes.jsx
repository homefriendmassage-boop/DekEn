import { useCallback, useEffect, useState } from 'react'
import { supabase } from '../supabaseClient'
import { fmtDateTime } from './format'
import Compose from './Compose'

const KIND = { worker_noshow: 'น้องไม่มาตามนัด (น้องกดถึงแล้วไว้)', imposter: 'คนอื่นมาแทน / ไม่ใช่คนในโปรไฟล์', mismatch: 'ไม่ตรงปกมาก', other: 'ปัญหาอื่น', customer_noshow_claim: 'น้องแจ้งว่าลูกค้าไม่มา (ลูกค้าคัดค้าน)' }
const RES = { customer: 'เห็นด้วยกับผู้แจ้ง', worker: 'ไม่เห็นด้วย (ฝ่ายตรงข้ามถูก)', none: 'ไม่ผิดใคร' }

// Booking disputes: money is held until an admin decides. No automatic refund.
export default function Disputes({ toast, onChanged }) {
  const [open, setOpen] = useState(true)
  const [rows, setRows] = useState(null)
  const [dec, setDec] = useState(null)        // { job, decision }
  const [note, setNote] = useState('')
  const [strike, setStrike] = useState(true)
  const [compose, setCompose] = useState(null)
  const load = useCallback(async () => {
    setRows(null)
    const { data, error } = await supabase.rpc('admin_disputes', { p_open: open })
    if (error) toast('โหลดไม่สำเร็จ: ' + error.message)
    setRows(data ?? [])
  }, [open, toast]) // eslint-disable-line react-hooks/exhaustive-deps
  useEffect(() => { load() }, [open]) // eslint-disable-line react-hooks/exhaustive-deps

  async function resolve() {
    const { error } = await supabase.rpc('admin_dispute_resolve', { p_job: dec.job.job_id, p_decision: dec.decision, p_note: note.trim() || null, p_strike: strike })
    if (error) return toast('บันทึกไม่สำเร็จ')
    toast('ตัดสินแล้ว ส่ง Flex แจ้งทั้งสองฝ่ายแล้ว'); setDec(null); setNote(''); load(); onChanged?.()
  }
  const w90 = (r) => (r ? `น้องผิดนัด ${r.worker_faults} · ลูกค้าผิดนัด ${r.customer_noshows} · ลูกค้ายกเลิก ${r.customer_cancels}` : '')
  const meaning = (j, d) => {
    const k = j.dispute_kind
    if (d === 'none') return 'คืนค่าจองให้ลูกค้า ไม่นับสถิติใคร'
    if (k === 'customer_noshow_claim') return d === 'worker' ? 'ค่าจองไม่คืน จ่ายส่วนแบ่ง บันทึกว่าลูกค้าไม่มา' : 'คืนค่าจองให้ลูกค้า ไม่นับสถิติ (น้องรายงานไม่จริง)'
    if (d === 'worker') return 'คำร้องของลูกค้าไม่ได้รับการยืนยัน: ถือเป็นการยกเลิกของลูกค้า ค่าจองไม่คืน จ่ายส่วนแบ่ง'
    return k === 'imposter' ? 'คืนค่าจองเต็ม + บล็อกน้องทันที (ปลดได้เฉพาะแอดมิน หลังยืนยันตัวตน)' : 'คืนค่าจองเต็ม + นับน้องผิดนัด 1 ครั้ง (ตัวนับค่าปรับ)'
  }

  return (
    <div className="space-y-3 p-3">
      <div className="flex gap-2">
        <button onClick={() => setOpen(true)} className={`rounded-full px-4 py-1.5 text-sm font-semibold ${open ? 'bg-amber-400 text-black' : 'bg-white/10'}`}>⚖️ รอตัดสิน</button>
        <button onClick={() => setOpen(false)} className={`rounded-full px-4 py-1.5 text-sm font-semibold ${!open ? 'bg-white text-black' : 'bg-white/10'}`}>ตัดสินแล้ว</button>
      </div>
      {rows === null ? <p className="py-8 text-center text-neutral-500">กำลังโหลด…</p> : rows.length === 0 ? <p className="rounded-2xl bg-white/5 p-6 text-center text-neutral-500">{open ? 'ไม่มีข้อพิพาทรอตัดสิน' : 'ยังไม่มีรายการ'}</p> : (
        <ul className="space-y-3">
          {rows.map((j) => (
            <li key={j.job_id} className="space-y-2 rounded-2xl bg-white/5 p-3 text-sm ring-1 ring-white/10">
              <p className="font-bold">{KIND[j.dispute_kind] ?? j.dispute_kind}</p>
              <p className="text-xs text-neutral-300">ลูกค้า: <b>{j.customer_name}</b> · น้อง: <b>{j.worker_name}</b> · ค่าจอง {j.booking_fee} บาท</p>
              <p className="text-xs text-neutral-400">นัด {j.scheduled_at ? fmtDateTime(j.scheduled_at) : '—'}{j.arrived_at ? ` · น้องกดถึงแล้ว ${fmtDateTime(j.arrived_at)}` : ' · น้องไม่ได้กดถึงแล้ว'}{j.customer_noshow_at ? ` · น้องรายงานลูกค้าไม่มา ${fmtDateTime(j.customer_noshow_at)}` : ''}</p>
              {j.dispute_note && <p className="rounded-lg bg-black/30 p-2 text-xs">💬 ผู้แจ้ง: {j.dispute_note}</p>}
              <div className="grid grid-cols-2 gap-2">
                <button onClick={() => setCompose({ id: j.worker_id, name: j.worker_name })} className="rounded-lg bg-sky-500/70 py-1.5 text-xs font-bold active:scale-95">✉️ ทักหาน้อง</button>
                <button onClick={() => setCompose({ id: j.customer_id, name: j.customer_name })} className="rounded-lg bg-sky-500/40 py-1.5 text-xs font-bold active:scale-95">✉️ ทักหาลูกค้า</button>
              </div>
              <p className="text-[11px] text-neutral-500">สถิติน้อง 90 วัน: {w90(j.worker_90d)} · ลูกค้าผิดนัด/ยกเลิก 90 วัน: {j.customer_90d}</p>
              {open ? (
                <div className="grid grid-cols-3 gap-2">
                  <button onClick={() => { setDec({ job: j, decision: 'customer' }); setStrike(true) }} className="rounded-lg bg-red-500/80 py-2 text-xs font-bold active:scale-95">เห็นด้วยกับ{j.dispute_by === 'customer' ? 'ลูกค้า' : 'น้อง'}</button>
                  <button onClick={() => setDec({ job: j, decision: 'worker' })} className="rounded-lg bg-white/15 py-2 text-xs font-bold active:scale-95">ไม่เห็นด้วย</button>
                  <button onClick={() => setDec({ job: j, decision: 'none' })} className="rounded-lg bg-white/10 py-2 text-xs font-semibold active:scale-95">ไม่ผิดใคร</button>
                </div>
              ) : <p className="rounded-lg bg-green-500/10 p-2 text-xs text-green-200">ตัดสิน: {j.resolution} · {j.resolved_at ? fmtDateTime(j.resolved_at) : ''}</p>}
            </li>
          ))}
        </ul>
      )}
      {compose && <Compose userId={compose.id} name={compose.name} toast={toast} onClose={() => setCompose(null)} />}
      {dec && (
        <div className="fixed inset-0 z-50 flex items-end justify-center bg-black/70 sm:items-center" onClick={() => setDec(null)}>
          <div onClick={(e) => e.stopPropagation()} className="w-full max-w-md space-y-3 rounded-t-3xl bg-neutral-900 p-5 sm:rounded-3xl">
            <h3 className="text-lg font-bold">ยืนยันคำตัดสิน: {dec.decision === 'none' ? 'ไม่ผิดใคร' : dec.decision === 'worker' ? 'ไม่เห็นด้วยกับคำร้อง' : 'เห็นด้วยกับผู้แจ้ง'}</h3>
            <p className="rounded-xl bg-amber-400/10 p-3 text-sm text-amber-100">{meaning(dec.job, dec.decision)}</p>
            {dec.decision === 'customer' && dec.job.dispute_kind !== 'customer_noshow_claim' && dec.job.dispute_kind !== 'imposter' && (
              <label className="flex items-center gap-2 text-sm"><input type="checkbox" checked={strike} onChange={(e) => setStrike(e.target.checked)} /> นับเป็นผิดนัดของน้อง (ตัวนับค่าปรับ)</label>
            )}
            <textarea rows={2} maxLength={200} value={note} onChange={(e) => setNote(e.target.value)} placeholder="หมายเหตุของแอดมิน (บันทึกไว้)" className="w-full rounded-xl bg-white/10 px-3 py-2 text-base outline-none ring-1 ring-white/10 focus:ring-line" />
            <div className="grid grid-cols-2 gap-2">
              <button onClick={() => setDec(null)} className="rounded-xl bg-white/10 py-2.5 text-sm">ยกเลิก</button>
              <button onClick={resolve} className="rounded-xl bg-line py-2.5 text-sm font-bold text-black">ยืนยันคำตัดสิน</button>
            </div>
            <p className="text-[11px] text-neutral-500">คำตัดสินแล้วเปลี่ยนไม่ได้ ระบบส่ง Flex แจ้งทั้งสองฝ่าย ({Object.values(RES).join(' / ')})</p>
          </div>
        </div>
      )}
    </div>
  )
}
