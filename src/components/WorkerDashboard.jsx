import { useCallback, useEffect, useState } from 'react'
import { supabase } from '../supabaseClient'
import { useI18n } from '../i18n'
import PhotoUploader from './PhotoUploader'
import ThreadList from './ThreadList'
import ChatModal from './ChatModal'
import RankBoost from './RankBoost'
import WorkerFields, { profileFromRow, profileToPayload, validateProfile } from './WorkerFields'
import { logoUrl } from '../lib/logo'
import { clearAgencyCode, getAgencyCode } from '../lib/auth'

// Provider home: online switch, profile edit, photo upload, live job inbox.
export default function WorkerDashboard({ userId, onTopUp }) {
  const { t, money, catName, statusName } = useI18n()
  const [worker, setWorker] = useState(null)
  const [jobs, setJobs] = useState([])
  const [form, setForm] = useState({ display_name: '', price: '', province: '', district: '', nearby: '' })
  const [chat, setChat] = useState(null)
  const [prof, setProf] = useState(null)   // details / prices / location (WorkerFields)
  const [note, setNote] = useState(null)
  const [invite, setInvite] = useState(() => getAgencyCode())      // invitation link opened earlier
  const [inviteAgency, setInviteAgency] = useState(null)
  const [aff, setAff] = useState(null)   // my_worker_agency(): { agency_name, logo_path, plan_expires_at, can_leave }
  const [error, setError] = useState(null)

  const loadWorker = useCallback(async () => {
    const { data, error } = await supabase.from('workers').select('*').eq('user_id', userId).single()
    if (error) return setError(t('errGeneric'))
    setWorker(data)
    setProf(profileFromRow(data))
    setForm({ display_name: data.display_name, price: String(data.price), province: data.province ?? '', district: data.district ?? '', nearby: data.nearby ?? '' })
  }, [userId]) // eslint-disable-line

  const loadJobs = useCallback(async () => {
    const { data } = await supabase.rpc('my_worker_jobs')
    setJobs(data ?? [])
  }, [])

  const loadAff = useCallback(() => supabase.rpc('my_worker_agency').then(({ data }) => setAff(data?.[0] ?? null)), [])
  useEffect(() => { loadWorker(); loadJobs(); loadAff() }, [loadWorker, loadJobs, loadAff])

  useEffect(() => {
    if (!invite) return setInviteAgency(null)
    supabase.rpc('agency_public', { p_code: invite }).then(({ data }) => setInviteAgency(data?.[0] ?? null))
  }, [invite])

  async function joinAgency() {
    const { error } = await supabase.rpc('worker_join_agency', { p_code: invite })
    if (error) return setError(t(error.message.includes('AGENCY_FULL') ? 'errAgencyFull' : error.message.includes('ALREADY_IN_AGENCY') ? 'errAlreadyInAgency' : 'errGeneric'))
    clearAgencyCode(); setInvite(null)
    setNote(t('joinedAgency'))
    loadAff()
  }

  async function leaveAgency() {
    if (!window.confirm(t('leaveAgencyConfirm'))) return
    const { error } = await supabase.rpc('worker_leave_agency')
    if (error) return setError(t('errGeneric'))
    setNote(t('leftAgency'))
    loadAff()
  }

  // New bookings / status changes appear instantly (RLS lets the worker see their own jobs).
  useEffect(() => {
    const ch = supabase.channel('worker-jobs')
      .on('postgres_changes', { event: '*', schema: 'public', table: 'jobs', filter: `worker_id=eq.${userId}` }, loadJobs)
      .subscribe()
    return () => { supabase.removeChannel(ch) }
  }, [userId, loadJobs])

  async function update(patch) {
    setError(null)
    const { error } = await supabase.from('workers').update(patch).eq('user_id', userId)
    if (error) return setError(t('errGeneric'))
    setNote(t('saved'))
    setTimeout(() => setNote(null), 2000)
    loadWorker()
  }

  async function setStatus(id, status) {
    setError(null)
    const { error } = await supabase.from('jobs').update({ status }).eq('id', id)
    if (error) setError(t('errGeneric'))
    loadJobs()
  }

  if (!worker) return <p className="py-20 text-center text-neutral-500">{error ?? t('loading')}</p>

  const input = 'mt-1 w-full rounded-xl bg-white/10 px-3 py-2.5 text-base outline-none ring-1 ring-white/10 focus:ring-line'

  return (
    <div className="space-y-5 p-4">
      {/* Online switch */}
      <button
        onClick={() => update({ is_online: !worker.is_online })}
        className={`flex w-full items-center justify-between rounded-2xl p-4 text-left ${worker.is_online ? 'bg-green-500/15 ring-1 ring-green-400' : 'bg-white/5 ring-1 ring-white/10'}`}
      >
        <span className="text-sm font-semibold">{worker.is_online ? t('onlineNow') : t('offlineNow')}</span>
        <span className={`relative h-7 w-12 shrink-0 rounded-full transition ${worker.is_online ? 'bg-line' : 'bg-neutral-600'}`}>
          <span className={`absolute top-0.5 h-6 w-6 rounded-full bg-white transition-all ${worker.is_online ? 'left-[22px]' : 'left-0.5'}`} />
        </span>
      </button>

      {error && <p className="rounded-lg bg-red-500/10 p-2 text-sm text-red-300">{error}</p>}

      {/* Invitation from an agency (also how a girl who left comes back) */}
      {invite && inviteAgency && !aff && (
        <section className="space-y-2 rounded-2xl bg-amber-400/10 p-3 ring-1 ring-amber-400/30">
          <div className="flex items-center gap-3">
            {inviteAgency.logo_path && <img src={logoUrl(inviteAgency.logo_path)} alt="" className="h-10 w-10 rounded-full object-cover" />}
            <p className="font-semibold">{t('invitedBy', { name: inviteAgency.name })}</p>
          </div>
          <div className="grid grid-cols-2 gap-2">
            <button onClick={joinAgency} className="rounded-xl bg-line py-2 text-sm font-bold text-black active:scale-95">{t('joinAgencyBtn')}</button>
            <button onClick={() => { clearAgencyCode(); setInvite(null) }} className="rounded-xl bg-white/10 py-2 text-sm active:scale-95">{t('joinLater')}</button>
          </div>
        </section>
      )}

      {/* Agency affiliation: she can leave after the waiting period (or when the agency's plan is not active) */}
      {aff && (
        <section className="space-y-2 rounded-2xl bg-white/5 p-3 ring-1 ring-white/10">
          <div className="flex items-center gap-3">
            {aff.logo_path && <img src={logoUrl(aff.logo_path)} alt="" className="h-10 w-10 rounded-full object-cover" />}
            <div className="min-w-0">
              <p className="text-xs text-neutral-400">{t('myAgency')}</p>
              <p className="truncate font-bold">{aff.agency_name}</p>
            </div>
          </div>
          <button disabled={!aff.can_leave} onClick={leaveAgency}
            className="w-full rounded-xl bg-white/10 py-2 text-sm font-semibold active:scale-95 disabled:opacity-40">{t('leaveAgency')}</button>
          {!aff.can_leave && aff.can_leave_at && (
            <p className="text-[11px] text-neutral-500">{t('leaveAgencyFrom', { date: new Date(aff.can_leave_at).toLocaleDateString() })}</p>
          )}
        </section>
      )}

      {/* Inbox */}
      <section>
        <h2 className="mb-2 text-base font-bold">{t('jobs')}</h2>
        {jobs.length === 0 ? (
          <p className="rounded-2xl bg-white/5 p-4 text-center text-sm text-neutral-500">{t('noJobs')}</p>
        ) : (
          <ul className="space-y-2">
            {jobs.map((j) => (
              <li key={j.id} className="rounded-2xl bg-white/5 p-3 text-sm ring-1 ring-white/10">
                <div className="flex items-center justify-between gap-2">
                  <p className="font-semibold">{t('customer')}: {j.customer_name ?? '—'}</p>
                  <span className="rounded-full bg-white/10 px-2 py-0.5 text-[11px]">{statusName(j.status)}</span>
                </div>
                <p className="mt-1 text-xs text-neutral-400">
                  {t('cashLabel')}: <b className="text-white">{money(j.service_price)}</b> · {t('feeLabel')}: {money(j.booking_fee)}
                </p>
                <p className="text-[11px] text-neutral-500">{new Date(j.created_at).toLocaleString()}</p>
                {(j.status === 'pending' || j.status === 'matched') && (
                  <div className="mt-2 grid grid-cols-2 gap-2">
                    {j.status === 'pending' ? (
                      <>
                        <button onClick={() => setStatus(j.id, 'matched')} className="rounded-lg bg-line py-2 font-bold text-black active:scale-95">{t('accept')}</button>
                        <button onClick={() => setStatus(j.id, 'cancelled')} className="rounded-lg bg-white/10 py-2 font-semibold active:scale-95">{t('decline')}</button>
                      </>
                    ) : (
                      <>
                        <button onClick={() => setStatus(j.id, 'completed')} className="rounded-lg bg-line py-2 font-bold text-black active:scale-95">{t('complete')}</button>
                        <button onClick={() => setStatus(j.id, 'cancelled')} className="rounded-lg bg-white/10 py-2 font-semibold active:scale-95">{t('cancelJob')}</button>
                      </>
                    )}
                  </div>
                )}
              </li>
            ))}
          </ul>
        )}
      </section>

      {/* Messages from members (in-app chat; no LINE push) */}
      <section>
        <h2 className="mb-2 text-base font-bold">{t('messages')}</h2>
        <ThreadList role="worker" onOpen={(th) => setChat(th)} />
      </section>

      {/* Profile */}
      <section className="space-y-3">
        <h2 className="text-base font-bold">{t('profile')} · <span className="text-sm font-normal text-neutral-400">{(worker.categories ?? []).map(catName).join(' · ')}</span></h2>
        <label className="block text-sm">{t('fName')}
          <input value={form.display_name} maxLength={40} onChange={(e) => setForm((f) => ({ ...f, display_name: e.target.value }))} className={input} />
        </label>
        {prof && <WorkerFields v={prof} set={(p) => setProf((x) => ({ ...x, ...p }))} />}
        <label className="block text-sm">{t('fDistrict')}
          <input value={form.district} maxLength={60} onChange={(e) => setForm((f) => ({ ...f, district: e.target.value }))} className={input} />
        </label>
        <label className="block text-sm">{t('fNearby')}
          <input value={form.nearby} maxLength={120} onChange={(e) => setForm((f) => ({ ...f, nearby: e.target.value }))} className={input} />
        </label>
        <button
          onClick={() => {
            const bad = prof && validateProfile(prof)
            if (bad) return setError(t(bad))
            update({
              display_name: form.display_name.trim(), ...profileToPayload(prof),
              district: form.district.trim() || null, nearby: form.nearby.trim() || null,
            })
          }}
          className="w-full rounded-xl bg-white/10 py-2.5 text-sm font-semibold active:scale-95"
        >
          {t('save')}
        </button>
        {note && <p className="text-sm text-green-400">{note}</p>}
      </section>

      {/* Photo */}
      <section className="space-y-3">
        <h2 className="text-base font-bold">{t('photo')}</h2>
        {worker.profile_image && <img src={worker.profile_image} alt="" className="mx-auto max-h-64 rounded-xl" />}
        <PhotoUploader userId={userId} previousOriginal={worker.original_path} onUploaded={loadWorker} />
      </section>
      {/* Buying a rank comes last: finish and save the profile first */}
      <RankBoost worker={worker} userId={userId} onTopUp={onTopUp} />

      {chat && <ChatModal threadId={chat.id} title={chat.other_name} meId={userId} onClose={() => setChat(null)} />}
    </div>
  )
}
