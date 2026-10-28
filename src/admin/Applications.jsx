import { useCallback, useEffect, useState } from 'react'
import { supabase } from '../supabaseClient'
import { CATEGORIES } from '../config'
import { baht, fmtDateTime } from './format'

const CAT = { bartender: 'ชงเหล้า', ent: 'ENT', masseuse: 'หมอนวด', spa: 'สปา' }
const FILTERS = [['pending', 'รอตรวจ'], ['approved', 'อนุมัติแล้ว'], ['rejected', 'ไม่ผ่าน']]

export default function Applications({ onChanged, toast }) {
  const [status, setStatus] = useState('pending')
  const [rows, setRows] = useState(null)

  const load = useCallback(async () => {
    setRows(null)
    const { data, error } = await supabase.rpc('admin_list_applications', { p_status: status })
    if (error) { toast('โหลดไม่สำเร็จ'); return setRows([]) }
    setRows(data ?? [])
  }, [status, toast])

  useEffect(() => { load() }, [load])

  async function review(id, approve, reason) {
    const { error } = await supabase.rpc('admin_review_application', { p_app: id, p_approve: approve, p_reason: reason ?? null })
    if (error) return toast('ทำรายการไม่สำเร็จ: ' + (error.message.includes('NOT_FOUND') ? 'ใบสมัครนี้ถูกจัดการไปแล้ว' : error.message.includes('AGENCY_NOT_CONFIRMED') ? 'ต้องรอให้โมเดลลิ่งกดรับเข้าสังกัดก่อน' : error.message))
    toast(approve ? 'อนุมัติแล้ว' : 'ปฏิเสธแล้ว')
    load()
    onChanged()
  }

  return (
    <div className="space-y-4">
      <div className="flex gap-2">
        {FILTERS.map(([id, label]) => (
          <button key={id} onClick={() => setStatus(id)}
            className={`rounded-full px-3 py-1 text-sm ${status === id ? 'bg-white text-black' : 'bg-white/10'}`}>{label}</button>
        ))}
      </div>

      {rows === null ? <p className="py-10 text-center text-neutral-500">กำลังโหลด…</p>
        : rows.length === 0 ? <p className="rounded-2xl bg-white/5 p-6 text-center text-neutral-500">ไม่มีรายการ</p>
        : <ul className="grid gap-3 md:grid-cols-2">{rows.map((a) => <Card key={a.id} a={a} onReview={review} />)}</ul>}
    </div>
  )
}

