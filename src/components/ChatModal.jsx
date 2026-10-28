import { useCallback, useEffect, useRef, useState } from 'react'
import { supabase } from '../supabaseClient'
import { useI18n } from '../i18n'

// Maps the exceptions raised by send_message() to translated text keys.
const ERROR_KEYS = { MEMBERS_ONLY: 'errMembersOnly', RATE_LIMIT: 'errRate', BAD_MESSAGE: 'errBadMessage', CONTACT_BLOCKED: 'errContact' }
const errorKey = (msg = '') => Object.entries(ERROR_KEYS).find(([k]) => msg.includes(k))?.[1] ?? 'errGeneric'

// In-app chat (no LINE push => no OA message cost). New messages arrive via Realtime.
export default function ChatModal({ threadId, title, meId, onClose, onTopUp }) {
  const { t, money } = useI18n()
  const [msgs, setMsgs] = useState([])
  const [text, setText] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState(null)
  const endRef = useRef(null)
  const [fee, setFee] = useState(null)        // row of chat_fee_status(): who I am here + whether a fee applies
  const [consent, setConsent] = useState(false)
  const [needTopup, setNeedTopup] = useState(false)
  const [room, setRoom] = useState('open')    // open | suspended | closed (an admin can stop a room)
  const [reporting, setReporting] = useState(false)
  const [rep, setRep] = useState({ reason: 'contact', note: '' })
  const [repMsg, setRepMsg] = useState(null)

  const loadFee = useCallback(async () => {
    const { data } = await supabase.rpc('chat_fee_status', { p_thread: threadId })
    setFee(data?.[0] ?? null)
  }, [threadId])

  const loadRoom = useCallback(async () => {
    const { data } = await supabase.from('chat_threads').select('status').eq('id', threadId).maybeSingle()
    if (data) setRoom(data.status)
  }, [threadId])

  const load = useCallback(async () => {
    const { data } = await supabase.from('chat_messages')
      .select('id, sender_id, body, created_at')
      .eq('thread_id', threadId).order('created_at', { ascending: true }).limit(200)
    setMsgs(data ?? [])
    supabase.rpc('mark_read', { p_thread: threadId }) // fire and forget
  }, [threadId])

  useEffect(() => {
    load()
    loadFee()
    loadRoom()
    const refresh = () => { load(); loadFee() }
    const ch = supabase.channel(`chat-${threadId}`)
      .on('postgres_changes', { event: 'INSERT', schema: 'public', table: 'chat_messages', filter: `thread_id=eq.${threadId}` }, refresh)
      .on('postgres_changes', { event: 'UPDATE', schema: 'public', table: 'chat_threads', filter: `id=eq.${threadId}` }, (p) => setRoom(p.new.status))
      .subscribe()
    const tick = setInterval(() => { loadFee(); loadRoom() }, 60000)   // hold / window countdown
    return () => { supabase.removeChannel(ch); clearInterval(tick) }
  }, [threadId, load, loadFee, loadRoom])

  useEffect(() => { endRef.current?.scrollIntoView({ block: 'end' }) }, [msgs])

  async function send(e, accepted = false) {
    e?.preventDefault()
    const body = text.trim()
    if (!body || busy) return
    // The first message of a conversation sets money aside: ask first (the server refuses without consent anyway).
    if (!accepted && fee?.role === 'customer' && fee.state === 'need_fee') return setConsent(true)
    setBusy(true)
    setError(null)
    setNeedTopup(false)
    const { data, error } = await supabase.rpc('send_message', { p_thread: threadId, p_body: body, p_accept_fee: accepted })
    setBusy(false)
    if (!error && typeof data === 'string' && data !== 'OK') {
      // refused for contact details: the attempt is recorded and the flag rises; the 4th one suspends the room
      if (data === 'THREAD_SUSPENDED') { setRoom('suspended'); setText(''); return setError(t('roomSuspendedNow')) }
      const n = Number(data.split(':')[1] ?? 1)
      return setError(`${t('errContact')} ${n >= 3 ? t('errContactLast') : n === 2 ? t('errContactWarn') : ''}`)
    }
    if (error) {
      if (error.message.includes('THREAD_SUSPENDED')) { setRoom('suspended'); return setError(t('roomSuspendedNow')) }
      if (error.message.includes('FEE_CONSENT_REQUIRED')) { await loadFee(); return setConsent(true) }
      if (error.message.includes('INSUFFICIENT_BALANCE')) { setNeedTopup(true); return setError(t('chatNeedTopup', { amount: money(fee?.amount ?? 40) })) }
      return setError(t(errorKey(error.message)))
    }
    setText('')
    load()
    loadFee()
  }

  const fmtTime = (v) => new Date(v).toLocaleString([], { dateStyle: 'short', timeStyle: 'short' })
  const banner = !fee ? null
    : fee.role === 'customer'
      ? fee.state === 'need_fee' ? t('chatBannerNeed', { amount: money(fee.amount), hours: fee.hold_hours })
        : fee.state === 'held' ? t('chatBannerHeld', { amount: money(fee.amount), time: fmtTime(fee.until) })
        : t('chatBannerFree', { time: fmtTime(fee.until) })
      : fee.state === 'held' ? t('chatWorkerHeld', { amount: money(fee.worker_amount), time: fmtTime(fee.until) })
        : fee.state === 'free' ? t('chatWorkerFree', { time: fmtTime(fee.until) }) : null

  return (
    <div className="fixed inset-0 z-50 flex items-end justify-center bg-black/70 sm:items-center sm:p-4" onClick={onClose} role="dialog" aria-modal="true">
      <div onClick={(e) => e.stopPropagation()} className="flex h-[85vh] w-full max-w-md flex-col rounded-t-3xl bg-neutral-900 shadow-2xl sm:rounded-3xl">
        <div className="flex items-center justify-between gap-3 border-b border-white/10 px-4 py-3">
          <h2 className="truncate text-base font-bold">{t('chatTitle', { name: title })}</h2>
          <button onClick={onClose} aria-label={t('close')} className="rounded-full bg-white/10 px-3 py-1 text-sm active:scale-95">✕</button>
        </div>

        <p className="px-4 pt-2 text-[11px] text-neutral-500">{t('chatNote')} {t('chatReviewNote')}</p>
        {room !== 'open' && (
          <p className="mx-4 mt-2 rounded-lg bg-red-500/15 p-2 text-sm font-semibold text-red-200">🚫 {t(room === 'closed' ? 'roomClosed' : 'roomSuspended')}</p>
        )}
        {banner && <p className="mx-4 mt-2 rounded-lg bg-amber-400/10 p-2 text-xs text-amber-200">{banner}</p>}

        <div className="flex-1 space-y-2 overflow-y-auto px-4 py-3">
          {msgs.map((m) => {
            const mine = m.sender_id === meId
            return (
              <div key={m.id} className={`flex ${mine ? 'justify-end' : 'justify-start'}`}>
                <p className={`max-w-[80%] whitespace-pre-wrap break-words rounded-2xl px-3 py-2 text-sm ${mine ? 'bg-line text-black' : 'bg-white/10'}`}>{m.body}</p>
              </div>
            )
          })}
          <div ref={endRef} />
        </div>

        {error && (
          <div className="mx-4 mb-2 rounded-lg bg-red-500/10 p-2 text-xs text-red-300">
            {error}
            {needTopup && onTopUp && <button onClick={onTopUp} className="ml-2 rounded-full bg-line px-3 py-1 font-bold text-black">{t('chatTopUp')}</button>}
          </div>
        )}
        {room === 'open' && (
          <button type="button" onClick={() => { setReporting(true); setRepMsg(null) }} className="mx-4 mb-1 self-start text-[11px] text-neutral-500 underline">🚩 {t('reportChat')}</button>
        )}
        <form onSubmit={send} className="flex gap-2 border-t border-white/10 p-3 pb-[calc(0.75rem+env(safe-area-inset-bottom))]">
          <input
            value={text} onChange={(e) => setText(e.target.value)} maxLength={500} disabled={room !== 'open'}
            placeholder={t('chatPlaceholder')}
            className="min-w-0 flex-1 rounded-xl bg-white/10 px-3 py-2.5 text-base outline-none ring-1 ring-white/10 focus:ring-line"
          />
          <button disabled={busy || !text.trim() || room !== 'open'} className="rounded-xl bg-line px-4 font-bold text-black active:scale-95 disabled:opacity-50">{t('send')}</button>
        </form>
      </div>

      {reporting && (
        <div onClick={(e) => { e.stopPropagation(); setReporting(false) }} className="absolute inset-0 z-10 flex items-center justify-center bg-black/60 p-6">
          <div onClick={(e) => e.stopPropagation()} className="w-full max-w-sm space-y-3 rounded-2xl bg-neutral-800 p-4 shadow-xl">
            <h3 className="text-base font-bold">🚩 {t('reportChat')}</h3>
            <p className="text-xs text-neutral-400">{t('reportHint')}</p>
            <select value={rep.reason} onChange={(e) => setRep((r) => ({ ...r, reason: e.target.value }))} className="w-full rounded-xl bg-white/10 px-3 py-2 text-sm">
              {['contact', 'fraud', 'harassment', 'underage', 'other'].map((k) => <option key={k} value={k} className="text-black">{t(`reportReason_${k}`)}</option>)}
            </select>
            <textarea rows={3} maxLength={500} value={rep.note} onChange={(e) => setRep((r) => ({ ...r, note: e.target.value }))} placeholder={t('reportNote')} className="w-full rounded-xl bg-white/10 px-3 py-2 text-sm" />
            {repMsg && <p className="text-xs text-amber-200">{repMsg}</p>}
            <div className="grid grid-cols-2 gap-2">
              <button onClick={() => setReporting(false)} className="rounded-xl bg-white/10 py-2 font-semibold active:scale-95">{t('close')}</button>
              <button onClick={async () => {
                const { error } = await supabase.rpc('report_thread', { p_thread: threadId, p_reason: rep.reason, p_note: rep.note })
                if (error) return setRepMsg(t(error.message.includes('ALREADY_REPORTED') ? 'reportAlready' : 'errGeneric'))
                setRepMsg(t('reportSent'))
              }} className="rounded-xl bg-red-500 py-2 font-bold active:scale-95">{t('reportSend')}</button>
            </div>
          </div>
        </div>
      )}

      {consent && (
        <div onClick={(e) => { e.stopPropagation(); setConsent(false) }} className="absolute inset-0 z-10 flex items-center justify-center bg-black/60 p-6">
          <div onClick={(e) => e.stopPropagation()} className="w-full max-w-sm space-y-3 rounded-2xl bg-neutral-800 p-4 shadow-xl">
            <h3 className="text-base font-bold">{t('chatConsentTitle')}</h3>
            <p className="text-sm text-neutral-300">
              {t('chatConsentBody', { amount: money(fee?.amount ?? 40), hours: fee?.hold_hours ?? 3, window: 24 })}
            </p>
            <div className="grid grid-cols-2 gap-2">
              <button onClick={() => setConsent(false)} className="rounded-xl bg-white/10 py-2 font-semibold active:scale-95">{t('close')}</button>
              <button onClick={() => { setConsent(false); send(null, true) }} className="rounded-xl bg-line py-2 font-bold text-black active:scale-95">{t('chatConsentOk')}</button>
            </div>
          </div>
        </div>
      )}
    </div>
  )
}
