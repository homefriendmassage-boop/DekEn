import { useEffect, useRef, useState } from 'react'
import { supabase } from '../supabaseClient'
import { useI18n } from '../i18n'

const MAX_W = 1080       // downscale big phone photos before upload
const MOSAIC_BLOCKS = 6  // ~6x6 blocks across the circle => face is unrecognisable

const toBlob = (canvas) =>
  new Promise((res, rej) => canvas.toBlob((b) => (b ? res(b) : rej(new Error('encode failed'))), 'image/jpeg', 0.85))

// Mosaic (pixelate) a circular area. Canvas `filter: blur()` is missing on iOS Safari,
// which LINE uses, so we pixelate instead: it works everywhere and can't be "un-blurred".
function mosaicCircle(src, cx, cy, r) {
  const out = document.createElement('canvas')
  out.width = src.width
  out.height = src.height
  const ctx = out.getContext('2d')
  ctx.drawImage(src, 0, 0)

  const d = Math.max(2, Math.round(r * 2))
  const sx = Math.round(cx - r)
  const sy = Math.round(cy - r)
  const tiny = document.createElement('canvas')
  tiny.width = tiny.height = MOSAIC_BLOCKS
  tiny.getContext('2d').drawImage(src, sx, sy, d, d, 0, 0, MOSAIC_BLOCKS, MOSAIC_BLOCKS)

  ctx.save()
  ctx.beginPath()
  ctx.arc(cx, cy, r, 0, Math.PI * 2)
  ctx.clip()
  ctx.imageSmoothingEnabled = false
  ctx.drawImage(tiny, 0, 0, MOSAIC_BLOCKS, MOSAIC_BLOCKS, sx, sy, d, d)
  ctx.restore()
  return out
}

/**
 * The worker picks a photo and drops a circle on their face.
 *  - original  -> PRIVATE bucket `worker-originals` (shown only to eligible members via signed URL)
 *  - mosaicked -> PUBLIC bucket `worker-public`     (the teaser everyone sees)
 * A preview of the public version must be confirmed before anything is uploaded.
 */
