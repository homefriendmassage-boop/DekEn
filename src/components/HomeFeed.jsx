import { useState } from 'react'
import { FREE_RANK_LIMIT, MIN_TIER } from '../config'
import { useI18n } from '../i18n'
import { logoUrl } from '../lib/logo'
import { withFee } from '../lib/booking'
import WorkerDetail, { LocBadge, priceLabel } from './WorkerDetail'

/**
 * Grid of workers in one category. Mobile-first: 2 columns on phones, 3 on tablets+.
 *
 * Access is decided by the DATABASE (list_workers -> w.can_view):
 *  - can_view  : full photo (signed URL of the private original) + Book button
 *  - !can_view : public teaser (the worker's own face-mosaicked photo) + lock + Unlock button
 * The browser never receives the full photo of a worker it isn't allowed to see.
 */
export default function HomeFeed({ workers, category, tier, loading, onBook, onUnlock, onAsk, meId, nearOn, nearBusy, onToggleNear }) {
  const { t } = useI18n()
  const freeCategory = MIN_TIER[category] === 0
  const [province, setProvince] = useState('')
  const provinces = [...new Set(workers.map((w) => w.province).filter(Boolean))].sort()
  const shown = province ? workers.filter((w) => w.province === province) : workers
  const canChat = tier >= 1 // paid members only: keeps casual chatting (and its cost) out
  const [detail, setDetail] = useState(null)

  return (
    <div>
      {tier === 0 && freeCategory && (
        <div className="mx-3 mt-3 rounded-xl border border-amber-400/30 bg-amber-400/10 px-3 py-2 text-xs text-amber-200 sm:text-sm">
          🔒 {t('freeLimitNote', { n: FREE_RANK_LIMIT })}
        </div>
      )}

      <div className="flex gap-2 px-3 pt-3">
        {onToggleNear && (
          <button onClick={onToggleNear} disabled={nearBusy}
            className={`shrink-0 rounded-xl px-3 py-2 text-sm font-semibold ring-1 active:scale-95 disabled:opacity-50 ${nearOn ? 'bg-line text-black ring-line' : 'bg-white/10 ring-white/10'}`}>
            {nearBusy ? '…' : nearOn ? `✓ ${t('nearMe')}` : t('nearMe')}
          </button>
        )}
        {provinces.length > 0 && (
          <select
            value={province} onChange={(e) => setProvince(e.target.value)}
            className="w-full rounded-xl bg-white/10 px-3 py-2 text-sm outline-none ring-1 ring-white/10"
          >
            <option value="" className="text-black">📍 {t('allProvinces')}</option>
            {provinces.map((p) => <option key={p} value={p} className="text-black">{p}</option>)}
          </select>
        )}
      </div>

      {loading ? (
        <p className="py-20 text-center text-neutral-500">{t('loading')}</p>
      ) : shown.length === 0 ? (
        <p className="py-20 text-center text-neutral-500">{nearOn ? t('nearEmpty') : t('noWorkers')}</p>
      ) : (
        <ul className="grid grid-cols-2 gap-3 p-3 sm:grid-cols-3 sm:gap-4">
          {shown.map((w) => (
            <WorkerCard key={w.user_id} worker={w} onUnlock={onUnlock} onDetail={() => setDetail(w)} isMe={w.user_id === meId} />
          ))}
        </ul>
      )}

      {detail && (
        <WorkerDetail worker={detail} isMe={detail.user_id === meId} onClose={() => setDetail(null)}
          onUnlock={() => { setDetail(null); onUnlock() }}
          onBook={() => { const w = detail; setDetail(null); onBook(w) }}
          onAsk={() => { const w = detail; setDetail(null); if (canChat) onAsk(w); else onUnlock() }} />
      )}
    </div>
  )
}

