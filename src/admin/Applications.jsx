import { useCallback, useEffect, useState } from 'react'
import { supabase } from '../supabaseClient'
import { CATEGORIES } from '../config'
import { baht, fmtDateTime } from './format'
import { PROVINCES } from '../provinces'
import LinkSheet from '../components/LinkSheet'
import ImageViewer from '../components/ImageViewer'
import { useI18n } from '../i18n'
import { inviteBubble } from '../lib/flex'
import { applyLink } from '../lib/drafts'
import WorkerFields, { GROUP_CATEGORIES, groupOf, profileFromRow, profileToPayload, validateProfile } from '../components/WorkerFields'

const CAT = { bartender: 'ชงเหล้า', ent: 'ENT', masseuse: 'หมอนวด', spa: 'สปา' }
const FILTERS = [['pending', 'รอตรวจ'], ['approved', 'อนุมัติแล้ว'], ['rejected', 'ไม่ผ่าน']]

export default function Applications({ onChanged, toast }) {
  const [status, setStatus] = useState('pending')
  const [rows, setRows] = useState(null)
  const [sheet, setSheet] = useState(false)   // registration-only link / Flex / QR
  const [pics, setPics] = useState({})         // user id -> LINE profile picture

  const load = useCallback(async () => {
    setRows(null)
    const { data, error } = await supabase.rpc('admin_list_applications', { p_status: status })
    if (error) { toast('โหลดไม่สำเร็จ'); return setRows([]) }
    setRows(data ?? [])
    const ids = [...new Set((data ?? []).map((r) => r.user_id).filter(Boolean))]
    if (ids.length) { const { data: p } = await supabase.rpc('admin_user_pictures', { p_ids: ids }); setPics(Object.fromEntries((p ?? []).map((x) => [x.id, x.picture_url]))) }
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
      <div className="flex flex-wrap items-center gap-2">
        {FILTERS.map(([id, label]) => (
          <button key={id} onClick={() => setStatus(id)}
            className={`rounded-full px-3 py-1 text-sm ${status === id ? 'bg-white text-black' : 'bg-white/10'}`}>{label}</button>
        ))}
        <button onClick={() => setSheet(true)} className="ml-auto rounded-xl bg-line px-3 py-1.5 text-sm font-bold text-black active:scale-95">🔗 ลิงก์สมัครงาน · Flex · QR</button>
      </div>
      {sheet && (
        <LinkSheet
          title="ลิงก์ลงทะเบียนสมัครงาน / โมเดลลิ่ง"
          intro="ส่งให้น้องกดกรอกใบสมัคร เปิดลิงก์นี้แล้วจะเห็นแค่หน้าสมัคร ไปหน้าอื่นของแอปไม่ได้ (ส่งเป็นการ์ด Flex หรือให้สแกน QR ก็ได้)"
          link={applyLink()}
          flex={{
            type: 'flex', altText: 'DekEn: สมัครงาน / โมเดลลิ่ง',
            contents: inviteBubble({ tagline: 'DekEn', title: 'สมัครงาน / โมเดลลิ่ง', body: 'กดเพื่อกรอกใบสมัครเป็นผู้ให้บริการกับ DekEn ใช้เวลาไม่กี่นาที', button: 'กรอกใบสมัคร', uri: applyLink() }),
          }}
          onClose={() => setSheet(false)}
        />
      )}

      {rows === null ? <p className="py-10 text-center text-neutral-500">กำลังโหลด…</p>
        : rows.length === 0 ? <p className="rounded-2xl bg-white/5 p-6 text-center text-neutral-500">ไม่มีรายการ</p>
        : <ul className="grid gap-3 md:grid-cols-2">{rows.map((a) => <Card key={a.id} a={a} linePic={pics[a.user_id]} onReview={review} onChanged={load} toast={toast} />)}</ul>}
    </div>
  )
}

function Card({ a, linePic, onReview, onChanged, toast }) {
  const { t } = useI18n()
  const [viewer, setViewer] = useState(null)   // { urls, index }: the clear originals in a zoomable viewer
  const [rejecting, setRejecting] = useState(false)
  const [reason, setReason] = useState('')
  const [editing, setEditing] = useState(false)

  // Original (unmosaicked) photo, for verifying the person. Admin-only signed URL, 5 minutes.
  async function openViewer(index = 0) {
    const paths = a.photos?.length ? a.photos.map((p) => p.original_path) : [a.original_path]
    const { data } = await supabase.storage.from('worker-originals').createSignedUrls(paths.filter(Boolean), 600)
    const urls = (data ?? []).map((x) => x.signedUrl).filter(Boolean)
    if (urls.length) setViewer({ urls, index: Math.min(index, urls.length - 1) })
  }

  return (
    <li className="space-y-3 rounded-2xl bg-white/5 p-4 ring-1 ring-white/10">
      <div className="flex gap-3">
        {a.profile_image
          ? <img src={a.profile_image} alt="" className="h-24 w-20 shrink-0 rounded-xl object-cover" />
          : linePic
            ? <div className="relative h-24 w-20 shrink-0 overflow-hidden rounded-xl bg-white/10"><img src={linePic} alt="" className="h-full w-full object-cover" /><span className="absolute inset-x-0 bottom-0 bg-black/60 text-center text-[9px]">โปรไฟล์ LINE</span></div>
            : <div className="flex h-24 w-20 shrink-0 items-center justify-center rounded-xl bg-white/10 text-xs text-neutral-500">ไม่มีรูป</div>}
        <div className="min-w-0 text-sm">
          <p className="truncate text-base font-bold">{a.display_name}</p>
          <p className="flex items-center gap-1.5 truncate text-xs text-neutral-400">{linePic && <img src={linePic} alt="" className="h-5 w-5 shrink-0 rounded-full object-cover" />}บัญชี LINE: {a.user_name ?? '—'}</p>
          <div className="mt-1 flex flex-wrap gap-1">
            {a.categories.filter((c) => CATEGORIES.includes(c)).map((c) => <span key={c} className="rounded-full bg-white/10 px-2 py-0.5 text-[11px]">{CAT[c]}</span>)}
          </div>
          <p className="mt-1">ราคาเริ่มต้น {baht(a.price)}</p>
          <button onClick={() => setEditing(true)} className="mt-2 rounded-lg bg-pink-500/90 px-3 py-1 text-xs font-bold active:scale-95">✏️ แก้ไขข้อมูล{a.status === 'approved' ? ' (อัปเดตโปรไฟล์จริงด้วย)' : ''}</button>
        </div>
      </div>

      <dl className="grid grid-cols-[auto,1fr] gap-x-3 gap-y-1 text-sm">
        <dt className="text-neutral-400">พื้นที่</dt><dd>{[a.province, a.district].filter(Boolean).join(' · ') || '—'}{a.nearby ? ` (ใกล้เคียง: ${a.nearby})` : ''}</dd>
        <dt className="text-neutral-400">เบอร์โทร</dt><dd>{a.phone ? <a className="text-line underline" href={`tel:${a.phone}`}>{a.phone}</a> : '—'}</dd>
        <dt className="text-neutral-400">LINE ID</dt><dd>{a.line_id ?? '—'}</dd>
        {a.note && <><dt className="text-neutral-400">หมายเหตุ</dt><dd className="whitespace-pre-wrap break-words">{a.note}</dd></>}
        {a.gender && <><dt className="text-neutral-400">ข้อมูล</dt><dd>{{ female: 'หญิง', male: 'ชาย', lgbt: 'LGBT' }[a.gender]} · อายุ {a.age ?? '—'} · สูง {a.height_cm ?? '—'} ซม. · หนัก {a.weight_kg ?? '—'} กก. · สัดส่วน {a.measurements ?? '—'}</dd></>}
        {a.tags?.length > 0 && <><dt className="text-neutral-400">บุคลิก</dt><dd>{a.tags.map((k) => (t(`tag_${k}`) === `tag_${k}` ? k : t(`tag_${k}`))).join(', ')}</dd></>}
        {a.about && <><dt className="text-neutral-400">แนะนำตัว</dt><dd className="whitespace-pre-wrap break-words">{a.about}</dd></>}
        <dt className="text-neutral-400">กลุ่มงาน</dt><dd>{a.grp === 'spa' ? '💆 หมอนวด/สปา' : '🍸 ชงเหล้า/ENT'}{a.service_mode ? ` · ${{ shop: 'ที่ร้าน', outcall: 'ไปหาลูกค้า', both: 'ทั้งสองแบบ' }[a.service_mode]}` : ''}</dd>
        <dt className="text-neutral-400">ราคาเริ่มต้นครั้งแรก</dt><dd>{a.start_rate === '@60' ? '60 นาที' : a.start_rate === '@90' ? '90 นาที' : a.start_rate === '@120' ? '120 นาที' : a.start_rate === '1h' ? '1 ชม.' : a.start_rate === '@4h' ? '4 ชม.' : a.start_rate === '@6h' ? '6 ชม.' : a.start_rate}</dd>
        {a.price_options?.length > 0 && <><dt className="text-neutral-400">ราคาทั้งหมด</dt><dd>{a.price_options.map((o) => `${o.label === '@60' ? '60 นาที' : o.label === '@90' ? '90 นาที' : o.label === '@120' ? '120 นาที' : o.label === '1h' ? '1 ชม.' : o.label === '@4h' ? '4 ชม.' : o.label === '@6h' ? '6 ชม.' : o.label} ${baht(o.price)}`).join(' · ')}</dd></>}
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
                <img src={p.public_url} alt="" onClick={() => openViewer(a.photos.indexOf(p))} className="aspect-[3/4] w-full cursor-zoom-in rounded-xl object-cover" />
              </li>
            ))}
          </ul>
          <button onClick={() => openViewer(0)} className="w-full rounded-xl bg-white/10 py-2 text-sm font-semibold active:scale-95">🔍 ขยายดูรูปจริง (ไม่โมเสก) ทั้ง {a.photos.length} ภาพ</button>
        </div>
      ) : a.original_path ? (
        <button onClick={() => openViewer(0)} className="w-full rounded-xl bg-white/10 py-2 text-sm font-semibold active:scale-95">🔍 ขยายดูรูปจริง (ไม่โมเสก)</button>
      ) : <p className="rounded-xl bg-red-500/10 p-2 text-xs text-red-300">ผู้สมัครยังไม่ได้แนบรูป</p>}
      {viewer && <ImageViewer images={viewer.urls} index={viewer.index} alt={a.display_name} onClose={() => setViewer(null)} />}

      {editing && <EditModal a={a} toast={toast} onClose={() => setEditing(false)} onSaved={() => { setEditing(false); onChanged() }} />}

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

