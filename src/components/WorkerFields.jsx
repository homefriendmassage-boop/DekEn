import { useState } from 'react'
import { supabase } from '../supabaseClient'
import { getPosition } from '../lib/geo'
import { PROVINCES } from '../provinces'
import { useI18n } from '../i18n'

export const TAGS = ['playful', 'fun_talk', 'not_picky', 'sing', 'dance', 'drinks', 'friendly']
const GENDERS = ['female', 'male', 'lgbt']
const MAX_CUSTOM = 5

export const emptyProfile = () => ({
  gender: '', age: '', height_cm: '', weight_kg: '', measurements: '', tags: [], about: '',
  hourly: '', p4: '', p6: '', custom: [], loc: null, locNew: false, locVerified: false, province: '', manual: false,
})

// Row from `workers` / `worker_applications` -> form state ('@4h' / '@6h' are the fixed 4 h and 6 h price rows).
export function profileFromRow(r) {
  const rows = Array.isArray(r.price_options) ? r.price_options : []
  const find = (k) => rows.find((x) => x.label === k)?.price
  return {
    ...emptyProfile(),
    gender: r.gender ?? '', age: r.age ?? '', height_cm: r.height_cm ?? '', weight_kg: r.weight_kg ?? '',
    measurements: r.measurements ?? '', tags: r.tags ?? [], about: r.about ?? '',
    hourly: r.price != null ? String(r.price) : '', p4: find('@4h') != null ? String(find('@4h')) : '', p6: find('@6h') != null ? String(find('@6h')) : '',
    custom: rows.filter((x) => x.label !== '@4h' && x.label !== '@6h').map((x) => ({ label: x.label, price: String(x.price) })),
    locVerified: !!r.loc_verified_at, province: r.province ?? '',
  }
}

// Form state -> columns. The server derives the province from the GPS point, so a typed province is only a fallback.
export function profileToPayload(v) {
  const rows = []
  if (v.p4 !== '') rows.push({ label: '@4h', price: Number(v.p4) })
  if (v.p6 !== '') rows.push({ label: '@6h', price: Number(v.p6) })
  for (const c of v.custom) if (c.label.trim() && c.price !== '') rows.push({ label: c.label.trim(), price: Number(c.price) })
  const out = {
    price: Number(v.hourly),
    gender: v.gender || null, age: v.age === '' ? null : Number(v.age),
    height_cm: v.height_cm === '' ? null : Number(v.height_cm), weight_kg: v.weight_kg === '' ? null : Number(v.weight_kg),
    measurements: v.measurements.trim() || null, tags: v.tags, about: v.about.trim() || null, price_options: rows,
  }
  if (v.locNew && v.loc) { out.loc_lat = v.loc.lat; out.loc_lng = v.loc.lng }
  if (v.province) out.province = v.province
  return out
}

// Returns an i18n key for the first problem, or null.
export function validateProfile(v) {
  if (!v.gender) return 'errGender'
  if (!(Number(v.age) >= 20)) return 'errAge'
  if (!(Number(v.hourly) > 0)) return 'errHourly'
  if (!v.loc && !v.locVerified && !v.province) return 'errNeedLocation'
  return null
}

const input = 'mt-1 w-full rounded-xl bg-white/10 px-3 py-2.5 text-base outline-none ring-1 ring-white/10 focus:ring-line'

