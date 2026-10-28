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
    if (error) return toast('ทำรายการไม่สำเร็จ: ' + (error.message.includes('NOT_FOUND') ? 'ใบสมัครนี้ถูกจัดการไปแล้ว' : error.message.includes('AGE_NOT_VERIFIED') ? 'ต้องบันทึกการยืนยันอายุก่อนอนุมัติ' : error.message.includes('NO_PHOTO') ? 'ผู้สมัครยังไม่ได้แนบรูป' : error.message.includes('AGENCY_NOT_CONFIRMED') ? 'ต้องรอให้โมเดลลิ่งกดรับเข้าสังกัดก่อน' : error.message))
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
        : <ul className="grid gap-3 md:grid-cols-2">{rows.map((a) => <Card key={a.id} a={a} onReview={review} onChanged={load} toast={toast} />)}</ul>}
    </div>
  )
}

function Card({ a, onReview, onChanged, toast }) {
  const [rejecting, setRejecting] = useState(false)
  const [reason, setReason] = useState('')
  const [fullUrl, setFullUrl] = useState(null)
  const [origs, setOrigs] = useState({})   // photo id -> signed URL of the private original

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
          <p className="mt-1">ราคาเริ่มต้น {baht(a.price)}</p>
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
        <dt className="text-neutral-400">ราคาเริ่มต้นครั้งแรก</dt><dd>{a.start_rate === '1h' ? '1 ชม.' : a.start_rate === '@4h' ? '4 ชม.' : a.start_rate === '@6h' ? '6 ชม.' : a.start_rate}</dd>
        {a.price_options?.length > 0 && <><dt className="text-neutral-400">ราคาทั้งหมด</dt><dd>{a.price_options.map((o) => `${o.label === '1h' ? '1 ชม.' : o.label === '@4h' ? '4 ชม.' : o.label === '@6h' ? '6 ชม.' : o.label} ${baht(o.price)}`).join(' · ')}</dd></>}
        <dt className="text-neutral-400">พิกัด</dt><dd className={a.loc_verified ? 'text-green-300' : 'text-amber-300'}>{a.loc_verified ? 'ยืนยันพิกัดจากโทรศัพท์แล้ว' : 'ไม่ได้ยืนยันพิกัด (เลือกจังหวัดเอง)'}</dd>
        {a.agency_name && <><dt className="text-neutral-400">สังกัด</dt><dd>{a.agency_name} · <span className={a.agency_status === 'accepted' ? 'text-green-300' : 'text-amber-300'}>{a.agency_status === 'accepted' ? 'โมเดลลิ่งยืนยันแล้ว' : a.agency_status === 'rejected' ? 'โมเดลลิ่งปฏิเสธ' : 'รอโมเดลลิ่งยืนยัน'}</span></dd></>}
        <dt className="text-neutral-400">ส่งเมื่อ</dt><dd>{fmtDateTime(a.created_at)}</dd>
        {a.reject_reason && <><dt className="text-neutral-400">เหตุผลที่ไม่ผ่าน</dt><dd className="text-red-300">{a.reject_reason}</dd></>}
      </dl>

      {/* Promo pictures attached to the application (mosaic = what the public sees; the original is for checking the person) */}
      {a.photos?.length > 0 ? (
        <div className="space-y-2">
          <p className="text-xs font-semibold text-neutral-400">รูปโปรโมท {a.photos.length} ภาพ</p>
          <ul className="grid grid-cols-3 gap-2">
            {a.photos.map((p) => (
              <li key={p.id} className="space-y-1">
                <img src={origs[p.id] ?? p.public_url} alt="" className="aspect-[3/4] w-full rounded-xl object-cover" />
                {!origs[p.id] && (
                  <button onClick={async () => { const { data } = await supabase.storage.from('worker-originals').createSignedUrl(p.original_path, 300); if (data?.signedUrl) setOrigs((o) => ({ ...o, [p.id]: data.signedUrl })) }}
                    className="w-full rounded-lg bg-white/10 py-1 text-[11px] active:scale-95">🔍 ต้นฉบับ</button>
                )}
              </li>
            ))}
          </ul>
        </div>
      ) : a.original_path ? (
        <button onClick={showOriginal} className="w-full rounded-xl bg-white/10 py-2 text-sm font-semibold active:scale-95">🔍 ดูรูปจริง (ไม่โมเสก)</button>
      ) : <p className="rounded-xl bg-red-500/10 p-2 text-xs text-red-300">ผู้สมัครยังไม่ได้แนบรูป</p>}
      {fullUrl && <img src={fullUrl} alt="" className="w-full rounded-xl" />}

      {a.status === 'pending' && <AgeCheck a={a} onChanged={onChanged} toast={toast} />}

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
              disabled={a.age_check_status !== 'verified'}
              onClick={() => window.confirm(`อนุมัติ "${a.display_name}" ให้เป็นผู้ให้บริการ?`) && onReview(a.id, true)}
              className="rounded-xl bg-line py-2.5 text-sm font-bold text-black active:scale-95 disabled:bg-neutral-700 disabled:text-neutral-400">อนุมัติ</button>
          </div>
        )
      )}
    </li>
  )
}

