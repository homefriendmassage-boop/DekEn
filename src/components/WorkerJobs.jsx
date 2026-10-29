import { useEffect, useState } from 'react'
import { supabase } from '../supabaseClient'
import { useI18n } from '../i18n'
import { fmtWhen, mapsLink, minutesLeft } from '../lib/booking'

const BADGE = { pending: 'bg-amber-400/20 text-amber-200', matched: 'bg-green-500/20 text-green-300', completed: 'bg-sky-500/20 text-sky-200', cancelled: 'bg-neutral-600/40 text-neutral-300' }

// The provider's booking inbox. Before she accepts she sees the time, the rate and the place note; after accepting she also
// gets the customer's phone and the map position. Pending bookings expire after 30 minutes.
export default function WorkerJobs({ jobs, reload, highlightId, onError }) {
  const { t, money, lang } = useI18n()
  const [, tick] = useState(0)
  useEffect(() => { const id = setInterval(() => tick((n) => n + 1), 30000); return () => clearInterval(id) }, [])

  async function setStatus(id, status) {
    const { error } = await supabase.from('jobs').update({ status }).eq('id', id)
    if (error) onError?.(t('errGeneric'))
    reload()
  }
  // Accept: a booking where the customer travels to her needs the place (name + room, optional map link)
  const [acc, setAcc] = useState(null)      // { id, place, url } while the place form is open
  async function accept(j, place = null, url = null) {
    const { error } = await supabase.rpc('job_accept', { p_job: j.id, p_place: place, p_url: url })
    if (error) { onError?.(/PLACE_REQUIRED/.test(error.message) ? t('errPlaceName') : /BAD_MAP_LINK/.test(error.message) ? t('errBadMapLink') : /CONTACT_IN_BOOKING/.test(error.message) ? t('errBookingContact') : t('errGeneric')); return }
    setAcc(null)
    reload()
  }
  async function arrived(id) {
    const { error } = await supabase.rpc('job_arrived', { p_job: id })
    if (error) onError?.(t('errGeneric'))
    reload()
  }

  if (jobs.length === 0) return <p className="rounded-2xl bg-white/5 p-4 text-center text-sm text-neutral-500">{t('noJobs')}</p>
  return (
    <ul className="space-y-2">
      {jobs.map((j) => {
        const map = mapsLink(j)
        return (
          <li key={j.id} className={`rounded-2xl p-3 text-sm ring-1 ${j.id === highlightId ? 'bg-pink-500/10 ring-pink-400/60' : 'bg-white/5 ring-white/10'}`}>
            <div className="flex items-center justify-between gap-2">
              <p className="font-semibold">{t('customer')}: {j.customer_name ?? '—'}</p>
              <span className={`rounded-full px-2 py-0.5 text-[11px] font-semibold ${BADGE[j.status]}`}>{t(`bkStatus_${j.status}`)}</span>
            </div>
            {j.source_label && <p className="mt-1 text-xs font-semibold text-amber-300">🏪 {t('jobFrom', { name: j.source_label })}</p>}
            <p className="mt-1 text-xs text-neutral-300">
              {j.rate_label ? `${t(`rate_${j.rate_label}`) === `rate_${j.rate_label}` ? j.rate_label : t(`rate_${j.rate_label}`)} · ` : ''}{t('cashLabel')}: <b className="text-white">{money(j.service_price)}</b>
            </p>
            {j.travel_mode === 'customer_goes' && j.status === 'pending' && <p className="text-xs font-semibold text-sky-300">{t('travelCustJob')}</p>}
            {j.scheduled_at && <p className="text-xs text-neutral-300">🕒 {fmtWhen(j.scheduled_at, lang)}</p>}
            {j.place_note && <p className="text-xs text-neutral-400">📍 {j.place_note}</p>}
            {j.customer_note && <p className="text-xs text-neutral-400">📝 {j.customer_note}</p>}

            {j.status === 'pending' && (
              <>
                <p className="mt-2 rounded-lg bg-amber-400/10 p-2 text-xs text-amber-200">⏳ {t('jobAnswerIn', { min: minutesLeft(j.expires_at) })} · {t('jobHidden')}</p>
                <div className="mt-2 grid grid-cols-2 gap-2">
                  <button onClick={() => (j.travel_mode === 'customer_goes' ? setAcc({ id: j.id, place: '', url: '' }) : accept(j))} className="rounded-lg bg-line py-2 font-bold text-black active:scale-95">{t('accept')}</button>
                  <button onClick={() => setStatus(j.id, 'cancelled')} className="rounded-lg bg-white/10 py-2 font-semibold active:scale-95">{t('decline')}</button>
                </div>
                {acc?.id === j.id && (
                  <div className="mt-2 space-y-2 rounded-xl bg-white/5 p-3">
                    <p className="text-sm font-semibold">{t('acceptPlaceTitle')}</p>
                    <input maxLength={200} value={acc.place} onChange={(e) => setAcc({ ...acc, place: e.target.value })} placeholder={t('acceptPlaceName')} className="w-full rounded-xl bg-white/10 px-3 py-2 text-base outline-none ring-1 ring-white/10 focus:ring-line" />
                    <input value={acc.url} onChange={(e) => setAcc({ ...acc, url: e.target.value })} placeholder={t('acceptPlaceUrl')} className="w-full rounded-xl bg-white/10 px-3 py-2 text-base outline-none ring-1 ring-white/10 focus:ring-line" />
                    <button onClick={() => accept(j, acc.place, acc.url.trim() || null)} className="w-full rounded-xl bg-line py-2.5 font-bold text-black active:scale-95">{t('acceptPlaceOk')}</button>
                  </div>
                )}
              </>
            )}
            {(j.status === 'matched' || j.status === 'completed') && (
              <div className="mt-2 space-y-1 rounded-xl bg-green-500/10 p-3">
                {j.customer_phone && <a href={`tel:${j.customer_phone}`} className="block font-bold text-green-200 underline">📞 {j.customer_phone}</a>}
                {map && <a href={map} target="_blank" rel="noreferrer" className="block font-semibold text-green-200 underline">🗺️ {t('jobOpenMap')}</a>}
                {j.arrived_at && <p className="text-xs font-semibold text-green-300">📍 {t('jobArrivedAt', { time: fmtWhen(j.arrived_at, lang) })}</p>}
              </div>
            )}
            {j.status === 'matched' && (
              <div className="mt-2 grid grid-cols-3 gap-2">
                <button disabled={!!j.arrived_at} onClick={() => arrived(j.id)} className="rounded-lg bg-sky-500 py-2 text-xs font-bold text-black active:scale-95 disabled:opacity-40">📍 {t('jobArrived')}</button>
                <button onClick={() => setStatus(j.id, 'completed')} className="rounded-lg bg-line py-2 text-xs font-bold text-black active:scale-95">{t('complete')}</button>
                <button onClick={() => window.confirm(t('jobCancelConfirm')) && setStatus(j.id, 'cancelled')} className="rounded-lg bg-white/10 py-2 text-xs font-semibold active:scale-95">{t('cancelJob')}</button>
              </div>
            )}
            {j.status === 'cancelled' && <p className="mt-2 rounded-lg bg-white/5 p-2 text-xs text-neutral-300">{t(`jobCancel_${j.cancel_reason ?? 'admin'}`)}</p>}
          </li>
        )
      })}
    </ul>
  )
}
