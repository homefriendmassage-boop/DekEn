import { formatTHB } from '../config'

/**
 * Gallery of workers. Mobile-first: 2 columns on phones, 3 on tablets+.
 *
 * VIP gating: non-VIP users get `filter blur-md` on the photo plus a lock overlay.
 * NOTE: CSS blur is a UX gate only — the image URL is still in the network
 * response. For real protection, serve a pre-blurred thumbnail to non-VIPs
 * (e.g. a separate `profile_image_blur` column / Storage policy).
 */
export default function HomeFeed({ workers, isVip, walletBalance, displayName, onBook }) {
  return (
    <div>
      {/* Sticky header with wallet chip */}
      <header className="sticky top-0 z-30 flex items-center justify-between gap-3 border-b border-white/10 bg-neutral-950/90 px-4 py-3 backdrop-blur">
        <div className="min-w-0">
          <p className="truncate text-xs text-neutral-400">Hello, {displayName}</p>
          <h1 className="text-lg font-bold leading-tight">Discover</h1>
        </div>
        <div className="flex shrink-0 items-center gap-2">
          {isVip && (
            <span className="rounded-full bg-gradient-to-r from-yellow-300 to-amber-500 px-2 py-0.5 text-[10px] font-extrabold text-black">VIP</span>
          )}
          <span className="rounded-full bg-white/10 px-3 py-1 text-sm font-semibold">
            💰 {formatTHB(walletBalance)}
          </span>
        </div>
      </header>

      {!isVip && (
        <div className="mx-3 mt-3 rounded-xl border border-amber-400/30 bg-amber-400/10 px-3 py-2 text-xs text-amber-200 sm:text-sm">
          🔒 Photos are blurred. Upgrade to VIP to view full profiles.
        </div>
      )}

      {workers.length === 0 ? (
        <p className="py-20 text-center text-neutral-500">No one is available right now.</p>
      ) : (
        <ul className="grid grid-cols-2 gap-3 p-3 sm:grid-cols-3 sm:gap-4">
          {workers.map((w) => (
            <WorkerCard key={w.user_id} worker={w} isVip={isVip} onBook={onBook} />
          ))}
        </ul>
      )}
    </div>
  )
}

function WorkerCard({ worker: w, isVip, onBook }) {
  return (
    <li
      className={`relative overflow-hidden rounded-2xl bg-neutral-900 ring-1 ${
        w.is_boosted ? 'ring-2 ring-amber-400 shadow-[0_0_20px_rgba(251,191,36,0.25)]' : 'ring-white/10'
      }`}
    >
      {/* Photo — overflow-hidden on the card stops the blur bleeding outside */}
      <div className="relative aspect-[3/4] w-full overflow-hidden bg-neutral-800">
        {w.profile_image && (
          <img
            src={w.profile_image}
            alt={isVip ? w.display_name : ''}
            loading="lazy"
            draggable={false}
            // Non-VIP => blurred. scale-110 hides the soft edge the blur creates.
            className={`h-full w-full select-none object-cover ${!isVip ? 'filter blur-md scale-110' : ''}`}
          />
        )}

        {!isVip && (
          <div className="absolute inset-0 flex items-center justify-center bg-black/20">
            <span className="rounded-full bg-black/60 px-3 py-1 text-xs font-semibold">🔒 VIP only</span>
          </div>
        )}

        {/* Boosted / Top Rank badge */}
        {w.is_boosted && (
          <span className="absolute left-2 top-2 flex items-center gap-1 rounded-full bg-gradient-to-r from-amber-300 to-orange-500 px-2 py-0.5 text-[10px] font-extrabold uppercase tracking-wide text-black shadow sm:text-xs">
            🔥 Top Rank
          </span>
        )}

        {/* Online indicator */}
        <span
          className={`absolute right-2 top-2 flex items-center gap-1 rounded-full bg-black/60 px-2 py-0.5 text-[10px] sm:text-xs ${
            w.is_online ? 'text-green-400' : 'text-neutral-400'
          }`}
        >
          <span className={`h-1.5 w-1.5 rounded-full ${w.is_online ? 'bg-green-400' : 'bg-neutral-500'}`} />
          {w.is_online ? 'Online' : 'Offline'}
        </span>
      </div>

      <div className="space-y-2 p-3">
        <div>
          <h2 className="truncate text-sm font-bold sm:text-base">{w.display_name}</h2>
          <div className="mt-1 flex flex-wrap gap-1">
            {w.service_types?.map((s) => (
              <span key={s} className="rounded-full bg-white/10 px-2 py-0.5 text-[10px] capitalize text-neutral-300 sm:text-xs">{s}</span>
            ))}
          </div>
        </div>
        <p className="text-xs text-neutral-400 sm:text-sm">
          From <span className="font-semibold text-white">{formatTHB(w.price)}</span>
        </p>
        <button
          onClick={() => onBook(w)}
          disabled={!w.is_online}
          className="w-full rounded-xl bg-line py-2.5 text-sm font-bold text-black transition active:scale-95 disabled:cursor-not-allowed disabled:bg-neutral-700 disabled:text-neutral-400"
        >
          {w.is_online ? 'Book' : 'Unavailable'}
        </button>
      </div>
    </li>
  )
}
