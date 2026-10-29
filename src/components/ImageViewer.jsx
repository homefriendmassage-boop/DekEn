import { useState } from 'react'
import { useI18n } from '../i18n'

// Full-screen viewer: tap the picture to zoom (2.5x, scroll to look around), ‹ › to change picture, ✕ or the dark area to close.
export default function ImageViewer({ images, index = 0, alt = '', onClose }) {
  const { t } = useI18n()
  const [idx, setIdx] = useState(index)
  const [zoom, setZoom] = useState(false)
  const n = images.length
  const go = (d) => { setZoom(false); setIdx((i) => (i + d + n) % n) }
  return (
    <div onClick={(e) => { e.stopPropagation(); onClose() }} className="fixed inset-0 z-[80] flex flex-col bg-black">
      <div className="flex items-center justify-between px-4 py-3 text-sm" onClick={(e) => e.stopPropagation()}>
        <span className="text-neutral-300">{n > 1 ? `${idx + 1} / ${n}` : ''}</span>
        <button onClick={onClose} aria-label={t('close')} className="rounded-full bg-white/15 px-3 py-1 active:scale-95">✕</button>
      </div>
      <div className="flex-1 overflow-auto" onClick={(e) => e.stopPropagation()}>
        <img src={images[idx]} alt={alt} draggable={false} onClick={() => setZoom((z) => !z)} className="mx-auto block select-none"
          style={zoom ? { width: '250%', maxWidth: 'none' } : { maxWidth: '100%', maxHeight: 'calc(100vh - 110px)', objectFit: 'contain', margin: '0 auto' }} />
      </div>
      <div className="flex items-center justify-center gap-4 px-4 pb-5 pt-2" onClick={(e) => e.stopPropagation()}>
        {n > 1 && <button onClick={() => go(-1)} className="rounded-full bg-white/15 px-5 py-2 text-lg active:scale-95">‹</button>}
        <span className="text-xs text-neutral-400">{zoom ? t('tapToShrink') : t('tapToZoom')}</span>
        {n > 1 && <button onClick={() => go(1)} className="rounded-full bg-white/15 px-5 py-2 text-lg active:scale-95">›</button>}
      </div>
    </div>
  )
}
