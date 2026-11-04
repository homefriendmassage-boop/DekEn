import { useEffect, useRef, useState } from 'react'
import { supabase } from '../supabaseClient'

const MAX_W = 1080
const BLOCKS = 6
const toBlob = (cv) => new Promise((res, rej) => cv.toBlob((b) => (b ? res(b) : rej(new Error('encode failed'))), 'image/jpeg', 0.85))
// same pixelation as the uploader (works on iOS Safari, cannot be un-blurred)
function mosaicCircle(src, cx, cy, r) {
  const out = document.createElement('canvas'); out.width = src.width; out.height = src.height
  const ctx = out.getContext('2d'); ctx.drawImage(src, 0, 0)
  const d = Math.max(2, Math.round(r * 2)); const sx = Math.round(cx - r); const sy = Math.round(cy - r)
  const tiny = document.createElement('canvas'); tiny.width = tiny.height = BLOCKS
  tiny.getContext('2d').drawImage(src, sx, sy, d, d, 0, 0, BLOCKS, BLOCKS)
  ctx.save(); ctx.beginPath(); ctx.arc(cx, cy, r, 0, Math.PI * 2); ctx.clip(); ctx.imageSmoothingEnabled = false
  ctx.drawImage(tiny, 0, 0, BLOCKS, BLOCKS, sx, sy, d, d); ctx.restore()
  return out
}

