import { useEffect, useState } from 'react'
import { supabase } from '../supabaseClient'
import { useI18n } from '../i18n'
import ShareModal from './ShareModal'

const VIA = { vendor: 'เซลล์ที่มี OA', provider: 'ผู้ให้บริการ', approved: 'เซลล์ที่อนุมัติแล้ว' }

// "My commission": am I a seller, what did the people I invited earn me (bookings 40 %, packages 20 %), and how to share my link.
export default function SellerPanel({ onClose }) {
  const { money, fmtDate } = useI18n()
  const [st, setSt] = useState(null)
  const [rep, setRep] = useState(null)
  const [note, setNote] = useState('')
  const [busy, setBusy] = useState(false)
  const [share, setShare] = useState(false)
  const [msg, setMsg] = useState(null)

  const load = async () => {
    const [a, b] = await Promise.all([supabase.rpc('my_seller_status'), supabase.rpc('my_commission_report')])
    setSt(a.data ?? null); setRep(b.data ?? null)
  }
  useEffect(() => { load() }, [])

  async function apply() {
    setBusy(true)
    const { error } = await supabase.rpc('seller_apply', { p_note: note })
    setBusy(false)
    setMsg(error ? 'ส่งคำขอไม่สำเร็จ' : 'ส่งคำขอแล้ว รอแอดมินอนุมัติ')
    load()
  }

  const req = st?.request
  return (
    <div className="fixed inset-0 z-[55] flex items-end justify-center bg-black/70 sm:items-center sm:p-4" onClick={onClose} role="dialog" aria-modal="true">
      <div onClick={(e) => e.stopPropagation()}
        className="max-h-[92vh] w-full max-w-md space-y-3 overflow-y-auto rounded-t-3xl bg-neutral-900 p-5 pb-[calc(1.25rem+env(safe-area-inset-bottom))] shadow-2xl sm:rounded-3xl">
        <div className="flex items-center justify-between">
          <h2 className="text-lg font-bold">🤝 ส่วนแบ่งของฉัน</h2>
          <button onClick={onClose} className="rounded-full bg-white/10 px-3 py-1 text-sm">✕</button>
        </div>

        <button onClick={() => setShare(true)} className="w-full rounded-xl bg-line py-3 font-bold text-black active:scale-95">🔗 แชร์ลิงก์ชวนเพื่อน</button>

        <ul className="space-y-1 rounded-2xl bg-white/5 p-3 text-xs text-neutral-300">
          <li>• <b>ค่าแพ็กเกจ 20%</b> ของคนที่คุณชวน (ครั้งแรก) เข้าโบนัสทุกครั้งที่เขาจ่ายหรือต่ออายุ</li>
          <li>• <b>ค่าจอง 40%</b> เฉพาะ "เซลล์" ได้ เมื่อลูกค้าที่คุณชวนจองในแอปกลาง หรือจองผ่านลิงก์ของคุณ</li>
        </ul>

        {!st ? <p className="text-center text-sm text-neutral-500">กำลังโหลด…</p> : st.is_seller ? (
          <p className="rounded-xl bg-green-500/10 p-3 text-sm text-green-200">✓ คุณเป็นเซลล์ ({VIA[st.via] ?? '—'}) ตั้งแต่ {fmtDate(st.since)}</p>
        ) : req?.status === 'pending' ? (
          <p className="rounded-xl bg-amber-400/10 p-3 text-sm text-amber-200">⏳ ส่งคำขอเป็นเซลล์แล้ว รอแอดมินอนุมัติ</p>
        ) : (
          <div className="space-y-2 rounded-2xl bg-white/5 p-3">
            {req?.status === 'rejected' && <p className="text-xs text-red-300">คำขอก่อนหน้าไม่ได้รับการอนุมัติ{req.admin_note ? `: ${req.admin_note}` : ''}</p>}
            <p className="text-sm font-semibold">อยากรับ 40% ของค่าจอง? ขอเป็นเซลล์</p>
            <input value={note} onChange={(e) => setNote(e.target.value)} maxLength={300} placeholder="บอกแอดมินสั้นๆ ว่าคุณหาลูกค้าอย่างไร" className="w-full rounded-xl bg-white/10 px-3 py-2 text-sm" />
            <button disabled={busy} onClick={apply} className="w-full rounded-xl bg-white/10 py-2 text-sm font-bold active:scale-95 disabled:opacity-50">ส่งคำขอเป็นเซลล์</button>
          </div>
        )}
        {msg && <p className="text-center text-xs text-amber-200">{msg}</p>}

        {rep && (
          <>
            <div className="grid grid-cols-2 gap-2 text-center">
              <div className="rounded-xl bg-white/5 p-3"><p className="text-[11px] text-neutral-400">ค่าจอง (40%)</p><p className="text-lg font-bold">{money(rep.booking_total)}</p></div>
              <div className="rounded-xl bg-white/5 p-3"><p className="text-[11px] text-neutral-400">ค่าแพ็กเกจ (20%)</p><p className="text-lg font-bold">{money(rep.package_total)}</p></div>
            </div>
            <List title="รายการค่าจองล่าสุด" rows={rep.bookings} fmtDate={fmtDate} money={money} sub={(r) => (r.via === 'link' ? 'จองผ่านลิงก์ของคุณ' : 'ลูกค้าที่คุณชวน')} />
            <List title="รายการค่าแพ็กเกจล่าสุด" rows={rep.packages} fmtDate={fmtDate} money={money} />
          </>
        )}
      </div>
      {share && <ShareModal onClose={() => setShare(false)} />}
    </div>
  )
}

function List({ title, rows, fmtDate, money, sub }) {
  if (!rows?.length) return null
  return (
    <div className="space-y-1">
      <p className="text-sm font-semibold">{title}</p>
      <ul className="space-y-1">
        {rows.map((r, i) => (
          <li key={i} className="flex items-center justify-between rounded-xl bg-white/5 px-3 py-2 text-sm">
            <span className="min-w-0"><b className="block truncate">{r.customer ?? '—'}</b><span className="text-[11px] text-neutral-400">{fmtDate(r.at)}{sub ? ` · ${sub(r)}` : ''}</span></span>
            <span className="shrink-0 font-semibold text-green-300">+{money(r.amount)}</span>
          </li>
        ))}
      </ul>
    </div>
  )
}
