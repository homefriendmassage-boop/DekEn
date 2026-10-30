import ImageViewer from './ImageViewer'
import LinkSheet from './LinkSheet'
import { useEffect, useState } from 'react'
import { supabase } from '../supabaseClient'
import { useI18n } from '../i18n'
import { logoUrl } from '../lib/logo'
import { feeFor, withFee } from '../lib/booking'
import { appLink, workerBubble } from '../lib/flex'

export function LocBadge({ verified }) {
  const { t } = useI18n()
  return (
    <span className={`rounded-full px-2 py-0.5 text-[10px] font-semibold ${verified ? 'bg-green-500/20 text-green-300' : 'bg-amber-400/20 text-amber-300'}`}>
      {verified ? t('locVerifiedBadge') : t('locSelfBadge')}
    </span>
  )
}

export const priceLabel = (label, t) => ({ '1h': t('price1h'), '@4h': t('price4h'), '@6h': t('price6h'), '@60': t('price60'), '@90': t('price90'), '@120': t('price120') }[label] ?? label)

// All of a provider's rates as [key, label, price], in display order: 4 h, 6 h, hourly, then her own rows.
export function ratesOf(w, t) {
  const rows = Array.isArray(w.price_options) ? w.price_options : []
  const rank = (l) => ({ '@60': 0, '@90': 1, '@120': 2, '@4h': 3, '@6h': 4, '1h': 5 }[l] ?? 9)
  const list = rows.map((o, i) => [o.label, priceLabel(o.label, t), o.price, i]).sort((a, b) => rank(a[0]) - rank(b[0]) || a[3] - b[3])
  return list.length ? list.map(([k, l, p]) => [k, l, p]) : [['1h', t('price1h'), w.price]]
}

