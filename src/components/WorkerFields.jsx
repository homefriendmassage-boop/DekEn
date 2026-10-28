import { useState } from 'react'
import { supabase } from '../supabaseClient'
import { getPosition } from '../lib/geo'
import { PROVINCES } from '../provinces'
import { useI18n } from '../i18n'

export const TAGS = ['playful', 'fun_talk', 'not_picky', 'sing', 'dance', 'drinks', 'friendly']
export const SPA_TAGS = ['thai_massage', 'oil', 'foot', 'aroma', 'sports', 'scrub', 'polite', 'punctual', 'experienced']
// Two application forms: night = bartender + ENT, spa = masseuse + spa (one profile never mixes them)
export const GROUP_CATEGORIES = { night: ['bartender', 'ent'], spa: ['masseuse', 'spa'] }
export const groupOf = (cats = []) => (cats.some((c) => GROUP_CATEGORIES.spa.includes(c)) && !cats.some((c) => GROUP_CATEGORIES.night.includes(c)) ? 'spa' : 'night')
const FIXED = { night: ['@4h', '@6h', '1h'], spa: ['@60', '@90', '@120'] }        // default starting rate: the first one filled, in this order
const FIELD = { '@4h': 'p4', '@6h': 'p6', '1h': 'hourly', '@60': 'p60', '@90': 'p90', '@120': 'p120' }
const SERVICE_MODES = ['shop', 'outcall', 'both']
const PRICE_KEY = { '@4h': 'price4h', '@6h': 'price6h', '1h': 'price1h', '@60': 'price60', '@90': 'price90', '@120': 'price120' }
const GENDERS = ['female', 'male', 'lgbt']
const MAX_CUSTOM = 5

export const emptyProfile = () => ({
  gender: '', age: '', height_cm: '', weight_kg: '', measurements: '', tags: [], about: '',
  hourly: '', p4: '', p6: '', p60: '', p90: '', p120: '', serviceMode: '', custom: [], start: '', loc: null, locNew: false, locVerified: false, province: '', manual: false,
})

// The starting rate is kept in the form as '1h' | '@4h' | '@6h' | 'c<index of the custom row>' (custom labels can still be typed).
const startKey = (label, customRows) => {
  if (!label) return ''
  if (label === '1h' || label === '@4h' || label === '@6h') return label
  const i = customRows.findIndex((x) => x.label === label)
  return i >= 0 ? `c${i}` : ''
}
const isFixed = (k) => k in FIELD
const keyValue = (v, k) => (isFixed(k) ? v[FIELD[k]] : (v.custom[Number(k.slice(1))]?.label.trim() ? v.custom[Number(k.slice(1))]?.price : ''))
const keyLabel = (v, k) => (k.startsWith('c') ? v.custom[Number(k.slice(1))]?.label.trim() : k)
// What the first hire really starts at: her tick if that row is filled in, else the first filled row.
export function effectiveStart(v, grp = 'night') {
  if (v.start && keyValue(v, v.start) !== '' && keyValue(v, v.start) != null) return v.start
  return [...FIXED[grp], ...v.custom.map((_, i) => `c${i}`)].find((k) => keyValue(v, k) !== '' && keyValue(v, k) != null) ?? ''
}

// Row from `workers` / `worker_applications` -> form state. Every rate is a price_options row ('1h', '@4h', '@6h' or her own).
export function profileFromRow(r) {
  const rows = Array.isArray(r.price_options) ? r.price_options : []
  const find = (k) => rows.find((x) => x.label === k)?.price
  const hourly = find('1h') ?? (rows.length === 0 && r.price != null && groupOf(r.categories) === 'night' ? r.price : null)
  const custom = rows.filter((x) => !(x.label in FIELD)).map((x) => ({ label: x.label, price: String(x.price) }))
  return {
    ...emptyProfile(),
    gender: r.gender ?? '', age: r.age ?? '', height_cm: r.height_cm ?? '', weight_kg: r.weight_kg ?? '',
    measurements: r.measurements ?? '', tags: r.tags ?? [], about: r.about ?? '',
    hourly: hourly != null ? String(hourly) : '', p4: find('@4h') != null ? String(find('@4h')) : '', p6: find('@6h') != null ? String(find('@6h')) : '',
    p60: find('@60') != null ? String(find('@60')) : '', p90: find('@90') != null ? String(find('@90')) : '', p120: find('@120') != null ? String(find('@120')) : '',
    serviceMode: r.service_mode ?? '',
    custom,
    start: startKey(r.start_rate, custom),
    locVerified: !!r.loc_verified_at, province: r.province ?? '',
  }
}

// Form state -> columns. The server derives the province from the GPS point, so a typed province is only a fallback.
export function profileToPayload(v, grp = 'night') {
  const rows = []
  for (const k of FIXED[grp]) if (v[FIELD[k]] !== '') rows.push({ label: k, price: Number(v[FIELD[k]]) })
  for (const c of v.custom) if (c.label.trim() && c.price !== '') rows.push({ label: c.label.trim(), price: Number(c.price) })
  const k = effectiveStart(v, grp)
  const startLbl = k ? keyLabel(v, k) : ''
  const out = {
    price: Number(rows.find((r) => r.label === startLbl)?.price ?? 0),      // the DB keeps `price` equal to the starting rate
    gender: v.gender || null, age: v.age === '' ? null : Number(v.age),
    height_cm: v.height_cm === '' ? null : Number(v.height_cm), weight_kg: v.weight_kg === '' ? null : Number(v.weight_kg),
    measurements: v.measurements.trim() || null, tags: v.tags, about: v.about.trim() || null, price_options: rows, start_rate: startLbl,
    service_mode: grp === 'spa' ? v.serviceMode || null : null,
  }
  if (v.locNew && v.loc) { out.loc_lat = v.loc.lat; out.loc_lng = v.loc.lng }
  if (v.province) out.province = v.province
  return out
}

