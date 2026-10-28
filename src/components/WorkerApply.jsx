import { useCallback, useEffect, useState } from 'react'
import { supabase } from '../supabaseClient'
import { CATEGORIES } from '../config'
import { PROVINCES } from '../provinces'
import { useI18n } from '../i18n'
import PhotoUploader from './PhotoUploader'

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
  const [error, setError] = useState(null)
  const [note, setNote] = useState(null)

  const load = useCallback(async () => {
    const { data } = await supabase.from('worker_applications').select('*')
      .eq('user_id', userId).order('created_at', { ascending: false }).limit(1)
    const row = data?.[0] ?? null
    setApp(row)
    if (row) setForm(toForm(row)) // pending: edit it; rejected: prefill a fresh attempt
    setLoading(false)
  }, [userId])

  useEffect(() => { load() }, [load])

  const set = (k) => (e) => setForm((f) => ({ ...f, [k]: e.target.value }))
  const toggleCat = (c) => setForm((f) => ({
    ...f, categories: f.categories.includes(c) ? f.categories.filter((x) => x !== c) : [...f.categories, c],
  }))

  async function submit(e) {
    e.preventDefault()
    setError(null)
    setNote(null)
    if (form.categories.length === 0) return setError(t('pickCategory'))
    if (!form.phone.trim() && !form.line_id.trim()) return setError(t('contactHint'))

    const payload = {
      display_name: form.display_name.trim(),
      categories: form.categories,
      price: Number(form.price),
      province: form.province,
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
      : await supabase.from('worker_applications').insert({ user_id: userId, ...payload })
    setBusy(false)
    if (error) return setError(error.message.includes('app_contact_check') ? t('errPhone') : t('errApply'))
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

      {/* Promo photo (needs an existing application, so it appears after the first submit) */}
      <section className="space-y-3">
        <h2 className="text-base font-bold">{t('appPhotoTitle')}</h2>
        {editing ? (
          <>
            {app.profile_image && <img src={app.profile_image} alt="" className="mx-auto max-h-64 rounded-xl" />}
            <PhotoUploader target="application" userId={userId} previousOriginal={app.original_path} onUploaded={load} />
          </>
        ) : (
          <p className="rounded-xl bg-white/5 p-3 text-sm text-neutral-400">{t('appPhotoAfter')}</p>
        )}
      </section>

      <form onSubmit={submit} className="space-y-4">
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

        <label className="block text-sm">{t('fPrice')}
          <input required type="number" min="0" inputMode="numeric" value={form.price} onChange={set('price')} className={input} />
        </label>
        <label className="block text-sm">{t('fProvince')}
          <select required value={form.province} onChange={set('province')} className={input}>
            <option value="" className="text-black">{t('chooseProvince')}</option>
            {PROVINCES.map((p) => <option key={p} value={p} className="text-black">{p}</option>)}
          </select>
        </label>
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

        {error && <p className="rounded-lg bg-red-500/10 p-2 text-sm text-red-300">{error}</p>}
        {note && <p className="text-sm text-green-400">{note}</p>}
        <button disabled={busy} className="w-full rounded-xl bg-line py-3 font-bold text-black active:scale-95 disabled:opacity-50">
          {busy ? t('submitting') : editing ? t('saveChanges') : t('submit')}
        </button>
      </form>
    </div>
  )
}
