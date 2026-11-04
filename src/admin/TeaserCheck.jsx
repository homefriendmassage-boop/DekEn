import { useCallback, useEffect, useState } from 'react'
import { supabase } from '../supabaseClient'
import MosaicEditor from '../components/MosaicEditor'

// The admin places the mosaic himself from the private original; the new public file replaces the old one.
function Editor({ photo, toast, onClose, onDone }) {
  async function save(blob) {
    const path = `${photo.worker_id}/${Date.now()}-public-admin.jpg`
    const up = await supabase.storage.from('worker-public').upload(path, blob, { contentType: 'image/jpeg' })
    if (up.error) throw up.error
    const url = supabase.storage.from('worker-public').getPublicUrl(path).data.publicUrl
    const { error } = await supabase.rpc('admin_teaser_replace', { p_photo: photo.photo_id, p_public_url: url })
    if (error) throw error
    supabase.storage.from('worker-public').remove([decodeURIComponent(photo.public_url.split('/worker-public/')[1] ?? '')]).catch(() => {})   // best effort: the old file
    toast('แทนรูปตัวอย่างแล้ว'); onDone()
  }
  return <MosaicEditor title={photo.display_name} originalPath={photo.original_path} onClose={onClose} onSave={save} toast={toast} />
}

// Every public teaser photo: find ones where a face shows, tell the girl / agency, or fix it here.
export default function TeaserCheck({ toast }) {
  const PAGE = 30
  const [q, setQ] = useState('')
  const [onlyFlag, setOnlyFlag] = useState(false)
  const [rows, setRows] = useState(null)
  const [more, setMore] = useState(false)
  const [zoom, setZoom] = useState(null)
  const [flagging, setFlagging] = useState(null)       // { worker_id, display_name, agency_name }
  const [note, setNote] = useState('หน้ายังเห็นชัด กรุณาวางโมเสกให้ครอบใบหน้าทุกคนในรูป')
  const [notify, setNotify] = useState('both')
  const [editing, setEditing] = useState(null)

  const load = useCallback(async (offset = 0) => {
    if (offset === 0) setRows(null)
    const { data, error } = await supabase.rpc('admin_teaser_list', { p_q: q.trim() || null, p_flagged: onlyFlag, p_limit: PAGE, p_offset: offset })
    if (error) { toast('โหลดไม่สำเร็จ: ' + error.message); return setRows([]) }
    const list = data ?? []
    setMore(new Set(list.map((r) => r.worker_id)).size >= PAGE)
    setRows((prev) => (offset === 0 ? list : [...(prev ?? []), ...list]))
  }, [q, onlyFlag]) // eslint-disable-line react-hooks/exhaustive-deps
  useEffect(() => { const h = setTimeout(() => load(0), 300); return () => clearTimeout(h) }, [load])

  // group the photos of one provider
  const groups = []
  ;(rows ?? []).forEach((r) => { const g = groups.find((x) => x.worker_id === r.worker_id); if (g) g.photos.push(r); else groups.push({ worker_id: r.worker_id, display_name: r.display_name, agency_name: r.agency_name, flag_note: r.flag_note, flagged_at: r.flagged_at, photos: [r] }) })

  async function sendFlag() {
    const { error } = await supabase.rpc('admin_teaser_flag', { p_worker: flagging.worker_id, p_note: note, p_notify: notify })
    if (error) return toast('ส่งไม่สำเร็จ')
    toast('แจ้งแล้ว'); setFlagging(null); load(0)
  }
  async function resolve(g) {
    await supabase.rpc('admin_teaser_resolve', { p_worker: g.worker_id }); toast('ปิดเรื่องแล้ว'); load(0)
  }

  return (
    <div className="space-y-3 p-3">
      <div className="flex gap-2">
        <input value={q} onChange={(e) => setQ(e.target.value)} placeholder="ค้นหาชื่อน้อง" className="min-w-0 flex-1 rounded-xl bg-white/10 px-3 py-2 text-base outline-none ring-1 ring-white/10 focus:ring-line" />
        <button onClick={() => setOnlyFlag(!onlyFlag)} className={`shrink-0 rounded-xl px-3 py-2 text-sm font-semibold ${onlyFlag ? 'bg-amber-400 text-black' : 'bg-white/10'}`}>🚩 รอแก้</button>
      </div>
      <p className="text-xs text-neutral-400">นี่คือรูปที่ทุกคนเห็น (โมเสกแล้ว) แตะรูปเพื่อขยาย ถ้าเห็นหน้า กด "แจ้งแก้" ให้น้อง/สังกัดวางโมเสกใหม่ หรือกด "วางโมเสกเอง" จากรูปต้นฉบับ</p>
      {rows === null ? <p className="py-10 text-center text-neutral-500">กำลังโหลด…</p> : groups.length === 0 ? <p className="rounded-2xl bg-white/5 p-6 text-center text-neutral-500">ไม่พบรายการ</p> : (
        <ul className="space-y-3">
          {groups.map((g) => (
            <li key={g.worker_id} className="space-y-2 rounded-2xl bg-white/5 p-3 ring-1 ring-white/10">
              <div className="flex items-start justify-between gap-2">
                <p className="min-w-0 font-bold">{g.display_name} <span className="text-xs font-normal text-neutral-400">{g.agency_name ? `· สังกัด ${g.agency_name}` : '· อิสระ'}</span></p>
                {g.flag_note !== null && g.flagged_at && <span className="shrink-0 rounded-full bg-amber-400/20 px-2 py-0.5 text-[11px] text-amber-200">🚩 รอแก้</span>}
              </div>
              {g.flagged_at && <p className="text-[11px] text-amber-200">แจ้งไว้: {g.flag_note || '—'}</p>}
              <div className="grid grid-cols-3 gap-2">
                {g.photos.map((p) => (
                  <div key={p.photo_id} className="space-y-1">
                    <button onClick={() => setZoom(p.public_url)} className="block w-full overflow-hidden rounded-xl bg-black active:scale-95"><img src={p.public_url} alt="" loading="lazy" className="aspect-[3/4] w-full object-cover" /></button>
                    <button onClick={() => setEditing(p)} className="w-full rounded-lg bg-pink-500/80 py-1 text-[11px] font-semibold active:scale-95">🎨 วางโมเสกเอง{p.is_cover ? ' (ปก)' : ''}</button>
                  </div>
                ))}
              </div>
              <div className="flex gap-2">
                <button onClick={() => { setNotify(g.agency_name ? 'both' : 'girl'); setFlagging(g) }} className="rounded-lg bg-amber-400 px-3 py-1.5 text-xs font-bold text-black active:scale-95">📢 แจ้งแก้</button>
                {g.flagged_at && <button onClick={() => resolve(g)} className="rounded-lg bg-white/10 px-3 py-1.5 text-xs active:scale-95">✓ ปิดเรื่อง</button>}
              </div>
            </li>
          ))}
        </ul>
      )}
      {more && rows && <button onClick={() => load(new Set(rows.map((r) => r.worker_id)).size)} className="w-full rounded-xl bg-white/10 py-2 text-sm">โหลดเพิ่ม</button>}

      {zoom && <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/90 p-3" onClick={() => setZoom(null)}><img src={zoom} alt="" className="max-h-full max-w-full rounded-xl" /></div>}
      {editing && <Editor photo={editing} toast={toast} onClose={() => setEditing(null)} onDone={() => { setEditing(null); load(0) }} />}
      {flagging && (
        <div className="fixed inset-0 z-50 flex items-end justify-center bg-black/70 sm:items-center" onClick={() => setFlagging(null)}>
          <div onClick={(e) => e.stopPropagation()} className="w-full max-w-md space-y-3 rounded-t-3xl bg-neutral-900 p-5 sm:rounded-3xl">
            <h3 className="text-lg font-bold">📢 แจ้งแก้โมเสก: {flagging.display_name}</h3>
            <label className="block text-sm">ข้อความ (น้อง/สังกัดเห็น)<textarea value={note} maxLength={100} rows={3} onChange={(e) => setNote(e.target.value)} className="mt-1 w-full rounded-xl bg-white/10 px-3 py-2 text-base outline-none ring-1 ring-white/10 focus:ring-line" /></label>
            <div className="grid grid-cols-3 gap-2 text-sm">
              {[['girl', 'น้อง'], ['agency', 'สังกัด'], ['both', 'ทั้งสอง']].map(([k, l]) => (
                <button key={k} onClick={() => setNotify(k)} disabled={k !== 'girl' && !flagging.agency_name} className={`rounded-xl py-2 font-semibold disabled:opacity-30 ${notify === k ? 'bg-line text-black' : 'bg-white/10'}`}>{l}</button>
              ))}
            </div>
            {!flagging.agency_name && <p className="text-[11px] text-neutral-500">น้องคนนี้ไม่ได้อยู่ในสังกัด แจ้งได้เฉพาะตัวน้อง</p>}
            <div className="grid grid-cols-2 gap-2">
              <button onClick={() => setFlagging(null)} className="rounded-xl bg-white/10 py-2.5 text-sm">ยกเลิก</button>
              <button onClick={sendFlag} disabled={!note.trim()} className="rounded-xl bg-amber-400 py-2.5 text-sm font-bold text-black disabled:opacity-40">ส่งแจ้ง (LINE)</button>
            </div>
          </div>
        </div>
      )}
    </div>
  )
}
