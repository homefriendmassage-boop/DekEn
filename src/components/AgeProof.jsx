import { useState } from 'react'
import { supabase } from '../supabaseClient'
import { useI18n } from '../i18n'
import { shrinkImage } from '../lib/photos'

// Shown to an applicant only when the admin asked for proof of age: ID card + a selfie holding it.
// The pictures go to a private bucket only admins can open; the admin deletes them once the age is confirmed.
export default function AgeProof({ userId, note, onDone }) {
  const { t } = useI18n()
  const [idFile, setIdFile] = useState(null)
  const [selfie, setSelfie] = useState(null)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState(null)

  async function send() {
    if (!idFile || !selfie || busy) return
    setBusy(true)
    setError(null)
    try {
      const idPath = `${userId}/id.jpg`
      const selfiePath = `${userId}/selfie.jpg`
      const a = await supabase.storage.from('id-docs').upload(idPath, await shrinkImage(idFile), { upsert: true, contentType: 'image/jpeg' })
      if (a.error) throw a.error
      const b = await supabase.storage.from('id-docs').upload(selfiePath, await shrinkImage(selfie), { upsert: true, contentType: 'image/jpeg' })
      if (b.error) throw b.error
      const { error } = await supabase.rpc('submit_age_proof', { p_id_path: idPath, p_selfie_path: selfiePath })
      if (error) throw error
      onDone?.()
    } catch (e) {
      console.error(e)
      setError(t('errUpload'))
    }
    setBusy(false)
  }

  const pick = (label, file, setFile) => (
    <label className="block cursor-pointer rounded-xl bg-white/10 p-3 text-center text-sm font-semibold active:scale-95">
      {file ? `✓ ${label}` : label}
      <input type="file" accept="image/*" className="hidden" onChange={(e) => setFile(e.target.files?.[0] ?? null)} />
      {file && <span className="mt-1 block truncate text-[11px] font-normal text-neutral-400">{file.name}</span>}
    </label>
  )

  return (
    <section className="space-y-3 rounded-2xl bg-amber-400/10 p-3 ring-1 ring-amber-400/30">
      <h2 className="text-base font-bold">🪪 {t('ageProofTitle')}</h2>
      <p className="text-sm text-amber-100">{t('ageProofBody')}{note ? ` — ${note}` : ''}</p>
      {pick(t('ageProofId'), idFile, setIdFile)}
      {pick(t('ageProofSelfie'), selfie, setSelfie)}
      <p className="text-[11px] text-neutral-400">{t('ageProofPrivacy')}</p>
      {error && <p className="rounded-lg bg-red-500/10 p-2 text-xs text-red-300">{error}</p>}
      <button disabled={!idFile || !selfie || busy} onClick={send} className="w-full rounded-xl bg-line py-2.5 font-bold text-black active:scale-95 disabled:opacity-40">
        {busy ? t('uploading') : t('ageProofSend')}
      </button>
    </section>
  )
}
