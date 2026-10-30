import { useCallback, useEffect, useState } from 'react'
import { supabase } from '../supabaseClient'
import { useI18n } from '../i18n'
import DraftEditor from './DraftEditor'
import LinkSheet from './LinkSheet'
import { inviteBubble } from '../lib/flex'
import { DRAFT_STATUS, draftLink } from '../lib/drafts'
import { ago, fmtDateTime } from '../admin/format'

const GROUP = { night: '🍸 ชงเหล้า/ENT', spa: '💆 หมอนวด/สปา' }
const ERR = { TOO_MANY_DRAFTS: 'มีแบบร่างที่ใช้งานอยู่ครบ 40 ใบแล้ว ลบหรือซ่อนบางใบก่อน', PLAN_INACTIVE: 'แพ็กเกจสังกัดยังไม่เปิด/หมดอายุ', NOT_APPROVED: 'แอดมินยังไม่อนุมัติแบบร่างนี้', NO_PHOTO: 'ต้องมีรูปอย่างน้อย 1 ภาพ', LOCKED: 'ทำรายการนี้ไม่ได้ในสถานะปัจจุบัน' }
const errText = (m = '') => ERR[Object.keys(ERR).find((k) => m.includes(k))] ?? 'ทำรายการไม่สำเร็จ'

