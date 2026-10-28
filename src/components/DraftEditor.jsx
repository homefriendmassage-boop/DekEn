import { useState } from 'react'
import { supabase } from '../supabaseClient'
import { useI18n } from '../i18n'
import PhotoUploader from './PhotoUploader'
import WorkerFields, { GROUP_CATEGORIES, emptyProfile, groupOf, profileFromRow, profileToPayload, validateProfile } from './WorkerFields'
import { removeDraftPhoto, uploadDraftPhoto } from '../lib/drafts'
import { PROVINCES } from '../provinces'

const input = 'mt-1 w-full rounded-xl bg-white/10 px-3 py-2.5 text-base outline-none ring-1 ring-white/10 focus:ring-line'
const ERR = {
  PLAN_INACTIVE: 'แพ็กเกจสังกัดยังไม่เปิด/หมดอายุ', TOO_MANY_DRAFTS: 'มีแบบร่างค้างเกิน 40 รายการ', TOO_MANY_PHOTOS: 'รูปได้สูงสุด 5 ภาพ',
  LOCKED: 'แบบร่างนี้แก้ไม่ได้ในสถานะปัจจุบัน', NO_PHOTO: 'ต้องมีรูปอย่างน้อย 1 ภาพ', MIXED_GROUPS: 'เลือกหมวดชงเหล้า/ENT ปนกับหมอนวด/สปาไม่ได้',
  CONTACT_IN_PROFILE: 'ห้ามใส่เบอร์โทร ไอดี หรือลิงก์ในชื่อ/แนะนำตัว/ที่อยู่', BAD_PROVINCE: 'จังหวัดไม่ถูกต้อง', BAD_AGE_METHOD: 'เลือกวิธีตรวจอายุ', CONSENT_REQUIRED: 'ต้องระบุว่าได้รับความยินยอมแล้ว', BAD_AGE: 'อายุต้อง 20 ปีขึ้นไป',
}
const errText = (m = '') => ERR[Object.keys(ERR).find((k) => m.includes(k))] ?? 'บันทึกไม่สำเร็จ'