// Profile details, prices and the GPS-confirmed location: shared by the application form and the provider's profile editor.
export default function WorkerFields({ v, set }) {
  const { t } = useI18n()
  const [busy, setBusy] = useState(false)
  const [err, setErr] = useState(null)
  const num = (k) => (e) => set({ [k]: e.target.value.replace(/[^\d]/g, '') })
  const toggleTag = (k) => set({ tags: v.tags.includes(k) ? v.tags.filter((x) => x !== k) : [...v.tags, k] })

  async function locate() {
    setBusy(true)
    setErr(null)
    try {
      const pos = await getPosition()
      const { data } = await supabase.rpc('province_for', { p_lat: pos.lat, p_lng: pos.lng })
      if (!data) { setErr(t('locOutside')); return }
      set({ loc: pos, locNew: true, province: data, manual: false })
    } catch {
      setErr(t('locDenied'))
      set({ manual: true })
    } finally {
      setBusy(false)
    }
  }

  return (
    <div className="space-y-4">
      <fieldset>
        <legend className="text-sm">{t('fGender')}</legend>
        <div className="mt-2 grid grid-cols-3 gap-2">
          {GENDERS.map((g) => (
            <button type="button" key={g} aria-pressed={v.gender === g} onClick={() => set({ gender: g })}
              className={`rounded-xl py-2 text-sm font-semibold ring-1 active:scale-95 ${v.gender === g ? 'bg-line text-black ring-line' : 'bg-white/10 ring-white/15'}`}>{t(`gender_${g}`)}</button>
          ))}
        </div>
      </fieldset>

      <div className="grid grid-cols-3 gap-2">
        <label className="block text-sm">{t('fAge')}
          <input inputMode="numeric" maxLength={2} value={v.age} onChange={num('age')} className={input} />
        </label>
        <label className="block text-sm">{t('fHeight')}
          <input inputMode="numeric" maxLength={3} value={v.height_cm} onChange={num('height_cm')} className={input} />
        </label>
        <label className="block text-sm">{t('fWeight')}
          <input inputMode="numeric" maxLength={3} value={v.weight_kg} onChange={num('weight_kg')} className={input} />
        </label>
      </div>
      <label className="block text-sm">{t('fMeasure')}
        <input maxLength={20} value={v.measurements} onChange={(e) => set({ measurements: e.target.value })} placeholder="34-24-35" className={input} />
      </label>

      <fieldset>
        <legend className="text-sm">{t('fTags')}</legend>
        <div className="mt-2 flex flex-wrap gap-2">
          {TAGS.map((k) => (
            <button type="button" key={k} aria-pressed={v.tags.includes(k)} onClick={() => toggleTag(k)}
              className={`rounded-full px-3 py-1.5 text-sm font-semibold ring-1 active:scale-95 ${v.tags.includes(k) ? 'bg-line text-black ring-line' : 'bg-white/10 ring-white/15'}`}>
              {v.tags.includes(k) ? '✓ ' : ''}{t(`tag_${k}`)}
            </button>
          ))}
        </div>
        <label className="mt-2 block text-sm">{t('fAbout')}
          <textarea rows={3} maxLength={300} value={v.about} onChange={(e) => set({ about: e.target.value })} className={input} />
        </label>
      </fieldset>

      <fieldset className="space-y-2 rounded-2xl bg-white/5 p-3">
        <legend className="px-1 text-sm font-semibold">{t('fPrices')}</legend>
        <label className="block text-sm">{t('price1h')}
          <input inputMode="numeric" value={v.hourly} onChange={num('hourly')} className={input} />
        </label>
        <div className="grid grid-cols-2 gap-2">
          <label className="block text-sm">{t('price4h')} <span className="text-[11px] text-neutral-500">({t('optional')})</span>
            <input inputMode="numeric" value={v.p4} onChange={num('p4')} className={input} />
          </label>
          <label className="block text-sm">{t('price6h')} <span className="text-[11px] text-neutral-500">({t('optional')})</span>
            <input inputMode="numeric" value={v.p6} onChange={num('p6')} className={input} />
          </label>
        </div>
        {v.custom.map((c, i) => (
          <div key={i} className="grid grid-cols-[1fr,7rem,auto] items-end gap-2">
            <label className="block text-sm">{i === 0 ? t('priceCustom') : ''}
              <input maxLength={30} value={c.label} placeholder={t('priceCustomLabel')} onChange={(e) => set({ custom: v.custom.map((x, j) => (j === i ? { ...x, label: e.target.value } : x)) })} className={input} />
            </label>
            <input inputMode="numeric" value={c.price} placeholder="฿" onChange={(e) => set({ custom: v.custom.map((x, j) => (j === i ? { ...x, price: e.target.value.replace(/[^\d]/g, '') } : x)) })} className={`${input} !mt-0`} />
            <button type="button" aria-label="remove" onClick={() => set({ custom: v.custom.filter((_, j) => j !== i) })} className="rounded-xl bg-white/10 px-3 py-2.5 active:scale-95">✕</button>
          </div>
        ))}
        {v.custom.length < MAX_CUSTOM && (
          <button type="button" onClick={() => set({ custom: [...v.custom, { label: '', price: '' }] })} className="rounded-xl bg-white/10 px-3 py-2 text-sm font-semibold active:scale-95">{t('addPriceRow')}</button>
        )}
      </fieldset>

      <fieldset className="space-y-2 rounded-2xl bg-white/5 p-3">
        <legend className="px-1 text-sm font-semibold">{t('locTitle')}</legend>
        <p className="text-xs text-neutral-400">{t('locHint')}</p>
        {(v.loc || v.locVerified) && v.province && (
          <p className="rounded-lg bg-green-500/10 p-2 text-sm text-green-300">✓ {t('locDetected', { province: v.province })}</p>
        )}
        <button type="button" disabled={busy} onClick={locate} className="w-full rounded-xl bg-line py-2.5 font-bold text-black active:scale-95 disabled:opacity-50">
          {busy ? t('locDetecting') : v.loc || v.locVerified ? t('locRecheck') : t('locConfirm')}
        </button>
        {!v.manual && <button type="button" onClick={() => set({ manual: true })} className="text-xs text-neutral-400 underline">{t('locCannot')}</button>}
        {err && <p className="rounded-lg bg-red-500/10 p-2 text-xs text-red-300">{err}</p>}
        {v.manual && v.province && !v.loc && <p className="rounded-lg bg-amber-400/10 p-2 text-xs text-amber-200">{t('locSelfNote')}</p>}
        {v.manual && (
          <label className="block text-sm">{t('locManual')}
            <select value={v.province} onChange={(e) => set({ province: e.target.value, loc: null, locNew: false, locVerified: false })} className={input}>
              <option value="" className="text-black">{t('chooseProvince')}</option>
              {PROVINCES.map((p) => <option key={p} value={p} className="text-black">{p}</option>)}
            </select>
          </label>
        )}
      </fieldset>
    </div>
  )
}
