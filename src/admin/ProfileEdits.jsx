import { useCallback, useEffect, useState } from 'react'
import { supabase } from '../supabaseClient'
import { baht, fmtDateTime } from './format'

const LABELS = {
  display_name: 'ชื่อที่แสดง', categories: 'หมวด', gender: 'เพศ', age: 'อายุ', height_cm: 'ส่วนสูง (ซม.)', weight_kg: 'น้ำหนัก (กก.)',
  measurements: 'สัดส่วน', tags: 'บุคลิก', about: 'แนะนำตัว', price: 'ราคาเริ่มต้น (ตัวเลข)', price_options: 'ราคาทั้งหมด', start_rate: 'ราคาเริ่มต้น', district: 'อำเภอ/เขต',
  nearby: 'พื้นที่ใกล้เคียง', province: 'จังหวัด', loc_lat: 'พิกัดใหม่ (ยืนยันจาก GPS)', loc_lng: '',
}
const GENDER = { female: 'หญิง', male: 'ชาย', lgbt: 'LGBT' }
const show = (k, v) => {
  if (v == null || v === '') return '—'
  if (k === 'gender') return GENDER[v] ?? v
  if (k === 'price') return baht(v)
  if (k === 'tags' || k === 'categories') return (v ?? []).join(', ') || '—'
  if (k === 'price_options') return (v ?? []).map((o) => `${o.label === '1h' ? '1 ชม.' : o.label === '@4h' ? '4 ชม.' : o.label === '@6h' ? '6 ชม.' : o.label} ${baht(o.price)}`).join(' · ') || '—'
  return String(v)
}

