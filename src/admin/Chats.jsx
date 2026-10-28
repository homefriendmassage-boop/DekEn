import { useCallback, useEffect, useState } from 'react'
import { supabase } from '../supabaseClient'
import { ago, fmtDateTime } from './format'

// Flag colours: 1 noted, 2 yellow, 3 orange, 4 red (the room is suspended automatically)
const FLAG = [
  ['', ''],
  ['⚪ ครั้งที่ 1', 'bg-slate-400/20 text-slate-200 ring-slate-300/40'],
  ['🟡 ครั้งที่ 2', 'bg-yellow-400/20 text-yellow-200 ring-yellow-300/50'],
  ['🟠 ครั้งที่ 3', 'bg-orange-500/20 text-orange-200 ring-orange-400/50'],
  ['🔴 ครั้งที่ 4', 'bg-red-500/25 text-red-200 ring-red-400/60'],
]
const REASON = { NUMBER: 'ส่งตัวเลข/เบอร์', LINK: 'ส่งลิงก์', HANDLE: 'ส่งไอดี/อีเมล', WORD: 'พิมพ์คำขอช่องทางติดต่อ', SPLIT_NUMBER: 'แบ่งส่งเลขทีละท่อน' }
const REPORT = { contact: 'ขอ/ส่งช่องทางติดต่อ', fraud: 'สงสัยฉ้อโกง', harassment: 'คุกคาม/คำหยาบ', underage: 'สงสัยอายุไม่ถึง 20', other: 'อื่นๆ' }
const WHO = { customer: 'ลูกค้า', worker: 'น้อง', agency: 'เอเจนซี่', system: 'ระบบ' }
const PREPORT = { fake_photo: 'รูปไม่ตรง/ปลอม', underage: 'สงสัยอายุไม่ถึง 20', contact: 'ใส่ช่องทางติดต่อ', fraud: 'สงสัยฉ้อโกง', other: 'อื่นๆ' }
const STATUS = { open: 'เปิดอยู่', suspended: '🚫 ระงับ', closed: '⛔ ปิดถาวร' }

export function FlagBadge({ level }) {
  if (!level) return null
  const [label, cls] = FLAG[Math.min(level, 4)]
  return <span className={`rounded-full px-2 py-0.5 text-[11px] font-bold ring-1 ${cls}`}>{label}</span>
}