function WorkerCard({ worker: w, onUnlock, onDetail, isMe }) {
  const { t, money, catName } = useI18n()
  const locked = !w.canView

  return (
    <li
      className={`relative overflow-hidden rounded-2xl bg-neutral-900 ring-1 ${
        w.is_boosted ? 'ring-2 ring-amber-400 shadow-[0_0_20px_rgba(251,191,36,0.25)]' : 'ring-white/10'
      }`}
    >
      {/* overflow-hidden on the card stops the blur bleeding outside */}
      <div className="relative aspect-[3/4] w-full overflow-hidden bg-neutral-800">
        {w.image && (
          <img
            src={w.image}
            alt={locked ? '' : w.display_name}
            loading="lazy"
            draggable={false}
            // Real teasers are already mosaicked by the worker; `demo` rows get a CSS blur instead.
            className={`h-full w-full select-none object-cover ${locked && w.demo ? 'filter blur-md scale-110' : ''}`}
          />
        )}

        {locked && (
          <div className="absolute inset-0 flex items-center justify-center bg-black/25">
            <span className="rounded-full bg-black/60 px-3 py-1 text-xs font-semibold">{t('vipOnly')}</span>
          </div>
        )}

        {w.is_boosted && (
          <span className="absolute left-2 top-2 flex items-center gap-1 rounded-full bg-gradient-to-r from-amber-300 to-orange-500 px-2 py-0.5 text-[10px] font-extrabold uppercase tracking-wide text-black shadow sm:text-xs">
            {t('topRank')}
          </span>
        )}

        {w.agency_logo && (
          <span className="absolute bottom-2 left-2 flex max-w-[80%] items-center gap-1 rounded-full bg-black/60 py-0.5 pl-0.5 pr-2 text-[10px] sm:text-xs">
            <img src={logoUrl(w.agency_logo)} alt="" className="h-5 w-5 shrink-0 rounded-full object-cover" />
            <span className="truncate">{w.agency_name}</span>
          </span>
        )}

        <span
          className={`absolute right-2 top-2 flex items-center gap-1 rounded-full bg-black/60 px-2 py-0.5 text-[10px] sm:text-xs ${
            w.is_online ? 'text-green-400' : 'text-neutral-400'
          }`}
        >
          <span className={`h-1.5 w-1.5 rounded-full ${w.is_online ? 'bg-green-400' : 'bg-neutral-500'}`} />
          {w.is_online ? t('online') : t('offline')}
        </span>
      </div>

      <div className="space-y-2 p-3">
        <div>
          <h2 className="truncate text-sm font-bold sm:text-base">{w.display_name}</h2>
          <div className="mt-1 flex flex-wrap gap-1">
            {(w.categories ?? [w.category]).map((c) => (
              <span key={c} className="rounded-full bg-white/10 px-2 py-0.5 text-[10px] text-neutral-300 sm:text-xs">{catName(c)}</span>
            ))}
          </div>
        </div>
        {w.distance_km != null && <p className="text-[11px] font-semibold text-amber-300 sm:text-xs">📍 {t('kmAway', { n: w.distance_km })}</p>}
        {w.province && <div><LocBadge verified={!!w.loc_verified} /></div>}
        {w.province && (
          <p className="truncate text-[11px] text-neutral-400 sm:text-xs">
            📍 {w.province}{w.district ? ` · ${w.district}` : ''}
            {w.nearby ? ` (${t('nearbyLabel')}: ${w.nearby})` : ''}
          </p>
        )}
        <p className="text-xs text-neutral-400 sm:text-sm">
          {t('from')} <span className="font-semibold text-white">{money(withFee(w.start_price ?? w.price))}</span>
          {w.start_rate && <span className="text-[10px] text-neutral-500"> / {priceLabel(w.start_rate, t)}</span>}
        </p>
        {isMe ? (
          <p className="rounded-xl bg-white/10 py-2.5 text-center text-sm font-semibold text-neutral-300">{t('ownProfile')}</p>
        ) : locked ? (
          <div className="grid gap-1.5">
            <button onClick={onDetail} className="w-full rounded-xl bg-pink-500 py-2.5 text-sm font-bold text-white transition active:scale-95">{t('viewDetail')}</button>
            <button onClick={onUnlock} className="w-full rounded-xl bg-amber-400 py-2 text-xs font-bold text-black transition active:scale-95">👑 {t('unlock')}</button>
          </div>
        ) : (
          <button onClick={onDetail} className="w-full rounded-xl bg-pink-500 py-2.5 text-sm font-bold text-white transition active:scale-95">
            {t('viewDetail')}
          </button>
        )}
      </div>
    </li>
  )
}
