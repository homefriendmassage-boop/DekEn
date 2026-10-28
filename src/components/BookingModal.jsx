import { useState } from 'react'
import { supabase } from '../supabaseClient'
import { BOOKING_FEE } from '../config'
import { useI18n } from '../i18n'

// Map the exceptions raised by the jobs_before_insert trigger to translated text keys.
const ERROR_KEYS = {
  INSUFFICIENT_BALANCE: 'errInsufficient',
  WORKER_UNAVAILABLE: 'errUnavailable',
  LOCKED: 'errLocked',
}
const errorKey = (msg = '') =>
  Object.entries(ERROR_KEYS).find(([k]) => msg.includes(k))?.[1] ?? 'errGeneric'

/**
 * Bottom sheet on phones, centered dialog on larger screens.
 * Props: worker, customerId, walletBalance, onClose(), onBooked()
 */
export default function BookingModal({ worker, customerId, walletBalance, onClose, onBooked }) {
  const { t, money } = useI18n()
  const [submitting, setSubmitting] = useState(false)
  const [error, setError] = useState(null)

  const insufficient = walletBalance < BOOKING_FEE

  async function confirm() {
    if (submitting || insufficient) return // guards double-taps
    setSubmitting(true)
    setError(null)

    // Plain insert. The DB trigger atomically verifies + deducts the wallet,
    // overrides booking_fee/status, and rejects if the worker is offline.
    // If anything fails the whole insert rolls back — no half-paid bookings.
    const { error } = await supabase.from('jobs').insert({
      customer_id: customerId,
      worker_id: worker.user_id,
      booking_fee: BOOKING_FEE,
    })

    setSubmitting(false)
    if (error) return setError(errorKey(error.message))
    onBooked()
  }

  return (
    <div
      className="fixed inset-0 z-50 flex items-end justify-center bg-black/70 sm:items-center sm:p-4"
      onClick={onClose} // tap backdrop to dismiss
      role="dialog"
      aria-modal="true"
    >
      <div
        onClick={(e) => e.stopPropagation()}
        className="max-h-[90vh] w-full max-w-md overflow-y-auto rounded-t-3xl bg-neutral-900 p-5 pb-[calc(1.25rem+env(safe-area-inset-bottom))] shadow-2xl sm:rounded-3xl"
      >
        <div className="mx-auto mb-4 h-1.5 w-10 rounded-full bg-white/20 sm:hidden" />

        <h2 className="text-xl font-bold">{t('bookTitle', { name: worker.display_name })}</h2>
        <p className="mt-1 text-sm text-neutral-400">{t('reviewPayment')}</p>

        <dl className="mt-4 divide-y divide-white/10 rounded-2xl bg-white/5 text-sm">
          <Row label={t('platformFee')} value={money(BOOKING_FEE)} strong />
          <Row label={t('payWorker')} value={money(worker.price)} />
          <Row
            label={t('walletBalance')}
            value={money(walletBalance)}
            valueClass={insufficient ? 'text-red-400' : 'text-green-400'}
          />
        </dl>

        <p className="mt-3 text-xs leading-relaxed text-neutral-500">
          {t('feeNote', { fee: money(BOOKING_FEE), name: worker.display_name })}
        </p>

        {insufficient && (
          <p className="mt-3 rounded-lg bg-red-500/10 p-2 text-sm text-red-300">
            {t('lowBalance', { fee: money(BOOKING_FEE) })}
          </p>
        )}
        {error && <p className="mt-3 rounded-lg bg-red-500/10 p-2 text-sm text-red-300">{t(error)}</p>}

        <div className="mt-5 grid grid-cols-2 gap-3">
          <button onClick={onClose} className="rounded-xl bg-white/10 py-3 font-semibold active:scale-95">
            {t('cancel')}
          </button>
          <button
            onClick={confirm}
            disabled={submitting || insufficient}
            className="rounded-xl bg-line py-3 font-bold text-black transition active:scale-95 disabled:cursor-not-allowed disabled:opacity-50"
          >
            {submitting ? t('booking') : t('confirm')}
          </button>
        </div>
      </div>
    </div>
  )
}

function Row({ label, value, strong, valueClass = '' }) {
  return (
    <div className="flex items-start justify-between gap-4 px-4 py-3">
      <dt className="text-neutral-300">{label}</dt>
      <dd className={`shrink-0 text-right ${strong ? 'font-bold' : 'font-semibold'} ${valueClass}`}>{value}</dd>
    </div>
  )
}