// Chats that were flagged by the filter, reported by a user or suspended. The admin can read ONLY these, must give a
// reason each time (logged), and decides: suspend / unblock / close for good.
export default function Chats({ onChanged, toast }) {
  const [part, setPart] = useState('chats')   // chats | profiles
  const [filter, setFilter] = useState('pending')
  const [rows, setRows] = useState(null)
  const [asking, setAsking] = useState(null)      // thread the admin is about to open
  const [reason, setReason] = useState('')
  const [view, setView] = useState(null)          // opened chat (admin_open_chat result)
  const [note, setNote] = useState('')

  const load = useCallback(async () => {
    const { data } = await supabase.rpc('admin_chat_queue', { p_filter: filter })
    setRows(data ?? [])
  }, [filter])
  useEffect(() => { load() }, [load])

  async function open() {
    const { data, error } = await supabase.rpc('admin_open_chat', { p_thread: asking.id, p_reason: reason })
    if (error) return toast(error.message.includes('REASON_REQUIRED') ? 'กรุณาใส่เหตุผลที่เปิดอ่าน' : 'เปิดไม่ได้: ' + error.message.slice(0, 80))
    setView({ ...data, row: asking })
    setAsking(null); setReason(''); setNote('')
  }

  async function act(action, confirmText, settle = null) {
    if (!window.confirm(confirmText)) return
    const { error } = await supabase.rpc('admin_chat_action', { p_thread: view.thread.id, p_action: action, p_note: note, p_settle: settle })
    if (error) return toast('ทำรายการไม่สำเร็จ: ' + error.message.slice(0, 80))
    toast(action === 'unblock' ? 'ปลดบล็อกแล้ว ห้องแชตใช้งานได้ตามปกติ (แจ้งในห้องแชตแล้ว)' : action === 'close' ? (settle === 'pay_worker' ? 'ปิดห้องถาวรแล้ว จ่ายเงินที่ค้างให้น้อง' : 'ปิดห้องถาวรแล้ว คืนเงินที่ค้างให้ลูกค้า') : 'ระงับห้องแล้ว (แจ้งในห้องแชตแล้ว)')
    setView(null); load(); onChanged?.()
  }

  if (part === 'profiles') return (
    <div className="space-y-4">
      <PartTabs part={part} setPart={setPart} />
      <ProfileReports onChanged={onChanged} toast={toast} />
    </div>
  )

  return (
    <div className="space-y-4">
      <PartTabs part={part} setPart={setPart} />
      <div className="flex flex-wrap gap-2">
        {[['pending', 'รอตรวจสอบ'], ['closed', 'ปิดถาวรแล้ว'], ['all', 'ทั้งหมดที่เคยติดธง']].map(([k, label]) => (
          <button key={k} onClick={() => setFilter(k)} className={`rounded-full px-3 py-1.5 text-sm font-semibold ${filter === k ? 'bg-line text-black' : 'bg-white/10'}`}>{label}</button>
        ))}
      </div>
      <p className="text-xs text-neutral-500">เปิดอ่านได้เฉพาะห้องที่ถูกติดธง ถูกรายงาน หรือถูกระงับ ทุกครั้งที่เปิดต้องระบุเหตุผลและระบบบันทึกไว้</p>

      {rows === null ? <p className="py-10 text-center text-neutral-500">กำลังโหลด…</p> : rows.length === 0 ? (
        <p className="rounded-2xl bg-white/5 p-6 text-center text-neutral-500">ไม่มีห้องแชตที่ต้องตรวจสอบ</p>
      ) : (
        <ul className="grid gap-2 md:grid-cols-2">
          {rows.map((r) => (
            <li key={r.id} className={`space-y-2 rounded-2xl p-3 ring-1 ${r.status === 'suspended' ? 'bg-red-500/10 ring-red-400/40' : 'bg-white/5 ring-white/10'}`}>
              <div className="flex flex-wrap items-center gap-2">
                <FlagBadge level={r.flag_level} />
                <span className="text-xs font-semibold">{STATUS[r.status]}</span>
                {r.reports > 0 && <span className="rounded-full bg-pink-500/20 px-2 py-0.5 text-[11px] text-pink-200">🚩 รายงาน {r.reports}</span>}
              </div>
              <p className="text-sm font-semibold">{r.customer_name} ↔ {r.worker_name}</p>
              <p className="text-xs text-neutral-400">พยายามส่ง {r.attempts} ครั้ง{r.last_event_at ? ` · ล่าสุด ${ago(r.last_event_at)}` : ''}</p>
              {r.review_note && <p className="text-xs text-neutral-500">หมายเหตุแอดมิน: {r.review_note}</p>}
              <button onClick={() => { setAsking(r); setReason('') }} className="w-full rounded-xl bg-white/10 py-2 text-sm font-semibold active:scale-95">เปิดอ่านห้องนี้</button>
            </li>
          ))}
        </ul>
      )}

      {asking && (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/70 p-4" onClick={() => setAsking(null)}>
          <div onClick={(e) => e.stopPropagation()} className="w-full max-w-sm space-y-3 rounded-2xl bg-neutral-900 p-4">
            <h3 className="font-bold">เปิดอ่านแชต {asking.customer_name} ↔ {asking.worker_name}</h3>
            <p className="text-xs text-neutral-400">ใส่เหตุผลที่ต้องอ่าน (ระบบบันทึกว่าใครเปิดเมื่อไหร่)</p>
            <div className="flex flex-wrap gap-1.5">
              {['ตรวจสอบการส่งข้อมูลติดต่อ', 'มีรายงานจากผู้ใช้', 'สงสัยฉ้อโกง'].map((x) => (
                <button key={x} onClick={() => setReason(x)} className="rounded-full bg-white/10 px-2.5 py-1 text-xs">{x}</button>
              ))}
            </div>
            <input value={reason} onChange={(e) => setReason(e.target.value)} maxLength={200} placeholder="เหตุผล" className="w-full rounded-xl bg-white/10 px-3 py-2 text-sm" />
            <div className="grid grid-cols-2 gap-2">
              <button onClick={() => setAsking(null)} className="rounded-xl bg-white/10 py-2 text-sm">ยกเลิก</button>
              <button onClick={open} className="rounded-xl bg-line py-2 text-sm font-bold text-black">เปิดอ่าน</button>
            </div>
          </div>
        </div>
      )}

      {view && (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/70 p-3" onClick={() => setView(null)}>
          <div onClick={(e) => e.stopPropagation()} className="flex max-h-[92vh] w-full max-w-2xl flex-col space-y-3 overflow-y-auto rounded-2xl bg-neutral-900 p-4">
            <div className="flex items-start justify-between gap-2">
              <div>
                <h3 className="font-bold">{view.row.customer_name} ↔ {view.row.worker_name}</h3>
                <div className="mt-1 flex items-center gap-2"><FlagBadge level={view.thread.flag_level} /><span className="text-xs">{STATUS[view.thread.status]}</span></div>
              </div>
              <button onClick={() => setView(null)} className="rounded-full bg-white/10 px-3 py-1 text-sm">✕</button>
            </div>

            {view.reports.length > 0 && (
              <section className="space-y-1 rounded-xl bg-pink-500/10 p-3 text-xs">
                <p className="font-semibold text-pink-200">🚩 รายงานจากผู้ใช้</p>
                {view.reports.map((r) => <p key={r.id}>{WHO[r.who]}: {REPORT[r.reason] ?? r.reason}{r.note ? ` — ${r.note}` : ''} <span className="text-neutral-500">({fmtDateTime(r.created_at)}{r.status === 'handled' ? ' · ตรวจแล้ว' : ''})</span></p>)}
              </section>
            )}
            {view.events.length > 0 && (
              <section className="space-y-1 rounded-xl bg-red-500/10 p-3 text-xs">
                <p className="font-semibold text-red-200">⚠️ ความพยายามที่ตัวกรองบล็อก ({view.events.length})</p>
                {view.events.map((e) => <p key={e.id}>{fmtDateTime(e.created_at)} · {WHO[e.who]} · {REASON[e.reason] ?? e.reason}: <span className="text-neutral-300">“{e.body}”</span></p>)}
              </section>
            )}

            <section className="max-h-72 space-y-1.5 overflow-y-auto rounded-xl bg-black/30 p-3">
              {view.messages.length === 0 && <p className="text-xs text-neutral-500">ยังไม่มีข้อความที่ส่งผ่าน</p>}
              {view.messages.map((m) => (
                m.who === 'system' ? <p key={m.id} className="mx-auto rounded-lg bg-red-500/15 px-2 py-1 text-center text-[11px] text-red-200">🛡️ {m.body} · {fmtDateTime(m.created_at)}</p> :
                <div key={m.id} className={`flex ${m.who === 'customer' ? 'justify-start' : 'justify-end'}`}>
                  <p className={`max-w-[85%] whitespace-pre-wrap break-words rounded-2xl px-3 py-1.5 text-sm ${m.who === 'customer' ? 'bg-white/10' : 'bg-pink-500/30'}`}>
                    <span className="block text-[10px] text-neutral-400">{WHO[m.who]} · {fmtDateTime(m.created_at)}</span>{m.body}
                  </p>
                </div>
              ))}
            </section>

            {view.views.length > 0 && <p className="text-[11px] text-neutral-500">ประวัติการเปิดอ่าน: {view.views.map((v) => `${v.admin ?? 'แอดมิน'} (${v.reason}) ${fmtDateTime(v.created_at)}`).join(' · ')}</p>}

            {view.thread.status !== 'closed' ? (
              <section className="space-y-2">
                <input value={note} onChange={(e) => setNote(e.target.value)} maxLength={300} placeholder="หมายเหตุการตัดสิน (ไม่บังคับ)" className="w-full rounded-xl bg-white/10 px-3 py-2 text-sm" />
                {view.thread.culprit && <p className="text-xs text-neutral-400">ฝั่งที่ถูกบล็อกบ่อยกว่า: <b className="text-white">{WHO[view.thread.culprit]}</b>{view.thread.held ? ` · เงินค่าแชตที่ค้าง ${view.thread.held.amount} บาท (น้องได้ ${view.thread.held.worker_amount})` : ''}</p>}
                <div className="grid gap-2 sm:grid-cols-2">
                  {view.thread.status === 'open' && <button onClick={() => act('suspend', 'ระงับห้องแชตนี้ชั่วคราว?')} className="rounded-xl bg-orange-500 py-2 text-sm font-bold text-black active:scale-95">🚫 ระงับห้อง</button>}
                  <button onClick={() => act('unblock', 'ปลดบล็อก/ล้างธง ให้แชตต่อได้?')} className="rounded-xl bg-line py-2 text-sm font-bold text-black active:scale-95">✅ ปลดบล็อก / ล้างธง</button>
                  <button onClick={() => act('close', 'ปิดห้องนี้ถาวร และคืนเงินค่าแชตที่ค้างให้ลูกค้า? เปิดอีกไม่ได้', 'refund')} className="rounded-xl bg-red-500 py-2 text-sm font-bold active:scale-95">⛔ ปิดถาวร + คืนเงินลูกค้า</button>
                  {view.thread.culprit !== 'worker' && <button onClick={() => act('close', 'ปิดห้องนี้ถาวร และจ่ายเงินค่าแชตที่ค้างให้น้อง (ลูกค้าไม่ได้คืน)? เปิดอีกไม่ได้', 'pay_worker')} className="rounded-xl bg-red-700 py-2 text-sm font-bold active:scale-95">⛔ ปิดถาวร + จ่ายน้อง</button>}
                </div>
              </section>
            ) : <p className="text-sm text-neutral-400">ห้องนี้ปิดถาวรแล้ว</p>}
          </div>
        </div>
      )}
    </div>
  )
}

