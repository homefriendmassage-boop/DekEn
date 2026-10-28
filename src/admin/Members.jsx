import { useEffect, useState } from 'react'
import { supabase } from '../supabaseClient'
import { PLAN_META } from '../config'
import { baht, fmtDate } from './format'

// Active paid members, soonest expiry first. "ต่ออายุ" jumps to the payment form with the member preselected.
export default function Members({ onRenew }) {
  const [rows, setRows] = useState(null)

  useEffect(() => {
    supabase.rpc('admin_list_members').then(({ data }) => setRows(data ?? []))
  }, [])

  if (rows === null) return <p className="py-10 text-center text-neutral-500">กำลังโหลด…</p>
  if (rows.length === 0) return <p className="rounded-2xl bg-white/5 p-6 text-center text-neutral-500">ยังไม่มีสมาชิกที่ใช้งานอยู่</p>

  return (
    <ul className="grid gap-2 md:grid-cols-2">
      {rows.map((m) => {
        const daysLeft = Math.ceil((new Date(m.vip_expires_at) - Date.now()) / 86400000)
        const meta = PLAN_META[m.vip_tier]
        return (
          <li key={m.id} className="flex items-center justify-between gap-3 rounded-2xl bg-white/5 p-3 ring-1 ring-white/10">
            <div className="min-w-0">
              <p className="truncate font-semibold">{m.display_name ?? '—'}</p>
              <p className="text-xs text-neutral-400">
                <span className={`mr-1 rounded-full px-2 py-0.5 text-[11px] font-bold ${meta.badge}`}>{meta.icon} {meta.name}</span>
                หมด {fmtDate(m.vip_expires_at)} ·{' '}
                <span className={daysLeft <= 7 ? 'font-semibold text-amber-300' : ''}>เหลือ {daysLeft} วัน</span>
              </p>
              <p className="text-[11px] text-neutral-500">Wallet {baht(m.wallet_balance)}</p>
            </div>
            <button onClick={() => onRenew(m)} className="shrink-0 rounded-xl bg-line px-3 py-2 text-sm font-bold text-black active:scale-95">ต่ออายุ</button>
          </li>
        )
      })}
    </ul>
  )
}