// Full profile of one provider (only reached for providers the viewer may open). Chat and booking start from here.
export default function WorkerDetail({ worker: w, onClose, onBook, onAsk, onUnlock, isMe, agencyView }) {
  const { t, money, catName } = useI18n()
  const [imgs, setImgs] = useState([])      // gallery: the clear picture where the viewer may see it, else the mosaic
  const [idx, setIdx] = useState(0)
  const [viewer, setViewer] = useState(false)   // full-screen viewer of the picture
  useEffect(() => {
    let alive = true
    ;(async () => {
      const { data } = await supabase.rpc('worker_photos', { p_worker: w.user_id })
      const rows = data ?? []
      const paths = rows.filter((r) => r.original_path).map((r) => r.original_path)
      const signed = {}
      if (paths.length) {
        const { data: urls } = await supabase.storage.from('worker-originals').createSignedUrls(paths, 3600)
        urls?.forEach((u) => { if (u.signedUrl) signed[u.path] = u.signedUrl })
      }
      if (alive) setImgs(rows.map((r) => ({ id: r.id, url: (r.original_path && signed[r.original_path]) || r.public_url })))
    })()
    return () => { alive = false }
  }, [w.user_id, w.canView])
  const [shareNote, setShareNote] = useState(null)
  const [reporting, setReporting] = useState(false)
  const [rep, setRep] = useState({ reason: 'fake_photo', note: '' })
  const [repMsg, setRepMsg] = useState(null)

  async function sendReport() {
    const { error } = await supabase.rpc('report_worker', { p_worker: w.user_id, p_reason: rep.reason, p_note: rep.note })
    if (error) return setRepMsg(t(error.message.includes('ALREADY_REPORTED') ? 'reportAlready' : 'errGeneric'))
    setRepMsg(t('reportSent'))
  }

  // The public photo + details, no price and no location. The link brings the friend back to this profile: Flex card, copy or QR.
  const [shareSheet, setShareSheet] = useState(null)   // { link, flex }
  async function shareWorker() {
    setShareNote(null)
    try {
      const { data } = await supabase.rpc('my_referral_stats')
      const code = data?.[0]?.code
      const uri = appLink({ ...(code ? { ref: code } : {}), worker: w.user_id })
      const lines = [
        w.gender && t(`gender_${w.gender}`), w.age && `${w.age} ${t('yearsShort')}`,
        w.height_cm && `${t('fHeight')} ${w.height_cm}`, w.weight_kg && `${t('fWeight')} ${w.weight_kg}`, w.measurements,
      ].filter(Boolean).join(' · ')
      setShareSheet({
        link: uri,
        flex: {
          type: 'flex',
          altText: t('shareWorkerAlt', { name: w.display_name, app: 'DekEn' }),
          contents: workerBubble({
            w, facts: lines, tags: (w.tags ?? []).map((k) => `#${t(`tag_${k}`)}`).join(' '), about: w.about,
            button: t('shareWorkerBtn'), uri, logoLabel: 'DekEn',
          }),
        },
      })
    } catch { setShareNote(t('shareFailed')) }
  }

  const facts = [
    w.gender && [t('fGender'), t(`gender_${w.gender}`)],
    w.age && [t('fAge'), `${w.age}`],
    w.height_cm && [t('fHeight'), `${w.height_cm}`],
    w.weight_kg && [t('fWeight'), `${w.weight_kg}`],
    w.measurements && [t('fMeasure'), w.measurements],
    w.service_mode && [t('fServiceMode'), t(`serviceMode_${w.service_mode}`)],
    w.province && [t('fProvince'), `${w.province}${w.district ? ` · ${w.district}` : ''}`],
  ].filter(Boolean)
  const prices = ratesOf(w, t)

  return (
    <div className="fixed inset-0 z-50 flex items-end justify-center bg-black/70 sm:items-center sm:p-4" onClick={onClose} role="dialog" aria-modal="true">
      <div onClick={(e) => e.stopPropagation()}
        className="max-h-[94vh] w-full max-w-md overflow-y-auto rounded-t-3xl bg-neutral-900 shadow-2xl sm:rounded-3xl">
        <div className="relative h-[52vh] w-full overflow-hidden bg-neutral-950">
          {(imgs[idx]?.url ?? w.image) && (
            <button type="button" onClick={() => (w.canView ? setViewer(true) : onUnlock?.())} aria-label={w.canView ? t('viewFull') : t('unlockDetails')} className="block h-full w-full">
              <img src={imgs[idx]?.url ?? w.image} alt={w.display_name} draggable={false} className="h-full w-full select-none object-contain" />
            </button>
          )}
          {(imgs[idx]?.url ?? w.image) && <span className="pointer-events-none absolute bottom-3 right-3 rounded-full bg-black/60 px-2 py-0.5 text-[10px] text-neutral-200">{w.canView ? `🔍 ${t('viewFull')}` : `🔒 ${t('unlockPhoto')}`}</span>}
          <button onClick={onClose} aria-label={t('close')} className="absolute right-3 top-3 rounded-full bg-black/60 px-3 py-1 text-sm active:scale-95">✕</button>
          {w.agency_logo && (
            <span className="absolute bottom-3 left-3 flex items-center gap-1 rounded-full bg-black/60 py-0.5 pl-0.5 pr-2 text-xs">
              <img src={logoUrl(w.agency_logo)} alt="" className="h-5 w-5 rounded-full object-cover" /> {w.agency_name}
            </span>
          )}
        </div>

        <div className="space-y-4 p-4 pb-[calc(1rem+env(safe-area-inset-bottom))]">
          {imgs.length > 1 && (
            <ul className="flex gap-2 overflow-x-auto">
              {imgs.map((im, i) => (
                <li key={im.id} className="shrink-0">
                  <button onClick={() => setIdx(i)} className={`block h-16 w-12 overflow-hidden rounded-lg ring-2 ${i === idx ? 'ring-pink-400' : 'ring-transparent'}`}>
                    <img src={im.url} alt="" className="h-full w-full object-cover" />
                  </button>
                </li>
              ))}
            </ul>
          )}
          <div>
            <h2 className="text-xl font-bold">{w.display_name}</h2>
            <div className="mt-1 flex flex-wrap items-center gap-1">
              {(w.categories ?? [w.category]).map((c) => <span key={c} className="rounded-full bg-white/10 px-2 py-0.5 text-xs text-neutral-300">{catName(c)}</span>)}
              <span className={`text-xs ${w.is_online && w.is_busy ? 'text-amber-300' : w.is_online ? 'text-green-400' : 'text-neutral-400'}`}>● {w.is_online && w.is_busy ? t('busyNow') : w.is_online ? t('online') : t('offline')}</span>
              {w.distance_km != null && <span className="text-xs text-amber-300">📍 {t('kmAway', { n: w.distance_km })}</span>}
              {w.province && <LocBadge verified={!!w.loc_verified} />}
            </div>
            {w.province && !w.loc_verified && <p className="mt-1 text-[11px] text-amber-200/80">{t('locSelfNote')}</p>}
          </div>
          {!w.canView && <p className="rounded-xl bg-amber-400/10 p-3 text-xs text-amber-200">{t('blurredNote')}</p>}
          {w.claimed === false && <p className="rounded-xl bg-amber-400/10 p-3 text-xs text-amber-200">⏳ {t('unclaimedNote')}</p>}

          {facts.length > 0 && (
            <dl className="grid grid-cols-2 gap-2">
              {facts.map(([k, v]) => (
                <div key={k} className="rounded-xl bg-white/5 p-2.5">
                  <dt className="text-[11px] text-neutral-400">{k}</dt>
                  <dd className="text-sm font-semibold">{v}</dd>
                </div>
              ))}
            </dl>
          )}

          {(w.tags?.length > 0 || w.about) && (
            <div className="space-y-2">
              {w.tags?.length > 0 && (
                <div className="flex flex-wrap gap-1.5">
                  {w.tags.map((k) => <span key={k} className="rounded-full bg-pink-500/15 px-2.5 py-1 text-xs text-pink-200">{t(`tag_${k}`)}</span>)}
                </div>
              )}
              {w.about && <p className="whitespace-pre-wrap break-words rounded-xl bg-white/5 p-3 text-sm text-neutral-200">{w.about}</p>}
            </div>
          )}

          <div>
            <h3 className="mb-1 text-sm font-semibold">{t('priceTable')}</h3>
            <ul className="divide-y divide-white/5 rounded-xl bg-white/5 text-sm">
              {prices.map(([key, label, price]) => (
                <li key={key} className="flex items-center justify-between px-3 py-2">
                  <span>{label}{(w.start_rate || prices[0]?.[0]) === key && <span className="ml-2 rounded-full bg-amber-400 px-2 py-0.5 text-[10px] font-bold text-black">{t('startHere')}</span>}</span><b>{money(withFee(price, w.categories))}</b></li>
              ))}
            </ul>
            <p className="mt-1 text-[11px] text-neutral-500">{t('priceNote', { fee: money(feeFor(w.categories)) })}</p>
          </div>

          {(
            <button onClick={shareWorker} className="w-full rounded-xl bg-white/10 py-2.5 text-sm font-bold active:scale-95">🔗 {t('shareWorker')}</button>
          )}
          {shareNote && <p className="text-xs text-amber-200">{shareNote}</p>}

          {!isMe && !agencyView && <button onClick={() => { setReporting(true); setRepMsg(null) }} className="text-[11px] text-neutral-500 underline">🚩 {t('reportProfile')}</button>}

          {agencyView ? (
            <p className="rounded-xl bg-white/10 py-2.5 text-center text-sm font-semibold text-neutral-300">🏢 น้องในสังกัดของคุณ</p>
          ) : isMe ? (
            <p className="rounded-xl bg-white/10 py-2.5 text-center text-sm font-semibold text-neutral-300">{t('ownProfile')}</p>
          ) : (
            w.claimed === false ? null : <div className="grid gap-2">
              <button onClick={onAsk} className="rounded-xl bg-pink-500 py-3 font-bold text-white active:scale-95">💬 {t('chatDirect')}</button>
              {w.canView ? (
                <button onClick={onBook} disabled={!w.is_online}
                  className="rounded-xl bg-line py-3 font-bold text-black active:scale-95 disabled:bg-neutral-700 disabled:text-neutral-400">
                  {w.is_online ? t('bookThis') : t('unavailable')}
                </button>
              ) : (
                <button onClick={onUnlock} className="rounded-xl bg-amber-400 py-3 font-bold text-black active:scale-95">{t('unlockFace')}</button>
              )}
            </div>
          )}
        </div>
      </div>

      {shareSheet && <LinkSheet title={w.display_name} intro={t('shareWorkerHint')} link={shareSheet.link} flex={shareSheet.flex} onClose={() => setShareSheet(null)} />}

      {viewer && w.canView && <ImageViewer images={(imgs.length ? imgs.map((i) => i.url) : [w.image]).filter(Boolean)} index={Math.min(idx, Math.max(0, imgs.length - 1))} alt={w.display_name} onClose={() => setViewer(false)} />}

      {reporting && (
        <div onClick={(e) => { e.stopPropagation(); setReporting(false) }} className="absolute inset-0 z-10 flex items-center justify-center bg-black/60 p-6">
          <div onClick={(e) => e.stopPropagation()} className="w-full max-w-sm space-y-3 rounded-2xl bg-neutral-800 p-4 shadow-xl">
            <h3 className="text-base font-bold">🚩 {t('reportProfile')}</h3>
            <p className="text-xs text-neutral-400">{t('reportProfileHint')}</p>
            <select value={rep.reason} onChange={(e) => setRep((r) => ({ ...r, reason: e.target.value }))} className="w-full rounded-xl bg-white/10 px-3 py-2 text-sm">
              {['fake_photo', 'underage', 'contact', 'fraud', 'other'].map((k) => <option key={k} value={k} className="text-black">{t(`reportP_${k}`)}</option>)}
            </select>
            <textarea rows={3} maxLength={500} value={rep.note} onChange={(e) => setRep((r) => ({ ...r, note: e.target.value }))} placeholder={t('reportNote')} className="w-full rounded-xl bg-white/10 px-3 py-2 text-sm" />
            {repMsg && <p className="text-xs text-amber-200">{repMsg}</p>}
            <div className="grid grid-cols-2 gap-2">
              <button onClick={() => setReporting(false)} className="rounded-xl bg-white/10 py-2 font-semibold active:scale-95">{t('close')}</button>
              <button onClick={sendReport} className="rounded-xl bg-red-500 py-2 font-bold active:scale-95">{t('reportSend')}</button>
            </div>
          </div>
        </div>
      )}
    </div>
  )
}
