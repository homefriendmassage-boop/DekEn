import { useCallback, useEffect, useState } from 'react'
import { supabase } from '../../supabaseClient'
import PhotoUploader from '../PhotoUploader'
import MosaicEditor from '../MosaicEditor'

const ERR = {
  REQUEST_PENDING: 'มีคำขอรอแอดมินตรวจสอบอยู่แล้ว รอให้ตรวจเสร็จก่อน',
  TOO_MANY_PHOTOS: 'รูปเต็มแล้ว (สูงสุด 5 รูป) ลบรูปเก่าก่อน',
  NO_PHOTO: 'ต้องเหลืออย่างน้อย 1 รูป',
  NOTHING_TO_CHANGE: 'ยังไม่ได้แก้อะไร',
  PLAN_INACTIVE: 'ชำระแพ็กเกจสังกัดก่อน จึงจะแก้รูปน้องได้',
  ALREADY_STAGED: 'รูปนี้มีรูปใหม่รอส่งอยู่แล้ว',
  INSUFFICIENT_BALANCE: 'ยอด Wallet ไม่พอสำหรับค่าบริการ กรุณาเติมเงินก่อน',
  TOO_MANY: 'แก้โมเสกบ่อยเกินไปวันนี้ ลองใหม่พรุ่งนี้',
}
const errText = (m = '') => Object.entries(ERR).find(([k]) => m.includes(k))?.[1] ?? 'ทำรายการไม่สำเร็จ'
const MAX = 5

