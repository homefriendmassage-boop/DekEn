import { FREE_RANK_LIMIT, LINE_OA_URL, MEMBERSHIP_DAYS, PLANS } from '../config'
import { useI18n } from '../i18n'

// Plan comparison. Payment is handled manually by an admin for now
// (select public.set_membership(user_id, tier, 30) in the SQL editor).
export default function MembershipModal({ tier, onClose }) {
  const { t } = useI18n()

  return (
    <div className="fixed inset-0 z-50 flex items-end justify-center bg-black/70 sm:items-center sm:p-4" onClick={onClose} role="dialog" aria-modal="true">
      <div
        onClick={(e) => e.stopPropagation()}
        className="max-h-[90vh] w-full max-w-md overflow-y-auto rounded-t-3xl bg-neutral-900 p-5 pb-[calc(1.25rem+env(safe-area-inset-bottom))] shadow-2xl sm:rounded-3xl"
      >
        <div className="mx-auto mb-4 h-1.5 w-10 rounded-full bg-white/20 sm:hidden" />
        <h2 className="text-xl font-bold">👑 {t('membershipTitle')}</h2>
        <p className="mt-1 text-sm text-neutral-400">{t('membershipSub', { days: MEMBERSHIP_DAYS })}</p>

        <ul className="mt-4 space-y-2 text-sm">
          <li className={`rounded-2xl p-3 ${tier === 0 ? 'bg-white/15 ring-1 ring-white/30' : 'bg-white/5'}`}>
            <p className="font-bold">{t('freePlan')} {tier === 0 && <span className="ml-1 text-xs text-green-300">· {t('yourPlan')}</span>}</p>
            <p className="text-neutral-400">{t('planFree', { n: FREE_RANK_LIMIT })}</p>
          </li>
          {PLANS.map((p) => (
            <li key={p.tier} className={`rounded-2xl p-3 ${tier === p.tier ? 'bg-amber-400/15 ring-1 ring-amber-400' : 'bg-white/5'}`}>
              <div className="flex items-baseline justify-between gap-2">
                <p className="font-bold">VIP {p.price} {tier === p.tier && <span className="ml-1 text-xs text-amber-300">· {t('yourPlan')}</span>}</p>
                <p className="text-xs text-amber-300">{t('pricePer', { price: p.price, days: MEMBERSHIP_DAYS })}</p>
              </div>
              <p className="text-neutral-400">{t(`plan${p.tier}`)}</p>
            </li>
          ))}
        </ul>

        <p className="mt-4 text-xs text-neutral-500">{t('contactAdminHint')}</p>
        <div className="mt-3 grid grid-cols-2 gap-3">
          <button onClick={onClose} className="rounded-xl bg-white/10 py-3 font-semibold active:scale-95">{t('close')}</button>
          {LINE_OA_URL ? (
            <a href={LINE_OA_URL} target="_blank" rel="noreferrer" className="rounded-xl bg-line py-3 text-center font-bold text-black active:scale-95">
              {t('contactAdmin')}
            </a>
          ) : (
            <span className="rounded-xl bg-neutral-800 py-3 text-center text-sm text-neutral-500">{t('contactAdmin')}</span>
          )}
        </div>
      </div>
    </div>
  )
}
