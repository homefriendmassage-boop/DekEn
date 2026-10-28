import { useI18n } from '../i18n'
import { logoUrl } from '../lib/logo'

export const priceLabel = (label, t) => (label === '@4h' ? t('price4h') : label === '@6h' ? t('price6h') : label)

// Full profile of one provider (only reached for providers the viewer may open). Chat and booking start from here.
export default function WorkerDetail({ worker: w, onClose, onBook, onAsk, isMe }) {
  const { t, money, catName } = useI18n()
  const facts = [
    w.gender && [t('fGender'), t(`gender_${w.gender}`)],
    w.age && [t('fAge'), `${w.age}`],
    w.height_cm && [t('fHeight'), `${w.height_cm}`],
    w.weight_kg && [t('fWeight'), `${w.weight_kg}`],
    w.measurements && [t('fMeasure'), w.measurements],
    w.province && [t('fProvince'), `${w.province}${w.district ? ` · ${w.district}` : ''}`],
  ].filter(Boolean)
  const prices = [[t('price1h'), w.price], ...(w.price_options ?? []).map((o) => [priceLabel(o.label, t), o.price])]

  return (
    <div className="fixed inset-0 z-50 flex items-end justify-center bg-black/70 sm:items-center sm:p-4" onClick={onClose} role="dialog" aria-modal="true">
      <div onClick={(e) => e.stopPropagation()}
        className="max-h-[94vh] w-full max-w-md overflow-y-auto rounded-t-3xl bg-neutral-900 shadow-2xl sm:rounded-3xl">
        <div className="relative aspect-[3/4] max-h-[52vh] w-full overflow-hidden bg-neutral-800">
          {w.image && <img src={w.image} alt={w.display_name} draggable={false} className="h-full w-full select-none object-cover" />}
          <button onClick={onClose} aria-label={t('close')} className="absolute right-3 top-3 rounded-full bg-black/60 px-3 py-1 text-sm active:scale-95">✕</button>
          {w.agency_logo && (
            <span className="absolute bottom-3 left-3 flex items-center gap-1 rounded-full bg-black/60 py-0.5 pl-0.5 pr-2 text-xs">
              <img src={logoUrl(w.agency_logo)} alt="" className="h-5 w-5 rounded-full object-cover" /> {w.agency_name}
            </span>
          )}
        </div>

        <div className="space-y-4 p-4 pb-[calc(1rem+env(safe-area-inset-bottom))]">
          <div>
            <h2 className="text-xl font-bold">{w.display_name}</h2>
            <div className="mt-1 flex flex-wrap items-center gap-1">
              {(w.categories ?? [w.category]).map((c) => <span key={c} className="rounded-full bg-white/10 px-2 py-0.5 text-xs text-neutral-300">{catName(c)}</span>)}
              <span className={`text-xs ${w.is_online ? 'text-green-400' : 'text-neutral-400'}`}>● {w.is_online ? t('online') : t('offline')}</span>
              {w.distance_km != null && <span className="text-xs text-amber-300">📍 {t('kmAway', { n: w.distance_km })}</span>}
            </div>
          </div>

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
              {prices.map(([label, price], i) => (
                <li key={i} className="flex items-center justify-between px-3 py-2"><span>{label}</span><b>{money(price)}</b></li>
              ))}
            </ul>
            <p className="mt-1 text-[11px] text-neutral-500">{t('priceNote')}</p>
          </div>

          {isMe ? (
            <p className="rounded-xl bg-white/10 py-2.5 text-center text-sm font-semibold text-neutral-300">{t('ownProfile')}</p>
          ) : (
            <div className="grid gap-2">
              <button onClick={onAsk} className="rounded-xl bg-pink-500 py-3 font-bold text-white active:scale-95">💬 {t('chatDirect')}</button>
              <button onClick={onBook} disabled={!w.is_online}
                className="rounded-xl bg-line py-3 font-bold text-black active:scale-95 disabled:bg-neutral-700 disabled:text-neutral-400">
                {w.is_online ? t('bookThis') : t('unavailable')}
              </button>
            </div>
          )}
        </div>
      </div>
    </div>
  )
}
