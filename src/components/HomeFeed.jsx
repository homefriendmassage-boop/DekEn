import { FREE_RANK_LIMIT, MIN_TIER } from '../config'
import { useI18n } from '../i18n'

/**
 * Grid of workers in one category. Mobile-first: 2 columns on phones, 3 on tablets+.
 *
 * Access is decided by the DATABASE (list_workers -> w.can_view):
 *  - can_view  : full photo (signed URL of the private original) + Book button
 *  - !can_view : public teaser (the worker's own face-mosaicked photo) + lock + Unlock button
 * The browser never receives the full photo of a worker it isn't allowed to see.
 */
export default function HomeFeed({ workers, category, tier, loading, onBook, onUnlock }) {
  const { t } = useI18n()
  const freeCategory = MIN_TIER[category] === 0

  return (
    <div>
      {tier === 0 && freeCategory && (
        <div className="mx-3 mt-3 rounded-xl border border-amber-400/30 bg-amber-400/10 px-3 py-2 text-xs text-amber-200 sm:text-sm">
          🔒 {t('freeLimitNote', { n: FREE_RANK_LIMIT })}
        </div>
      )}

      {loading ? (
        <p className="py-20 text-center text-neutral-500">{t('loading')}</p>
      ) : workers.length === 0 ? (
        <p className="py-20 text-center text-neutral-500">{t('noWorkers')}</p>
      ) : (
        <ul className="grid grid-cols-2 gap-3 p-3 sm:grid-cols-3 sm:gap-4">
          {workers.map((w) => (
            <WorkerCard key={w.user_id} worker={w} onBook={onBook} onUnlock={onUnlock} />
          ))}
        </ul>
      )}
    </div>
  )
}

function WorkerCard({ worker: w, onBook, onUnlock }) {
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
          <span className="mt-1 inline-block rounded-full bg-white/10 px-2 py-0.5 text-[10px] text-neutral-300 sm:text-xs">{catName(w.category)}</span>
        </div>
        <p className="text-xs text-neutral-400 sm:text-sm">
          {t('from')} <span className="font-semibold text-white">{money(w.price)}</span>
        </p>
        {locked ? (
          <button onClick={onUnlock} className="w-full rounded-xl bg-amber-400 py-2.5 text-sm font-bold text-black transition active:scale-95">
            👑 {t('unlock')}
          </button>
        ) : (
          <button
            onClick={() => onBook(w)}
            disabled={!w.is_online}
            className="w-full rounded-xl bg-line py-2.5 text-sm font-bold text-black transition active:scale-95 disabled:cursor-not-allowed disabled:bg-neutral-700 disabled:text-neutral-400"
          >
            {w.is_online ? t('book') : t('unavailable')}
          </button>
        )}
      </div>
    </li>
  )
}
