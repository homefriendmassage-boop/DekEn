import { useCallback, useEffect, useState } from 'react'
import { supabase } from '../supabaseClient'
import { fmtDateTime } from './format'

const SETTINGS = [
  ['response_minutes', 'job_response_minutes', 'เวลาที่น้องต้องตอบ (นาที) 5–180 · แนะนำ 15/30/60'],
  ['autocomplete_hours', 'job_autocomplete_hours', 'งานเสร็จอัตโนมัติหลังเวลานัด (ชั่วโมง) และเป็นช่วงที่ลูกค้ารายงานปัญหาได้'],
  ['free_cancel_minutes', 'job_free_cancel_minutes', 'ลูกค้ายกเลิกฟรีภายใน (นาที) หลังกดจอง'],
  ['cancel_fee', 'job_cancel_fee', 'ค่ายกเลิก (บาท) ที่หักจากค่าจอง'],
  ['early_cancel_hours', 'job_early_cancel_hours', 'ลูกค้ายกเลิกหลังน้องรับ ล่วงหน้าอย่างน้อย (ชั่วโมง) ถึงจะคืนค่าจอง (หักค่ายกเลิก)'],
  ['noshow_wait_minutes', 'job_noshow_wait_minutes', 'รอกี่นาทีหลังเวลานัด/หลังกดถึงแล้ว ก่อนกด "น้องไม่มา/ลูกค้าไม่มา"'],
  ['objection_hours', 'job_objection_hours', 'ลูกค้าคัดค้านการรายงาน "ลูกค้าไม่มา" ได้ภายใน (ชั่วโมง)'],
  ['resched_notice_hours', 'job_resched_notice_hours', 'ขอเลื่อนนัดล่วงหน้าอย่างน้อย (ชั่วโมง)'],
  ['comp_max', 'job_comp_max', 'ค่าชดเชยสูงสุดที่ลูกค้าใส่ได้ (บาท)'],
  ['penalty_step', 'penalty_step', 'ค่าปรับต่อ 1 ครั้งที่ผิดนัด (บาท) ครั้งที่ n = n × ค่านี้'],
  ['penalty_from', 'penalty_from', 'ผิดนัดครั้งที่เท่าไหร่เริ่มบล็อก+ปรับ (ก่อนหน้านั้นเตือน)'],
  ['cust_pause_count', 'cust_pause_count', 'ลูกค้าไม่มา/ยกเลิกหลังรับครบกี่ครั้ง ถึงพักการจอง'],
  ['cust_pause_window_days', 'cust_pause_window_days', '...ภายในกี่วัน'],
  ['cust_pause_days', 'cust_pause_days', '...พักการจองกี่วัน'],
]
const EVKIND = { worker_fault: 'น้องผิดนัด', customer_noshow: 'ลูกค้าไม่มา', customer_cancel: 'ลูกค้ายกเลิกหลังรับ' }

// Booking rules back office: strikes / fines, single events ("do not count"), compensation, settings
export default function JobAdmin({ toast }) {
  const [sub, setSub] = useState('strikes')
  return (
    <div className="space-y-3 p-3">
      <div className="flex flex-wrap gap-2">
        {[['strikes', '🚫 ค่าปรับ/ตัวนับ'], ['comp', '💰 ค่าชดเชย'], ['rules', '⚙️ กติกาการจอง']].map(([id, label]) => (
          <button key={id} onClick={() => setSub(id)} className={`rounded-full px-4 py-1.5 text-sm font-semibold ${sub === id ? 'bg-white text-black' : 'bg-white/10'}`}>{label}</button>
        ))}
      </div>
      {sub === 'strikes' && <Strikes toast={toast} />}
      {sub === 'comp' && <Comp toast={toast} />}
      {sub === 'rules' && <Rules toast={toast} />}
    </div>
  )
}

