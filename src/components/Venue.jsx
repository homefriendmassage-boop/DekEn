import { useEffect, useState } from 'react'
import { supabase } from '../supabaseClient'
import { getPosition } from '../lib/geo'
import { useI18n } from '../i18n'

const link = (lat, lng) => `https://www.google.com/maps?q=${lat},${lng}`

// Regular venue of a PR girl, as shown on her profile (name + a map link). Renders nothing for anybody else / without data.
export function VenueView({ worker }) {
  const { t } = useI18n()
  const [v, setV] = useState(null)
  const isPr = (worker.categories ?? []).includes('pr')
  useEffect(() => {
    if (!isPr) return undefined
    let alive = true
    supabase.rpc('worker_venue', { p_worker: worker.user_id }).then(({ data }) => { if (alive) setV(data?.[0] ?? null) })
    return () => { alive = false }
  }, [worker.user_id, isPr, worker.canView])
  if (!isPr || !v || (!v.venue_name && v.venue_lat == null)) return null
  return (
    <div className="rounded-xl bg-white/5 p-2.5">
      <p className="text-[11px] text-neutral-400">{t('venueTitle')}</p>
      <p className="text-sm font-semibold">🏠 {v.venue_name ?? '—'}</p>
      {v.venue_lat != null && (
        <a href={link(v.venue_lat, v.venue_lng)} target="_blank" rel="noreferrer" className="mt-1 inline-block rounded-lg bg-line px-3 py-1 text-xs font-bold text-black active:scale-95">📍 {t('venueOpenMap')}</a>
      )}
    </div>
  )
}

// A PR girl keeps her venue name and pin up to date herself: it is saved at once, no admin approval.
export function VenueEditor({ worker }) {
  const { t } = useI18n()
  const [name, setName] = useState('')
  const [pin, setPin] = useState(null)
  const [busy, setBusy] = useState(false)
  const [msg, setMsg] = useState(null)
  const [err, setErr] = useState(null)
  const isPr = (worker.categories ?? []).includes('pr')
  useEffect(() => {
    if (!isPr) return undefined
    let alive = true
    supabase.rpc('worker_venue', { p_worker: worker.user_id }).then(({ data }) => {
      const r = data?.[0]
      if (alive && r) { setName(r.venue_name ?? ''); setPin(r.venue_lat != null ? { lat: r.venue_lat, lng: r.venue_lng } : null) }
    })
    return () => { alive = false }
  }, [worker.user_id, isPr])
  if (!isPr) return null

  async function here() {
    setErr(null); setMsg(null); setBusy(true)
    try { setPin(await getPosition()) } catch { setErr(t('locDenied')) } finally { setBusy(false) }
  }
  async function save() {
    setErr(null); setMsg(null); setBusy(true)
    const { error } = await supabase.rpc('set_my_venue', { p_name: name, p_lat: pin?.lat ?? null, p_lng: pin?.lng ?? null })
    setBusy(false)
    if (error) {
      const m = error.message
      return setErr(t(m.includes('BAD_VENUE_NAME') ? 'venueBadName' : m.includes('CONTACT') ? 'errContactProfile' : m.includes('BAD_LOCATION') ? 'locOutside' : 'errGeneric'))
    }
    setMsg(t('venueSaved'))
  }

  return (
    <div className="space-y-2 rounded-2xl bg-white/5 p-3 ring-1 ring-white/10">
      <p className="text-sm font-bold">🏠 {t('venueTitle')}</p>
      <p className="text-[11px] text-neutral-400">{t('venueHint')}</p>
      <label className="block text-sm">{t('venueName')}
        <input maxLength={60} value={name} onChange={(e) => setName(e.target.value)} className="mt-1 w-full rounded-xl bg-white/10 px-3 py-2.5 text-base outline-none ring-1 ring-white/10 focus:ring-line" />
      </label>
      <div className="flex flex-wrap items-center gap-2">
        <button type="button" onClick={here} disabled={busy} className="rounded-xl bg-white/10 px-3 py-2 text-sm font-semibold active:scale-95 disabled:opacity-50">📍 {t('venueUseHere')}</button>
        {pin && <>
          <a href={link(pin.lat, pin.lng)} target="_blank" rel="noreferrer" className="text-xs text-line underline">{t('venueOpenMap')}</a>
          <button type="button" onClick={() => setPin(null)} className="text-xs text-neutral-400 underline">{t('venueClearPin')}</button>
        </>}
      </div>
      {msg && <p className="text-sm text-green-400">{msg}</p>}
      {err && <p className="rounded-lg bg-red-500/10 p-2 text-sm text-red-300">{err}</p>}
      <button type="button" onClick={save} disabled={busy} className="w-full rounded-xl bg-line py-2.5 font-bold text-black active:scale-95 disabled:opacity-50">{busy ? t('submitting') : t('venueSave')}</button>
    </div>
  )
}
