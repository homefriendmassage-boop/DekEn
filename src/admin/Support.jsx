import { useCallback, useEffect, useState } from 'react'
import { supabase } from '../supabaseClient'
import SupportChat from '../components/SupportChat'
import { ago } from './format'

// Inbox of customer chats. New messages refresh the list live (admins can read every support message via RLS).
export default function Support({ onChanged }) {
  const [rows, setRows] = useState(null)
  const [open, setOpen] = useState(null)

  const load = useCallback(async () => {
    const { data } = await supabase.rpc('admin_support_threads')
    setRows(data ?? [])
    onChanged?.()
  }, [onChanged])

  useEffect(() => {
    load()
    const ch = supabase.channel('admin-support-list')
      .on('postgres_changes', { event: 'INSERT', schema: 'public', table: 'support_messages' }, load)
      .subscribe()
    return () => { supabase.removeChannel(ch) }
  }, [load])

  if (rows === null) return <p className="py-10 text-center text-neutral-500">กำลังโหลด…</p>
  return (
    <>
      {rows.length === 0 ? <p className="rounded-2xl bg-white/5 p-6 text-center text-neutral-500">ยังไม่มีข้อความจากลูกค้า</p> : (
        <ul className="grid gap-2 md:grid-cols-2">
          {rows.map((t) => (
            <li key={t.thread_id}>
              <button onClick={() => setOpen(t)} className="flex w-full items-center gap-3 rounded-2xl bg-white/5 p-3 text-left ring-1 ring-white/10 active:scale-[0.99]">
                {t.picture_url
                  ? <img src={t.picture_url} alt="" referrerPolicy="no-referrer" className="h-10 w-10 shrink-0 rounded-full object-cover" />
                  : <span className="flex h-10 w-10 shrink-0 items-center justify-center rounded-full bg-white/10 font-bold">{(t.user_name ?? '?').slice(0, 1)}</span>}
                <span className="min-w-0 flex-1">
                  <span className="block truncate font-semibold">{t.user_name ?? '—'}</span>
                  <span className="block truncate text-xs text-neutral-400">{t.last_body}</span>
                  <span className="block text-[11px] text-neutral-600">{t.last_message_at ? ago(t.last_message_at) : ''}</span>
                </span>
                {t.unread > 0 && <span className="shrink-0 rounded-full bg-red-500 px-2 py-0.5 text-[11px] font-bold">{t.unread}</span>}
              </button>
            </li>
          ))}
        </ul>
      )}
      {open && <SupportChat threadId={open.thread_id} title={open.user_name ?? 'ลูกค้า'} isAdmin onClose={() => { setOpen(null); load() }} />}
    </>
  )
}
