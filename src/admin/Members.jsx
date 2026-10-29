import { useEffect, useState } from 'react'
import { supabase } from '../supabaseClient'
import { PLAN_META } from '../config'
import { baht, fmtDate, ago } from './format'
import ManageUser from './ManageUser'
import VendorSelect from './VendorSelect'

const ERRORS = {
  CONFIG_MISSING: 'ยังไม่ได้ตั้งค่า LINE_CHANNEL_ACCESS_TOKEN / LIFF_ID ใน Supabase Secrets ของฟังก์ชัน send-renewal',
  FORBIDDEN: 'ไม่มีสิทธิ์',
}

// Active paid members, soonest expiry first.
// "📣 แจ้งต่ออายุ" pushes a LINE Flex Message (button -> plan picker in the app). "บันทึกรับเงิน" opens the payment form.
export default function Members({ onRenew, toast }) {
  const [rows, setRows] = useState(null)
  const [busy, setBusy] = useState(null) // user id | 'bulk'
  const [manage, setManage] = useState(null) // user id whose controls are open
  const [q, setQ] = useState('')
  const [found, setFound] = useState([])

  const [vendor, setVendor] = useState(null)        // null = central members, else one seller's customers
  const load = () => (vendor ? supabase.rpc('admin_list_vendor_members', { p_vendor: vendor }) : supabase.rpc('admin_list_members')).then(({ data }) => setRows(data ?? []))
  useEffect(() => { setRows(null); load() }, [vendor]) // eslint-disable-line react-hooks/exhaustive-deps

  async function notify(body, label) {
    if (busy) return
    setBusy(body.user_id ?? 'bulk')
    const { data, error } = await supabase.functions.invoke('send-renewal', { body })
    setBusy(null)
    if (error || !data) return toast('ส่งไม่สำเร็จ (ตรวจว่า deploy ฟังก์ชัน send-renewal แล้ว)')
    if (!data.ok) return toast(ERRORS[data.code] ?? 'ส่งไม่สำเร็จ')
    const failed = data.results?.find((r) => r.status === 'FAILED')
    if (data.sent === 0 && data.failed === 0) return toast(data.skipped ? 'ข้าม: เพิ่งแจ้งไปแล้วหรือไม่มีรหัส LINE' : 'ไม่มีผู้รับ')
    toast(`${label}: ส่งแล้ว ${data.sent}${data.skipped ? ` · ข้าม ${data.skipped}` : ''}${data.failed ? ` · ไม่สำเร็จ ${data.failed}` : ''}${failed?.detail ? ` (${failed.detail.slice(0, 80)})` : ''}`)
    load()
  }

  // Search any user (members, expired, non-members) to open their controls.
  useEffect(() => {
    if (q.trim().length < 2) return setFound([])
    const h = setTimeout(() => supabase.rpc('admin_search_users', { p_q: q }).then(({ data }) => setFound(data ?? [])), 300)
    return () => clearTimeout(h)
  }, [q])

  if (rows === null) return <p className="py-10 text-center text-neutral-500">กำลังโหลด…</p>

  const expiring = rows.filter((m) => new Date(m.vip_expires_at) - Date.now() < 7 * 86400000)

  return (
    <div className="space-y-3">
      <VendorSelect value={vendor} onChange={setVendor} />
      <div>
        <input value={q} onChange={(e) => setQ(e.target.value)} placeholder="🔍 ค้นหาผู้ใช้ (ชื่อ / LINE ID) เพื่อยกเลิก แก้แพ็กเกจ หรือระงับบัญชี"
          className="w-full rounded-xl bg-white/10 px-3 py-2 text-sm outline-none focus:ring-2 focus:ring-line" />
        {found.length > 0 && (
          <ul className="mt-2 space-y-1">
            {found.map((f) => (
              <li key={f.id}>
                <button onClick={() => setManage(f.id)} className="flex w-full items-center justify-between rounded-xl bg-white/5 px-3 py-2 text-left text-sm active:scale-95">
                  <span className="truncate">{f.role === 'worker' ? '💃 ' : ''}{f.display_name ?? '—'}</span>
                  <span className="text-xs text-neutral-400">{f.vip_tier > 0 && new Date(f.vip_expires_at) > new Date() ? PLAN_META[f.vip_tier].name : 'ไม่มีแพ็กเกจ'}</span>
                </button>
              </li>
            ))}
          </ul>
        )}
      </div>

      {rows.length === 0 && <p className="rounded-2xl bg-white/5 p-6 text-center text-neutral-500">ยังไม่มีสมาชิกที่ใช้งานอยู่</p>}

      {expiring.length > 0 && (
        <button
          disabled={busy}
          onClick={() => window.confirm(`ส่งข้อความแจ้งต่ออายุให้สมาชิกที่เหลือ ≤ 7 วัน (${expiring.length} คน)\n\nนับโควตาข้อความ LINE OA คนละ 1 ข้อความ และส่งถึงเฉพาะคนที่เพิ่มเพื่อน OA\nคนที่ถูกแจ้งไปแล้วภายใน 3 วันจะถูกข้าม\n\nยืนยัน?`) && notify({ expiring_days: 7 }, 'แจ้งทั้งกลุ่ม')}
          className="w-full rounded-2xl bg-amber-400 py-3 font-bold text-black active:scale-95 disabled:opacity-50">
          {busy === 'bulk' ? 'กำลังส่ง…' : `📣 แจ้งต่ออายุทุกคนที่เหลือ ≤ 7 วัน (${expiring.length})`}
        </button>
      )}

      <ul className="grid gap-2 md:grid-cols-2">
        {rows.map((m) => {
          const daysLeft = Math.ceil((new Date(m.vip_expires_at) - Date.now()) / 86400000)
          const meta = PLAN_META[m.vip_tier]
          return (
            <li key={m.id} className="space-y-2 rounded-2xl bg-white/5 p-3 ring-1 ring-white/10">
              <div className="flex items-center gap-3">
                {m.picture_url
                  ? <img src={m.picture_url} alt="" referrerPolicy="no-referrer" className="h-10 w-10 shrink-0 rounded-full object-cover" />
                  : <span className="flex h-10 w-10 shrink-0 items-center justify-center rounded-full bg-white/10 font-bold">{(m.display_name ?? '?').slice(0, 1)}</span>}
                <div className="min-w-0 flex-1">
                  <p className="truncate font-semibold">{m.display_name ?? '—'}</p>
                  <p className="text-xs text-neutral-400">
                    <span className={`mr-1 rounded-full px-2 py-0.5 text-[11px] font-bold ${meta.badge}`}>{meta.icon} {meta.name}</span>
                    หมด {fmtDate(m.vip_expires_at)} ·{' '}
                    <span className={daysLeft <= 7 ? 'font-semibold text-amber-300' : ''}>เหลือ {daysLeft} วัน</span>
                  </p>
                  <p className="text-[11px] text-neutral-500">Wallet {baht(m.wallet_balance)}{m.last_notice_at ? ` · แจ้งต่ออายุแล้ว ${ago(m.last_notice_at)}` : ''}</p>
                </div>
              </div>
              <div className="grid grid-cols-3 gap-2">
                <button
                  disabled={busy}
                  onClick={() => window.confirm(`ส่งข้อความแจ้งต่ออายุถึง ${m.display_name ?? 'สมาชิก'} ทาง LINE?\n(นับโควตาข้อความ LINE OA 1 ข้อความ)`) && notify({ user_id: m.id }, m.display_name ?? 'สมาชิก')}
                  className="rounded-xl bg-line py-2 text-sm font-bold text-black active:scale-95 disabled:opacity-50">
                  {busy === m.id ? 'กำลังส่ง…' : '📣 แจ้งต่ออายุ'}
                </button>
                <button onClick={() => onRenew(m)} className="rounded-xl bg-white/10 py-2 text-sm font-semibold active:scale-95">บันทึกรับเงิน</button>
                <button onClick={() => setManage(m.id)} className="rounded-xl bg-white/10 py-2 text-sm font-semibold active:scale-95">⚙️ จัดการ</button>
              </div>
            </li>
          )
        })}
      </ul>
      {manage && <ManageUser userId={manage} onClose={() => setManage(null)} onChanged={load} toast={toast} />}
    </div>
  )
}