function Card({ a, onReview }) {
  const [rejecting, setRejecting] = useState(false)
  const [reason, setReason] = useState('')
  const [fullUrl, setFullUrl] = useState(null)

  // Original (unmosaicked) photo, for verifying the person. Admin-only signed URL, 5 minutes.
  async function showOriginal() {
    const { data } = await supabase.storage.from('worker-originals').createSignedUrl(a.original_path, 300)
    setFullUrl(data?.signedUrl ?? null)
  }

  return (
    <li className="space-y-3 rounded-2xl bg-white/5 p-4 ring-1 ring-white/10">
      <div className="flex gap-3">
        {a.profile_image
          ? <img src={a.profile_image} alt="" className="h-24 w-20 shrink-0 rounded-xl object-cover" />
          : <div className="flex h-24 w-20 shrink-0 items-center justify-center rounded-xl bg-white/10 text-xs text-neutral-500">ไม่มีรูป</div>}
        <div className="min-w-0 text-sm">
          <p className="truncate text-base font-bold">{a.display_name}</p>
          <p className="truncate text-xs text-neutral-400">บัญชี LINE: {a.user_name ?? '—'}</p>
          <div className="mt-1 flex flex-wrap gap-1">
            {a.categories.filter((c) => CATEGORIES.includes(c)).map((c) => <span key={c} className="rounded-full bg-white/10 px-2 py-0.5 text-[11px]">{CAT[c]}</span>)}
          </div>
          <p className="mt-1">ราคา {baht(a.price)}</p>
        </div>
      </div>

      <dl className="grid grid-cols-[auto,1fr] gap-x-3 gap-y-1 text-sm">
        <dt className="text-neutral-400">พื้นที่</dt><dd>{[a.province, a.district].filter(Boolean).join(' · ') || '—'}{a.nearby ? ` (ใกล้เคียง: ${a.nearby})` : ''}</dd>
        <dt className="text-neutral-400">เบอร์โทร</dt><dd>{a.phone ? <a className="text-line underline" href={`tel:${a.phone}`}>{a.phone}</a> : '—'}</dd>
        <dt className="text-neutral-400">LINE ID</dt><dd>{a.line_id ?? '—'}</dd>
        {a.note && <><dt className="text-neutral-400">หมายเหตุ</dt><dd className="whitespace-pre-wrap break-words">{a.note}</dd></>}
        {a.gender && <><dt className="text-neutral-400">ข้อมูล</dt><dd>{{ female: 'หญิง', male: 'ชาย', lgbt: 'LGBT' }[a.gender]} · อายุ {a.age ?? '—'} · สูง {a.height_cm ?? '—'} ซม. · หนัก {a.weight_kg ?? '—'} กก. · สัดส่วน {a.measurements ?? '—'}</dd></>}
        {a.tags?.length > 0 && <><dt className="text-neutral-400">บุคลิก</dt><dd>{a.tags.join(', ')}</dd></>}
        {a.about && <><dt className="text-neutral-400">แนะนำตัว</dt><dd className="whitespace-pre-wrap break-words">{a.about}</dd></>}
        {a.price_options?.length > 0 && <><dt className="text-neutral-400">ราคาอื่น</dt><dd>{a.price_options.map((o) => `${o.label === '@4h' ? '4 ชม.' : o.label === '@6h' ? '6 ชม.' : o.label} ${baht(o.price)}`).join(' · ')}</dd></>}
        <dt className="text-neutral-400">พิกัด</dt><dd className={a.loc_verified ? 'text-green-300' : 'text-amber-300'}>{a.loc_verified ? 'ยืนยันพิกัดจากโทรศัพท์แล้ว' : 'ไม่ได้ยืนยันพิกัด (เลือกจังหวัดเอง)'}</dd>
        {a.agency_name && <><dt className="text-neutral-400">สังกัด</dt><dd>{a.agency_name} · <span className={a.agency_status === 'accepted' ? 'text-green-300' : 'text-amber-300'}>{a.agency_status === 'accepted' ? 'โมเดลลิ่งยืนยันแล้ว' : a.agency_status === 'rejected' ? 'โมเดลลิ่งปฏิเสธ' : 'รอโมเดลลิ่งยืนยัน'}</span></dd></>}
        <dt className="text-neutral-400">ส่งเมื่อ</dt><dd>{fmtDateTime(a.created_at)}</dd>
        {a.reject_reason && <><dt className="text-neutral-400">เหตุผลที่ไม่ผ่าน</dt><dd className="text-red-300">{a.reject_reason}</dd></>}
      </dl>

      {a.original_path && (
        <button onClick={showOriginal} className="w-full rounded-xl bg-white/10 py-2 text-sm font-semibold active:scale-95">🔍 ดูรูปจริง (ไม่โมเสก)</button>
      )}
      {fullUrl && <img src={fullUrl} alt="" className="w-full rounded-xl" />}

      {a.status === 'pending' && (
        rejecting ? (
          <div className="space-y-2">
            <textarea rows={2} maxLength={300} value={reason} onChange={(e) => setReason(e.target.value)} placeholder="เหตุผล (ผู้สมัครจะเห็น)"
              className="w-full rounded-xl bg-white/10 px-3 py-2 text-sm outline-none ring-1 ring-white/10 focus:ring-red-400" />
            <div className="grid grid-cols-2 gap-2">
              <button onClick={() => setRejecting(false)} className="rounded-xl bg-white/10 py-2 text-sm font-semibold">ยกเลิก</button>
              <button onClick={() => onReview(a.id, false, reason)} className="rounded-xl bg-red-500 py-2 text-sm font-bold">ยืนยันปฏิเสธ</button>
            </div>
          </div>
        ) : (
          <div className="grid grid-cols-2 gap-2">
            <button onClick={() => setRejecting(true)} className="rounded-xl bg-white/10 py-2.5 text-sm font-semibold active:scale-95">ปฏิเสธ</button>
            <button
              onClick={() => window.confirm(`อนุมัติ "${a.display_name}" ให้เป็นผู้ให้บริการ?`) && onReview(a.id, true)}
              className="rounded-xl bg-line py-2.5 text-sm font-bold text-black active:scale-95">อนุมัติ</button>
          </div>
        )
      )}
    </li>
  )
}