// Place the mosaic again from a private original (admin, or the agency for its own girls).
// onSave(blob) receives the new PUBLIC picture (a JPEG blob) and uploads / stores it; the original is never changed.
export default function MosaicEditor({ title, originalPath, onClose, onSave, saveLabel = 'ยืนยัน แทนที่รูปเดิม', toast }) {
  const boxRef = useRef(null)
  const dragging = useRef(-1)
  const [src, setSrc] = useState(null)
  const [circles, setCircles] = useState([{ x: 0.5, y: 0.3, r: 0.18 }])
  const [sel, setSel] = useState(0)
  const [preview, setPreview] = useState(null)
  const [busy, setBusy] = useState(false)
  useEffect(() => {
    supabase.storage.from('worker-originals').createSignedUrl(originalPath, 600).then(({ data, error }) => {
      if (error || !data?.signedUrl) { toast?.('เปิดรูปต้นฉบับไม่ได้'); onClose(); return }
      setSrc(data.signedUrl)
    })
  }, []) // eslint-disable-line react-hooks/exhaustive-deps
  const place = (e, i) => {
    const rect = boxRef.current.getBoundingClientRect()
    setCircles((cs) => cs.map((c, k) => (k !== i ? c : { ...c, x: Math.min(1, Math.max(0, (e.clientX - rect.left) / rect.width)), y: Math.min(1, Math.max(0, (e.clientY - rect.top) / rect.height)) })))
  }
  async function makePreview() {
    setBusy(true)
    try {
      const img = await new Promise((res, rej) => { const i = new Image(); i.crossOrigin = 'anonymous'; i.onload = () => res(i); i.onerror = rej; i.src = src })
      const scale = Math.min(1, MAX_W / img.naturalWidth)
      const w = Math.round(img.naturalWidth * scale); const h = Math.round(img.naturalHeight * scale)
      const base = document.createElement('canvas'); base.width = w; base.height = h
      base.getContext('2d').drawImage(img, 0, 0, w, h)
      const pub = await toBlob(circles.reduce((cv, c) => mosaicCircle(cv, c.x * w, c.y * h, c.r * w), base))
      if (preview) URL.revokeObjectURL(preview.url)
      setPreview({ blob: pub, url: URL.createObjectURL(pub) })
    } catch (e) { console.error(e); toast?.('สร้างตัวอย่างไม่สำเร็จ') }
    setBusy(false)
  }
  async function save() {
    setBusy(true)
    try { await onSave(preview.blob) } catch (e) { console.error(e); toast?.('บันทึกไม่สำเร็จ') }
    setBusy(false)
  }
  return (
    <div className="fixed inset-0 z-[65] flex items-end justify-center bg-black/80 sm:items-center sm:p-4" onClick={(e) => { e.stopPropagation(); onClose() }}>
      <div onClick={(e) => e.stopPropagation()} className="max-h-[94vh] w-full max-w-md space-y-3 overflow-y-auto rounded-t-3xl bg-neutral-900 p-5 sm:rounded-3xl">
        <div className="flex items-center justify-between"><h3 className="text-lg font-bold">🎨 วางโมเสก: {title}</h3><button onClick={onClose} className="rounded-full bg-white/10 px-3 py-1 text-sm">✕</button></div>
        {!src ? <p className="py-8 text-center text-neutral-500">กำลังโหลดรูปต้นฉบับ…</p> : !preview ? (
          <>
            <div ref={boxRef} className="relative mx-auto w-fit max-w-full select-none overflow-hidden rounded-xl bg-black">
              <img src={src} alt="" className="block max-h-[50vh] w-auto max-w-full" draggable={false} />
              {circles.map((c, i) => (
                <div key={i} className={`absolute cursor-grab touch-none rounded-full border-2 ${i === sel ? 'border-amber-400 bg-amber-400/25' : 'border-dashed border-white/80 bg-white/10'}`}
                  style={{ left: `${c.x * 100}%`, top: `${c.y * 100}%`, width: `${c.r * 200}%`, aspectRatio: '1', transform: 'translate(-50%, -50%)', zIndex: i === sel ? 2 : 1 }}
                  onPointerDown={(e) => { dragging.current = i; setSel(i); e.currentTarget.setPointerCapture(e.pointerId); e.preventDefault() }}
                  onPointerMove={(e) => { if (dragging.current === i) place(e, i) }} onPointerUp={() => { dragging.current = -1 }} onPointerCancel={() => { dragging.current = -1 }}>
                  <span className="absolute left-1/2 top-1/2 -translate-x-1/2 -translate-y-1/2 text-lg opacity-80">{i === 0 ? '✥' : i + 1}</span>
                </div>
              ))}
            </div>
            <label className="block text-xs text-neutral-400">ขนาดวงที่เลือก
              <input type="range" min="0.03" max="0.45" step="0.01" value={circles[sel]?.r ?? 0.18} className="mt-1 w-full"
                onChange={(e) => setCircles((cs) => cs.map((c, k) => (k === sel ? { ...c, r: Number(e.target.value) } : c)))} /></label>
            <p className="text-[11px] text-neutral-500">วงแรกคือใบหน้า ลากเพื่อย้าย แตะวงเพื่อเลือก เพิ่มจุดได้ถึง 8 จุด (หน้าอื่นในรูปรวม รอยสัก ป้ายชื่อ)</p>
            <div className="grid grid-cols-2 gap-2">
              <button onClick={() => { setCircles((cs) => [...cs, { x: 0.5, y: 0.6, r: 0.08 }].slice(0, 8)); setSel(circles.length) }} disabled={circles.length >= 8} className="rounded-xl bg-white/10 py-2 text-sm disabled:opacity-40">➕ เพิ่มจุดโมเสก</button>
              <button onClick={() => { if (sel === 0) return; setCircles((cs) => cs.filter((_, k) => k !== sel)); setSel(0) }} disabled={sel === 0} className="rounded-xl bg-white/10 py-2 text-sm disabled:opacity-40">🗑 ลบจุดนี้</button>
            </div>
            <button onClick={makePreview} disabled={busy} className="w-full rounded-xl bg-amber-400 py-2.5 text-sm font-bold text-black disabled:opacity-50">{busy ? '…' : 'ดูตัวอย่างรูปสาธารณะ'}</button>
          </>
        ) : (
          <>
            <p className="text-xs text-amber-300">นี่คือรูปที่ทุกคนจะเห็น ตรวจว่าทุกหน้าถูกโมเสกแล้ว</p>
            <img src={preview.url} alt="" className="mx-auto block max-h-[52vh] w-auto max-w-full rounded-xl" />
            <div className="grid grid-cols-2 gap-2">
              <button onClick={() => setPreview(null)} disabled={busy} className="rounded-xl bg-white/10 py-2.5 text-sm">แก้ต่อ</button>
              <button onClick={save} disabled={busy} className="rounded-xl bg-line py-2.5 text-sm font-bold text-black disabled:opacity-50">{busy ? 'กำลังบันทึก…' : saveLabel}</button>
            </div>
          </>
        )}
      </div>
    </div>
  )
}
