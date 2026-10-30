import { useCallback, useEffect, useState } from 'react'
import { supabase } from '../supabaseClient'
import { promptPayPayload } from '../lib/promptpay'
import Certificate from '../components/Certificate'

const baht = (n) => `${Number(n ?? 0).toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 })} บาท`
const SUBS = [['identity', '🪪 ยืนยันตัวตน'], ['pending', '💸 รอโอน'], ['paid', '✅ โอนแล้ว'], ['other', 'ปฏิเสธ/ยกเลิก'], ['settings', '⚙️ ตั้งค่า']]
const field = 'mt-1 w-full rounded-xl bg-white/10 px-3 py-2 text-sm outline-none ring-1 ring-white/10 focus:ring-line'
const ERR = { PAYER_NOT_SET: 'ยังไม่ได้ตั้งชื่อผู้จ่ายเงิน (ไปที่แท็บตั้งค่า)', REF_REQUIRED: 'ใส่เลขอ้างอิงสลิปก่อน', REASON_REQUIRED: 'ใส่เหตุผลก่อน', NOT_FOUND: 'รายการนี้ถูกจัดการไปแล้ว' }
const errText = (m = '') => Object.entries(ERR).find(([k]) => m.includes(k))?.[1] ?? `ไม่สำเร็จ (${m.slice(0, 100)})`

// Back office for cash withdrawals: identity checks, the transfer queue (PromptPay QR with the exact net amount), paid history with certificates, settings.
export default function Withdrawals({ toast, onChanged }) {
  const [sub, setSub] = useState('identity')
  const [rows, setRows] = useState(null)
  const [cert, setCert] = useState(null)

  const load = useCallback(async () => {
    setRows(null)
    if (sub === 'settings') return setRows([])
    if (sub === 'identity') { const { data } = await supabase.rpc('admin_payout_profiles', { p_status: 'pending' }); return setRows(data ?? []) }
    if (sub === 'other') {
      const [a, b] = await Promise.all([supabase.rpc('admin_withdrawals', { p_status: 'rejected' }), supabase.rpc('admin_withdrawals', { p_status: 'cancelled' })])
      return setRows([...(a.data ?? []), ...(b.data ?? [])])
    }
    const { data } = await supabase.rpc('admin_withdrawals', { p_status: sub }); setRows(data ?? [])
  }, [sub])
  useEffect(() => { load() }, [load])
  const done = (msg) => { toast(msg); load(); onChanged?.() }

  return (
    <div className="space-y-4">
      <div className="flex flex-wrap gap-2">
        {SUBS.map(([id, label]) => <button key={id} onClick={() => setSub(id)} className={`rounded-full px-3 py-1.5 text-sm font-semibold ${sub === id ? 'bg-white text-black' : 'bg-white/10'}`}>{label}</button>)}
      </div>
      {sub === 'settings' ? <Settings toast={toast} /> : rows === null ? <p className="py-10 text-center text-neutral-500">กำลังโหลด…</p> : rows.length === 0 ? <p className="rounded-2xl bg-white/5 p-6 text-center text-neutral-500">ไม่มีรายการ</p> : (
        <ul className="grid gap-3 md:grid-cols-2">
          {sub === 'identity' && rows.map((p) => <IdentityCard key={p.user_id} p={p} toast={toast} onDone={done} />)}
          {sub !== 'identity' && rows.map((w) => <WithdrawCard key={w.id} w={w} sub={sub} toast={toast} onDone={done} onCert={setCert} />)}
        </ul>
      )}
      {cert && <Certificate cert={cert} adminView onClose={() => setCert(null)} />}
    </div>
  )
}