function Strikes({ toast }) {
  const [rows, setRows] = useState(null)
  const [events, setEvents] = useState(null)       // { worker, list }
  const [q, setQ] = useState('')
  const [found, setFound] = useState([])
  const load = useCallback(async () => { const { data } = await supabase.rpc('admin_strikes'); setRows(data ?? []) }, [])
  useEffect(() => { load() }, [load])
  async function show(w) { const { data } = await supabase.rpc('admin_job_events', { p_worker: w.worker_id ?? w.id }); setEvents({ worker: { id: w.worker_id ?? w.id, name: w.name ?? w.display_name }, list: data ?? [] }) }
  async function setCount(w) {
    const v = window.prompt(`ตั้งตัวนับค่าปรับของ ${w.name} (ตอนนี้ ${w.strikes}) เป็นกี่ครั้ง? (0 = ล้าง)`, String(Math.max(0, w.strikes - 1)))
    if (v === null) return
    const n = parseInt(v, 10)
    if (Number.isNaN(n) || n < 0) return toast('ใส่ตัวเลข 0 ขึ้นไป')
    const { error } = await supabase.rpc('admin_strike_set', { p_worker: w.worker_id, p_count: n })
    toast(error ? 'ทำรายการไม่สำเร็จ' : 'ปรับตัวนับแล้ว'); load()
  }
  async function unblock(w) {
    if (!window.confirm(`ปลดบล็อก ${w.name}${w.block_kind === 'imposter' ? ' (ตรวจเซลฟีสดแล้วหรือยัง?)' : ' และยกเว้นค่าปรับ'}?`)) return
    const { error } = await supabase.rpc('admin_worker_unblock', { p_worker: w.worker_id })
    toast(error ? 'ทำรายการไม่สำเร็จ' : 'ปลดบล็อกแล้ว'); load()
  }
  async function voidEvent(ev) {
    const reason = window.prompt('เหตุผลที่ไม่นับรายการนี้ (บันทึกไว้ ตรวจย้อนหลังได้)', '')
    if (!reason || reason.trim().length < 3) return
    const { error } = await supabase.rpc('admin_event_void', { p_event: ev.id, p_reason: reason })
    if (error) return toast('ทำรายการไม่สำเร็จ')
    toast('ไม่นับรายการนี้แล้ว'); show({ id: events.worker.id, name: events.worker.name }); load()
  }
  async function search() {
    if (!q.trim()) return setFound([])
    const { data } = await supabase.rpc('admin_teaser_list', { p_q: q.trim(), p_flagged: false, p_limit: 8, p_offset: 0 })
    const m = new Map(); (data ?? []).forEach((r) => m.set(r.worker_id, { id: r.worker_id, display_name: r.display_name })); setFound([...m.values()])
  }
  return (
    <div className="space-y-3">
      <p className="text-xs text-neutral-400">ตัวนับค่าปรับสะสมจนกว่าแอดมินจะปรับ (ผิดนัดครั้งที่ n: เตือน → บล็อก+ปรับ n×100) แยกจากสถิติ 90 วันที่ลูกค้าเห็น ซึ่งลบได้ทีละรายการเท่านั้น (ต้องใส่เหตุผล)</p>
      {rows === null ? <p className="py-6 text-center text-neutral-500">กำลังโหลด…</p> : rows.length === 0 ? <p className="rounded-2xl bg-white/5 p-5 text-center text-neutral-500">ยังไม่มีน้องที่ผิดนัด</p> : (
        <ul className="space-y-2">
          {rows.map((w) => (
            <li key={w.worker_id} className="space-y-2 rounded-2xl bg-white/5 p-3 text-sm ring-1 ring-white/10">
              <div className="flex items-center justify-between gap-2"><p className="font-bold">{w.name}</p>
                {w.blocked && <span className="rounded-full bg-red-500/20 px-2 py-0.5 text-[11px] text-red-300">🚫 บล็อก{w.block_kind === 'imposter' ? ' (คนอื่นแทน)' : ` · ค่าปรับ ${w.fine_due}`}</span>}</div>
              <p className="text-xs text-neutral-400">ผิดนัดสะสม {w.strikes} ครั้ง</p>
              <div className="grid grid-cols-3 gap-2">
                <button onClick={() => show(w)} className="rounded-lg bg-white/10 py-1.5 text-xs active:scale-95">ดูรายการ</button>
                <button onClick={() => setCount(w)} className="rounded-lg bg-amber-400 py-1.5 text-xs font-bold text-black active:scale-95">ปรับตัวนับ</button>
                {w.blocked && <button onClick={() => unblock(w)} className="rounded-lg bg-line py-1.5 text-xs font-bold text-black active:scale-95">ปลดบล็อก</button>}
              </div>
            </li>
          ))}
        </ul>
      )}
      <div className="space-y-2 rounded-2xl bg-white/5 p-3 ring-1 ring-white/10">
        <p className="text-sm font-semibold">ค้นหาน้อง เพื่อดู/ลบรายการในสถิติ 90 วัน</p>
        <div className="flex gap-2"><input value={q} onChange={(e) => setQ(e.target.value)} onKeyDown={(e) => e.key === 'Enter' && search()} placeholder="ชื่อน้อง" className="min-w-0 flex-1 rounded-xl bg-white/10 px-3 py-2 text-base outline-none ring-1 ring-white/10 focus:ring-line" /><button onClick={search} className="rounded-xl bg-white/10 px-4 text-sm">ค้นหา</button></div>
        {found.map((f) => <button key={f.id} onClick={() => show(f)} className="block w-full rounded-lg bg-white/5 px-3 py-2 text-left text-sm">{f.display_name}</button>)}
      </div>
      {events && (
        <div className="fixed inset-0 z-50 flex items-end justify-center bg-black/70 sm:items-center" onClick={() => setEvents(null)}>
          <div onClick={(e) => e.stopPropagation()} className="max-h-[85vh] w-full max-w-md space-y-2 overflow-y-auto rounded-t-3xl bg-neutral-900 p-5 sm:rounded-3xl">
            <div className="flex items-center justify-between"><h3 className="text-lg font-bold">รายการของ {events.worker.name}</h3><button onClick={() => setEvents(null)} className="rounded-full bg-white/10 px-3 py-1 text-sm">✕</button></div>
            {events.list.length === 0 ? <p className="py-4 text-center text-neutral-500">ไม่มีรายการใน 180 วัน</p> : events.list.map((ev) => (
              <div key={ev.id} className={`space-y-1 rounded-xl bg-white/5 p-3 text-sm ${ev.voided_at ? 'opacity-50' : ''}`}>
                <p className="font-semibold">{EVKIND[ev.kind]}{ev.detail ? ` (${ev.detail})` : ''} <span className="text-xs font-normal text-neutral-400">· {fmtDateTime(ev.at)}</span></p>
                {ev.worker_reason && <p className="text-xs text-neutral-300">เหตุผลของน้อง: {ev.worker_reason}</p>}
                {ev.voided_at ? <p className="text-xs text-green-300">ไม่นับแล้ว: {ev.void_reason}</p> : <button onClick={() => voidEvent(ev)} className="rounded-lg bg-white/10 px-3 py-1 text-xs active:scale-95">ไม่นับรายการนี้</button>}
              </div>
            ))}
          </div>
        </div>
      )}
    </div>
  )
}