// The agency edits the pictures of one of its girls: add, delete, place the mosaic again. Nothing goes live until an admin approves the request.
export default function AgencyPhotos({ girl, paid, onClose, flash, onChanged }) {
  const [rows, setRows] = useState(null)
  const [req, setReq] = useState(null)          // her latest request from this agency { status, reject_reason }
  const [marks, setMarks] = useState(new Set()) // live pictures marked for removal
  const [adding, setAdding] = useState(false)
  const [editing, setEditing] = useState(null)
  const [busy, setBusy] = useState(false)
  const [fee, setFee] = useState(null)          // { fee, wallet, is_free } of the next add / delete request
  const [direct, setDirect] = useState(null)    // a picture getting extra mosaic spots (on the public picture, at once)

  const load = useCallback(async () => {
    const [p, r, f] = await Promise.all([supabase.rpc('agency_girl_photos', { p_worker: girl.user_id }), supabase.rpc('agency_photo_requests'), supabase.rpc('agency_photo_fee', { p_worker: girl.user_id })])
    setRows(p.data ?? [])
    setFee(f.data?.[0] ?? null)
    setReq((r.data ?? []).find((x) => x.worker_id === girl.user_id) ?? null)
  }, [girl.user_id])
  useEffect(() => { load() }, [load])

  const live = (rows ?? []).filter((x) => x.state === 'live')
  const staged = (rows ?? []).filter((x) => x.state === 'agency_add' && !x.request_id)
  const replaced = new Set(staged.filter((x) => x.replaces).map((x) => x.replaces))
  const pending = req?.status === 'pending'
  const plainAdds = staged.filter((x) => !x.replaces).length
  const keep = live.filter((x) => !marks.has(x.id) && !replaced.has(x.id)).length
  const canAdd = !pending && keep + staged.length < MAX
  const changed = marks.size > 0 || staged.length > 0

  async function uploadPair(folder, orig, pub) {
    const ts = Date.now()
    const out = { origPath: null, pubPath: `${folder}/${ts}-public.jpg` }
    if (orig) { out.origPath = `${folder}/${ts}.jpg`; const u1 = await supabase.storage.from('worker-originals').upload(out.origPath, orig, { contentType: 'image/jpeg' }); if (u1.error) throw u1.error }
    const u2 = await supabase.storage.from('worker-public').upload(out.pubPath, pub, { contentType: 'image/jpeg' })
    if (u2.error) { if (out.origPath) supabase.storage.from('worker-originals').remove([out.origPath]).catch(() => {}); throw u2.error }
    out.url = supabase.storage.from('worker-public').getPublicUrl(out.pubPath).data.publicUrl
    return out
  }
  async function stage(orig, pub, replaces = null, origPath = null) {
    const up = await uploadPair(girl.user_id, orig, pub)
    const { error } = await supabase.rpc('agency_stage_photo', { p_worker: girl.user_id, p_public_url: up.url, p_original_path: origPath ?? up.origPath, p_replaces: replaces })
    if (error) {
      supabase.storage.from('worker-public').remove([up.pubPath]).catch(() => {})
      if (up.origPath) supabase.storage.from('worker-originals').remove([up.origPath]).catch(() => {})
      flash(errText(error.message)); return false
    }
    return true
  }
  async function onNew({ orig, pub }) {
    setBusy(true); setAdding(false)
    if (await stage(orig, pub)) flash('เพิ่มรูปแล้ว (ยังไม่ส่งคำขอ)')
    setBusy(false); load()
  }
  async function unstage(p) {
    setBusy(true)
    const { data, error } = await supabase.rpc('agency_unstage_photo', { p_id: p.id })
    if (error) flash(errText(error.message))
    else {
      const name = decodeURIComponent(p.public_url.split('/worker-public/')[1] ?? '')
      if (name) supabase.storage.from('worker-public').remove([name]).catch(() => {})
      if (data) supabase.storage.from('worker-originals').remove([data]).catch(() => {})
    }
    setBusy(false); load()
  }
  // extra mosaic spots on the public picture: free, no admin, at once (the old picture is kept so an admin can put it back)
  async function saveDirect(p, blob) {
    const up = await uploadPair(girl.user_id, null, blob)
    const { error } = await supabase.rpc('agency_mosaic_direct', { p_photo: p.id, p_public_url: up.url })
    if (error) { supabase.storage.from('worker-public').remove([up.pubPath]).catch(() => {}); flash(errText(error.message)); return }
    flash('บันทึกโมเสกแล้ว มีผลทันที'); setDirect(null); load(); onChanged?.()
  }
  async function submit() {
    if (!window.confirm('ส่งคำขอแก้ไขรูปให้แอดมินอนุมัติ? รูปใหม่จะแสดงเมื่อแอดมินอนุมัติเท่านั้น')) return
    setBusy(true)
    const { error } = await supabase.rpc('agency_submit_photo_edit', { p_worker: girl.user_id, p_remove: [...marks] })
    setBusy(false)
    if (error) return flash(errText(error.message))
    flash('ส่งคำขอให้แอดมินแล้ว รอตรวจสอบ'); setMarks(new Set()); load(); onChanged?.()
  }
  async function cancelReq() {
    if (!window.confirm('ยกเลิกคำขอที่ส่งไปแล้ว?')) return
    const { error } = await supabase.rpc('agency_cancel_photo_edit', { p_worker: girl.user_id })
    flash(error ? errText(error.message) : 'ยกเลิกคำขอแล้ว'); load(); onChanged?.()
  }
  const toggle = (id) => setMarks((m) => { const n = new Set(m); if (n.has(id)) n.delete(id); else n.add(id); return n })

  return (
    <div className="fixed inset-0 z-[60] flex items-end justify-center bg-black/70 sm:items-center sm:p-4" onClick={onClose} role="dialog" aria-modal="true">
      <div onClick={(e) => e.stopPropagation()} className="max-h-[92vh] w-full max-w-md space-y-3 overflow-y-auto rounded-t-3xl bg-neutral-900 p-5 pb-[calc(1.25rem+env(safe-area-inset-bottom))] shadow-2xl sm:rounded-3xl">
        <div className="flex items-center justify-between"><h3 className="text-lg font-bold">🖼️ แก้ไขรูป: {girl.display_name}</h3><button onClick={onClose} className="rounded-full bg-white/10 px-3 py-1 text-sm">✕</button></div>
        <p className="text-xs text-neutral-400">🎨 เพิ่มโมเสกทับรูปเดิม: ฟรี มีผลทันที ไม่ต้องรออนุมัติ (ใช้ได้ทุกสังกัด) · เพิ่มรูป/ลบรูป/วางใหม่จากต้นฉบับ: สังกัดที่ชำระแพ็กเกจ ส่งคำขอให้แอดมินอนุมัติ คำขอแรกของน้องแต่ละคนฟรี ครั้งต่อไป 20 บาท หักจาก Wallet</p>
        {pending && (
          <div className="space-y-1 rounded-xl bg-amber-400/10 p-3 text-sm text-amber-100">
            <p className="font-semibold">⏳ ส่งคำขอแล้ว รอแอดมินตรวจสอบ</p>
            <button onClick={cancelReq} className="rounded-lg bg-white/10 px-3 py-1 text-xs active:scale-95">ยกเลิกคำขอนี้</button>
          </div>
        )}
        {req?.status === 'rejected' && <p className="rounded-xl bg-red-500/10 p-3 text-sm text-red-200">❌ แอดมินไม่อนุมัติ{req.reject_reason ? `: ${req.reject_reason}` : ''} แก้ตามเหตุผลแล้วส่งใหม่ได้</p>}
        {req?.status === 'approved' && <p className="rounded-xl bg-green-500/10 p-3 text-xs text-green-200">✅ คำขอล่าสุดได้รับอนุมัติแล้ว</p>}

        {rows === null ? <p className="py-6 text-center text-neutral-500">กำลังโหลด…</p> : (
          <>
            <p className="text-sm font-semibold">รูปปัจจุบัน ({live.length})</p>
            <ul className="grid grid-cols-3 gap-2">
              {live.map((p, i) => {
                const gone = marks.has(p.id)
                const swap = replaced.has(p.id)
                return (
                  <li key={p.id} className="space-y-1">
                    <div className="relative overflow-hidden rounded-xl bg-black">
                      <img src={p.public_url} alt="" className={`aspect-[3/4] w-full object-cover ${gone || swap ? 'opacity-30' : ''}`} />
                      {i === 0 && <span className="absolute left-1 top-1 rounded-full bg-black/70 px-1.5 text-[10px]">ปก</span>}
                      {gone && <span className="absolute inset-0 flex items-center justify-center text-xs font-bold text-red-300">จะถูกลบ</span>}
                      {swap && <span className="absolute inset-0 flex items-center justify-center text-center text-[11px] font-bold text-amber-200">จะถูกแทนที่</span>}
                    </div>
                    <div className="grid gap-1">
                      <button disabled={busy || swap || gone} onClick={() => setDirect(p)} className="rounded-lg bg-pink-500/80 py-1 text-[11px] font-semibold active:scale-95 disabled:opacity-40">🎨 เพิ่มโมเสกทับ</button>
                      {!pending && paid && (
                        <>
                          <button disabled={busy || swap || gone} onClick={() => setEditing(p)} className="rounded-lg bg-white/10 py-1 text-[11px] active:scale-95 disabled:opacity-40">วางใหม่จากต้นฉบับ</button>
                          <button disabled={busy || swap} onClick={() => toggle(p.id)} className="rounded-lg bg-white/10 py-1 text-[11px] active:scale-95 disabled:opacity-40">{gone ? '↩ ไม่ลบ' : '🗑 ลบ'}</button>
                        </>
                      )}
                    </div>
                  </li>
                )
              })}
            </ul>
            {staged.length > 0 && (
              <>
                <p className="text-sm font-semibold text-green-300">รูปใหม่ที่รอส่งคำขอ ({staged.length})</p>
                <ul className="grid grid-cols-3 gap-2">
                  {staged.map((p) => (
                    <li key={p.id} className="space-y-1">
                      <div className="relative overflow-hidden rounded-xl bg-black ring-2 ring-green-400/60"><img src={p.public_url} alt="" className="aspect-[3/4] w-full object-cover" />
                        <span className="absolute left-1 top-1 rounded-full bg-green-500/80 px-1.5 text-[10px] text-black">{p.replaces ? 'โมเสกใหม่' : 'ใหม่'}</span></div>
                      {!pending && <button disabled={busy} onClick={() => unstage(p)} className="w-full rounded-lg bg-white/10 py-1 text-[11px] active:scale-95 disabled:opacity-40">ยกเลิกรูปนี้</button>}
                    </li>
                  ))}
                </ul>
              </>
            )}
            {!pending && !paid && <p className="rounded-xl bg-white/5 p-3 text-xs text-neutral-300">เพิ่มรูป / ลบรูป / วางโมเสกใหม่จากรูปต้นฉบับ ต้องชำระแพ็กเกจสังกัดก่อน (ส่วนการเพิ่มจุดโมเสกทับรูปเดิม ทำได้เลยโดยไม่ต้องรออนุมัติ)</p>}
            {!pending && paid && (
              <>
                {adding ? (
                  <div className="space-y-2 rounded-2xl bg-white/5 p-3">
                    <div className="flex items-center justify-between"><p className="text-sm font-semibold">เพิ่มรูปใหม่</p><button onClick={() => setAdding(false)} className="text-xs text-neutral-400">ปิด</button></div>
                    <PhotoUploader userId={girl.user_id} onPicked={onNew} />
                  </div>
                ) : (
                  <button disabled={!canAdd || busy} onClick={() => setAdding(true)} className="w-full rounded-xl bg-white/10 py-2.5 text-sm font-semibold active:scale-95 disabled:opacity-40">➕ เพิ่มรูป {canAdd ? '' : '(เต็ม 5 รูป)'}</button>
                )}
                {fee && changed && <p className={`rounded-xl p-2 text-xs ${fee.is_free ? 'bg-green-500/10 text-green-200' : 'bg-amber-400/10 text-amber-100'}`}>{fee.is_free ? 'คำขอแรกของน้องคนนี้ ฟรี' : `ค่าบริการส่งคำขอ ${fee.fee} บาท หักจาก Wallet สังกัด (คืนถ้าไม่ผ่านอนุมัติ) · Wallet ของคุณ ${Number(fee.wallet).toFixed(0)} บาท`}</p>}
                <button disabled={!changed || busy} onClick={submit} className="w-full rounded-xl bg-line py-3 text-sm font-bold text-black active:scale-95 disabled:opacity-40">
                  {busy ? '…' : `ส่งคำขอให้แอดมินอนุมัติ${changed ? ` (เพิ่ม ${plainAdds} · แทน ${staged.length - plainAdds} · ลบ ${marks.size})` : ''}`}
                </button>
              </>
            )}
          </>
        )}
      </div>
      {direct && <MosaicEditor title={girl.display_name} sourceUrl={direct.public_url} toast={flash} saveLabel="ยืนยัน (มีผลทันที)" onClose={() => setDirect(null)} onSave={(blob) => saveDirect(direct, blob)} />}
      {editing && (
        <MosaicEditor title={girl.display_name} originalPath={editing.original_path} toast={flash} saveLabel="ยืนยัน (รอส่งคำขอ)" onClose={() => setEditing(null)}
          onSave={async (blob) => { if (await stage(null, blob, editing.id, editing.original_path)) { flash('บันทึกโมเสกใหม่แล้ว (ยังไม่ส่งคำขอ)'); setEditing(null); load() } }} />
      )}
    </div>
  )
}