function IdentityCard({ p, toast, onDone }) {
  const [detail, setDetail] = useState(null)
  const [rejecting, setRejecting] = useState(false)
  const [reason, setReason] = useState('')
  async function show() { const { data, error } = await supabase.rpc('admin_payout_detail', { p_user: p.user_id }); if (error) return toast('เปิดข้อมูลไม่สำเร็จ'); setDetail(data) }
  async function decide(ok) {
    const { error } = await supabase.rpc('admin_payout_decide', { p_user: p.user_id, p_approve: ok, p_reason: ok ? null : reason })
    if (error) return toast(errText(error.message))
    onDone(ok ? 'ยืนยันตัวตนแล้ว' : 'ปฏิเสธแล้ว')
  }
  return (
    <li className="space-y-2 rounded-2xl bg-white/5 p-4 ring-1 ring-white/10">
      <p className="font-bold">{p.full_name} <span className="text-xs font-normal text-neutral-400">· บัญชี LINE: {p.user_name ?? '—'}</span></p>
      <p className="text-xs text-neutral-400">บัตรลงท้าย {p.id_last4} · ส่งเมื่อ {new Date(p.created_at).toLocaleString('th-TH')}</p>
      {detail ? (
        <dl className="space-y-0.5 rounded-xl bg-black/30 p-3 text-sm">
          <dt className="text-xs text-neutral-400">เลขบัตรประชาชน</dt><dd className="font-mono">{detail.national_id}</dd>
          <dt className="text-xs text-neutral-400">ที่อยู่</dt><dd>{detail.address}</dd>
          <dt className="text-xs text-neutral-400">พร้อมเพย์</dt><dd className="font-mono">{detail.promptpay}</dd>
        </dl>
      ) : <button onClick={show} className="rounded-lg bg-white/10 px-3 py-1.5 text-xs font-semibold active:scale-95">👁 ดูข้อมูลเต็ม (บันทึกว่าเปิดดู)</button>}
      <p className="text-[11px] text-amber-200">ยืนยันกับเจ้าตัวทาง LINE ก่อนกดอนุมัติ (ชื่อตรงกับบัตร/พร้อมเพย์)</p>
      {rejecting ? (
        <div className="space-y-2">
          <input value={reason} onChange={(e) => setReason(e.target.value)} maxLength={200} placeholder="เหตุผล (ผู้สมัครเห็น)" className={field} />
          <div className="grid grid-cols-2 gap-2"><button onClick={() => setRejecting(false)} className="rounded-xl bg-white/10 py-2 text-sm">ยกเลิก</button><button onClick={() => decide(false)} className="rounded-xl bg-red-500 py-2 text-sm font-bold">ยืนยันปฏิเสธ</button></div>
        </div>
      ) : (
        <div className="grid grid-cols-2 gap-2"><button onClick={() => setRejecting(true)} className="rounded-xl bg-white/10 py-2.5 text-sm font-semibold active:scale-95">ปฏิเสธ</button><button onClick={() => window.confirm(`อนุมัติ ${p.full_name}?`) && decide(true)} className="rounded-xl bg-line py-2.5 text-sm font-bold text-black active:scale-95">อนุมัติยืนยันตัวตน</button></div>
      )}
    </li>
  )
}

function WithdrawCard({ w, sub, toast, onDone, onCert }) {
  const [ref, setRef] = useState('')
  const [qr, setQr] = useState(null)
  const [rejecting, setRejecting] = useState(false)
  const [reason, setReason] = useState('')
  async function showQr() {
    if (qr) return setQr(null)
    const QR = await import('qrcode')
    setQr(await QR.toDataURL(promptPayPayload(w.promptpay, Number(w.net)), { width: 300, margin: 2 }))
  }
  async function pay() {
    if (!window.confirm(`ยืนยันว่าโอน ${baht(w.net)} ให้ ${w.payee_name} แล้ว? ระบบจะออกใบหัก ณ ที่จ่าย`)) return
    const { error } = await supabase.rpc('admin_withdraw_pay', { p_id: w.id, p_ref: ref })
    if (error) return toast(errText(error.message))
    onDone('บันทึกการโอนแล้ว ออกใบหัก ณ ที่จ่ายแล้ว')
  }
  async function reject() {
    const { error } = await supabase.rpc('admin_withdraw_reject', { p_id: w.id, p_reason: reason })
    if (error) return toast(errText(error.message))
    onDone('ปฏิเสธแล้ว คืนยอดเข้ากระเป๋าโบนัส')
  }
  async function openCert() {
    const { data, error } = await supabase.rpc('admin_certificate', { p_withdrawal: w.id })
    if (error) return toast('เปิดใบหัก ณ ที่จ่ายไม่สำเร็จ')
    onCert(data)
  }
  return (
    <li className="space-y-2 rounded-2xl bg-white/5 p-4 ring-1 ring-white/10">
      <div className="flex items-start justify-between gap-2">
        <div><p className="font-bold">{w.payee_name ?? w.user_name}</p><p className="text-xs text-neutral-400">LINE: {w.user_name ?? '—'} · {new Date(w.created_at).toLocaleString('th-TH')}</p></div>
        <div className="text-right"><p className="text-xs text-neutral-400">โอนสุทธิ</p><p className="text-lg font-extrabold text-green-300">{baht(w.net)}</p></div>
      </div>
      <p className="text-xs text-neutral-300">ยอดถอน {baht(w.gross)} − ภาษี {w.tax_percent}% {baht(w.tax_amount)} − ค่าธรรมเนียม {baht(w.fee)}</p>
      {sub === 'pending' && (
        <>
          <p className="text-sm">พร้อมเพย์: <span className="font-mono">{w.promptpay}</span></p>
          <button onClick={showQr} className="rounded-lg bg-white/10 px-3 py-1.5 text-xs font-semibold active:scale-95">▦ QR โอนยอดสุทธิ (สแกนจากแอปธนาคาร)</button>
          {qr && <img src={qr} alt="QR" className="mx-auto w-56 rounded-xl bg-white p-2" />}
          {rejecting ? (
            <div className="space-y-2">
              <input value={reason} onChange={(e) => setReason(e.target.value)} maxLength={200} placeholder="เหตุผล (ผู้ขอเห็น) · ยอดคืนเข้ากระเป๋าโบนัส" className={field} />
              <div className="grid grid-cols-2 gap-2"><button onClick={() => setRejecting(false)} className="rounded-xl bg-white/10 py-2 text-sm">ยกเลิก</button><button onClick={reject} className="rounded-xl bg-red-500 py-2 text-sm font-bold">ยืนยันปฏิเสธ</button></div>
            </div>
          ) : (
            <>
              <label className="block text-sm">เลขอ้างอิงสลิป (หลังโอนแล้ว)<input value={ref} onChange={(e) => setRef(e.target.value)} maxLength={100} placeholder="เช่น 202610301234ABC" className={field} /></label>
              <div className="grid grid-cols-2 gap-2"><button onClick={() => setRejecting(true)} className="rounded-xl bg-white/10 py-2.5 text-sm font-semibold active:scale-95">ปฏิเสธ</button><button onClick={pay} className="rounded-xl bg-line py-2.5 text-sm font-bold text-black active:scale-95">โอนแล้ว · ออกใบหัก</button></div>
            </>
          )}
        </>
      )}
      {sub === 'paid' && <div className="flex items-center justify-between"><p className="text-xs text-neutral-400">สลิป: {w.paid_ref ?? '—'}</p>{w.has_certificate && <button onClick={openCert} className="rounded-lg bg-green-500/80 px-3 py-1.5 text-xs font-bold text-black active:scale-95">📄 ใบหัก ณ ที่จ่าย</button>}</div>}
      {sub === 'other' && <p className="text-xs text-red-300">{w.status === 'rejected' ? `ปฏิเสธ: ${w.reject_reason ?? ''}` : 'ผู้ขอยกเลิกเอง'}</p>}
    </li>
  )
}

