import { useCallback, useEffect, useState } from 'react'
import { supabase } from '../supabaseClient'
import { useI18n } from '../i18n'

// List of my chats (works for both customers and providers; the DB returns the other party's name).
// `onChange` lets the parent refresh its unread badge.
export default function ThreadList({ onOpen, refreshKey, onChange, role }) {
  const { t } = useI18n()
  const [threads, setThreads] = useState(null)

  const load = useCallback(async () => {
    const { data } = await supabase.rpc('my_threads', { p_role: role ?? null })
    setThreads(data ?? [])
    onChange?.(data ?? [])
  }, [onChange, role])

  useEffect(() => { load() }, [load, refreshKey])

  // RLS limits these events to my own threads.
  useEffect(() => {
    const ch = supabase.channel('thread-list')
      .on('postgres_changes', { event: 'INSERT', schema: 'public', table: 'chat_messages' }, load)
      .subscribe()
    return () => { supabase.removeChannel(ch) }
  }, [load])

  if (threads === null) return <p className="py-6 text-center text-sm text-neutral-500">{t('loading')}</p>
  if (threads.length === 0) return <p className="rounded-2xl bg-white/5 p-4 text-center text-sm text-neutral-500">{t('noThreads')}</p>

  return (
    <ul className="space-y-2">
      {threads.map((th) => (
        <li key={th.id}>
          <button onClick={() => onOpen(th)} className="flex w-full items-center justify-between gap-3 rounded-2xl bg-white/5 p-3 text-left ring-1 ring-white/10 active:scale-[0.99]">
            <span className="min-w-0">
              <span className="block truncate text-sm font-semibold">{th.other_name}</span>
              <span className="block truncate text-xs text-neutral-400">{th.last_body ?? '…'}</span>
            </span>
            {th.unread > 0 && <span className="shrink-0 rounded-full bg-red-500 px-2 py-0.5 text-[11px] font-bold">{th.unread}</span>}
          </button>
        </li>
      ))}
    </ul>
  )
}
