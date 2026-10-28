import { useEffect, useState } from 'react'
import { supabase } from '../supabaseClient'
import { CATEGORIES } from '../config'
import { useI18n } from '../i18n'

// Application form. An admin approves it with: select public.approve_worker('<application id>');
export default function WorkerApply({ userId, defaultName }) {
  const { t, catName } = useI18n()
  const [status, setStatus] = useState(null) // latest application status, or null
  const [loading, setLoading] = useState(true)
  const [form, setForm] = useState({ display_name: defaultName ?? '', category: CATEGORIES[0], price: '', contact: '', note: '' })
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState(null)

  useEffect(() => {
    supabase.from('worker_applications').select('status').eq('user_id', userId)
      .order('created_at', { ascending: false }).limit(1)
      .then(({ data }) => { setStatus(data?.[0]?.status ?? null); setLoading(false) })
  }, [userId])

  const set = (k) => (e) => setForm((f) => ({ ...f, [k]: e.target.value }))

  async function submit(e) {
    e.preventDefault()
    setBusy(true)
    setError(null)
    const { error } = await supabase.from('worker_applications').insert({
      user_id: userId,
      display_name: form.display_name.trim(),
      category: form.category,
      price: Number(form.price),
      contact: form.contact.trim() || null,
      note: form.note.trim() || null,
    })
    setBusy(false)
    if (error) return setError(t('errApply'))
    setStatus('pending')
  }

  if (loading) return <p className="py-20 text-center text-neutral-500">{t('loading')}</p>
  if (status === 'pending') return <p className="m-4 rounded-2xl bg-amber-400/10 p-4 text-center text-amber-200">{t('appPending')}</p>

  const input = 'mt-1 w-full rounded-xl bg-white/10 px-3 py-2.5 text-base outline-none ring-1 ring-white/10 focus:ring-line'

  return (
    <form onSubmit={submit} className="space-y-4 p-4">
      <p className="text-sm text-neutral-400">{t('applySub')}</p>
      {status === 'rejected' && <p className="rounded-xl bg-red-500/10 p-2 text-sm text-red-300">{t('appRejected')}</p>}

      <label className="block text-sm">{t('fName')}
        <input required maxLength={40} value={form.display_name} onChange={set('display_name')} className={input} />
      </label>
      <label className="block text-sm">{t('fCategory')}
        <select value={form.category} onChange={set('category')} className={input}>
          {CATEGORIES.map((c) => <option key={c} value={c} className="text-black">{catName(c)}</option>)}
        </select>
      </label>
      <label className="block text-sm">{t('fPrice')}
        <input required type="number" min="0" inputMode="numeric" value={form.price} onChange={set('price')} className={input} />
      </label>
      <label className="block text-sm">{t('fContact')}
        <input value={form.contact} onChange={set('contact')} className={input} />
      </label>
      <label className="block text-sm">{t('fNote')}
        <textarea rows={3} value={form.note} onChange={set('note')} className={input} />
      </label>

      {error && <p className="rounded-lg bg-red-500/10 p-2 text-sm text-red-300">{error}</p>}
      <button disabled={busy} className="w-full rounded-xl bg-line py-3 font-bold text-black active:scale-95 disabled:opacity-50">
        {busy ? t('submitting') : t('submit')}
      </button>
    </form>
  )
}
