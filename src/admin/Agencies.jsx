import { useCallback, useEffect, useState } from 'react'
import { supabase } from '../supabaseClient'
import { logoUrl } from '../lib/logo'
import { fmtDate, fmtDateTime } from './format'

const FILTERS = [['pending', 'รอตรวจ'], ['approved', 'อนุมัติแล้ว'], ['rejected', 'ไม่ผ่าน']]

// Modelling agencies: approve the name + logo before they can sell anything.
// Suspend an agency (and so hide all its girls) from "สมาชิก" -> search -> ⚙️ จัดการ.
export default function Agencies({ onChanged, toast }) {
  const [status, setStatus] = useState('pending')
  const [rows, setRows] = useState(null)
  const [rejecting, setRejecting] = useState(null)
  const [reason, setReason] = useState('')

  const load = useCallback(async () => {
    setRows(null)
    const { data } = await supabase.rpc('admin_list_agencies', { p_status: status })
    setRows(data ?? [])
  }, [status])
  useEffect(() => { load() }, [load])

  async function review(a, approve) {
    const { error } = await supabase.rpc('admin_review_agency', { p_user: a.user_id, p_approve: approve, p_reason: approve ? null : reason })
    if (error) return toast('ทำรายการไม่สำเร็จ')
    toast(approve ? 'อนุมัติสังกัดแล้ว' : 'ปฏิเสธแล้ว')
    setRejecting(null); setReason(''); load(); onChanged?.()
  }

  return (
    <div className="space-y-4">
      <div className="flex gap-2">
        {FILTERS.map(([id, label]) => (
          <button key={id} onClick={() => setStatus(id)} className={`rounded-full px-3 py-1 text-sm ${status === id ? 'bg-white text-black' : 'bg-white/10'}`}>{label}</button>
        ))}
      </div>
      {rows === null ? <p className="py-10 text-center text-neutral-500">กำลังโหลด…</p>
        : rows.length === 0 ? <p className="rounded-2xl bg-white/5 p-6 text-center text-neutral-500">ไม่มีรายการ</p>
        : (
          <ul className="grid gap-3 md:grid-cols-2">
            {rows.map((a) => (
              <li key={a.user_id} className="space-y-2 rounded-2xl bg-neutral-900 p-3 ring-1 ring-white/10">
                <div className="flex items-center gap-3">
                  {a.logo_path ? <img src={logoUrl(a.logo_path)} alt="" className="h-14 w-14 rounded-full object-cover" /> : <span className="h-14 w-14 rounded-full bg-white/10" />}
                  <div className="min-w-0">
                    <p className="truncate font-bold">{a.name}</p>
                    <p className="truncate text-xs text-neutral-400">LINE: {a.user_name ?? '—'} · {a.contact ?? 'ไม่มีช่องทางติดต่อ'}</p>
                    <p className="text-[11px] text-neutral-500">สมัคร {fmtDateTime(a.created_at)}</p>
                  </div>
                </div>
                {a.status === 'approved' && (
                  <p className="text-xs text-neutral-300">น้องในสังกัด {a.girls} คน · แพ็กเกจ {a.plan_expires_at ? `หมด ${fmtDate(a.plan_expires_at)}` : 'ยังไม่ชำระ'}</p>
                )}
                {a.status === 'rejected' && <p className="text-xs text-red-300">ไม่ผ่าน{a.reject_reason ? ` — ${a.reject_reason}` : ''}</p>}
                {a.status === 'pending' && (
                  rejecting === a.user_id ? (
                    <div className="space-y-2">
                      <input value={reason} onChange={(e) => setReason(e.target.value)} placeholder="เหตุผล (ไม่บังคับ)" className="w-full rounded-xl bg-white/10 px-3 py-2 text-sm" />
                      <div className="grid grid-cols-2 gap-2">
                        <button onClick={() => review(a, false)} className="rounded-xl bg-red-500/30 py-2 text-sm font-bold">ยืนยันปฏิเสธ</button>
                        <button onClick={() => setRejecting(null)} className="rounded-xl bg-white/10 py-2 text-sm">ยกเลิก</button>
                      </div>
                    </div>
                  ) : (
                    <div className="grid grid-cols-2 gap-2">
                      <button onClick={() => review(a, true)} className="rounded-xl bg-line py-2 font-bold text-black active:scale-95">อนุมัติ</button>
                      <button onClick={() => setRejecting(a.user_id)} className="rounded-xl bg-white/10 py-2 active:scale-95">ปฏิเสธ</button>
                    </div>
                  )
                )}
              </li>
            ))}
          </ul>
        )}
    </div>
  )
}