export default function PhotoUploader({ userId, previousOriginal, onUploaded }) {
  const { t } = useI18n()
  const boxRef = useRef(null)
  const [src, setSrc] = useState(null)               // object URL of the chosen file
  const [circle, setCircle] = useState({ x: 0.5, y: 0.3, r: 0.18 }) // fractions of image width
  const [preview, setPreview] = useState(null)       // { orig: Blob, pub: Blob, url }
  const [busy, setBusy] = useState(false)
  const [msg, setMsg] = useState(null)

  useEffect(() => () => { src && URL.revokeObjectURL(src); preview && URL.revokeObjectURL(preview.url) }, []) // eslint-disable-line

  function onFile(e) {
    const f = e.target.files?.[0]
    if (!f) return
    setPreview(null)
    setMsg(null)
    setSrc(URL.createObjectURL(f))
  }

  // Tap / drag on the photo to move the circle (touch-action:none stops page scroll while dragging).
  function place(e) {
    const rect = boxRef.current.getBoundingClientRect()
    setCircle((c) => ({
      ...c,
      x: Math.min(1, Math.max(0, (e.clientX - rect.left) / rect.width)),
      y: Math.min(1, Math.max(0, (e.clientY - rect.top) / rect.height)),
    }))
  }

  async function makePreview() {
    setBusy(true)
    setMsg(null)
    try {
      const img = await new Promise((res, rej) => {
        const i = new Image()
        i.onload = () => res(i)
        i.onerror = rej
        i.src = src
      })
      const scale = Math.min(1, MAX_W / img.naturalWidth)
      const w = Math.round(img.naturalWidth * scale)
      const h = Math.round(img.naturalHeight * scale)
      const base = document.createElement('canvas')
      base.width = w
      base.height = h
      base.getContext('2d').drawImage(img, 0, 0, w, h)

      const pubCanvas = mosaicCircle(base, circle.x * w, circle.y * h, circle.r * w)
      const [orig, pub] = await Promise.all([toBlob(base), toBlob(pubCanvas)])
      if (preview) URL.revokeObjectURL(preview.url)
      setPreview({ orig, pub, url: URL.createObjectURL(pub) })
    } catch (e) {
      console.error(e)
      setMsg(t('errUpload'))
    }
    setBusy(false)
  }

  async function upload() {
    setBusy(true)
    setMsg(null)
    try {
      const ts = Date.now()
      const origPath = `${userId}/${ts}.jpg`
      const pubPath = `${userId}/${ts}-public.jpg`

      const up1 = await supabase.storage.from('worker-originals').upload(origPath, preview.orig, { contentType: 'image/jpeg' })
      if (up1.error) throw up1.error
      const up2 = await supabase.storage.from('worker-public').upload(pubPath, preview.pub, { contentType: 'image/jpeg' })
      if (up2.error) throw up2.error

      const url = supabase.storage.from('worker-public').getPublicUrl(pubPath).data.publicUrl
      const { error } = await supabase.from('workers')
        .update({ profile_image: url, original_path: origPath })
        .eq('user_id', userId)
      if (error) throw error

      if (previousOriginal) supabase.storage.from('worker-originals').remove([previousOriginal]) // best effort
      setSrc(null)
      setPreview(null)
      setMsg(t('uploaded'))
      onUploaded?.()
    } catch (e) {
      console.error(e)
      setMsg(t('errUpload'))
    }
    setBusy(false)
  }

  return (
    <div className="space-y-3">
      <p className="text-xs text-neutral-400">{t('photoHelp')}</p>

      <label className="block w-full cursor-pointer rounded-xl bg-white/10 py-2.5 text-center text-sm font-semibold active:scale-95">
        {t('choosePhoto')}
        <input type="file" accept="image/*" className="hidden" onChange={onFile} />
      </label>

      {src && !preview && (
        <>
          <div
            ref={boxRef}
            className="relative w-full touch-none select-none overflow-hidden rounded-xl bg-black"
            onPointerDown={(e) => { e.currentTarget.setPointerCapture(e.pointerId); place(e) }}
            onPointerMove={(e) => e.buttons && place(e)}
          >
            <img src={src} alt="" className="block w-full" draggable={false} />
            <div
              className="pointer-events-none absolute rounded-full border-2 border-amber-400 bg-amber-400/20"
              style={{
                left: `${circle.x * 100}%`,
                top: `${circle.y * 100}%`,
                width: `${circle.r * 200}%`,
                aspectRatio: '1',
                transform: 'translate(-50%, -50%)',
              }}
            />
          </div>
          <label className="block text-xs text-neutral-400">
            {t('faceSize')}
            <input
              type="range" min="0.05" max="0.45" step="0.01" value={circle.r}
              onChange={(e) => setCircle((c) => ({ ...c, r: Number(e.target.value) }))}
              className="mt-1 w-full"
            />
          </label>
          <button onClick={makePreview} disabled={busy} className="w-full rounded-xl bg-amber-400 py-2.5 text-sm font-bold text-black active:scale-95 disabled:opacity-50">
            {t('previewPhoto')}
          </button>
        </>
      )}

      {preview && (
        <>
          <p className="text-xs text-amber-300">{t('publicPreview')}</p>
          <img src={preview.url} alt="" className="w-full rounded-xl" />
          <div className="grid grid-cols-2 gap-3">
            <button onClick={() => setPreview(null)} disabled={busy} className="rounded-xl bg-white/10 py-2.5 text-sm font-semibold active:scale-95">{t('back')}</button>
            <button onClick={upload} disabled={busy} className="rounded-xl bg-line py-2.5 text-sm font-bold text-black active:scale-95 disabled:opacity-50">
              {busy ? t('uploading') : t('confirmUpload')}
            </button>
          </div>
        </>
      )}

      {msg && <p className="text-sm text-neutral-300">{msg}</p>}
    </div>
  )
}
