import { useCallback, useEffect, useState } from 'react'
import { supabase } from '../supabaseClient'
import { useI18n } from '../i18n'
import WorkerFields, { profileFromRow, profileToPayload, validateProfile } from './WorkerFields'
import PhotoManager from './PhotoManager'
import { LocBadge, priceLabel } from './WorkerDetail'

const same = (a, b) => JSON.stringify(a ?? null) === JSON.stringify(b ?? null)

// Only what really differs from the live profile goes into the request.
function diffProfile(payload, w) {
  const cur = {
    price: Number(w.price), gender: w.gender, age: w.age, height_cm: w.height_cm, weight_kg: w.weight_kg,
    measurements: w.measurements, tags: [...(w.tags ?? [])].sort(), about: w.about, price_options: w.price_options ?? [],
    district: w.district, nearby: w.nearby, province: w.province, display_name: w.display_name,
  }
  const out = {}
  for (const [k, v] of Object.entries(payload)) {
    if (k === 'loc_lat' || k === 'loc_lng') { out[k] = v; continue }          // only present when the position was re-confirmed
    const a = k === 'tags' ? [...v].sort() : v
    if (!same(a, cur[k] ?? null)) out[k] = v
  }
  return out
}

// "My profile" for an approved provider. It is LOCKED: every change is a request the admin approves; the live
// profile stays as it is until then. First approved request is free, later ones cost money (refunded if not approved).
export default function ProfileSection({ worker, userId, onChanged, onTopUp }) {
  const { t, money, catName } = useI18n()
  const [mode, setMode] = useState('view')            // view | edit
  const [photos, setPhotos] = useState([])
  const [status, setStatus] = useState(null)          // my_edit_status()
  const [name, setName] = useState('')
  const [district, setDistrict] = useState('')
  const [nearby, setNearby] = useState('')
  const [prof, setProf] = useState(null)
  const [removeIds, setRemoveIds] = useState([])
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState(null)
  const [msg, setMsg] = useState(null)

  const load = useCallback(async () => {
    const [p, s] = await Promise.all([supabase.rpc('my_photos'), supabase.rpc('my_edit_status')])
    setPhotos(p.data ?? [])
    setStatus(s.data?.[0] ?? null)
  }, [])
  useEffect(() => { load() }, [load])

  function startEdit() {
    setName(worker.display_name ?? '')
    setDistrict(worker.district ?? '')
    setNearby(worker.nearby ?? '')
    setProf(profileFromRow(worker))
    setRemoveIds([])
    setError(null)
    setMsg(null)
    setMode('edit')
  }

  async function submit() {
    setError(null)
    const bad = validateProfile(prof)
    if (bad) return setError(t(bad))
    const payload = { display_name: name.trim(), ...profileToPayload(prof), district: district.trim() || null, nearby: nearby.trim() || null }
    const changes = diffProfile(payload, worker)
    const fee = status && status.free_left <= 0 ? Number(status.fee) : 0
    if (!window.confirm(fee > 0 ? t('editConfirmFee', { fee: money(fee) }) : t('editConfirmFree'))) return
    setBusy(true)
    const { error } = await supabase.rpc('submit_profile_edit', { p_changes: changes, p_remove: removeIds })
    setBusy(false)
    if (error) {
      const code = ['NOTHING_TO_CHANGE', 'REQUEST_PENDING', 'INSUFFICIENT_BALANCE', 'TOO_MANY_PHOTOS', 'NO_PHOTO', 'BAD_AGE', 'SUSPENDED'].find((c) => error.message.includes(c))
      if (code === 'INSUFFICIENT_BALANCE' && onTopUp && window.confirm(t('editNeedTopup', { fee: money(fee) }))) return onTopUp()
      return setError(t(code ? `editErr_${code}` : 'errGeneric'))
    }
    setMode('view')
    setMsg(t('editSent'))
    load()
    onChanged?.()
  }

  async function cancelEdit() {
    if (!window.confirm(t('editCancelConfirm'))) return
    const { error } = await supabase.rpc('cancel_profile_edit')
    if (error) return setError(t('errGeneric'))
    setMsg(null)
    load()
  }

  async function deleteProfile() {
    if (!window.confirm(t('deleteConfirm'))) return
    const { error } = await supabase.rpc('request_profile_deletion')
    if (error) return setError(t(error.message.includes('HAS_ACTIVE_JOBS') ? 'deleteErr_HAS_ACTIVE_JOBS' : 'errGeneric'))
    load()
    onChanged?.()
  }
  async function cancelDeletion() {
    const { error } = await supabase.rpc('cancel_profile_deletion')
    if (error) return setError(t('errGeneric'))
    load()
    onChanged?.()
  }

  const input = 'mt-1 w-full rounded-xl bg-white/10 px-3 py-2.5 text-base outline-none ring-1 ring-white/10 focus:ring-line'
  const live = photos.filter((p) => p.state === 'live')
  const fmt = (v) => new Date(v).toLocaleString([], { dateStyle: 'medium', timeStyle: 'short' })

  if (mode === 'edit' && prof) {
    return (
      <section className="space-y-4">
        <h2 className="text-base font-bold">✏️ {t('editTitle')}</h2>
        <p className="rounded-xl bg-amber-400/10 p-3 text-xs text-amber-200">
          {status && status.free_left > 0 ? t('editFreeNote') : t('editFeeNote', { fee: money(status?.fee ?? 20) })}
        </p>
        <label className="block text-sm">{t('fName')}
          <input value={name} maxLength={40} onChange={(e) => setName(e.target.value)} className={input} />
        </label>
        <WorkerFields v={prof} set={(p) => setProf((x) => ({ ...x, ...p }))} />
        <label className="block text-sm">{t('fDistrict')}
          <input value={district} maxLength={60} onChange={(e) => setDistrict(e.target.value)} className={input} />
        </label>
        <label className="block text-sm">{t('fNearby')}
          <input value={nearby} maxLength={120} onChange={(e) => setNearby(e.target.value)} className={input} />
        </label>
        <PhotoManager userId={userId} state="pending_add" photos={photos} removeIds={removeIds} setRemoveIds={setRemoveIds} onChanged={load} />
        {error && <p className="rounded-lg bg-red-500/10 p-2 text-sm text-red-300">{error}</p>}
        <div className="grid grid-cols-2 gap-2">
          <button onClick={() => setMode('view')} disabled={busy} className="rounded-xl bg-white/10 py-3 font-semibold active:scale-95">{t('back')}</button>
          <button onClick={submit} disabled={busy} className="rounded-xl bg-line py-3 font-bold text-black active:scale-95 disabled:opacity-50">{busy ? t('submitting') : t('editSubmit')}</button>
        </div>
      </section>
    )
  }

  const facts = [
    worker.gender && [t('fGender'), t(`gender_${worker.gender}`)], worker.age && [t('fAge'), worker.age],
    worker.height_cm && [t('fHeight'), worker.height_cm], worker.weight_kg && [t('fWeight'), worker.weight_kg],
    worker.measurements && [t('fMeasure'), worker.measurements],
  ].filter(Boolean)
  const prices = [[t('price1h'), worker.price], ...(worker.price_options ?? []).map((o) => [priceLabel(o.label, t), o.price])]

  return (
    <section className="space-y-4">
      <div>
        <h2 className="text-base font-bold">{t('profile')} · <span className="text-sm font-normal text-neutral-400">{(worker.categories ?? []).map(catName).join(' · ')}</span></h2>
        <p className="text-[11px] text-neutral-500">🔒 {t('profileLocked')}</p>
      </div>

      {status?.delete_requested_at ? (
        <div className="space-y-2 rounded-2xl bg-red-500/10 p-3 text-sm text-red-200">
          <p>{t('deletePending', { date: fmt(status.delete_at) })}</p>
          <button onClick={cancelDeletion} className="w-full rounded-xl bg-white/10 py-2 text-sm font-semibold active:scale-95">{t('deleteCancel')}</button>
        </div>
      ) : status?.pending_id ? (
        <div className="space-y-2 rounded-2xl bg-amber-400/10 p-3 text-sm text-amber-200">
          <p>⏳ {t('editPending', { date: fmt(status.pending_since) })}</p>
          <button onClick={cancelEdit} className="w-full rounded-xl bg-white/10 py-2 text-sm font-semibold active:scale-95">{t('editCancel')}</button>
        </div>
      ) : (
        <button onClick={startEdit} className="w-full rounded-xl bg-white/10 py-3 font-bold active:scale-95">
          ✏️ {t('editStart')}
          <span className="block text-[11px] font-normal text-neutral-400">{status && status.free_left > 0 ? t('editFreeShort') : t('editFeeShort', { fee: money(status?.fee ?? 20) })}</span>
        </button>
      )}
      {msg && <p className="text-sm text-green-400">{msg}</p>}
      {error && <p className="rounded-lg bg-red-500/10 p-2 text-sm text-red-300">{error}</p>}

      <div className="space-y-3 rounded-2xl bg-white/5 p-3 ring-1 ring-white/10">
        <div className="flex flex-wrap items-center gap-2">
          <p className="text-lg font-bold">{worker.display_name}</p>
          {worker.province && <LocBadge verified={!!worker.loc_verified_at} />}
        </div>
        <p className="text-xs text-neutral-400">📍 {[worker.province, worker.district].filter(Boolean).join(' · ') || '—'}</p>
        {facts.length > 0 && (
          <dl className="grid grid-cols-3 gap-2 text-center">
            {facts.map(([k, v]) => <div key={k} className="rounded-xl bg-white/5 p-2"><dt className="text-[10px] text-neutral-400">{k}</dt><dd className="text-sm font-semibold">{v}</dd></div>)}
          </dl>
        )}
        {worker.tags?.length > 0 && <div className="flex flex-wrap gap-1.5">{worker.tags.map((k) => <span key={k} className="rounded-full bg-pink-500/15 px-2.5 py-1 text-xs text-pink-200">{t(`tag_${k}`)}</span>)}</div>}
        {worker.about && <p className="whitespace-pre-wrap break-words text-sm text-neutral-200">{worker.about}</p>}
        <ul className="divide-y divide-white/5 rounded-xl bg-white/5 text-sm">
          {prices.map(([label, price], i) => <li key={i} className="flex justify-between px-3 py-2"><span>{label}</span><b>{money(price)}</b></li>)}
        </ul>
      </div>

      <div className="space-y-2">
        <h3 className="text-sm font-bold">{t('photosTitle', { n: live.length, max: 5 })}</h3>
        {live.length === 0 ? <p className="text-xs text-neutral-500">{t('noPhotos')}</p> : (
          <ul className="grid grid-cols-3 gap-2">
            {live.map((p, i) => (
              <li key={p.id} className="relative aspect-[3/4] overflow-hidden rounded-xl bg-neutral-800 ring-1 ring-white/10">
                <img src={p.public_url} alt="" className="h-full w-full object-cover" />
                {i === 0 && <span className="absolute left-1 top-1 rounded-full bg-amber-400 px-1.5 text-[10px] font-bold text-black">{t('photoMain')}</span>}
              </li>
            ))}
          </ul>
        )}
      </div>

      {!status?.delete_requested_at && (
        <button onClick={deleteProfile} className="w-full rounded-xl bg-red-500/10 py-2.5 text-sm font-semibold text-red-300 active:scale-95">🗑 {t('deleteStart')}</button>
      )}
    </section>
  )
}