function PartTabs({ part, setPart }) {
  return (
    <div className="grid grid-cols-2 gap-2">
      {[['chats', '💬 ห้องแชต'], ['profiles', '🪪 รายงานโปรไฟล์']].map(([k, label]) => (
        <button key={k} onClick={() => setPart(k)} className={`rounded-xl py-2 text-sm font-bold ${part === k ? 'bg-line text-black' : 'bg-white/10'}`}>{label}</button>
      ))}
    </div>
  )
}

// Reports against a provider's profile: dismiss, hide the profile (she is told on her dashboard) or show it again.
function ProfileReports({ onChanged, toast }) {
  const [filter, setFilter] = useState('open')
  const [rows, setRows] = useState(null)
  const load = useCallback(async () => {
    const { data } = await supabase.rpc('admin_profile_reports', { p_filter: filter })
    setRows(data ?? [])
  }, [filter])
  useEffect(() => { load() }, [load])

  async function act(r, action, text) {
    if (!window.confirm(text)) return
    const { error } = await supabase.rpc('admin_profile_report_action', { p_worker: r.worker_id, p_action: action })
    if (error) return toast('ทำรายการไม่สำเร็จ: ' + error.message.slice(0, 80))
    toast(action === 'hide' ? 'ซ่อนโปรไฟล์แล้ว' : action === 'unhide' ? 'แสดงโปรไฟล์อีกครั้งแล้ว' : 'ปิดรายงานแล้ว')
    load(); onChanged?.()
  }

  return (
    <div className="space-y-4">
      <div className="flex flex-wrap gap-2">
        {[['open', 'รอตรวจสอบ'], ['hidden', 'ที่ซ่อนอยู่'], ['all', 'ทั้งหมด']].map(([k, label]) => (
          <button key={k} onClick={() => setFilter(k)} className={`rounded-full px-3 py-1.5 text-sm font-semibold ${filter === k ? 'bg-line text-black' : 'bg-white/10'}`}>{label}</button>
        ))}
      </div>
      {rows === null ? <p className="py-10 text-center text-neutral-500">กำลังโหลด…</p> : rows.length === 0 ? (
        <p className="rounded-2xl bg-white/5 p-6 text-center text-neutral-500">ไม่มีรายงานโปรไฟล์</p>
      ) : (
        <ul className="grid gap-2 md:grid-cols-2">
          {rows.map((r) => (
            <li key={r.worker_id} className={`space-y-2 rounded-2xl p-3 ring-1 ${r.admin_hidden ? 'bg-red-500/10 ring-red-400/40' : 'bg-white/5 ring-white/10'}`}>
              <div className="flex flex-wrap items-center gap-2">
                <p className="font-semibold">{r.display_name}</p>
                {r.admin_hidden && <span className="rounded-full bg-red-500/25 px-2 py-0.5 text-[11px] font-bold text-red-200">ซ่อนอยู่</span>}
                {r.reports > 0 && <span className="rounded-full bg-pink-500/20 px-2 py-0.5 text-[11px] text-pink-200">🚩 {r.reports} รายงานที่ยังไม่ตรวจ</span>}
              </div>
              <ul className="space-y-1 text-xs">
                {r.details.slice(0, 6).map((d) => (
                  <li key={d.id} className={d.status === 'open' ? '' : 'text-neutral-500'}>
                    {PREPORT[d.reason] ?? d.reason}{d.note ? ` — ${d.note}` : ''} <span className="text-neutral-500">({ago(d.created_at)}{d.status === 'handled' ? ` · ${d.action === 'hidden' ? 'ซ่อนแล้ว' : 'ปิดรายงาน'}` : ''})</span>
                  </li>
                ))}
              </ul>
              <div className="grid grid-cols-2 gap-2">
                {r.reports > 0 && <button onClick={() => act(r, 'dismiss', `ไม่พบความผิด ปิดรายงานของ "${r.display_name}"?`)} className="rounded-xl bg-white/10 py-2 text-sm font-semibold active:scale-95">ปิดรายงาน</button>}
                {!r.admin_hidden
                  ? <button onClick={() => act(r, 'hide', `ซ่อนโปรไฟล์ "${r.display_name}" ชั่วคราวเพื่อตรวจสอบ?`)} className="rounded-xl bg-orange-500 py-2 text-sm font-bold text-black active:scale-95">🙈 ซ่อนโปรไฟล์</button>
                  : <button onClick={() => act(r, 'unhide', `แสดงโปรไฟล์ "${r.display_name}" อีกครั้ง?`)} className="col-span-2 rounded-xl bg-line py-2 text-sm font-bold text-black active:scale-95">👁 แสดงโปรไฟล์อีกครั้ง</button>}
              </div>
            </li>
          ))}
        </ul>
      )}
    </div>
  )
}