// Returns an i18n key for the first problem, or null.
export function validateProfile(v, grp = 'night', { needLocation = true } = {}) {
  if (!v.gender) return 'errGender'
  if (!(Number(v.age) >= 20)) return 'errAge'
  if (!effectiveStart(v, grp) || !(Number(keyValue(v, effectiveStart(v, grp))) > 0)) return 'errPrice'
  if (grp === 'spa' && !v.serviceMode) return 'errServiceMode'
  if (needLocation && !v.loc && !v.locVerified && !v.province) return 'errNeedLocation'
  return null
}

const input = 'mt-1 w-full rounded-xl bg-white/10 px-3 py-2.5 text-base outline-none ring-1 ring-white/10 focus:ring-line'

// Profile details, prices and the GPS-confirmed location: shared by the application form and the provider's profile editor.
export default function WorkerFields({ v, set, grp = 'night', hideLocation = false }) {
  const { t } = useI18n()
  const [busy, setBusy] = useState(false)
  const [err, setErr] = useState(null)
  const num = (k) => (e) => set({ [k]: e.target.value.replace(/[^\d]/g, '') })
  const spa = grp === 'spa'
  const eff = effectiveStart(v, grp)
  const pick = (k) => set({ start: k })
  const Start = ({ k }) => (
    <button type="button" aria-pressed={eff === k} aria-label={t('startHere')} onClick={() => pick(k)}
      className={`shrink-0 rounded-full px-2.5 py-1 text-[11px] font-bold ring-1 active:scale-95 ${eff === k ? 'bg-amber-400 text-black ring-amber-400' : 'bg-white/10 text-neutral-300 ring-white/15'}`}>
      {eff === k ? `✓ ${t('startHere')}` : t('startPick')}
    </button>
  )
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

      {spa ? (
        <label className="block text-sm">{t('fAge')}
          <input inputMode="numeric" maxLength={2} value={v.age} onChange={num('age')} className={input} />
        </label>
      ) : (
        <>
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
        </>
      )}

      {spa && (
        <fieldset>
          <legend className="text-sm">{t('fServiceMode')}</legend>
          <div className="mt-2 grid grid-cols-3 gap-2">
            {SERVICE_MODES.map((m) => (
              <button type="button" key={m} aria-pressed={v.serviceMode === m} onClick={() => set({ serviceMode: m })}
                className={`rounded-xl px-1 py-2 text-xs font-semibold ring-1 active:scale-95 ${v.serviceMode === m ? 'bg-line text-black ring-line' : 'bg-white/10 ring-white/15'}`}>{t(`serviceMode_${m}`)}</button>
            ))}
          </div>
        </fieldset>
      )}

      <fieldset>
        <legend className="text-sm">{t('fTags')}</legend>
        <div className="mt-2 flex flex-wrap gap-2">
          {(spa ? SPA_TAGS : TAGS).map((k) => (
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
        <p className="rounded-lg bg-amber-400/10 p-2 text-xs text-amber-200">{t(spa ? 'startHintSpa' : 'startHint')}</p>
        {FIXED[grp].map((k) => (
          <label key={k} className="block text-sm"><span className="flex items-center justify-between gap-1">{t(PRICE_KEY[k])} <Start k={k} /></span>
            <input inputMode="numeric" value={v[FIELD[k]]} onChange={num(FIELD[k])} className={input} />
          </label>
        ))}
        {v.custom.map((c, i) => (
          <div key={i} className="space-y-1">
          <div className="grid grid-cols-[1fr,7rem,auto] items-end gap-2">
            <label className="block text-sm">{i === 0 ? t('priceCustom') : ''}
              <input maxLength={30} value={c.label} placeholder={t('priceCustomLabel')} onChange={(e) => set({ custom: v.custom.map((x, j) => (j === i ? { ...x, label: e.target.value } : x)) })} className={input} />
            </label>
            <input inputMode="numeric" value={c.price} placeholder="฿" onChange={(e) => set({ custom: v.custom.map((x, j) => (j === i ? { ...x, price: e.target.value.replace(/[^\d]/g, '') } : x)) })} className={`${input} !mt-0`} />
            <button type="button" aria-label="remove" onClick={() => set({ custom: v.custom.filter((_, j) => j !== i), start: v.start === `c${i}` ? '' : v.start.startsWith('c') && Number(v.start.slice(1)) > i ? `c${Number(v.start.slice(1)) - 1}` : v.start })} className="rounded-xl bg-white/10 px-3 py-2.5 active:scale-95">✕</button>
          </div>
          <Start k={`c${i}`} />
          </div>
        ))}
        {v.custom.length < MAX_CUSTOM && (
          <button type="button" onClick={() => set({ custom: [...v.custom, { label: '', price: '' }] })} className="rounded-xl bg-white/10 px-3 py-2 text-sm font-semibold active:scale-95">{t('addPriceRow')}</button>
        )}
      </fieldset>

      {!hideLocation && <fieldset className="space-y-2 rounded-2xl bg-white/5 p-3">
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
      </fieldset>}
    </div>
  )
}