const METHODS = [['photo', 'ดูจากรูป/ข้อมูลแล้วมั่นใจ'], ['video_call', 'วิดีโอคอลแล้ว'], ['in_person', 'พบตัวจริงแล้ว'], ['id_card', 'ตรวจบัตรประชาชนแล้ว']]

// Age check: the admin must record HOW the age was confirmed before approving. If unsure, ask the applicant for an ID + selfie.
function AgeCheck({ a, onChanged, toast }) {
  const [method, setMethod] = useState(a.age_check_status === 'submitted' ? 'id_card' : 'photo')
  const [note, setNote] = useState(a.age_check_note ?? '')
  const [del, setDel] = useState(true)
  const [docs, setDocs] = useState({})
  const [busy, setBusy] = useState(false)

  async function view(kind, path) {
    const { data } = await supabase.storage.from('id-docs').createSignedUrl(path, 300)
    if (data?.signedUrl) setDocs((d) => ({ ...d, [kind]: data.signedUrl }))
  }
  async function request() {
    setBusy(true)
    const { error } = await supabase.rpc('admin_request_age_proof', { p_app: a.id, p_note: note })
    setBusy(false)
    if (error) return toast('ส่งคำขอไม่สำเร็จ')
    toast('ส่งคำขอเอกสารให้ผู้สมัครแล้ว (แจ้งในแชตของเธอ)')
    onChanged()
  }
  async function verify() {
    if (!window.confirm(`บันทึกว่าตรวจอายุของ "${a.display_name}" แล้ว (${METHODS.find((m) => m[0] === method)?.[1]})?`)) return
    setBusy(true)
    if (del && a.age_id_path) await supabase.storage.from('id-docs').remove([a.age_id_path, a.age_selfie_path].filter(Boolean))
    const { error } = await supabase.rpc('admin_verify_age', { p_app: a.id, p_method: method, p_note: note })
    setBusy(false)
    if (error) return toast('บันทึกไม่สำเร็จ')
    toast('บันทึกการยืนยันอายุแล้ว')
    onChanged()
  }

  if (a.age_check_status === 'verified') {
    return <p className="rounded-xl bg-green-500/10 p-2 text-sm text-green-300">✓ ยืนยันอายุแล้ว · {METHODS.find((m) => m[0] === a.age_verified_method)?.[1]}{a.age_check_note ? ` · ${a.age_check_note}` : ''}</p>
  }
  return (
    <div className="space-y-2 rounded-xl bg-amber-400/10 p-3 text-sm ring-1 ring-amber-400/30">
      <p className="font-semibold text-amber-200">🪪 ตรวจอายุ (อนุมัติได้เมื่อบันทึกว่าตรวจแล้ว) · ผู้สมัครแจ้งอายุ {a.age ?? '—'} ปี</p>
      {a.age_check_status === 'requested' && <p className="text-xs text-neutral-300">⏳ ขอเอกสารไปแล้ว รอผู้สมัครส่ง</p>}
      {a.age_check_status === 'submitted' && (
        <div className="space-y-2">
          <p className="text-xs text-neutral-300">ผู้สมัครส่งเอกสารแล้ว เทียบวันเกิดกับอายุที่กรอก และหน้ากับเซลฟี่</p>
          <div className="grid grid-cols-2 gap-2">
            <button onClick={() => view('id', a.age_id_path)} className="rounded-lg bg-white/10 py-1.5 text-xs">ดูบัตร</button>
            <button onClick={() => view('selfie', a.age_selfie_path)} className="rounded-lg bg-white/10 py-1.5 text-xs">ดูเซลฟี่</button>
          </div>
          {docs.id && <img src={docs.id} alt="" className="w-full rounded-lg" />}
          {docs.selfie && <img src={docs.selfie} alt="" className="w-full rounded-lg" />}
          <label className="flex items-center gap-2 text-xs"><input type="checkbox" checked={del} onChange={(e) => setDel(e.target.checked)} /> ลบรูปเอกสารทันทีหลังยืนยัน (แนะนำ)</label>
        </div>
      )}
      <input value={note} onChange={(e) => setNote(e.target.value)} maxLength={300} placeholder="บันทึกเพิ่มเติม (เช่น วิดีโอคอลวันที่ ...)" className="w-full rounded-lg bg-white/10 px-3 py-2 text-xs" />
      <select value={method} onChange={(e) => setMethod(e.target.value)} className="w-full rounded-lg bg-white/10 px-3 py-2 text-sm">
        {METHODS.map(([k, v]) => <option key={k} value={k} className="text-black">{v}</option>)}
      </select>
      <div className="grid grid-cols-2 gap-2">
        <button disabled={busy} onClick={verify} className="rounded-xl bg-line py-2 text-sm font-bold text-black active:scale-95 disabled:opacity-50">✓ ยืนยันอายุแล้ว</button>
        <button disabled={busy || a.age_check_status === 'requested'} onClick={request} className="rounded-xl bg-white/10 py-2 text-sm font-semibold active:scale-95 disabled:opacity-40">ขอเอกสารจากผู้สมัคร</button>
      </div>
    </div>
  )
}