// Profile change requests and removal requests of approved providers.
export default function ProfileEdits({ onChanged, toast }) {
  const [status, setStatus] = useState('pending')
  const [rows, setRows] = useState(null)
  const [dels, setDels] = useState([])
  const [rejecting, setRejecting] = useState(null)
  const [reason, setReason] = useState('')
  const [origs, setOrigs] = useState({})

  const load = useCallback(async () => {
    const [a, b] = await Promise.all([supabase.rpc('admin_list_profile_edits', { p_status: status }), supabase.rpc('admin_list_deletions')])
    setRows(a.data ?? [])
    setDels(b.data ?? [])
  }, [status])
  useEffect(() => { load() }, [load])

  async function review(r, approve) {
    const { error } = await supabase.rpc('admin_review_profile_edit', { p_id: r.id, p_approve: approve, p_reason: approve ? null : reason })
    if (error) return toast('ทำรายการไม่สำเร็จ: ' + error.message.slice(0, 80))
    toast(approve ? 'อนุมัติการแก้ไขแล้ว' : 'ปฏิเสธแล้ว (คืนค่าบริการถ้ามี)')
    setRejecting(null); setReason(''); load(); onChanged?.()
  }
  async function reviewDeletion(d, approve) {
    if (approve && !window.confirm(`ลบโปรไฟล์ของ "${d.display_name}" ออกจากระบบทันที?`)) return
    const { error } = await supabase.rpc('admin_review_deletion', { p_user: d.user_id, p_approve: approve })
    if (error) return toast('ทำรายการไม่สำเร็จ')
    toast(approve ? 'ลบโปรไฟล์แล้ว' : 'ไม่ลบ โปรไฟล์กลับมาแสดง')
    load(); onChanged?.()
  }
  async function original(p) {
    const { data } = await supabase.storage.from('worker-originals').createSignedUrl(p.original_path, 300)
    if (data?.signedUrl) setOrigs((o) => ({ ...o, [p.id]: data.signedUrl }))
  }

  return (
    <div className="space-y-6">
      {dels.length > 0 && (
        <section className="space-y-2">
          <h2 className="text-base font-bold">🗑 คำขอลบโปรไฟล์ ({dels.length})</h2>
          <p className="text-xs text-neutral-500">ซ่อนจากหน้าลูกค้าแล้ว ถ้าไม่จัดการภายใน 24 ชม. ระบบลบให้อัตโนมัติ</p>
          <ul className="grid gap-2 md:grid-cols-2">
            {dels.map((d) => (
              <li key={d.user_id} className="space-y-2 rounded-2xl bg-white/5 p-3 ring-1 ring-red-400/30">
                <p className="font-semibold">{d.display_name} <span className="text-xs font-normal text-neutral-400">({d.user_name})</span></p>
                <p className="text-xs text-neutral-400">ขอเมื่อ {fmtDateTime(d.requested_at)} · ลบอัตโนมัติ {fmtDateTime(d.delete_at)}</p>
                <div className="grid grid-cols-2 gap-2">
                  <button onClick={() => reviewDeletion(d, true)} className="rounded-xl bg-red-500/80 py-2 text-sm font-bold active:scale-95">ลบเลย</button>
                  <button onClick={() => reviewDeletion(d, false)} className="rounded-xl bg-white/10 py-2 text-sm active:scale-95">ไม่ลบ</button>
                </div>
              </li>
            ))}
          </ul>
        </section>
      )}

      <section className="space-y-3">
        <h2 className="text-base font-bold">✏️ คำขอแก้ไขโปรไฟล์</h2>
        <div className="flex gap-2">
          {[['pending', 'รอตรวจ'], ['approved', 'อนุมัติแล้ว'], ['rejected', 'ไม่ผ่าน']].map(([id, label]) => (
            <button key={id} onClick={() => setStatus(id)} className={`rounded-full px-3 py-1 text-sm ${status === id ? 'bg-white text-black' : 'bg-white/10'}`}>{label}</button>
          ))}
        </div>
        {rows === null ? <p className="py-6 text-center text-neutral-500">กำลังโหลด…</p>
          : rows.length === 0 ? <p className="rounded-2xl bg-white/5 p-6 text-center text-neutral-500">ไม่มีรายการ</p>
          : (
            <ul className="grid gap-3 md:grid-cols-2">
              {rows.map((r) => {
                const keys = Object.keys(r.changes ?? {}).filter((k) => k !== 'loc_lng')
                return (
                  <li key={r.id} className="space-y-3 rounded-2xl bg-white/5 p-4 ring-1 ring-white/10">
                    <div className="flex items-center justify-between gap-2">
                      <p className="font-bold">{r.current?.display_name ?? r.user_name} <span className="text-xs font-normal text-neutral-400">({r.user_name})</span></p>
                      {r.fee > 0 && <span className="rounded-full bg-amber-400/20 px-2 py-0.5 text-[11px] text-amber-200">ชำระ {baht(r.fee)}</span>}
                    </div>
                    <p className="text-[11px] text-neutral-500">ส่งเมื่อ {fmtDateTime(r.created_at)}{r.reject_reason ? ` · เหตุผลที่ไม่ผ่าน: ${r.reject_reason}` : ''}</p>

                    {keys.length > 0 && (
                      <dl className="grid grid-cols-[auto,1fr] gap-x-3 gap-y-1 text-sm">
                        {keys.map((k) => (
                          <div key={k} className="contents">
                            <dt className="text-neutral-400">{LABELS[k] ?? k}</dt>
                            <dd>{k === 'loc_lat' ? 'ยืนยันตำแหน่งใหม่จากโทรศัพท์' : <><span className="text-neutral-500 line-through">{show(k, r.current?.[k])}</span> → <b className="text-green-300">{show(k, r.changes[k])}</b></>}</dd>
                          </div>
                        ))}
                      </dl>
                    )}

                    {r.add_photos.length > 0 && (
                      <div>
                        <p className="mb-1 text-xs font-semibold text-green-300">รูปที่เพิ่ม ({r.add_photos.length})</p>
                        <ul className="grid grid-cols-3 gap-2">
                          {r.add_photos.map((p) => (
                            <li key={p.id} className="space-y-1">
                              <img src={origs[p.id] ?? p.public_url} alt="" className="aspect-[3/4] w-full rounded-xl object-cover" />
                              {!origs[p.id] && <button onClick={() => original(p)} className="w-full rounded-lg bg-white/10 py-1 text-[11px]">🔍 ต้นฉบับ</button>}
                            </li>
                          ))}
                        </ul>
                      </div>
                    )}
                    {r.remove_photos.length > 0 && (
                      <div>
                        <p className="mb-1 text-xs font-semibold text-red-300">รูปที่ขอลบ ({r.remove_photos.length})</p>
                        <ul className="grid grid-cols-3 gap-2">{r.remove_photos.map((p) => <li key={p.id}><img src={p.public_url} alt="" className="aspect-[3/4] w-full rounded-xl object-cover opacity-60" /></li>)}</ul>
                      </div>
                    )}

                    {r.status === 'pending' && (rejecting === r.id ? (
                      <div className="space-y-2">
                        <input value={reason} onChange={(e) => setReason(e.target.value)} maxLength={300} placeholder="เหตุผล (ผู้ขอจะเห็นในแชต)" className="w-full rounded-xl bg-white/10 px-3 py-2 text-sm" />
                        <div className="grid grid-cols-2 gap-2">
                          <button onClick={() => review(r, false)} className="rounded-xl bg-red-500 py-2 text-sm font-bold">ยืนยันปฏิเสธ</button>
                          <button onClick={() => setRejecting(null)} className="rounded-xl bg-white/10 py-2 text-sm">ยกเลิก</button>
                        </div>
                      </div>
                    ) : (
                      <div className="grid grid-cols-2 gap-2">
                        <button onClick={() => setRejecting(r.id)} className="rounded-xl bg-white/10 py-2.5 text-sm font-semibold active:scale-95">ปฏิเสธ</button>
                        <button onClick={() => window.confirm('อนุมัติการแก้ไขนี้?') && review(r, true)} className="rounded-xl bg-line py-2.5 text-sm font-bold text-black active:scale-95">อนุมัติ</button>
                      </div>
                    ))}
                  </li>
                )
              })}
            </ul>
          )}
      </section>
    </div>
  )
}
