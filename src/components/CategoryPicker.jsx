import { CATEGORIES, MIN_TIER, PLAN_META } from '../config'
import { useI18n } from '../i18n'

const EMOJI = { bartender: '🍸', ent: '🎤', masseuse: '💆', spa: '🧖' }

// Category tiles. Every tile opens its list: in the paid groups (massage / spa) a visitor without the package sees the girls with
// the face covered and cannot open the details until he subscribes (HomeFeed). The lock label tells which package is needed.
export default function CategoryPicker({ tier, onPick }) {
  const { t, catName } = useI18n()

  return (
    <div className="p-4">
      <p className="mb-3 text-sm text-neutral-400">{t('chooseCategory')}</p>
      <ul className="grid grid-cols-2 gap-3">
        {CATEGORIES.map((c) => {
          const open = tier >= MIN_TIER[c]
          const free = MIN_TIER[c] === 0
          return (
            <li key={c}>
              <button
                onClick={() => onPick(c)}
                className={`relative flex aspect-square w-full flex-col items-center justify-center gap-2 rounded-3xl p-3 text-center ring-1 transition active:scale-95 ${
                  open ? 'bg-white/10 ring-white/20' : 'bg-white/5 ring-white/10'
                }`}
              >
                <span className={`text-4xl ${open ? '' : 'opacity-50'}`}>{EMOJI[c]}</span>
                <span className="text-base font-bold">{catName(c)}</span>
                <span className={`rounded-full px-2 py-0.5 text-[10px] font-semibold ${
                  free ? 'bg-green-500/20 text-green-300' : open ? 'bg-amber-400/20 text-amber-300' : 'bg-black/40 text-neutral-400'
                }`}>
                  {free ? t('freeView') : open ? `${PLAN_META[tier].icon} ✓` : `🔒 ${t('needTier', { tier: PLAN_META[MIN_TIER[c]].name })} · ${t('blurredView')}`}
                </span>
              </button>
            </li>
          )
        })}
      </ul>
    </div>
  )
}
