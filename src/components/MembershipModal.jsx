import { FREE_RANK_LIMIT, LINE_OA_URL, MEMBERSHIP_DAYS, PLAN_META, PLANS } from '../config'
import { useI18n } from '../i18n'

// Plan comparison. Payment is handled manually by an admin for now
// (select public.set_membership(user_id, tier, 30) in the SQL editor).
export default function MembershipModal({ tier, onClose, onPay, onSupport }) {
  const { t } = useI18n()
  const curPrice = PLANS.find((p) => p.tier === tier)?.price ?? 0

  return (
    <div className="fixed inset-0 z-50 flex items-end justify-center bg-black/70 sm:items-center sm:p-4" onClick={onClose} role="dialog" aria-modal="true">
      <div
        onClick={(e) => e.stopPropagation()}
        className="max-h-[90vh] w-full max-w-md overflow-y-auto rounded-t-3xl bg-neutral-900 p-5 pb-[calc(1.25rem+env(safe-area-inset-bottom))] shadow-2xl sm:rounded-3xl"
      >
        <div className="mx-auto mb-4 h-1.5 w-10 rounded-full bg-white/20 sm:hidden" />
        <h2 className="text-xl font-bold">✨ {t('membershipTitle')}</h2>
        <p className="mt-1 text-sm text-neutral-400">{t('membershipSub', { days: MEMBERSHIP_DAYS })}</p>

        <ul className="mt-4 space-y-2 text-sm">
          <li className={`rounded-2xl p-3 ${tier === 0 ? 'bg-white/15 ring-1 ring-white/30' : 'bg-white/5'}`}>
            <p className="font-bold">{t('freePlan')} {tier === 0 && <span className="ml-1 text-xs text-green-300">· {t('yourPlan')}</span>}</p>
            <p className="text-neutral-400">{t('planFree', { n: FREE_RANK_LIMIT })}</p>
          </li>
          {PLANS.map((p) => {
            const m = PLAN_META[p.tier]
            return (
              <li key={p.tier} className={`rounded-2xl p-3 ring-1 ${m.soft} ${tier === p.tier ? `${m.ring} ring-2` : 'ring-white/10'}`}>
                <div className="flex items-center justify-between gap-2">
                  <span className={`rounded-full px-3 py-0.5 text-sm font-extrabold tracking-wide shadow ${m.badge}`}>{m.icon} {m.name}</span>
                  <p className="text-xs font-semibold text-white">{t('pricePer', { price: p.price, days: MEMBERSHIP_DAYS })}</p>
                </div>
                {tier === p.tier && <p className="mt-1 text-xs text-green-300">✓ {t('yourPlan')}</p>}
                <p className="mt-2 text-neutral-300">{t(`plan${p.tier}`)}</p>
                {onPay && p.tier >= tier && (
                  <>
                    <button onClick={() => onPay(p.tier)} className={`mt-3 w-full rounded-xl py-2 text-sm font-bold shadow active:scale-95 ${m.badge}`}>
                      {tier === p.tier ? t('renew') : tier > 0 ? t('upgrade') : t('pay')} · {tier > 0 && p.tier > tier ? p.price - curPrice : p.price} {t('currency')}
                    </button>
                    {tier > 0 && p.tier > tier && <p className="mt-1 text-center text-[11px] text-neutral-400">{t('upgradeNote')}</p>}
                  </>
                )}
              </li>
            )
          })}
        </ul>

        <div className="mt-4 grid grid-cols-2 gap-3">
          <button onClick={onClose} className="rounded-xl bg-white/10 py-3 font-semibold active:scale-95">{t('close')}</button>
          {onSupport && (
            <button onClick={onSupport} className="rounded-xl bg-white/10 py-3 font-semibold active:scale-95">{t('chatAdmin')}</button>
          )}
        </div>
      </div>
    </div>
  )
}
