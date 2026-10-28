import { useCallback, useEffect, useState } from 'react'
import { supabase } from '../supabaseClient'
import { CATEGORIES } from '../config'
import { useI18n } from '../i18n'
import PhotoManager from './PhotoManager'
import AgeProof from './AgeProof'
import { uploadPhoto } from '../lib/photos'
import WorkerFields, { emptyProfile, profileFromRow, profileToPayload, validateProfile } from './WorkerFields'
import { clearAgencyCode, getAgencyCode } from '../lib/auth'
import { logoUrl } from '../lib/logo'

const EMPTY = { display_name: '', categories: [], price: '', province: '', district: '', nearby: '', phone: '', line_id: '', note: '' }
const toForm = (a) => ({
  display_name: a.display_name ?? '', categories: a.categories ?? [], price: String(a.price ?? ''),
  province: a.province ?? '', district: a.district ?? '', nearby: a.nearby ?? '',
  phone: a.phone ?? '', line_id: a.line_id ?? '', note: a.note ?? '',
})

// Application form. Creating it makes a `pending` row; while pending the applicant can edit it
// and upload a promo photo. An admin approves with: select public.approve_worker('<application id>');
export default function WorkerApply({ userId, defaultName }) {
  const { t, catName } = useI18n()
  const [app, setApp] = useState(null)       // latest application row, or null
  const [loading, setLoading] = useState(true)
  const [form, setForm] = useState({ ...EMPTY, display_name: defaultName ?? '' })
  const [busy, setBusy] = useState(false)
  const [prof, setProf] = useState(emptyProfile)
  const [terms, setTerms] = useState(false)
  const [photos, setPhotos] = useState([])     // my_photos() rows (an existing application)
  const [local, setLocal] = useState([])       // pictures picked before the application exists
  const [error, setError] = useState(null)
  const [note, setNote] = useState(null)
  const [invite, setInvite] = useState(() => getAgencyCode())   // code from the agency's own link, if any
  const [agency, setAgency] = useState(null)                     // { name, logo_path } of that agency (or of my application)

  const load = useCallback(async () => {
    const { data } = await supabase.from('worker_applications').select('*')
      .eq('user_id', userId).order('created_at', { ascending: false }).limit(1)
    const row = data?.[0] ?? null
    setApp(row)
    if (row) { setForm(toForm(row)); setProf(profileFromRow(row)) } // pending: edit it; rejected: prefill a fresh attempt
    if (row?.status === 'pending') { const ph = await supabase.rpc('my_photos'); setPhotos(ph.data ?? []) }
    setLoading(false)
  }, [userId])

  useEffect(() => { load() }, [load])

  // Which agency the link (or my existing application) belongs to. An unknown code is forgotten.
  const lookupCode = app?.agency_code ?? invite
  useEffect(() => {
    if (!lookupCode) return setAgency(null)
    supabase.rpc('agency_public', { p_code: lookupCode }).then(({ data }) => {
      setAgency(data?.[0] ?? null)
      if (!data?.[0] && !app?.agency_code) { clearAgencyCode(); setInvite(null) }
    })
  }, [lookupCode, app?.agency_code])

  const set = (k) => (e) => setForm((f) => ({ ...f, [k]: e.target.value }))
  const toggleCat = (c) => setForm((f) => ({
    ...f, categories: f.categories.includes(c) ? f.categories.filter((x) => x !== c) : [...f.categories, c],
  }))

  async function submit(e) {
    e.preventDefault()
    setError(null)
    setNote(null)
    if (form.categories.length === 0) return setError(t('pickCategory'))
    const bad = validateProfile(prof)
    if (bad) return setError(t(bad))
    if (app?.status !== 'pending' && !terms) return setError(t('errTerms'))
    if (app?.status !== 'pending' && local.length === 0) return setError(t('errNeedPhoto'))
    if (!form.phone.trim() && !form.line_id.trim()) return setError(t('contactHint'))
    const joining = app?.status !== 'pending' && !!invite && !!agency

    const payload = {
      display_name: form.display_name.trim(),
      categories: form.categories,
      ...profileToPayload(prof),
      district: form.district.trim() || null,
      nearby: form.nearby.trim() || null,
      phone: form.phone.trim() || null,
      line_id: form.line_id.trim() || null,
      note: form.note.trim() || null,
    }
    setBusy(true)
    const editing = app?.status === 'pending'
    const { error } = editing
      ? await supabase.from('worker_applications').update(payload).eq('id', app.id)
      : await supabase.from('worker_applications').insert({ user_id: userId, ...payload, accepted_terms: true, agency_code: joining ? invite : null })
    setBusy(false)
    if (error) return setError(error.message.includes('app_contact_check') ? t('errPhone') : error.message.includes('AGENCY_NOT_FOUND') ? t('errAgencyNotFound') : error.message.includes('AGENCY_FULL') ? t('errAgencyFull') : error.message.includes('CONTACT_IN_PROFILE') ? t('errContactProfile') : t('errApply'))
    if (joining) clearAgencyCode()
    if (!editing && local.length > 0) {            // the application exists now: send the pictures picked earlier
      try { for (const pic of local) await uploadPhoto(userId, pic, 'application') } catch (e) { console.error(e); setError(t('errUpload')) }
      setLocal([])
    }
    setNote(t('saved'))
    load()
  }

  if (loading) return <p className="py-20 text-center text-neutral-500">{t('loading')}</p>

  const editing = app?.status === 'pending'
  const input = 'mt-1 w-full rounded-xl bg-white/10 px-3 py-2.5 text-base outline-none ring-1 ring-white/10 focus:ring-line'

  return (
    <div className="space-y-5 p-4">
      {editing ? (
        <p className="rounded-2xl bg-amber-400/10 p-3 text-sm text-amber-200">{t('appPending')}</p>
      ) : (
        <>
          <p className="text-sm text-neutral-400">{t('applySub')}</p>
          {app?.status === 'rejected' && (
            <p className="rounded-xl bg-red-500/10 p-2 text-sm text-red-300">
              {t('appRejected')}{app.reject_reason ? ` — ${app.reject_reason}` : ''}
            </p>
          )}
        </>
      )}

      {/* The admin asked for proof of age */}
      {editing && app.age_check_status === 'requested' && <AgeProof userId={userId} note={app.age_check_note} onDone={load} />}
      {editing && app.age_check_status === 'submitted' && <p className="rounded-2xl bg-white/5 p-3 text-sm text-neutral-300">🪪 {t('ageProofSent')}</p>}

      {/* Promo pictures: 1-5, attached to the application so the admin can judge them together with the form */}
      <section className="space-y-3">
        <h2 className="text-base font-bold">{t('appPhotoTitle')}</h2>
        <PhotoManager userId={userId} state="application" photos={photos} local={editing ? undefined : local} setLocal={editing ? undefined : setLocal} onChanged={load} />
      </section>

      <form onSubmit={submit} className="space-y-4">
        {editing && app.agency_id ? (
          <div className="flex items-center gap-3 rounded-2xl bg-white/5 p-3 ring-1 ring-white/10">
            {agency?.logo_path && <img src={logoUrl(agency.logo_path)} alt="" className="h-10 w-10 rounded-full object-cover" />}
            <div className="text-sm">
              <p className="font-semibold">{t('agencyIs', { name: agency?.name ?? '…' })}</p>
              <p className="text-xs text-neutral-400">
                {app.agency_status === 'rejected' ? t('affRejected', { name: agency?.name ?? '' }) : t('affAccepted', { name: agency?.name ?? '' })}
              </p>
            </div>
          </div>
        ) : !editing && invite && agency && (
          <div className="space-y-2 rounded-2xl bg-amber-400/10 p-3 ring-1 ring-amber-400/30">
            <div className="flex items-center gap-3">
              {agency.logo_path && <img src={logoUrl(agency.logo_path)} alt="" className="h-10 w-10 rounded-full object-cover" />}
              <div className="text-sm">
                <p className="font-semibold">{t('applyingUnder', { name: agency.name })}</p>
                <p className="text-xs text-neutral-300">{t('agencyInfo')}</p>
              </div>
            </div>
            <button type="button" onClick={() => { clearAgencyCode(); setInvite(null) }} className="text-xs text-neutral-400 underline">{t('applySelfInstead')}</button>
          </div>
        )}

        <label className="block text-sm">{t('fName')}
          <input required maxLength={40} value={form.display_name} onChange={set('display_name')} className={input} />
        </label>

        <fieldset>
          <legend className="text-sm">{t('fCategories')}</legend>
          <div className="mt-2 flex flex-wrap gap-2">
            {CATEGORIES.map((c) => {
              const on = form.categories.includes(c)
              return (
                <button
                  type="button" key={c} onClick={() => toggleCat(c)} aria-pressed={on}
                  className={`rounded-full px-4 py-2 text-sm font-semibold ring-1 transition active:scale-95 ${
                    on ? 'bg-line text-black ring-line' : 'bg-white/10 text-neutral-200 ring-white/15'
                  }`}
                >
                  {on ? '✓ ' : ''}{catName(c)}
                </button>
              )
            })}
          </div>
        </fieldset>

        <WorkerFields v={prof} set={(p) => setProf((x) => ({ ...x, ...p }))} />
        <label className="block text-sm">{t('fDistrict')}
          <input maxLength={60} value={form.district} onChange={set('district')} className={input} />
        </label>
        <label className="block text-sm">{t('fNearby')}
          <input maxLength={120} value={form.nearby} onChange={set('nearby')} className={input} />
        </label>

        <div className="space-y-3 rounded-2xl bg-white/5 p-3">
          <p className="text-xs text-neutral-400">{t('contactHint')}</p>
          <label className="block text-sm">{t('fPhone')}
            <input type="tel" inputMode="tel" maxLength={20} value={form.phone} onChange={set('phone')} className={input} />
          </label>
          <label className="block text-sm">{t('fLineId')}
            <input maxLength={40} value={form.line_id} onChange={set('line_id')} className={input} />
          </label>
        </div>

        <label className="block text-sm">{t('fNote')}
          <textarea rows={3} value={form.note} onChange={set('note')} className={input} />
        </label>

        {!editing && (
          <label className="flex items-start gap-2 rounded-xl bg-white/5 p-3 text-xs text-neutral-300">
            <input type="checkbox" checked={terms} onChange={(e) => setTerms(e.target.checked)} className="mt-0.5 h-4 w-4 shrink-0" />
            <span>{t('termsLabel')}</span>
          </label>
        )}
        {error && <p className="rounded-lg bg-red-500/10 p-2 text-sm text-red-300">{error}</p>}
        {note && <p className="text-sm text-green-400">{note}</p>}
        <button disabled={busy} className="w-full rounded-xl bg-line py-3 font-bold text-black active:scale-95 disabled:opacity-50">
          {busy ? t('submitting') : editing ? t('saveChanges') : t('submit')}
        </button>
      </form>
    </div>
  )
}