const field = 'mt-1 w-full rounded-xl bg-white/10 px-3 py-2.5 text-base outline-none ring-1 ring-white/10 focus:ring-line'

// The admin corrects an applicant's data at any time, also after approval (then the live profile is updated too).
function EditModal({ a, onClose, onSaved, toast }) {
  const grp = a.grp ?? groupOf(a.categories)
  const [form, setForm] = useState({
    display_name: a.display_name ?? '', categories: a.categories ?? [], province: a.province ?? '', district: a.district ?? '',
    nearby: a.nearby ?? '', phone: a.phone ?? '', line_id: a.line_id ?? '', note: a.note ?? '',
  })
  const [prof, setProf] = useState(() => profileFromRow(a))
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState(null)
  const set = (k) => (e) => setForm((f) => ({ ...f, [k]: e.target.value }))
  const toggle = (c) => setForm((f) => ({ ...f, categories: f.categories.includes(c) ? f.categories.filter((x) => x !== c) : [...f.categories, c] }))

  async function save() {
    setError(null)
    if (!form.display_name.trim()) return setError('กรุณาใส่ชื่อที่แสดง')
    if (form.categories.length === 0) return setError('กรุณาเลือกประเภทงาน')
    const bad = validateProfile(prof, grp, { needLocation: false })
    if (bad) return setError({ errGender: 'กรุณาเลือกเพศ', errAge: 'อายุต้อง 20 ปีขึ้นไป', errPrice: 'กรอกราคาอย่างน้อย 1 ช่อง', errServiceMode: 'เลือกรูปแบบการให้บริการ' }[bad] ?? 'ข้อมูลไม่ครบ')
    const payload = {
      display_name: form.display_name.trim(), categories: form.categories, ...profileToPayload(prof, grp),
      province: form.province || null, district: form.district.trim() || null, nearby: form.nearby.trim() || null,
      phone: form.phone.trim() || null, line_id: form.line_id.trim() || null, note: form.note.trim() || null,
    }
    delete payload.loc_lat; delete payload.loc_lng
    setBusy(true)
    const { error: e } = await supabase.rpc('admin_edit_application', { p_app: a.id, p_data: payload })
    setBusy(false)
    if (e) return setError(e.message.includes('CONTACT_IN_PROFILE') ? 'ห้ามใส่เบอร์ ไอดี หรือลิงก์ในชื่อ/แนะนำตัว/ที่อยู่' : e.message.includes('BAD_PROVINCE') ? 'จังหวัดไม่ถูกต้อง' : e.message.includes('MIXED_GROUPS') ? 'เลือกหมวดชงเหล้า/ENT ปนกับหมอนวด/สปาไม่ได้' : `บันทึกไม่สำเร็จ (${e.message.slice(0, 120)})`)
    toast(a.status === 'approved' ? 'แก้ไขแล้ว อัปเดตโปรไฟล์จริงและแจ้งน้องแล้ว' : 'แก้ไขใบสมัครแล้ว')
    onSaved()
  }

  return (
    <div className="fixed inset-0 z-50 flex items-end justify-center bg-black/70 sm:items-center sm:p-4" onClick={onClose}>
      <div onClick={(e) => e.stopPropagation()} className="max-h-[94vh] w-full max-w-lg space-y-3 overflow-y-auto rounded-t-3xl bg-neutral-900 p-5 shadow-2xl sm:rounded-3xl">
        <div className="flex items-center justify-between"><h2 className="text-lg font-bold">✏️ แก้ไข: {a.display_name}</h2><button onClick={onClose} className="rounded-full bg-white/10 px-3 py-1 text-sm">✕</button></div>
        {a.status === 'approved' && <p className="rounded-xl bg-amber-400/10 p-2 text-xs text-amber-200">ใบสมัครนี้อนุมัติแล้ว การบันทึกจะอัปเดตโปรไฟล์ที่ลูกค้าเห็นด้วย และส่งข้อความแจ้งน้อง (รูปแก้ในหน้านี้ไม่ได้)</p>}
        <label className="block text-sm">ชื่อที่แสดง<input maxLength={40} value={form.display_name} onChange={set('display_name')} className={field} /></label>
        <fieldset>
          <legend className="text-sm">ประเภทงาน</legend>
          <div className="mt-2 flex flex-wrap gap-2">
            {GROUP_CATEGORIES[grp].map((c) => (
              <button type="button" key={c} onClick={() => toggle(c)} aria-pressed={form.categories.includes(c)}
                className={`rounded-full px-4 py-1.5 text-sm font-semibold ring-1 ${form.categories.includes(c) ? 'bg-line text-black ring-line' : 'bg-white/10 ring-white/15'}`}>{form.categories.includes(c) ? '✓ ' : ''}{CAT[c]}</button>
            ))}
          </div>
        </fieldset>
        <WorkerFields v={prof} set={(p) => setProf((x) => ({ ...x, ...p }))} grp={grp} hideLocation />
        <label className="block text-sm">จังหวัด
          <select value={form.province} onChange={set('province')} className={field}>
            <option value="" className="text-black">ไม่เปลี่ยน / ไม่ระบุ</option>
            {PROVINCES.map((p) => <option key={p} value={p} className="text-black">{p}</option>)}
          </select>
          <span className="text-[11px] text-neutral-400">ถ้าเปลี่ยนจังหวัดของน้องที่ยืนยันพิกัด GPS แล้ว ระบบจะเปลี่ยนเป็น "จังหวัดที่น้องระบุเอง"</span>
        </label>
        <label className="block text-sm">อำเภอ / เขต<input maxLength={60} value={form.district} onChange={set('district')} className={field} /></label>
        <label className="block text-sm">พื้นที่ใกล้เคียง<input maxLength={120} value={form.nearby} onChange={set('nearby')} className={field} /></label>
        <div className="grid grid-cols-2 gap-2">
          <label className="block text-sm">เบอร์โทรศัพท์<input type="tel" maxLength={20} value={form.phone} onChange={set('phone')} className={field} /></label>
          <label className="block text-sm">LINE ID<input maxLength={40} value={form.line_id} onChange={set('line_id')} className={field} /></label>
        </div>
        <label className="block text-sm">หมายเหตุ<textarea rows={2} maxLength={300} value={form.note} onChange={set('note')} className={field} /></label>
        {error && <p className="rounded-xl bg-red-500/10 p-3 text-sm text-red-300">{error}</p>}
        <div className="grid grid-cols-2 gap-2">
          <button onClick={onClose} className="rounded-xl bg-white/10 py-3 font-semibold active:scale-95">ยกเลิก</button>
          <button disabled={busy} onClick={save} className="rounded-xl bg-line py-3 font-bold text-black active:scale-95 disabled:opacity-50">{busy ? 'กำลังบันทึก…' : 'บันทึกการแก้ไข'}</button>
        </div>
      </div>
    </div>
  )
}