// Application drafts. mode 'agency': my own drafts (create, send to an admin, copy the link once approved).
// mode 'admin': the review queue of agency drafts + drafts the admin fills in for girls herself.
export default function DraftsPanel({ mode, toast }) {
  const { money, catName } = useI18n()
  const [filter, setFilter] = useState(mode === 'admin' ? 'review' : 'all')
  const [showHidden, setShowHidden] = useState(false)   // agency: the hidden (cancelled) drafts
  const hiddenView = mode === 'admin' ? filter === 'hidden' : showHidden
  const [rows, setRows] = useState(null)
  const [editing, setEditing] = useState(null)      // null | 'new' | draft
  const [open, setOpen] = useState(null)            // expanded draft id
  const [rejecting, setRejecting] = useState(null)  // { id, reason }
  const [clear, setClear] = useState({})            // photo id -> signed URL of the clear original (admin only)

  const load = useCallback(async () => {
    const { data } = mode === 'admin' ? await supabase.rpc('admin_drafts_list', { p_filter: filter }) : await supabase.rpc('my_drafts', { p_hidden: showHidden })
    setRows(data ?? [])
  }, [mode, filter, showHidden])
  useEffect(() => { load() }, [load])

  // the link the girl must open within 3 days: copy / Flex card / QR code
  const [sheet, setSheet] = useState(null)
  function copy(token, name) {
    const link = draftLink(token)
    setSheet({ link, name })
    try { navigator.clipboard.writeText(link) } catch { /* the sheet shows the link */ }
  }
  async function run(fn, okText) {
    const { data, error } = await fn()
    if (error) return toast(errText(error.message))
    if (okText) toast(okText)
    await load()
    return data
  }
  const submit = (d) => run(() => supabase.rpc('draft_submit', { p_id: d.id }), 'ส่งให้แอดมินตรวจแล้ว')
  async function issue(d) { const tok = await run(() => supabase.rpc('draft_issue_link', { p_id: d.id })); if (tok) copy(tok) }
  async function approve(d) { await run(() => supabase.rpc('admin_draft_review', { p_id: d.id, p_approve: true }), 'อนุมัติแล้ว ออกลิงก์ให้โมเดลลิ่งแล้ว (อายุ 3 วัน)') }
  async function reject(d) {
    await run(() => supabase.rpc('admin_draft_review', { p_id: d.id, p_approve: false, p_reason: rejecting.reason }), 'ตีกลับแล้ว')
    setRejecting(null)
  }
  const cancel = (d) => window.confirm(d.managed ? `ถอดโปรไฟล์ "${d.display_name}" ออกจากระบบและซ่อนแบบร่าง?` : `ซ่อนแบบร่างของ "${d.display_name}"? (ไม่นับโควตา กู้คืนได้จากปุ่ม "ที่ซ่อนไว้")`) && run(() => supabase.rpc('draft_cancel', { p_id: d.id }), 'ซ่อนแล้ว (ไม่นับโควตา)')
  const restore = (d) => run(() => supabase.rpc('draft_restore', { p_id: d.id }), 'กู้คืนเป็นแบบร่างแล้ว')
  async function destroy(d) {
    if (!window.confirm(`ลบ "${d.display_name}" ถาวร? กู้คืนไม่ได้ รูปทั้งหมดจะถูกลบด้วย`)) return
    const paths = await run(() => supabase.rpc('draft_delete', { p_id: d.id }), 'ลบถาวรแล้ว')
    for (const o of paths ?? []) {
      supabase.storage.from('worker-originals').remove([o]).then(() => {}, () => {})
      supabase.storage.from('worker-public').remove([o.replace(/\.jpg$/, '-public.jpg')]).then(() => {}, () => {})
    }
  }

  async function onSaved(id, andThen, pub) {
    setEditing(null)
    if (andThen === 'submit') await run(() => supabase.rpc('draft_submit', { p_id: id }), 'ส่งให้แอดมินตรวจแล้ว')
    else if (andThen === 'publish') {
      const tok = await run(() => supabase.rpc('admin_publish_draft', { p_id: id, p_province: pub.province, p_age_method: pub.method, p_consent_note: pub.consent }), 'เปิดโปรไฟล์แล้ว (ลูกค้าเห็นแต่จองไม่ได้จนกว่าน้องกดรับ)')
      if (tok) copy(tok)
    } else if (andThen === 'link') { const tok = await run(() => supabase.rpc('draft_issue_link', { p_id: id })); if (tok) copy(tok) }
    else { toast('บันทึกร่างแล้ว'); await load() }
  }

  async function showClear(d) {
    setOpen(open === d.id ? null : d.id)
    if (mode !== 'admin' || open === d.id) return
    const next = {}
    for (const p of d.photos) {
      const { data } = await supabase.storage.from('worker-originals').createSignedUrl(p.original_path, 600)
      if (data?.signedUrl) next[p.id] = data.signedUrl
    }
    setClear((c) => ({ ...c, ...next }))
  }

  return (
    <div className="space-y-4">
      <div className="flex flex-wrap items-center gap-2">
        {mode === 'admin' && [['review', 'รอตรวจจากโมเดลลิ่ง'], ['links', 'ลิงก์/ร่างของแอดมิน'], ['all', 'ทั้งหมด'], ['hidden', '🗂 ที่ซ่อนไว้']].map(([k, label]) => (
          <button key={k} onClick={() => setFilter(k)} className={`rounded-full px-3 py-1.5 text-sm font-semibold ${filter === k ? 'bg-line text-black' : 'bg-white/10'}`}>{label}</button>
        ))}
        {mode === 'agency' && <button onClick={() => setShowHidden((v) => !v)} className={`rounded-full px-3 py-1.5 text-sm font-semibold ${showHidden ? 'bg-line text-black' : 'bg-white/10'}`}>🗂 {showHidden ? 'กลับไปแบบร่างปกติ' : 'ที่ซ่อนไว้'}</button>}
        <button onClick={() => setEditing('new')} className="ml-auto rounded-xl bg-pink-500 px-4 py-2 text-sm font-bold active:scale-95">➕ สร้างแบบร่างให้น้อง</button>
      </div>
      <p className="text-xs text-neutral-500">
        {hiddenView ? 'แบบร่างที่ซ่อนไว้ ไม่แสดงในรายการปกติและไม่นับโควตา กู้คืนกลับมาเป็นแบบร่างได้ หรือลบถาวร (หายไปเลย)'
          : mode === 'agency'
          ? 'กรอกข้อมูลแทนน้อง → แอดมินตรวจ/อนุมัติ → ได้ลิงก์ (3 วัน) ส่งให้น้องกดยืนยันพิกัดและเข้าสังกัดด้วย LINE ของน้อง น้องที่กดรับแล้วจึงนับในโควตาของสังกัด'
          : 'แบบร่างจากแอดมิน ออกลิงก์ได้ทันที น้องกดยืนยันพิกัดแล้วเลือกสมัครเองหรือเข้าสังกัด จากนั้นเป็นใบสมัครปกติ (ตรวจอายุ + อนุมัติ)'}
      </p>

      {rows === null ? <p className="py-10 text-center text-neutral-500">กำลังโหลด…</p> : rows.length === 0 ? (
        <p className="rounded-2xl bg-white/5 p-6 text-center text-neutral-500">{hiddenView ? 'ไม่มีแบบร่างที่ซ่อนไว้' : 'ยังไม่มีแบบร่าง'}</p>
      ) : (
        <ul className="grid gap-3 md:grid-cols-2">
          {rows.map((d) => {
            const [label, cls] = DRAFT_STATUS[d.link_expired && d.status !== 'claimed' ? 'expired' : d.status] ?? DRAFT_STATUS.draft
            const status = d.link_expired && d.status !== 'claimed' ? 'expired' : d.status
            const mine = mode === 'agency' || d.source === 'admin'
            return (
              <li key={d.id} className="space-y-2 rounded-2xl bg-white/5 p-3 ring-1 ring-white/10">
                <div className="flex gap-3">
                  <div className="h-24 w-[4.5rem] shrink-0 overflow-hidden rounded-xl bg-neutral-800">
                    {d.photos[0] && <img src={d.photos[0].public_url} alt="" className="h-full w-full object-cover" />}
                  </div>
                  <div className="min-w-0 flex-1 space-y-1">
                    <p className="truncate font-bold">{d.display_name}</p>
                    <div className="flex flex-wrap items-center gap-1.5">
                      <span className={`rounded-full px-2 py-0.5 text-[11px] font-semibold ${cls}`}>{label}</span>
                      <span className="rounded-full bg-white/10 px-2 py-0.5 text-[11px]">{GROUP[d.grp]}</span>
                    </div>
                    <p className="text-[11px] text-neutral-400">{d.categories.map(catName).join(' · ')}{d.price ? ` · เริ่มต้น ${money(d.price)}` : ''}</p>
                    {mode === 'admin' && <p className="text-[11px] text-neutral-500">{d.source === 'agency' ? `โมเดลลิ่ง ${d.agency_name ?? ''}` : `แอดมิน ${d.creator_name ?? ''}`} · {ago(d.updated_at)}</p>}
                    {d.managed && <p className="text-[11px] font-semibold text-green-300">🟢 โปรไฟล์เปิดแสดงอยู่ · รอน้องยืนยัน{d.claim_deadline ? ` (ซ่อนเองถ้าไม่กดรับภายใน ${fmtDateTime(d.claim_deadline)})` : ''}</p>}
                    {d.link_expires_at && d.link_active && <p className="text-[11px] text-green-300">ลิงก์หมดอายุ {fmtDateTime(d.link_expires_at)}</p>}
                    {d.reject_reason && d.status === 'rejected' && <p className="text-[11px] text-red-300">เหตุผลที่ตีกลับ: {d.reject_reason}</p>}
                  </div>
                </div>

                <button onClick={() => showClear(d)} className="text-xs text-neutral-400 underline">{open === d.id ? 'ซ่อนรายละเอียด' : 'ดูรายละเอียด'}</button>
                {open === d.id && (
                  <div className="space-y-2 rounded-xl bg-black/30 p-2 text-xs">
                    <ul className="grid grid-cols-3 gap-1.5">{d.photos.map((p) => <li key={p.id} className="aspect-[3/4] overflow-hidden rounded-lg bg-neutral-800"><img src={clear[p.id] ?? p.public_url} alt="" className="h-full w-full object-cover" /></li>)}</ul>
                    <p>{[d.gender, d.age && `${d.age} ปี`, d.height_cm && `${d.height_cm} ซม.`, d.weight_kg && `${d.weight_kg} กก.`, d.measurements, d.service_mode].filter(Boolean).join(' · ')}</p>
                    {d.tags?.length > 0 && <p className="text-pink-200">{d.tags.join(', ')}</p>}
                    {d.about && <p className="whitespace-pre-wrap break-words text-neutral-300">{d.about}</p>}
                    <p>ราคา: {(d.price_options ?? []).map((o) => `${o.label} ${money(o.price)}`).join(' · ')} (เริ่มต้น: {d.start_rate})</p>
                    {(d.district || d.nearby) && <p>📍 {[d.district, d.nearby].filter(Boolean).join(' · ')}</p>}
                    {d.managed_user_id && d.age_verified_method && <p className="text-green-300">ตรวจอายุ: {d.age_verified_method} · ความยินยอม: {d.consent_note}</p>}
                    {(d.phone || d.line_id) && <p>ติดต่อ: {[d.phone, d.line_id].filter(Boolean).join(' · ')}</p>}
                    {d.note && <p className="text-neutral-400">หมายเหตุ: {d.note}</p>}
                  </div>
                )}

                <div className="flex flex-wrap gap-2">
                  {mode === 'admin' && status === 'submitted' && (
                    <>
                      <button onClick={() => approve(d)} className="rounded-xl bg-line px-3 py-1.5 text-sm font-bold text-black active:scale-95">✅ อนุมัติ + ออกลิงก์</button>
                      <button onClick={() => setRejecting({ id: d.id, reason: '' })} className="rounded-xl bg-white/10 px-3 py-1.5 text-sm font-semibold active:scale-95">↩︎ ตีกลับ</button>
                    </>
                  )}
                  {mine && ['draft', 'rejected', 'approved', 'expired'].includes(status) && <button onClick={() => setEditing(d)} className="rounded-xl bg-white/10 px-3 py-1.5 text-sm font-semibold active:scale-95">✏️ แก้ไข</button>}
                  {mode === 'agency' && ['draft', 'rejected'].includes(status) && <button onClick={() => submit(d)} className="rounded-xl bg-line px-3 py-1.5 text-sm font-bold text-black active:scale-95">ส่งให้แอดมินตรวจ</button>}
                  {mode === 'admin' && d.source === 'admin' && status === 'draft' && <button onClick={() => issue(d)} className="rounded-xl bg-line px-3 py-1.5 text-sm font-bold text-black active:scale-95">ออกลิงก์</button>}
                  {d.link_active && d.token && <button onClick={() => copy(d.token, d.display_name)} className="rounded-xl bg-green-500/80 px-3 py-1.5 text-sm font-bold text-black active:scale-95">🔗 ลิงก์ · Flex · QR</button>}
                  {['approved', 'expired'].includes(status) && mine && <button onClick={() => issue(d)} className="rounded-xl bg-white/10 px-3 py-1.5 text-sm font-semibold active:scale-95">🔄 ออกลิงก์ใหม่</button>}
                  {mode === 'admin' && d.source === 'agency' && ['approved', 'expired'].includes(status) && <button onClick={() => issue(d)} className="rounded-xl bg-white/10 px-3 py-1.5 text-sm font-semibold active:scale-95">🔄 ออกลิงก์ใหม่</button>}
                  {['draft', 'rejected', 'approved', 'expired', 'submitted'].includes(status) && (mine || mode === 'admin') && <button onClick={() => cancel(d)} className="rounded-xl bg-white/10 px-3 py-1.5 text-sm text-neutral-300 active:scale-95">🙈 ซ่อน (ยกเลิก)</button>}
                  {status === 'cancelled' && (
                    <>
                      <button onClick={() => restore(d)} className="rounded-xl bg-line px-3 py-1.5 text-sm font-bold text-black active:scale-95">↩︎ กู้คืน</button>
                      <button onClick={() => destroy(d)} className="rounded-xl bg-red-500/20 px-3 py-1.5 text-sm font-semibold text-red-300 active:scale-95">🗑 ลบถาวร</button>
                    </>
                  )}
                </div>

                {rejecting?.id === d.id && (
                  <div className="space-y-2 rounded-xl bg-red-500/10 p-2">
                    <input value={rejecting.reason} onChange={(e) => setRejecting({ id: d.id, reason: e.target.value })} maxLength={300} placeholder="เหตุผลที่ตีกลับ (โมเดลลิ่งจะเห็น)" className="w-full rounded-lg bg-white/10 px-3 py-2 text-sm" />
                    <div className="grid grid-cols-2 gap-2">
                      <button onClick={() => setRejecting(null)} className="rounded-lg bg-white/10 py-1.5 text-sm">ยกเลิก</button>
                      <button onClick={() => reject(d)} className="rounded-lg bg-red-500 py-1.5 text-sm font-bold">ตีกลับ</button>
                    </div>
                  </div>
                )}
              </li>
            )
          })}
        </ul>
      )}

      {editing && <DraftEditor draft={editing === 'new' ? null : editing} mode={mode} onClose={() => setEditing(null)} onSaved={onSaved} />}

      {sheet && (
        <LinkSheet
          title="ลิงก์ให้น้องกดรับ (ใช้ได้ 3 วัน)"
          intro={`ส่งให้ ${sheet.name ?? 'น้อง'} เปิดด้วย LINE ของตัวเองเพื่อยืนยันโปรไฟล์ ส่งเป็นการ์ด Flex หรือให้สแกน QR ก็ได้`}
          link={sheet.link}
          flex={{
            type: 'flex', altText: 'DekEn: ยืนยันโปรไฟล์ของคุณ',
            contents: inviteBubble({ tagline: 'DekEn', title: 'ยืนยันโปรไฟล์ของคุณ', body: 'มีผู้ดูแลสร้างโปรไฟล์ให้คุณแล้ว กดเพื่อตรวจข้อมูล ยืนยันตัวตน และเริ่มรับงาน (ลิงก์ใช้ได้ 3 วัน)', button: 'กดเพื่อยืนยัน', uri: sheet.link }),
          }}
          onClose={() => setSheet(null)}
        />
      )}
    </div>
  )
}
