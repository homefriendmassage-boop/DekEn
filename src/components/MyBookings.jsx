import { useCallback, useEffect, useState } from 'react'
import { supabase } from '../supabaseClient'
import { useI18n } from '../i18n'
import { fmtWhen, minutesLeft, withFee } from '../lib/booking'

const BADGE = { pending: 'bg-amber-400/20 text-amber-200', matched: 'bg-green-500/20 text-green-300', completed: 'bg-sky-500/20 text-sky-200', cancelled: 'bg-neutral-600/40 text-neutral-300' }

// The customer's bookings: status, countdown while the provider has not answered, and the provider's contact once she accepted.
export default function MyBookings({ onClose, highlightId }) {
  const { t, money, lang } = useI18n()
  const [rows, setRows] = useState(null)
  const [, tick] = useState(0)

  const load = useCallback(async () => {
    const { data } = await supabase.rpc('my_customer_jobs')
    setRows(data ?? [])
  }, [])
  useEffect(() => { load() }, [load])
  useEffect(() => {          // status changes (accepted / declined / expired / arrived) arrive live
    const ch = supabase.channel('my-bookings').on('postgres_changes', { event: '*', schema: 'public', table: 'jobs' }, load).subscribe()
    const id = setInterval(() => tick((n) => n + 1), 30000)
    return () => { supabase.removeChannel(ch); clearInterval(id) }
  }, [load])

  async function cancel(j) {
    if (!window.confirm(t('bkCancelConfirm'))) return
    await supabase.from('jobs').update({ status: 'cancelled' }).eq('id', j.id)
    load()
  }

  return (
    <div className="fixed inset-0 z-50 flex items-end justify-center bg-black/70 sm:items-center sm:p-4" onClick={onClose} role="dialog" aria-modal="true">
      <div onClick={(e) => e.stopPropagation()} className="max-h-[92vh] w-full max-w-md space-y-3 overflow-y-auto rounded-t-3xl bg-neutral-900 p-5 pb-[calc(1.25rem+env(safe-area-inset-bottom))] shadow-2xl sm:rounded-3xl">
        <div className="mx-auto h-1.5 w-10 rounded-full bg-white/20 sm:hidden" />
        <h2 className="text-xl font-bold">📅 {t('myBookings')}</h2>
        {rows === null ? <p className="py-8 text-center text-neutral-500">{t('loading')}</p> : rows.length === 0 ? (
          <p className="rounded-2xl bg-white/5 p-6 text-center text-sm text-neutral-500">{t('bkNone')}</p>
        ) : (
          <ul className="space-y-3">
            {rows.map((j) => (
              <li key={j.id} className={`space-y-2 rounded-2xl p-3 ring-1 ${j.id === highlightId ? 'bg-pink-500/10 ring-pink-400/60' : 'bg-white/5 ring-white/10'}`}>
                <div className="flex items-center gap-3">
                  <div className="h-12 w-10 shrink-0 overflow-hidden rounded-lg bg-neutral-800">{j.worker_image && <img src={j.worker_image} alt="" className="h-full w-full object-cover" />}</div>
                  <div className="min-w-0 flex-1">
                    <p className="truncate font-bold">{j.worker_name}</p>
                    <p className="text-xs text-neutral-400">{fmtWhen(j.scheduled_at, lang)}</p>
                  </div>
                  <span className={`shrink-0 rounded-full px-2 py-0.5 text-[11px] font-semibold ${BADGE[j.status]}`}>{t(`bkStatus_${j.status}`)}</span>
                </div>
                <p className="text-xs text-neutral-300">{t('bkRateLine', { rate: j.rate_label ? t(`rate_${j.rate_label}`) === `rate_${j.rate_label}` ? j.rate_label : t(`rate_${j.rate_label}`) : '', price: money(withFee(j.service_price)), cash: money(j.service_price) })}</p>
                {j.place_note && <p className="text-xs text-neutral-400">📍 {j.place_note}</p>}

                {j.status === 'pending' && (
                  <>
                    <p className="rounded-lg bg-amber-400/10 p-2 text-xs text-amber-200">⏳ {t('bkWaiting', { min: minutesLeft(j.expires_at) })}</p>
                    <button onClick={() => cancel(j)} className="w-full rounded-xl bg-white/10 py-2 text-sm font-semibold active:scale-95">{t('bkCancel')}</button>
                  </>
                )}
                {(j.status === 'matched' || j.status === 'completed') && (
                  <div className="space-y-1 rounded-xl bg-green-500/10 p-3 text-sm">
                    <p className="text-xs font-semibold text-green-300">{t('bkContactTitle')}</p>
                    {j.worker_phone && <a href={`tel:${j.worker_phone}`} className="block font-bold text-green-200 underline">📞 {j.worker_phone}</a>}
                    {j.worker_line_id && <p>LINE: <b>{j.worker_line_id}</b></p>}
                    {!j.worker_phone && !j.worker_line_id && <p className="text-xs text-neutral-400">{t('bkNoContact')}</p>}
                    {j.arrived_at && <p className="text-xs font-semibold text-green-300">📍 {t('bkArrived')}</p>}
                    <p className="text-[11px] text-neutral-400">{t('bkPayCash', { cash: money(j.service_price) })}</p>
                  </div>
                )}
                {j.status === 'cancelled' && <p className="rounded-lg bg-white/5 p-2 text-xs text-neutral-300">{t(`bkCancel_${j.cancel_reason ?? 'admin'}`)}</p>}
              </li>
            ))}
          </ul>
        )}
        <button onClick={onClose} className="w-full rounded-xl bg-white/10 py-3 font-semibold active:scale-95">{t('close')}</button>
      </div>
    </div>
  )
}
