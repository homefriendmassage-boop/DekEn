import { useEffect, useState } from 'react'
import { supabase } from '../supabaseClient'

const baht = (n) => `${Number(n ?? 0).toLocaleString('en-US')} บาท`
const field = 'mt-1 w-full rounded-xl bg-white/10 px-3 py-2 text-sm outline-none ring-1 ring-white/10 focus:ring-line'

// Offers that bring new providers in: the referral bonus and the "new profile" places at the top of the lists.
export default function Growth({ toast }) {
  const [v, setV] = useState(null)
  useEffect(() => { supabase.rpc('admin_growth_settings').then(({ data }) => setV(data ?? null)) }, [])
  async function save(key) {
    const { error } = await supabase.rpc('admin_set_growth_setting', { p_key: key, p_value: String(v[key] ?? '') })
    toast(error ? 'บันทึกไม่สำเร็จ (ใส่เป็นจำนวนเต็ม)' : 'บันทึกแล้ว')
  }
  if (!v) return <p className="py-10 text-center text-neutral-500">กำลังโหลด…</p>
  const num = (key, label, hint) => (
    <div key={key} className="flex items-end gap-2">
      <label className="flex-1 text-sm">{label}<input inputMode="numeric" value={v[key]} onChange={(e) => setV({ ...v, [key]: e.target.value.replace(/\D/g, '') })} className={field} />{hint && <span className="text-[11px] text-neutral-500">{hint}</span>}</label>
      <button onClick={() => save(key)} className="rounded-xl bg-white/10 px-4 py-2 text-sm font-semibold active:scale-95">บันทึก</button>
    </div>
  )
  return (
    <div className="max-w-lg space-y-4">
      <section className="space-y-3 rounded-2xl bg-white/5 p-4">
        <p className="text-sm font-bold">💃 โบนัสชวนเพื่อนมาสมัครงาน (จ่ายครั้งเดียว)</p>
        <p className="text-[11px] text-neutral-400">จ่ายเข้ากระเป๋าโบนัสของคนชวน เมื่อเพื่อนได้รับอนุมัติและ <b>รับงานแรกสำเร็จ</b> (ไม่จ่ายถ้าลูกค้างานแรกคือคนชวนเอง) ใส่ 0 = ปิด</p>
        {num('recruit_bonus', 'ผู้ชวนที่เป็นน้อง / เซลล์ / สังกัด (บาท)', 'ได้ส่วนแบ่ง 40% ต่อเนื่อง 90 วันด้วย')}
        {num('recruit_bonus_customer', 'ผู้ชวนที่เป็นลูกค้าทั่วไป (บาท)', 'ไม่ได้ 40% ต่อเนื่อง')}
        <p className="text-xs text-neutral-300">จ่ายไปแล้ว {v.bonuses_count} ราย รวม {baht(v.bonuses_paid)}</p>
      </section>
      <section className="space-y-3 rounded-2xl bg-white/5 p-4">
        <p className="text-sm font-bold">🆕 น้องใหม่ขึ้นลำดับต้น (ฟรี)</p>
        <p className="text-[11px] text-neutral-400">น้องที่เพิ่งได้รับอนุมัติ (รวมน้องเข้าสังกัด) ขึ้นต่อจากลำดับที่ซื้อไว้ พร้อมป้าย "ใหม่" สลับรายวัน ใส่ 0 วัน = ปิด</p>
        {num('new_profile_days', 'จำนวนวัน')}
        {num('new_profile_cap', 'จำนวนสูงสุดต่อหมวด (คน)')}
      </section>
    </div>
  )
}
