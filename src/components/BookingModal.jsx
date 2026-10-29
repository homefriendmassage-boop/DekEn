import { getVendor } from '../lib/vendor'
import { useEffect, useMemo, useState } from 'react'
import { supabase } from '../supabaseClient'
import { useI18n } from '../i18n'
import { getPosition } from '../lib/geo'
import { bookingErrorKey, feeFor, fmtWhen, isPremium, rateMinutes, withFee } from '../lib/booking'
import { ratesOf } from './WorkerDetail'

const input = 'mt-1 w-full rounded-xl bg-white/10 px-3 py-2.5 text-base outline-none ring-1 ring-white/10 focus:ring-line'
const pad = (n) => String(n).padStart(2, '0')
const localInput = (d) => `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}T${pad(d.getHours())}:${pad(d.getMinutes())}`

/**
 * Booking sheet: pick the rate, when and where, leave a phone number, see exactly what is paid where.
 * The customer sees (what the provider gets in cash + the platform fee); the fee is taken from the Wallet now,
 * the rest is paid to the provider in cash when they meet. The provider has 30 minutes to answer.
 * Props: worker, walletBalance, onClose(), onBooked(), onTopUp()
 */
export default function BookingModal({ worker, walletBalance, onClose, onBooked, onTopUp }) {
  const { t, money, lang } = useI18n()
  const rates = useMemo(() => ratesOf(worker, t), [worker, t])
  const [rate, setRate] = useState(worker.start_rate && rates.some((r) => r[0] === worker.start_rate) ? worker.start_rate : rates[0]?.[0])
  const soon = useMemo(() => { const d = new Date(Date.now() + 60 * 60000); d.setMinutes(0, 0, 0); return localInput(d) }, [])
  const [when, setWhen] = useState(soon)
  const [placeNote, setPlaceNote] = useState('')
  const [url, setUrl] = useState('')
  const [pin, setPin] = useState(null)
  const [pinBusy, setPinBusy] = useState(false)
  const canChooseTravel = isPremium(worker.categories)                     // massage / spa: who goes to whom
  const [travel, setTravel] = useState('worker_goes')
  const custGoes = canChooseTravel && travel === 'customer_goes'
  const [phone, setPhone] = useState('')
  const [note, setNote] = useState('')
  const [submitting, setSubmitting] = useState(false)
  const [error, setError] = useState(null)

  // time ranges she already has accepted bookings for: the customer decides whether to book another time
  const [slots, setSlots] = useState([])
  useEffect(() => { supabase.rpc('worker_booked_slots', { p_worker: worker.user_id }).then(({ data }) => setSlots(data ?? [])) }, [worker.user_id])

  const picked = rates.find((r) => r[0] === rate) ?? rates[0]
  const cash = Number(picked?.[2] ?? 0)
  const startMs = when ? new Date(when).getTime() : NaN
  const endMs = startMs + rateMinutes(rate) * 60000
  const overlaps = slots.some((x) => startMs < new Date(x.end_at).getTime() && endMs > new Date(x.start_at).getTime())
  const fee = feeFor(worker.categories)                                   // 500, or 700 for massage / spa
  const insufficient = walletBalance < fee

  async function pinHere() {
    setPinBusy(true); setError(null)
    try { setPin(await getPosition()) } catch { setError(t('locDenied')) } finally { setPinBusy(false) }
  }

  async function confirm() {
    if (submitting || insufficient) return
    setError(null)
    if (!when) return setError(t('errBadTime'))
    if (!custGoes && !pin && !url.trim() && !placeNote.trim()) return setError(t('errPlaceRequired'))
    if (phone.replace(/\D/g, '').length < 9) return setError(t('errBadPhone'))
    setSubmitting(true)
    const { error } = await supabase.rpc('create_booking', {
      p_worker: worker.user_id, p_rate: rate, p_scheduled: new Date(when).toISOString(), p_place_note: custGoes ? '' : placeNote, p_note: note,
      p_phone: phone, p_lat: custGoes ? null : pin?.lat ?? null, p_lng: custGoes ? null : pin?.lng ?? null, p_url: custGoes ? null : url.trim() || null,
      p_vendor: getVendor()?.id ?? null, p_travel: custGoes ? 'customer_goes' : 'worker_goes',      // the seller whose link he is booking through (gets the sales share)
    })
    setSubmitting(false)
    if (error) return setError(t(bookingErrorKey(error.message)))
    onBooked()
  }

  return (
    <div className="fixed inset-0 z-50 flex items-end justify-center bg-black/70 sm:items-center sm:p-4" onClick={onClose} role="dialog" aria-modal="true">
      <div onClick={(e) => e.stopPropagation()}
        className="max-h-[92vh] w-full max-w-md space-y-4 overflow-y-auto rounded-t-3xl bg-neutral-900 p-5 pb-[calc(1.25rem+env(safe-area-inset-bottom))] shadow-2xl sm:rounded-3xl">
        <div className="mx-auto h-1.5 w-10 rounded-full bg-white/20 sm:hidden" />

        <div className="flex items-start justify-between gap-3">
          <div className="min-w-0">
            <h2 className="truncate text-xl font-bold">{t('bookTitle', { name: worker.display_name })}</h2>
            <p className="mt-1 text-sm text-neutral-400">{t('reviewPayment')}</p>
          </div>
          <div className="shrink-0 rounded-2xl bg-white/10 px-3 py-1.5 text-right">
            <p className="text-[10px] text-neutral-400">💰 Wallet</p>
            <p className={`text-base font-extrabold ${insufficient ? 'text-red-300' : ''}`}>{money(walletBalance)}</p>
          </div>
        </div>

        <fieldset>
          <legend className="text-sm font-semibold">{t('bookRate')}</legend>
          <div className="mt-2 space-y-2">
            {rates.map(([k, label, price]) => (
              <button type="button" key={k} aria-pressed={rate === k} onClick={() => setRate(k)}
                className={`flex w-full items-center justify-between rounded-xl px-3 py-2.5 text-left ring-1 active:scale-[0.99] ${rate === k ? 'bg-line text-black ring-line' : 'bg-white/10 ring-white/15'}`}>
                <span className="font-semibold">{rate === k ? '✓ ' : ''}{label}</span><b>{money(withFee(price, worker.categories))}</b>
              </button>
            ))}
          </div>
        </fieldset>

        <label className="block text-sm font-semibold">{t('bookWhen')}
          <input type="datetime-local" value={when} min={localInput(new Date(Date.now() + 15 * 60000))} onChange={(e) => setWhen(e.target.value)} className={input} />
        </label>
        {slots.length > 0 && (
          <div className="space-y-1 rounded-2xl bg-amber-400/10 p-3 ring-1 ring-amber-400/30">
            <p className="text-sm font-semibold text-amber-200">🗓️ {t('slotsTitle')}</p>
            <ul className="space-y-0.5 text-xs text-amber-100">
              {slots.map((x, i) => <li key={i}>• {fmtWhen(x.start_at, lang)} – {new Date(x.end_at).toLocaleTimeString(lang === 'th' ? 'th-TH' : undefined, { hour: '2-digit', minute: '2-digit' })}</li>)}
            </ul>
            <p className="text-[11px] text-neutral-400">{t('slotsNote')}</p>
            {overlaps && <p className="rounded-lg bg-red-500/15 p-2 text-xs font-semibold text-red-200">⚠️ {t('slotsOverlap')}</p>}
          </div>
        )}

        {canChooseTravel && (
          <fieldset className="space-y-2 rounded-2xl bg-white/5 p-3">
            <legend className="px-1 text-sm font-semibold">{t('travelTitle')}</legend>
            <div className="grid grid-cols-2 gap-2">
              {[['worker_goes', t('travelWorkerGoes')], ['customer_goes', t('travelCustGoes')]].map(([k, label]) => (
                <button key={k} type="button" onClick={() => setTravel(k)} aria-pressed={travel === k}
                  className={`rounded-xl py-2.5 text-sm font-semibold active:scale-95 ${travel === k ? 'bg-line text-black' : 'bg-white/10'}`}>{label}</button>
              ))}
            </div>
            {custGoes && <p className="text-[11px] text-neutral-400">{t('travelCustNote')}</p>}
          </fieldset>
        )}

        {!custGoes && (
        <fieldset className="space-y-2 rounded-2xl bg-white/5 p-3">
          <legend className="px-1 text-sm font-semibold">{t('bookWhere')}</legend>
          <button type="button" onClick={pinHere} disabled={pinBusy} className="w-full rounded-xl bg-white/10 py-2.5 text-sm font-semibold active:scale-95 disabled:opacity-50">
            {pinBusy ? t('locDetecting') : pin ? `✓ ${t('bookPinned')}` : `📍 ${t('bookPin')}`}
          </button>
          <label className="block text-sm">{t('bookMapLink')}
            <input value={url} onChange={(e) => setUrl(e.target.value)} placeholder="https://maps.app.goo.gl/…" className={input} />
          </label>
          <label className="block text-sm">{t('bookPlaceNote')}
            <input maxLength={200} value={placeNote} onChange={(e) => setPlaceNote(e.target.value)} className={input} />
          </label>
          <p className="text-[11px] text-neutral-500">{t('bookPrivacy')}</p>
        </fieldset>
        )}

        <label className="block text-sm font-semibold">{t('bookPhone')}
          <input type="tel" inputMode="tel" maxLength={20} value={phone} onChange={(e) => setPhone(e.target.value)} className={input} />
          <span className="text-[11px] font-normal text-neutral-500">{t('bookPhoneHint')}</span>
        </label>
        <label className="block text-sm">{t('bookNote')}
          <input maxLength={300} value={note} onChange={(e) => setNote(e.target.value)} className={input} />
        </label>

        <div className="overflow-hidden rounded-2xl bg-white/5 text-sm ring-1 ring-white/10">
          <div className="flex items-center justify-between px-4 py-3"><span>{t('bookWage', { rate: picked?.[1] ?? '' })}</span><b>{money(withFee(cash, worker.categories))}</b></div>
          <div className="flex items-center justify-between border-t border-white/5 px-4 py-3"><span>{t('bookFeeRow')}</span><b>{money(fee)}</b></div>
          <div className="flex items-center justify-between border-t border-white/5 bg-white/5 px-4 py-3"><span>{t('bookDirectRow')}</span><b className="text-green-300">{money(cash)}</b></div>
        </div>
        <p className="text-[11px] text-neutral-500">{t('bookAnswerNote')}</p>

        {insufficient && (
          <div className="space-y-2 rounded-xl bg-red-500/10 p-3 text-sm text-red-300">
            <p>{t('lowBalance', { fee: money(fee) })}</p>
            {onTopUp && <button onClick={onTopUp} className="w-full rounded-xl bg-line py-2 font-bold text-black active:scale-95">{t('topUp')}</button>}
          </div>
        )}
        {error && <p className="rounded-xl bg-red-500/10 p-3 text-sm text-red-300">{error}</p>}

        <div className="grid grid-cols-2 gap-2">
          <button onClick={onClose} className="rounded-xl bg-white/10 py-3 font-semibold active:scale-95">{t('cancel')}</button>
          <button onClick={confirm} disabled={submitting || insufficient} className="rounded-xl bg-line py-3 font-bold text-black active:scale-95 disabled:opacity-50">{submitting ? t('booking') : t('confirm')}</button>
        </div>
      </div>
    </div>
  )
}