// Application draft filled in for a provider (by an admin or a modelling agency). She only confirms afterwards.
// props: draft (a draft_view json, or null for a new one), mode ('admin' | 'agency'), onClose(), onSaved(id, andThen)
export default function DraftEditor({ draft, mode, onClose, onSaved }) {
  const { catName } = useI18n()
  const [grp, setGrp] = useState(draft ? groupOf(draft.categories) : null)
  const [form, setForm] = useState({
    display_name: draft?.display_name ?? '', categories: draft?.categories ?? [], district: draft?.district ?? '', nearby: draft?.nearby ?? '',
    phone: draft?.phone ?? '', line_id: draft?.line_id ?? '', note: draft?.note ?? '',
  })
  const [prof, setProf] = useState(() => (draft ? profileFromRow(draft) : emptyProfile()))
  const [photos, setPhotos] = useState(draft?.photos ?? [])           // already saved
  const [removed, setRemoved] = useState([])
  const [local, setLocal] = useState([])                              // picked, not uploaded yet
  const [adding, setAdding] = useState(false)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState(null)
  const [pub, setPub] = useState({ province: draft?.province ?? '', method: '', consent: '', ok: false })   // admin: publish now
  const set = (k) => (e) => setForm((f) => ({ ...f, [k]: e.target.value }))
  const total = photos.length - removed.length + local.length

  async function save(andThen) {
    setError(null)
    if (!form.display_name.trim()) return setError('กรุณาใส่ชื่อที่แสดง')
    if (form.categories.length === 0) return setError('กรุณาเลือกประเภทงาน')
    const bad = validateProfile(prof, grp, { needLocation: false })
    if (bad) return setError({ errGender: 'กรุณาเลือกเพศ', errAge: 'อายุต้อง 20 ปีขึ้นไป', errPrice: 'กรอกราคาอย่างน้อย 1 ช่อง', errServiceMode: 'เลือกรูปแบบการให้บริการ' }[bad] ?? 'ข้อมูลไม่ครบ')
    if (total < 1) return setError('ต้องมีรูปอย่างน้อย 1 ภาพ')
    if (andThen === 'publish') {
      if (!pub.province) return setError('กรุณาเลือกจังหวัดของน้อง')
      if (!pub.method) return setError('กรุณาเลือกวิธีที่ตรวจอายุแล้ว')
      if (!pub.ok || pub.consent.trim().length < 3) return setError('ต้องยืนยันว่าได้รับความยินยอมจากน้องแล้ว และระบุช่องทางที่ได้รับ')
    }
    setBusy(true)
    try {
      const payload = {
        display_name: form.display_name.trim(), categories: form.categories, ...profileToPayload(prof, grp),
        district: form.district.trim() || null, nearby: form.nearby.trim() || null,
        phone: form.phone.trim() || null, line_id: form.line_id.trim() || null, note: form.note.trim() || null,
      }
      delete payload.province
      const { data: id, error: e1 } = await supabase.rpc('draft_save', { p_id: draft?.id ?? null, p_data: payload })
      if (e1) throw e1
      for (const pid of removed) await removeDraftPhoto(pid)
      for (const pic of local) await uploadDraftPhoto(id, pic)
      await onSaved(id, andThen, pub)
    } catch (e) {
      console.error(e)
      setError(errText(e.message ?? String(e)))
    }
    setBusy(false)
  }

  if (!grp) {
    return (
      <Shell onClose={onClose} title="สร้างแบบร่างใบสมัครให้น้อง">
        <p className="text-sm text-neutral-400">เลือกประเภทงานของน้อง (ฟอร์มต่างกัน)</p>
        {[['night', '🍸', 'ชงเหล้า / ENT'], ['spa', '💆', 'หมอนวด / สปา']].map(([g, icon, label]) => (
          <button key={g} onClick={() => setGrp(g)} className="flex w-full items-center gap-4 rounded-3xl bg-white/5 p-4 text-left text-lg font-bold ring-1 ring-white/10 active:scale-[0.98]"><span className="text-3xl">{icon}</span>{label}</button>
        ))}
      </Shell>
    )
  }

  return (
    <Shell onClose={onClose} title={draft ? 'แก้ไขแบบร่าง' : 'สร้างแบบร่างใบสมัครให้น้อง'}>
      <p className="rounded-xl bg-amber-400/10 p-3 text-xs text-amber-200">
        {mode === 'agency'
          ? 'กรอกข้อมูลแทนน้อง แล้วส่งให้แอดมินตรวจ เมื่ออนุมัติจะได้ลิงก์ (ใช้ได้ 3 วัน) ไปส่งให้น้องกดยืนยันพิกัดและยอมรับด้วย LINE ของตัวเอง'
          : 'กรอกข้อมูลแทนน้อง แล้วออกลิงก์ (ใช้ได้ 3 วัน) ส่งให้น้องกดยืนยันพิกัด และเลือกสมัครเองหรือเข้าสังกัด'}
      </p>

      <section className="space-y-2">
        <div className="flex items-center justify-between">
          <h3 className="text-sm font-bold">รูปโปรโมท ({total}/5) — ต้องมีอย่างน้อย 1 รูป</h3>
          {total < 5 && !adding && <button onClick={() => setAdding(true)} className="rounded-xl bg-white/10 px-3 py-1.5 text-sm font-semibold active:scale-95">+ เพิ่มรูป</button>}
        </div>
        <ul className="grid grid-cols-3 gap-2">
          {photos.filter((p) => !removed.includes(p.id)).map((p) => (
            <li key={p.id} className="relative aspect-[3/4] overflow-hidden rounded-xl bg-neutral-800"><img src={p.public_url} alt="" className="h-full w-full object-cover" />
              <button onClick={() => setRemoved((r) => [...r, p.id])} className="absolute right-1 top-1 rounded-full bg-black/70 px-2 py-0.5 text-xs">✕</button></li>
          ))}
          {local.map((p) => (
            <li key={p.key} className="relative aspect-[3/4] overflow-hidden rounded-xl bg-neutral-800"><img src={p.url} alt="" className="h-full w-full object-cover" />
              <span className="absolute inset-x-0 bottom-0 bg-amber-500/90 py-0.5 text-center text-[10px] font-semibold text-black">ใหม่</span>
              <button onClick={() => setLocal((l) => l.filter((x) => x.key !== p.key))} className="absolute right-1 top-1 rounded-full bg-black/70 px-2 py-0.5 text-xs">✕</button></li>
          ))}
        </ul>
        {adding && (
          <div className="space-y-2 rounded-2xl bg-white/5 p-3 ring-1 ring-white/10">
            <PhotoUploader onPicked={(pic) => { setAdding(false); setLocal((l) => [...l, { key: Math.random().toString(36).slice(2), ...pic }]) }} />
            <button onClick={() => setAdding(false)} className="w-full rounded-xl bg-white/10 py-2 text-sm">ปิด</button>
          </div>
        )}
      </section>

      <label className="block text-sm">ชื่อที่แสดง
        <input maxLength={40} value={form.display_name} onChange={set('display_name')} className={input} />
      </label>
      <fieldset>
        <legend className="text-sm">ประเภทงาน (เลือกได้หลายอย่างในกลุ่มเดียวกัน)</legend>
        <div className="mt-2 flex flex-wrap gap-2">
          {GROUP_CATEGORIES[grp].map((c) => {
            const on = form.categories.includes(c)
            return <button type="button" key={c} aria-pressed={on} onClick={() => setForm((f) => ({ ...f, categories: on ? f.categories.filter((x) => x !== c) : [...f.categories, c] }))}
              className={`rounded-full px-4 py-2 text-sm font-semibold ring-1 active:scale-95 ${on ? 'bg-line text-black ring-line' : 'bg-white/10 ring-white/15'}`}>{on ? '✓ ' : ''}{catName(c)}</button>
          })}
        </div>
      </fieldset>

      <WorkerFields v={prof} set={(p) => setProf((x) => ({ ...x, ...p }))} grp={grp} hideLocation />
      <p className="text-[11px] text-neutral-500">พิกัดน้องเป็นคนยืนยันเอง (GPS) ตอนกดรับลิงก์ จังหวัดจึงไม่ต้องกรอก</p>
      <label className="block text-sm">อำเภอ / เขต (ไม่บังคับ)<input maxLength={60} value={form.district} onChange={set('district')} className={input} /></label>
      <label className="block text-sm">พื้นที่ใกล้เคียง (ไม่บังคับ)<input maxLength={120} value={form.nearby} onChange={set('nearby')} className={input} /></label>
      <div className="space-y-2 rounded-2xl bg-white/5 p-3">
        <p className="text-xs text-neutral-400">ช่องทางติดต่อน้อง (ใช้ให้แอดมินติดต่อเท่านั้น ไม่แสดงให้ลูกค้า) ถ้าไม่กรอก น้องจะกรอกเองตอนกดรับ</p>
        <label className="block text-sm">เบอร์โทรศัพท์<input type="tel" inputMode="tel" maxLength={20} value={form.phone} onChange={set('phone')} className={input} /></label>
        <label className="block text-sm">LINE ID<input maxLength={40} value={form.line_id} onChange={set('line_id')} className={input} /></label>
      </div>
      <label className="block text-sm">หมายเหตุถึงแอดมิน (ไม่บังคับ)<textarea rows={2} maxLength={300} value={form.note} onChange={set('note')} className={input} /></label>

      {mode === 'admin' && !draft?.managed && (
        <section className="space-y-2 rounded-2xl bg-green-500/10 p-3 ring-1 ring-green-400/30">
          <h3 className="text-sm font-bold text-green-200">เปิดโปรไฟล์ทันที (ลูกค้าเห็นได้ แต่จอง/แชตไม่ได้จนกว่าน้องกดยืนยัน)</h3>
          <label className="block text-sm">จังหวัดที่น้องรับงาน
            <select value={pub.province} onChange={(e) => setPub((x) => ({ ...x, province: e.target.value }))} className={input}>
              <option value="" className="text-black">เลือกจังหวัด</option>
              {PROVINCES.map((p) => <option key={p} value={p} className="text-black">{p}</option>)}
            </select>
            <span className="text-[11px] text-neutral-400">แสดงเป็น "จังหวัดที่ตั้งเอง" จนกว่าน้องจะยืนยันพิกัดด้วย GPS</span>
          </label>
          <label className="block text-sm">ตรวจอายุแล้วด้วยวิธี
            <select value={pub.method} onChange={(e) => setPub((x) => ({ ...x, method: e.target.value }))} className={input}>
              <option value="" className="text-black">เลือกวิธี</option>
              {[['photo', 'ดูจากรูป'], ['video_call', 'วิดีโอคอล'], ['in_person', 'พบตัวจริง'], ['id_card', 'ตรวจบัตรประชาชน']].map(([k, label]) => <option key={k} value={k} className="text-black">{label}</option>)}
            </select>
          </label>
          <label className="block text-sm">ได้รับความยินยอมจากน้องทางช่องทางไหน
            <input maxLength={200} value={pub.consent} onChange={(e) => setPub((x) => ({ ...x, consent: e.target.value }))} placeholder="เช่น วิดีโอคอล 29 ต.ค. / แชต LINE" className={input} />
          </label>
          <label className="flex items-start gap-2 text-xs text-neutral-200">
            <input type="checkbox" checked={pub.ok} onChange={(e) => setPub((x) => ({ ...x, ok: e.target.checked }))} className="mt-0.5 h-4 w-4 shrink-0" />
            <span>ข้าพเจ้า (แอดมิน) ยืนยันว่าได้รับความยินยอมจากเจ้าของรูปและข้อมูลแล้ว และตรวจอายุแล้ว ระบบบันทึกชื่อและเวลา โปรไฟล์จะซ่อนเองถ้าน้องไม่กดรับภายใน 14 วัน</span>
          </label>
        </section>
      )}
      {draft?.managed && <p className="rounded-xl bg-green-500/10 p-3 text-xs text-green-200">โปรไฟล์นี้เปิดแสดงอยู่แล้ว การแก้ไขที่บันทึกจะอัปเดตโปรไฟล์ที่แสดงอยู่ทันที (จนกว่าน้องจะกดรับ)</p>}
      {error && <p className="rounded-lg bg-red-500/10 p-2 text-sm text-red-300">{error}</p>}
      <div className="grid gap-2">
        {mode === 'agency' ? (
          <button disabled={busy} onClick={() => save('submit')} className="rounded-xl bg-line py-3 font-bold text-black active:scale-95 disabled:opacity-50">{busy ? 'กำลังบันทึก…' : 'บันทึกและส่งให้แอดมินตรวจ'}</button>
        ) : !draft?.managed && (
          <button disabled={busy} onClick={() => save('publish')} className="rounded-xl bg-line py-3 font-bold text-black active:scale-95 disabled:opacity-50">{busy ? 'กำลังบันทึก…' : '🟢 เปิดโปรไฟล์ทันที + ออกลิงก์ให้น้อง'}</button>
        )}
        <button disabled={busy} onClick={() => save(null)} className="rounded-xl bg-white/10 py-2.5 font-semibold active:scale-95 disabled:opacity-50">{draft?.managed ? 'บันทึกการแก้ไข' : 'บันทึกเป็นร่างไว้ก่อน'}</button>
        <button disabled={busy} onClick={onClose} className="rounded-xl bg-white/5 py-2 text-sm active:scale-95">ยกเลิก</button>
      </div>
    </Shell>
  )
}

function Shell({ title, onClose, children }) {
  return (
    <div className="fixed inset-0 z-[55] flex items-end justify-center bg-black/80 sm:items-center sm:p-4" onClick={onClose}>
      <div onClick={(e) => e.stopPropagation()} className="max-h-[94vh] w-full max-w-md space-y-4 overflow-y-auto rounded-t-3xl bg-neutral-900 p-5 pb-[calc(1.25rem+env(safe-area-inset-bottom))] shadow-2xl sm:rounded-3xl">
        <div className="flex items-center justify-between"><h2 className="text-lg font-bold">{title}</h2><button onClick={onClose} className="rounded-full bg-white/10 px-3 py-1 text-sm">✕</button></div>
        {children}
      </div>
    </div>
  )
}