function Comp({ toast }) {
  const [status, setStatus] = useState('pending')
  const [rows, setRows] = useState(null)
  const load = useCallback(async () => { setRows(null); const { data } = await supabase.rpc('admin_compensations', { p_status: status }); setRows(data ?? []) }, [status])
  useEffect(() => { load() }, [load])
  async function credit(c) {
    const v = window.prompt(`เติม Wallet ของ ${c.worker_name} เท่าไหร่? (ลูกค้าจ่ายมา ${c.amount} บาท)`, String(c.amount))
    if (v === null) return
    const n = Number(v)
    if (!(n > 0) || n > c.amount) return toast('จำนวนไม่ถูกต้อง')
    const { error } = await supabase.rpc('admin_compensation_credit', { p_job: c.job_id, p_amount: n })
    toast(error ? 'ทำรายการไม่สำเร็จ' : 'เติม Wallet น้องแล้ว'); load()
  }
  async function dismiss(c) {
    if (!window.confirm('ไม่เติมให้น้อง (เก็บเป็นรายได้แพลตฟอร์ม)?')) return
    await supabase.rpc('admin_compensation_dismiss', { p_job: c.job_id }); toast('บันทึกแล้ว'); load()
  }
  return (
    <div className="space-y-3">
      <div className="flex gap-2">{[['pending', 'รอพิจารณา'], ['credited', 'เติมแล้ว'], ['dismissed', 'ไม่เติม']].map(([k, l]) => <button key={k} onClick={() => setStatus(k)} className={`rounded-full px-3 py-1 text-sm ${status === k ? 'bg-white text-black' : 'bg-white/10'}`}>{l}</button>)}</div>
      <p className="text-xs text-neutral-400">ค่าชดเชยที่ลูกค้าใส่ตอนยกเลิกหลังน้องรับ เข้าแพลตฟอร์มแล้ว คุณพิจารณาเติม Wallet ให้น้องได้ตามความเหมาะสม</p>
      {rows === null ? <p className="py-6 text-center text-neutral-500">กำลังโหลด…</p> : rows.length === 0 ? <p className="rounded-2xl bg-white/5 p-5 text-center text-neutral-500">ไม่มีรายการ</p> : (
        <ul className="space-y-2">{rows.map((c) => (
          <li key={c.job_id} className="space-y-1 rounded-2xl bg-white/5 p-3 text-sm ring-1 ring-white/10">
            <p className="font-bold">{c.amount} บาท <span className="text-xs font-normal text-neutral-400">· {fmtDateTime(c.at)}</span></p>
            <p className="text-xs text-neutral-300">ลูกค้า {c.customer_name} → น้อง <b>{c.worker_name}</b></p>
            {c.note && <p className="text-xs text-neutral-400">เหตุผลลูกค้า: {c.note}</p>}
            {c.status === 'credited' && <p className="text-xs text-green-300">เติมให้น้องแล้ว {c.credited_amount} บาท</p>}
            {c.status === 'pending' && <div className="grid grid-cols-2 gap-2"><button onClick={() => credit(c)} className="rounded-lg bg-line py-1.5 text-xs font-bold text-black active:scale-95">เติม Wallet น้อง</button><button onClick={() => dismiss(c)} className="rounded-lg bg-white/10 py-1.5 text-xs active:scale-95">ไม่เติม</button></div>}
          </li>
        ))}</ul>
      )}
    </div>
  )
}

