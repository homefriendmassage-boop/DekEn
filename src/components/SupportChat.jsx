import { useCallback, useEffect, useRef, useState } from 'react'
import { supabase } from '../supabaseClient'
import { useI18n } from '../i18n'

const ERROR_KEYS = { RATE_LIMIT: 'errRate', BAD_MESSAGE: 'errBadMessage' }
const errorKey = (msg = '') => Object.entries(ERROR_KEYS).find(([k]) => msg.includes(k))?.[1] ?? 'errGeneric'

// Chat with the admin team (customer side) or with a customer (admin side, isAdmin).
// In-app only: new messages arrive via Realtime; nothing is pushed to LINE.
export default function SupportChat({ threadId, title, isAdmin = false, onClose }) {
  const { t } = useI18n()
  const [msgs, setMsgs] = useState([])
  const [text, setText] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState(null)
  const endRef = useRef(null)

  const load = useCallback(async () => {
    const { data } = await supabase.from('support_messages')
      .select('id, from_admin, kind, body, created_at')
      .eq('thread_id', threadId).order('created_at', { ascending: true }).limit(300)
    setMsgs(data ?? [])
    supabase.rpc('support_mark_read', { p_thread: threadId }) // fire and forget
  }, [threadId])

  useEffect(() => {
    load()
    const ch = supabase.channel(`support-${threadId}`)
      .on('postgres_changes', { event: 'INSERT', schema: 'public', table: 'support_messages', filter: `thread_id=eq.${threadId}` }, load)
      .subscribe()
    return () => { supabase.removeChannel(ch) }
  }, [threadId, load])

  useEffect(() => { endRef.current?.scrollIntoView({ block: 'end' }) }, [msgs])

  async function send(e) {
    e.preventDefault()
    const body = text.trim()
    if (!body || busy) return
    setBusy(true)
    setError(null)
    const { error } = await supabase.rpc('support_send', { p_thread: threadId, p_body: body })
    setBusy(false)
    if (error) return setError(t(errorKey(error.message)))
    setText('')
    load()
  }

  return (
    <div className="fixed inset-0 z-[70] flex items-end justify-center bg-black/70 sm:items-center sm:p-4" onClick={onClose} role="dialog" aria-modal="true">
      <div onClick={(e) => e.stopPropagation()} className="flex h-[85vh] w-full max-w-md flex-col rounded-t-3xl bg-neutral-900 shadow-2xl sm:rounded-3xl">
        <div className="flex items-center justify-between gap-3 border-b border-white/10 px-4 py-3">
          <h2 className="truncate text-base font-bold">🛟 {title ?? t('supportTitle')}</h2>
          <button onClick={onClose} aria-label={t('close')} className="rounded-full bg-white/10 px-3 py-1 text-sm active:scale-95">✕</button>
        </div>
        {!isAdmin && <p className="px-4 pt-2 text-[11px] text-neutral-500">{t('supportNote')}</p>}

        <div className="flex-1 space-y-2 overflow-y-auto px-4 py-3">
          {msgs.length === 0 && <p className="py-10 text-center text-sm text-neutral-500">{t('supportEmpty')}</p>}
          {msgs.map((m) => {
            if (m.kind === 'system') {
              return <p key={m.id} className="mx-auto max-w-[90%] rounded-xl bg-white/5 px-3 py-2 text-center text-xs text-neutral-300">{m.body}</p>
            }
            const mine = m.from_admin === isAdmin
            return (
              <div key={m.id} className={`flex ${mine ? 'justify-end' : 'justify-start'}`}>
                <p className={`max-w-[80%] whitespace-pre-wrap break-words rounded-2xl px-3 py-2 text-sm ${mine ? 'bg-line text-black' : 'bg-white/10'}`}>{m.body}</p>
              </div>
            )
          })}
          <div ref={endRef} />
        </div>

        {error && <p className="mx-4 mb-2 rounded-lg bg-red-500/10 p-2 text-xs text-red-300">{error}</p>}
        <form onSubmit={send} className="flex gap-2 border-t border-white/10 p-3 pb-[calc(0.75rem+env(safe-area-inset-bottom))]">
          <input value={text} onChange={(e) => setText(e.target.value)} maxLength={isAdmin ? 1000 : 500} placeholder={t('chatPlaceholder')}
            className="min-w-0 flex-1 rounded-xl bg-white/10 px-3 py-2.5 text-base outline-none ring-1 ring-white/10 focus:ring-line" />
          <button disabled={busy || !text.trim()} className="rounded-xl bg-line px-4 font-bold text-black active:scale-95 disabled:opacity-50">{t('send')}</button>
        </form>
      </div>
    </div>
  )
}
