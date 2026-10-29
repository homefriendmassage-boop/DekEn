import { useCallback, useEffect, useState } from 'react'
import { supabase } from '../supabaseClient'

// People who asked to become a seller (earn the 40 % sales share of the bookings of the customers they invited).
// Providers and sellers with their own OA are sellers automatically; everyone else is approved here, one by one.
export default function SellerRequests({ toast }) {
  const [rows, setRows] = useState(null)
  const load = useCallback(async () => { const { data } = await supabase.rpc('admin_seller_requests', { p_status: 'pending' }); setRows(data ?? []) }, [])
  useEffect(() => { load() }, [load])

  async function decide(r, approve) {
    const note = approve ? null : window.prompt('เหตุผลที่ไม่อนุมัติ (ผู้สมัครจะเห็น)')
    if (!approve && note === null) return
    const { error } = await supabase.rpc('admin_seller_decide', { p_user: r.user_id, p_approve: approve, p_note: note })
    toast(error ? 'ไม่สำเร็จ' : approve ? `อนุมัติ ${r.name ?? 'เซลล์'} แล้ว` : 'ไม่อนุมัติแล้ว')
    load()
  }

  if (!rows || rows.length === 0) return null
  return (
    <section className="mb-4 space-y-2 rounded-2xl bg-amber-400/10 p-3 ring-1 ring-amber-400/30">
      <h2 className="text-sm font-bold text-amber-200">🤝 ขอเป็นเซลล์ ({rows.length})</h2>
      <p className="text-[11px] text-neutral-400">เซลล์ได้ส่วนแบ่ง 40% ของค่าจองของลูกค้าที่ตัวเองชวน นับตั้งแต่วันที่อนุมัติ (ผู้ให้บริการและเซลล์ที่มี OA เป็นเซลล์อยู่แล้ว)</p>
      <ul className="space-y-2">
        {rows.map((r) => (
          <li key={r.user_id} className="space-y-2 rounded-xl bg-white/5 p-3 text-sm">
            <p><b>{r.name ?? '—'}</b> <span className="text-xs text-neutral-400">· ลูกค้าที่ชวน {r.customers} คน</span></p>
            {r.note && <p className="text-xs text-neutral-300">"{r.note}"</p>}
            <div className="grid grid-cols-2 gap-2">
              <button onClick={() => decide(r, true)} className="rounded-xl bg-line py-2 text-sm font-bold text-black active:scale-95">อนุมัติ</button>
              <button onClick={() => decide(r, false)} className="rounded-xl bg-red-500/20 py-2 text-sm font-bold text-red-300 active:scale-95">ไม่อนุมัติ</button>
            </div>
          </li>
        ))}
      </ul>
    </section>
  )
}