function Settings({ toast }) {
  const [v, setV] = useState(null)
  useEffect(() => { supabase.rpc('admin_payout_settings').then(({ data }) => setV(data ?? null)) }, [])
  async function save(key) {
    const { error } = await supabase.rpc('admin_set_payout_setting', { p_key: key, p_value: String(v[key] ?? '') })
    toast(error ? 'บันทึกไม่สำเร็จ' : 'บันทึกแล้ว')
  }
  if (!v) return <p className="py-10 text-center text-neutral-500">กำลังโหลด…</p>
  const num = (key, label, hint) => (
    <div key={key} className="flex items-end gap-2">
      <label className="flex-1 text-sm">{label}<input inputMode="decimal" value={v[key]} onChange={(e) => setV({ ...v, [key]: e.target.value })} className={field} />{hint && <span className="text-[11px] text-neutral-500">{hint}</span>}</label>
      <button onClick={() => save(key)} className="rounded-xl bg-white/10 px-4 py-2 text-sm font-semibold active:scale-95">บันทึก</button>
    </div>
  )
  const txt = (key, label) => (
    <div key={key} className="flex items-end gap-2">
      <label className="flex-1 text-sm">{label}<input value={v[key] ?? ''} onChange={(e) => setV({ ...v, [key]: e.target.value })} maxLength={250} className={field} /></label>
      <button onClick={() => save(key)} className="rounded-xl bg-white/10 px-4 py-2 text-sm font-semibold active:scale-95">บันทึก</button>
    </div>
  )
  return (
    <div className="max-w-lg space-y-4">
      <section className="space-y-3 rounded-2xl bg-white/5 p-4">
        <p className="text-sm font-bold">อัตราและเงื่อนไข</p>
        {num('withdraw_min', 'ถอนขั้นต่ำ (บาท)')}
        {num('withdraw_fee', 'ค่าธรรมเนียมถอนต่อครั้ง (บาท)')}
        {num('withdraw_tax_percent', 'ภาษีหัก ณ ที่จ่าย (% ของยอดถอน)', 'ต้องให้ผู้ทำบัญชียืนยันอัตราก่อนใช้จริง (ตั้งเป็น 0 ถ้าไม่หัก)')}
      </section>
      <section className="space-y-3 rounded-2xl bg-white/5 p-4">
        <p className="text-sm font-bold">ผู้จ่ายเงิน (ปรากฏในใบหัก ณ ที่จ่าย)</p>
        {txt('payer_name', 'ชื่อบริษัท/บุคคลผู้จ่าย')}
        {txt('payer_tax_id', 'เลขประจำตัวผู้เสียภาษี')}
        {txt('payer_address', 'ที่อยู่')}
        <p className="text-[11px] text-amber-200">ต้องตั้งชื่อผู้จ่ายก่อน จึงจะบันทึกการโอนและออกใบหัก ณ ที่จ่ายได้</p>
      </section>
    </div>
  )
}
