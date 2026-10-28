import { useEffect, useState } from 'react'
import { supabase } from '../supabaseClient'
import { getPosition } from '../lib/geo'
import { useI18n } from '../i18n'
import { logoUrl } from '../lib/logo'
import { priceLabel, ratesOf } from './WorkerDetail'

// The girl opens the link an admin / modelling agency issued for her, with HER OWN LINE. She sees the data that was
// filled in for her, confirms her location and accepts (20+, consent, terms, joining the agency). The result is a normal
// pending application (age check + approval by an admin follow as usual).
export default function ClaimDraft({ token, onClose, onDone }) {
  const { t, catName, money } = useI18n()
  const [d, setD] = useState(null)
  const [err, setErr] = useState(null)       // load error code
  const [idx, setIdx] = useState(0)
  const [pos, setPos] = useState(null)
  const [province, setProvince] = useState(null)
  const [locBusy, setLocBusy] = useState(false)
  const [locErr, setLocErr] = useState(null)
  const [choice, setChoice] = useState('self')
  const [code, setCode] = useState('')
  const [phone, setPhone] = useState('')
  const [lineId, setLineId] = useState('')
  const [chk, setChk] = useState({ adult: false, consent: false, terms: false })
  const [busy, setBusy] = useState(false)
  const [msg, setMsg] = useState(null)
  const [sent, setSent] = useState(false)

  useEffect(() => {
    supabase.rpc('claim_preview', { p_token: token }).then(({ data, error }) => {
      if (error) return setErr(['EXPIRED', 'USED', 'NOT_FOUND'].find((c) => error.message.includes(c)) ?? 'GENERIC')
      setD(data); setPhone(data.phone ?? ''); setLineId(data.line_id ?? '')
    })
  }, [token])

  async function locate() {
    setLocBusy(true); setLocErr(null)
    try {
      const p = await getPosition()
      const { data } = await supabase.rpc('province_for', { p_lat: p.lat, p_lng: p.lng })
      if (!data) return setLocErr(t('locOutside'))
      setPos(p); setProvince(data)
    } catch { setLocErr(t('locDenied')) } finally { setLocBusy(false) }
  }

  async function submit() {
    setMsg(null)
    if (!pos) return setMsg(t('claimNeedLoc'))
    if (!(chk.adult && chk.consent && chk.terms)) return setMsg(t('claimNeedChecks'))
    if (d.source === 'admin' && choice === 'agency' && !code.trim()) return setMsg(t('claimNeedCode'))
    if (!phone.trim() && !lineId.trim()) return setMsg(t('contactHint'))
    setBusy(true)
    const { error } = await supabase.rpc('claim_draft', {
      p_token: token, p_lat: pos.lat, p_lng: pos.lng, p_choice: d.source === 'agency' ? 'agency' : choice, p_agency_code: code.trim() || null,
      p_phone: phone.trim() || null, p_line_id: lineId.trim() || null, p_adult: chk.adult, p_consent: chk.consent, p_terms: chk.terms,
    })
    setBusy(false)
    if (error) {
      const k = ['AGENCY_NOT_FOUND', 'AGENCY_FULL', 'ALREADY_PROVIDER', 'EXPIRED', 'USED', 'BAD_LOCATION', 'CONTACT_REQUIRED'].find((c) => error.message.includes(c))
      return setMsg(t(k ? `claimErr_${k}` : error.message.includes('app_contact_check') ? 'errPhone' : 'errGeneric'))
    }
    setSent(true)
  }

  const shell = (children) => (
    <div className="fixed inset-0 z-[60] flex items-end justify-center bg-black/85 sm:items-center sm:p-4">
      <div className="max-h-[94vh] w-full max-w-md space-y-4 overflow-y-auto rounded-t-3xl bg-neutral-900 p-5 pb-[calc(1.25rem+env(safe-area-inset-bottom))] shadow-2xl sm:rounded-3xl">{children}</div>
    </div>
  )

  if (err) {
    return shell(<>
      <h2 className="text-lg font-bold">{t('claimTitle')}</h2>
      <p className="rounded-xl bg-red-500/10 p-3 text-sm text-red-200">{t(`claimLoad_${err}`)}</p>
      <button onClick={onClose} className="w-full rounded-xl bg-white/10 py-3 font-semibold active:scale-95">{t('close')}</button>
    </>)
  }
  if (!d) return shell(<p className="py-10 text-center text-neutral-500">{t('loading')}</p>)
  if (sent) {
    return shell(<>
      <h2 className="text-lg font-bold">✅ {t(d.managed ? 'claimSentManagedTitle' : 'claimSentTitle')}</h2>
      <p className="text-sm text-neutral-300">{t(d.managed ? 'claimSentManagedBody' : 'claimSentBody')}</p>
      <button onClick={onDone} className="w-full rounded-xl bg-line py-3 font-bold text-black active:scale-95">{t('claimGo')}</button>
    </>)
  }
  if (d.already_provider) {
    return shell(<>
      <h2 className="text-lg font-bold">{t('claimTitle')}</h2>
      <p className="rounded-xl bg-amber-400/10 p-3 text-sm text-amber-200">{t('claimErr_ALREADY_PROVIDER')}</p>
      <button onClick={onClose} className="w-full rounded-xl bg-white/10 py-3 font-semibold active:scale-95">{t('close')}</button>
    </>)
  }

  const rates = ratesOf(d, t)
  const facts = [
    d.gender && [t('fGender'), t(`gender_${d.gender}`)], d.age && [t('fAge'), d.age], d.height_cm && [t('fHeight'), d.height_cm],
    d.weight_kg && [t('fWeight'), d.weight_kg], d.measurements && [t('fMeasure'), d.measurements],
    d.service_mode && [t('fServiceMode'), t(`serviceMode_${d.service_mode}`)],
  ].filter(Boolean)
  const input = 'mt-1 w-full rounded-xl bg-white/10 px-3 py-2.5 text-base outline-none ring-1 ring-white/10 focus:ring-line'
  const Check = ({ k, label }) => (
    <label className="flex items-start gap-2 rounded-xl bg-white/5 p-3 text-xs text-neutral-200">
      <input type="checkbox" checked={chk[k]} onChange={(e) => setChk((c) => ({ ...c, [k]: e.target.checked }))} className="mt-0.5 h-4 w-4 shrink-0" />
      <span>{label}</span>
    </label>
  )

  return shell(<>
    <h2 className="text-lg font-bold">{t('claimTitle')}</h2>
    <p className="text-sm text-neutral-400">{d.managed ? t('claimIntroManaged') : d.source === 'agency' ? t('claimIntroAgency', { name: d.agency_name ?? '' }) : t('claimIntroAdmin')}</p>

    {d.source === 'agency' && (
      <div className="flex items-center gap-3 rounded-2xl bg-amber-400/10 p-3 ring-1 ring-amber-400/30">
        {d.agency_logo && <img src={logoUrl(d.agency_logo)} alt="" className="h-10 w-10 rounded-full object-cover" />}
        <p className="text-sm font-semibold">{t('claimJoinsAgency', { name: d.agency_name ?? '' })}</p>
      </div>
    )}

    {d.photos.length > 0 && (
      <div>
        <div className="aspect-[3/4] max-h-[46vh] overflow-hidden rounded-2xl bg-neutral-800"><img src={d.photos[idx]} alt="" className="h-full w-full object-cover" /></div>
        {d.photos.length > 1 && (
          <ul className="mt-2 flex gap-2 overflow-x-auto">
            {d.photos.map((u, i) => <li key={u} className="shrink-0"><button onClick={() => setIdx(i)} className={`block h-14 w-11 overflow-hidden rounded-lg ring-2 ${i === idx ? 'ring-pink-400' : 'ring-transparent'}`}><img src={u} alt="" className="h-full w-full object-cover" /></button></li>)}
          </ul>
        )}
        <p className="mt-1 text-[11px] text-neutral-500">{t('claimPhotoNote')}</p>
      </div>
    )}

    <div>
      <h3 className="text-lg font-bold">{d.display_name}</h3>
      <div className="mt-1 flex flex-wrap gap-1">{d.categories.map((c) => <span key={c} className="rounded-full bg-white/10 px-2 py-0.5 text-xs">{catName(c)}</span>)}</div>
    </div>
    {facts.length > 0 && (
      <dl className="grid grid-cols-3 gap-2 text-center">
        {facts.map(([k, v]) => <div key={k} className="rounded-xl bg-white/5 p-2"><dt className="text-[10px] text-neutral-400">{k}</dt><dd className="text-sm font-semibold">{v}</dd></div>)}
      </dl>
    )}
    {d.tags?.length > 0 && <div className="flex flex-wrap gap-1.5">{d.tags.map((k) => <span key={k} className="rounded-full bg-pink-500/15 px-2.5 py-1 text-xs text-pink-200">{t(`tag_${k}`)}</span>)}</div>}
    {d.about && <p className="whitespace-pre-wrap break-words rounded-xl bg-white/5 p-3 text-sm">{d.about}</p>}
    <ul className="divide-y divide-white/5 rounded-xl bg-white/5 text-sm">
      {rates.map(([k, label, price]) => (
        <li key={k} className="flex justify-between px-3 py-2"><span>{label}{(d.start_rate || rates[0]?.[0]) === k && <span className="ml-2 rounded-full bg-amber-400 px-2 py-0.5 text-[10px] font-bold text-black">{t('startHere')}</span>}</span><b>{money(price)}</b></li>
      ))}
    </ul>
    <p className="text-xs text-neutral-500">{t('claimWrong')}</p>

    <section className="space-y-2 rounded-2xl bg-white/5 p-3">
      <h3 className="text-sm font-semibold">{t('locTitle')}</h3>
      <p className="text-xs text-neutral-400">{t('locHint')}</p>
      {province && <p className="rounded-lg bg-green-500/10 p-2 text-sm text-green-300">✓ {t('locDetected', { province })}</p>}
      <button onClick={locate} disabled={locBusy} className="w-full rounded-xl bg-line py-2.5 font-bold text-black active:scale-95 disabled:opacity-50">{locBusy ? t('locDetecting') : pos ? t('locRecheck') : t('locConfirm')}</button>
      {locErr && <p className="rounded-lg bg-red-500/10 p-2 text-xs text-red-300">{locErr}</p>}
    </section>

    {d.source === 'admin' && (
      <fieldset className="space-y-2">
        <legend className="text-sm font-semibold">{t('claimChoose')}</legend>
        <div className="grid grid-cols-2 gap-2">
          {[['self', t('claimSelf')], ['agency', t('claimAgency')]].map(([k, label]) => (
            <button key={k} type="button" aria-pressed={choice === k} onClick={() => setChoice(k)}
              className={`rounded-xl py-2.5 text-sm font-semibold ring-1 active:scale-95 ${choice === k ? 'bg-line text-black ring-line' : 'bg-white/10 ring-white/15'}`}>{label}</button>
          ))}
        </div>
        {choice === 'agency' && (
          <label className="block text-sm">{t('claimAgencyCode')}
            <input value={code} onChange={(e) => setCode(e.target.value)} maxLength={32} className={input} />
          </label>
        )}
      </fieldset>
    )}

    {(d.managed || !d.phone || !d.line_id) && (
      <div className="space-y-2 rounded-2xl bg-white/5 p-3">
        <p className="text-xs text-neutral-400">{d.managed ? t('bcHint') : t('contactHint')}</p>
        <label className="block text-sm">{t('fPhone')}<input type="tel" inputMode="tel" maxLength={20} value={phone} onChange={(e) => setPhone(e.target.value)} className={input} /></label>
        <label className="block text-sm">{t('fLineId')}<input maxLength={40} value={lineId} onChange={(e) => setLineId(e.target.value)} className={input} /></label>
      </div>
    )}

    <div className="space-y-2">
      <Check k="adult" label={t('claimAdult')} />
      <Check k="consent" label={t('claimConsent')} />
      <Check k="terms" label={d.source === 'agency' ? `${t('termsLabel')} ${t('claimJoinsAgency', { name: d.agency_name ?? '' })}` : t('termsLabel')} />
    </div>
    <p className="text-[11px] text-neutral-500">{t('claimExpires', { date: new Date(d.expires_at).toLocaleString([], { dateStyle: 'medium', timeStyle: 'short' }) })}</p>
    {msg && <p className="rounded-lg bg-red-500/10 p-2 text-sm text-red-300">{msg}</p>}
    <div className="grid grid-cols-2 gap-2">
      <button onClick={onClose} className="rounded-xl bg-white/10 py-3 font-semibold active:scale-95">{t('close')}</button>
      <button onClick={submit} disabled={busy} className="rounded-xl bg-line py-3 font-bold text-black active:scale-95 disabled:opacity-50">{busy ? t('submitting') : t('claimConfirm')}</button>
    </div>
  </>)
}