function Rules({ toast }) {
  const [st, setSt] = useState(null)
  const [draft, setDraft] = useState({})
  const load = useCallback(async () => { const { data } = await supabase.rpc('admin_job_settings'); setSt(data ?? {}); setDraft(Object.fromEntries(Object.entries(data ?? {}).map(([k, v]) => [k, String(v)]))) }, [])
  useEffect(() => { load() }, [load])
  async function save(field, key) {
    const { error } = await supabase.rpc('admin_set_setting', { p_key: key, p_value: String(parseInt(draft[field], 10)) })
    toast(error ? 'บันทึกไม่สำเร็จ (ตรวจช่วงค่าที่อนุญาต)' : 'บันทึกแล้ว'); load()
  }
  if (!st) return <p className="py-6 text-center text-neutral-500">กำลังโหลด…</p>
  return (
    <div className="space-y-2">
      <p className="text-xs text-neutral-400">ค่าใหม่ใช้กับการจองที่สร้างหลังบันทึก (การคำนวณเวลาและค่าปรับอ่านค่าปัจจุบันทุกครั้ง) ค่าจองต่อครั้งตอนนี้ {st.booking_fee} บาท</p>
      {SETTINGS.map(([field, key, label]) => (
        <div key={key} className="space-y-1 rounded-xl bg-white/5 p-3 ring-1 ring-white/10">
          <p className="text-xs text-neutral-300">{label}</p>
          <div className="flex gap-2">
            <input type="number" min="0" value={draft[field] ?? ''} onChange={(e) => setDraft({ ...draft, [field]: e.target.value })} className="w-28 rounded-lg bg-white/10 px-3 py-2 text-base outline-none ring-1 ring-white/10 focus:ring-line" />
            <button onClick={() => save(field, key)} disabled={String(st[field]) === draft[field]} className="rounded-lg bg-line px-3 py-2 text-sm font-bold text-black disabled:opacity-30">บันทึก</button>
          </div>
        </div>
      ))}
    </div>
  )
}
