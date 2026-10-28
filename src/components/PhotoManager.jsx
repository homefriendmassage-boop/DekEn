import { useState } from 'react'
import { useI18n } from '../i18n'
import PhotoUploader from './PhotoUploader'
import { removeStaged, uploadPhoto } from '../lib/photos'

const MAX = 5

// Up to 5 promo pictures. Three kinds of thumbnails:
//   live    - on the profile now. In "edit" mode they can be marked for removal (the admin decides).
//   staged  - attached to the application / the edit request but not decided yet: can be taken back.
//   local   - picked on this phone, not uploaded yet (only while the application does not exist): held in `local`.
// props: userId, state ('application' | 'pending_add'), photos (rows of my_photos), local/setLocal (deferred mode),
//        removeIds/setRemoveIds (edit mode), onChanged()
export default function PhotoManager({ userId, state, photos = [], local, setLocal, removeIds = [], setRemoveIds, onChanged }) {
  const { t } = useI18n()
  const [adding, setAdding] = useState(false)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState(null)

  const live = photos.filter((p) => p.state === 'live')
  const staged = photos.filter((p) => p.state === state)
  const localList = local ?? []
  const keptLive = live.filter((p) => !removeIds.includes(p.id))
  const total = keptLive.length + staged.length + localList.length
  const full = total >= MAX

  async function picked(pic) {
    setError(null)
    setAdding(false)
    if (setLocal) return setLocal((l) => [...l, { key: Math.random().toString(36).slice(2), ...pic }])   // deferred
    setBusy(true)
    try { await uploadPhoto(userId, pic, state); onChanged?.() } catch (e) { console.error(e); setError(t('errUpload')) }
    setBusy(false)
  }

  async function dropStaged(p) {
    setBusy(true)
    try { await removeStaged(p.id); onChanged?.() } catch (e) { console.error(e); setError(t('errGeneric')) }
    setBusy(false)
  }

  const thumb = 'relative aspect-[3/4] overflow-hidden rounded-xl bg-neutral-800 ring-1 ring-white/10'
  const btn = 'absolute right-1 top-1 rounded-full bg-black/70 px-2 py-0.5 text-xs active:scale-95'

  return (
    <div className="space-y-3">
      <div className="flex items-center justify-between">
        <h3 className="text-sm font-bold">{t('photosTitle', { n: total, max: MAX })}</h3>
        {!full && !adding && <button type="button" disabled={busy} onClick={() => setAdding(true)} className="rounded-xl bg-white/10 px-3 py-1.5 text-sm font-semibold active:scale-95">{t('addPhoto')}</button>}
      </div>
      <p className="text-[11px] text-neutral-500">{t('photosHint')}</p>

      <ul className="grid grid-cols-3 gap-2">
        {live.map((p, i) => {
          const marked = removeIds.includes(p.id)
          return (
            <li key={p.id} className={`${thumb} ${marked ? 'opacity-40' : ''}`}>
              <img src={p.public_url} alt="" className="h-full w-full object-cover" />
              {i === 0 && !marked && <span className="absolute left-1 top-1 rounded-full bg-amber-400 px-1.5 text-[10px] font-bold text-black">{t('photoMain')}</span>}
              {setRemoveIds && (
                <button type="button" onClick={() => setRemoveIds((r) => (marked ? r.filter((x) => x !== p.id) : [...r, p.id]))} className={btn}>
                  {marked ? t('photoKeep') : '🗑'}
                </button>
              )}
              {marked && <span className="absolute inset-x-0 bottom-0 bg-red-600/80 py-0.5 text-center text-[10px]">{t('photoRemoving')}</span>}
            </li>
          )
        })}
        {staged.map((p) => (
          <li key={p.id} className={thumb}>
            <img src={p.public_url} alt="" className="h-full w-full object-cover" />
            <span className="absolute inset-x-0 bottom-0 bg-amber-500/90 py-0.5 text-center text-[10px] font-semibold text-black">{t('photoNew')}</span>
            <button type="button" disabled={busy} onClick={() => dropStaged(p)} className={btn}>✕</button>
          </li>
        ))}
        {localList.map((p) => (
          <li key={p.key} className={thumb}>
            <img src={p.url} alt="" className="h-full w-full object-cover" />
            <span className="absolute inset-x-0 bottom-0 bg-amber-500/90 py-0.5 text-center text-[10px] font-semibold text-black">{t('photoNew')}</span>
            <button type="button" onClick={() => setLocal((l) => l.filter((x) => x.key !== p.key))} className={btn}>✕</button>
          </li>
        ))}
      </ul>

      {adding && (
        <div className="space-y-2 rounded-2xl bg-white/5 p-3 ring-1 ring-white/10">
          <PhotoUploader userId={userId} onPicked={picked} />
          <button type="button" onClick={() => setAdding(false)} className="w-full rounded-xl bg-white/10 py-2 text-sm active:scale-95">{t('close')}</button>
        </div>
      )}
      {error && <p className="rounded-lg bg-red-500/10 p-2 text-xs text-red-300">{error}</p>}
    </div>
  )
}

export { uploadPhoto }
