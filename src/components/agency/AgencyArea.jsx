import { useCallback, useEffect, useRef, useState } from 'react'
import { supabase } from '../../supabaseClient'
import { logoBlob, logoUrl } from '../../lib/logo'
import { useI18n } from '../../i18n'
import ChatModal from '../ChatModal'
import ShareModal from '../ShareModal'

const ERRORS = {
  INSUFFICIENT_BALANCE: 'ยอด Wallet ไม่พอ กรุณาเติมเงินก่อน',
  PLAN_INACTIVE: 'แพ็กเกจสังกัดหมดอายุ กรุณาชำระ/ต่ออายุก่อน',
  NOT_APPROVED: 'ยังไม่ได้รับอนุมัติจากแอดมิน',
  ALREADY_APPROVED: 'สังกัดนี้ได้รับอนุมัติแล้ว',
  SUSPENDED: 'บัญชีถูกระงับ',
  BAD_INPUT: 'ข้อมูลไม่ถูกต้อง',
  NOT_FOUND: 'ไม่พบรายการ (อาจถูกจัดการไปแล้ว)',
}
const errText = (m = '') => Object.entries(ERRORS).find(([k]) => m.includes(k))?.[1] ?? 'ทำรายการไม่สำเร็จ'
const fmtDate = (v) => new Date(v).toLocaleDateString('th-TH', { dateStyle: 'medium' })
const baht = (n) => `${Number(n ?? 0).toLocaleString('en-US')} บาท`

// Back office of a modelling agency (Thai only, like the admin). Not visible to customers.
export default function AgencyArea({ me, embedded, onBack, onTopUp, onWallet, onChanged }) {
  const { t } = useI18n()
  const [ag, setAg] = useState(undefined)   // undefined = loading, null = no agency yet
  const [toast, setToast] = useState(null)
  const flash = (m) => { setToast(m); setTimeout(() => setToast(null), 3500) }

  const load = useCallback(async () => {
    const { data } = await supabase.rpc('my_agency')
    setAg(data?.[0] ?? null)
  }, [])
  useEffect(() => { load() }, [load])

  if (ag === undefined) return <p className="py-20 text-center text-neutral-500">{t('loading')}</p>

  return (
    <div className="mx-auto w-full max-w-md pb-10">
      <header className="flex items-center gap-3 border-b border-white/10 px-4 py-3">
        {!embedded && <button onClick={onBack} className="rounded-full bg-white/10 px-2.5 py-1 text-sm active:scale-95">←</button>}
        {ag?.logo_path && <img src={logoUrl(ag.logo_path)} alt="" className="h-8 w-8 rounded-full object-cover" />}
        <h1 className="truncate text-lg font-bold">{ag?.name ?? '🏢 สมัครเป็นโมเดลลิ่ง / สังกัด'}</h1>
      </header>

      {!ag || ag.status === 'rejected'
        ? <Apply ag={ag} me={me} onDone={load} flash={flash} />
        : ag.status === 'pending'
          ? <p className="m-4 rounded-2xl bg-amber-400/10 p-4 text-sm text-amber-200">ส่งใบสมัครแล้ว รอแอดมินตรวจสอบและอนุมัติ ระบบจะเปิดให้ใช้งานเมื่ออนุมัติ</p>
          : <Dashboard ag={ag} me={me} reload={load} flash={flash} onTopUp={onTopUp} onWallet={onWallet} onChanged={onChanged} />}

      {toast && <div className="fixed inset-x-4 bottom-6 z-[60] mx-auto max-w-sm rounded-xl bg-line px-4 py-3 text-center text-sm font-semibold text-black shadow-lg">{toast}</div>}
    </div>
  )
}

function Apply({ ag, me, onDone, flash }) {
  const [name, setName] = useState(ag?.name ?? '')
  const [contact, setContact] = useState(ag?.contact ?? '')
  const [file, setFile] = useState(null)
  const [preview, setPreview] = useState(null)   // object URL of the chosen logo
  const [busy, setBusy] = useState(false)
  const input = 'mt-1 w-full rounded-xl bg-white/10 px-3 py-2.5 text-base outline-none ring-1 ring-white/10 focus:ring-line'

  async function submit(e) {
    e.preventDefault()
    if (busy) return
    if (!ag && !file) return flash('กรุณาเลือกโลโก้สังกัด')
    setBusy(true)
    let path = null
    if (file) {
      path = `${me.id}/logo.jpg`
      let blob
      try { blob = await logoBlob(file) } catch { setBusy(false); return flash('อ่านรูปนี้ไม่ได้ กรุณาเลือกรูป JPG หรือ PNG') }
      const { error } = await supabase.storage.from('agency-logos').upload(path, blob, { upsert: true, contentType: 'image/jpeg' })
      if (error) { setBusy(false); return flash(`อัปโหลดโลโก้ไม่สำเร็จ: ${error.message}`.slice(0, 140)) }
    }
    const { error } = await supabase.rpc('agency_apply', { p_name: name, p_contact: contact, p_logo_path: path })
    setBusy(false)
    if (error) return flash(errText(error.message))
    flash('ส่งใบสมัครแล้ว')
    onDone()
  }

  return (
    <form onSubmit={submit} className="space-y-4 p-4">
      {ag?.status === 'rejected' && <p className="rounded-xl bg-red-500/10 p-2 text-sm text-red-300">ไม่ผ่านการอนุมัติ{ag.reject_reason ? ` — ${ag.reject_reason}` : ''} แก้ไขแล้วส่งใหม่ได้</p>}
      <p className="text-sm text-neutral-400">ค่าใช้แพลตฟอร์ม 1,000 บาท / 30 วัน (ชำระจาก Wallet หลังอนุมัติ) ขึ้นรูปน้องได้ 10 คน เกินคนละ 200 บาท / 30 วัน น้องสมัครด้วย LINE ของตัวเองผ่านลิงก์ที่คุณส่งให้ ระบบรับเข้าสังกัดอัตโนมัติ</p>
      <label className="block text-sm">ชื่อสังกัด
        <input required minLength={2} maxLength={60} value={name} onChange={(e) => setName(e.target.value)} className={input} />
      </label>
      <label className="block text-sm">เบอร์โทร / LINE ID สำหรับติดต่อ
        <input maxLength={60} value={contact} onChange={(e) => setContact(e.target.value)} className={input} />
      </label>
      <div className="space-y-2 text-sm">
        <span>โลโก้สังกัด (รูปสี่เหลี่ยม ใช้แสดงบนรูปน้อง)</span>
        <div className="flex items-center gap-3 rounded-2xl bg-white/5 p-3">
          {preview || ag?.logo_path
            ? <img src={preview ?? logoUrl(ag.logo_path)} alt="logo" className="h-20 w-20 shrink-0 rounded-full object-cover ring-2 ring-white/20" />
            : <span className="flex h-20 w-20 shrink-0 items-center justify-center rounded-full bg-white/10 text-3xl">🏢</span>}
          <label className="flex-1 cursor-pointer rounded-xl bg-white/10 py-2.5 text-center font-semibold active:scale-95">
            {preview || ag?.logo_path ? 'เปลี่ยนรูปโลโก้' : 'เลือกรูปโลโก้'}
            <input type="file" accept="image/*" className="hidden"
              onChange={(e) => { const f = e.target.files?.[0] ?? null; setFile(f); setPreview((old) => { if (old) URL.revokeObjectURL(old); return f ? URL.createObjectURL(f) : null }) }} />
          </label>
        </div>
      </div>
      <button disabled={busy} className="w-full rounded-xl bg-line py-3 font-bold text-black active:scale-95 disabled:opacity-50">{busy ? 'กำลังส่ง…' : 'ส่งใบสมัคร'}</button>
    </form>
  )
}

function Dashboard({ ag, me, reload, flash, onTopUp, onWallet, onChanged }) {
  const [tab, setTab] = useState('girls')
  const tabs = [['girls', '👯 น้อง'], ['reqs', '⏳ รออนุมัติ'], ['chat', '💬 แชต'], ['plan', '🧾 แพ็กเกจ']]
  return (
    <div>
      <nav className="flex gap-2 overflow-x-auto px-4 py-3">
        {tabs.map(([id, label]) => (
          <button key={id} onClick={() => setTab(id)} className={`shrink-0 rounded-full px-4 py-1.5 text-sm font-semibold ${tab === id ? 'bg-line text-black' : 'bg-white/10'}`}>{label}</button>
        ))}
      </nav>
      {!ag.active && (
        <p className="mx-4 mb-3 rounded-xl bg-red-500/10 p-3 text-sm text-red-300">แพ็กเกจสังกัดยังไม่เปิด/หมดอายุ น้องของคุณจะไม่แสดงในหน้าลูกค้า ไปที่แท็บ "แพ็กเกจ" เพื่อชำระ</p>
      )}
      <div className="px-4">
        {tab === 'girls' && <Girls flash={flash} reload={reload} />}
        {tab === 'reqs' && <Requests flash={flash} reload={reload} />}
        {tab === 'chat' && <AgencyChats me={me} onTopUp={onTopUp} />}
        {tab === 'plan' && <Plan ag={ag} me={me} reload={reload} flash={flash} onTopUp={onTopUp} onWallet={onWallet} onChanged={onChanged} />}
      </div>
    </div>
  )
}

function Girls({ flash, reload }) {
  const [rows, setRows] = useState(null)
  const load = useCallback(() => supabase.rpc('agency_girls').then(({ data }) => setRows(data ?? [])), [])
  useEffect(() => { load() }, [load])
  async function remove(g) {
    if (!window.confirm(`เอา ${g.display_name} ออกจากสังกัด? เธอจะกลับไปเป็นน้องอิสระ`)) return
    const { error } = await supabase.rpc('agency_remove_girl', { p_worker: g.user_id })
    if (error) return flash(errText(error.message))
    flash('นำออกจากสังกัดแล้ว'); load(); reload()
  }
  if (rows === null) return <p className="py-8 text-center text-neutral-500">กำลังโหลด…</p>
  if (rows.length === 0) return <p className="rounded-2xl bg-white/5 p-6 text-center text-neutral-500">ยังไม่มีน้องในสังกัด ส่งลิงก์ให้น้องที่แท็บ "แพ็กเกจ"</p>
  return (
    <ul className="space-y-2">
      {rows.map((g) => (
        <li key={g.user_id} className="rounded-2xl bg-white/5 p-3 ring-1 ring-white/10">
          <div className="flex items-center justify-between gap-2">
            <p className="truncate font-semibold">{g.display_name}</p>
            <span className={`rounded-full px-2 py-0.5 text-[11px] ${g.listed ? 'bg-green-500/20 text-green-300' : 'bg-neutral-600/40 text-neutral-300'}`}>{g.listed ? 'แสดงอยู่' : 'ไม่แสดง'}</span>
          </div>
          <p className="mt-1 text-xs text-neutral-400">จองเดือนนี้ {g.jobs_month} ครั้ง · ส่วนแบ่งสะสม {baht(g.earned)}</p>
          <button onClick={() => remove(g)} className="mt-2 rounded-lg bg-white/10 px-3 py-1 text-xs active:scale-95">นำออกจากสังกัด</button>
        </li>
      ))}
    </ul>
  )
}

function Requests({ flash, reload }) {
  const [rows, setRows] = useState(null)
  const load = useCallback(() => supabase.rpc('agency_pending_girls').then(({ data }) => setRows(data ?? [])), [])
  useEffect(() => { load() }, [load])
  async function withdraw(r) {
    if (!window.confirm(`ถอนชื่อ ${r.display_name} ออกจากสังกัด? แอดมินจะไม่อนุมัติเธอในสังกัดนี้`)) return
    const { error } = await supabase.rpc('agency_review_girl', { p_app: r.app_id, p_accept: false })
    if (error) return flash(errText(error.message))
    flash('ถอนชื่อแล้ว'); load(); reload()
  }
  if (rows === null) return <p className="py-8 text-center text-neutral-500">กำลังโหลด…</p>
  return (
    <>
      <p className="mb-2 text-xs text-neutral-400">น้องที่สมัครผ่านลิงก์ของคุณ เข้าสังกัดอัตโนมัติ รอแอดมินอนุมัติโปรไฟล์ ไม่ต้องกดยืนยัน (นับรวมในโควตาแล้ว)</p>
      {rows.length === 0 ? <p className="rounded-2xl bg-white/5 p-6 text-center text-neutral-500">ไม่มีน้องที่รออนุมัติ</p> : (
        <ul className="space-y-2">
          {rows.map((r) => (
            <li key={r.app_id} className="rounded-2xl bg-white/5 p-3 ring-1 ring-white/10">
              <p className="font-semibold">{r.display_name}</p>
              <p className="text-xs text-neutral-400">{r.province ?? ''} · สมัครเมื่อ {fmtDate(r.created_at)}</p>
              <button onClick={() => withdraw(r)} className="mt-2 rounded-lg bg-white/10 px-3 py-1 text-xs active:scale-95">ถอนชื่อ</button>
            </li>
          ))}
        </ul>
      )}
    </>
  )
}

function AgencyChats({ me, onTopUp }) {
  const [rows, setRows] = useState(null)
  const [open, setOpen] = useState(null)
  const load = useCallback(() => supabase.rpc('agency_threads').then(({ data }) => setRows(data ?? [])), [])
  useEffect(() => {
    load()
    const ch = supabase.channel('agency-threads').on('postgres_changes', { event: 'INSERT', schema: 'public', table: 'chat_messages' }, load).subscribe()
    return () => { supabase.removeChannel(ch) }
  }, [load])
  if (rows === null) return <p className="py-8 text-center text-neutral-500">กำลังโหลด…</p>
  return (
    <>
      <p className="mb-2 text-xs text-neutral-400">ตอบแทนน้องได้ (ลูกค้าเห็นว่าเป็นน้องตอบ) เงินค่าแชต 30 บาทเข้าบัญชีของน้อง</p>
      {rows.length === 0 ? <p className="rounded-2xl bg-white/5 p-6 text-center text-neutral-500">ยังไม่มีแชต</p> : (
        <ul className="space-y-2">
          {rows.map((r) => (
            <li key={r.id}>
              <button onClick={() => setOpen(r)} className="flex w-full items-center justify-between gap-3 rounded-2xl bg-white/5 p-3 text-left ring-1 ring-white/10 active:scale-[0.99]">
                <span className="min-w-0">
                  <span className="block truncate text-sm font-semibold">{r.girl_name} ⇄ {r.other_name}</span>
                  <span className="block truncate text-xs text-neutral-400">{r.last_body ?? '…'}</span>
                </span>
                {r.unread > 0 && <span className="shrink-0 rounded-full bg-red-500 px-2 py-0.5 text-[11px] font-bold">{r.unread}</span>}
              </button>
            </li>
          ))}
        </ul>
      )}
      {open && <ChatModal threadId={open.id} title={`${open.girl_name} ⇄ ${open.other_name}`} meId={me.id} onClose={() => { setOpen(null); load() }} onTopUp={onTopUp} />}
    </>
  )
}

function Plan({ ag, me, reload, flash, onTopUp, onWallet, onChanged }) {
  const [busy, setBusy] = useState(false)
  const [share, setShare] = useState(false)
  const guard = useRef(false)
  const wallet = Number(me?.wallet_balance ?? 0)

  async function pay() {
    if (guard.current) return
    if (!window.confirm(`ชำระแพ็กเกจสังกัด ${baht(ag.renewal_price)} จาก Wallet?`)) return
    guard.current = true; setBusy(true)
    const { error } = await supabase.rpc('agency_pay_plan')
    guard.current = false; setBusy(false)
    if (error) return flash(errText(error.message))
    flash('ชำระแล้ว เปิดสังกัด 30 วัน'); reload(); onChanged?.()
  }
  async function slot() {
    if (!window.confirm('ซื้อที่เพิ่ม 1 คน 200 บาท จาก Wallet (ใช้ได้ถึงสิ้นรอบ 30 วันนี้)?')) return
    const { error } = await supabase.rpc('agency_buy_slot')
    if (error) return flash(errText(error.message))
    flash('เพิ่มที่แล้ว'); reload(); onChanged?.()
  }

  return (
    <div className="space-y-3">
      <section className="space-y-1 rounded-2xl bg-white/5 p-3 ring-1 ring-white/10 text-sm">
        <p>สถานะ: <b className={ag.active ? 'text-green-300' : 'text-red-300'}>{ag.active ? 'เปิดใช้งาน' : 'ยังไม่เปิด / หมดอายุ'}</b></p>
        {ag.plan_expires_at && <p>หมดอายุ: {fmtDate(ag.plan_expires_at)}</p>}
        <p>น้องในสังกัด: {ag.girls} / {ag.capacity} คน</p>
        <p>ค่าต่ออายุรอบหน้า: <b>{baht(ag.renewal_price)}</b> <span className="text-xs text-neutral-400">(1,000 + 200 × น้องที่เกิน 10 คน)</span></p>
        <p>Wallet: {baht(wallet)}</p>
        <div className="grid grid-cols-2 gap-2 pt-2">
          <button disabled={busy} onClick={pay} className="rounded-xl bg-line py-2 font-bold text-black active:scale-95 disabled:opacity-50">{ag.active ? 'ต่ออายุ' : 'ชำระแพ็กเกจ'}</button>
          <button onClick={onTopUp} className="rounded-xl bg-white/10 py-2 font-semibold active:scale-95">เติมเงิน</button>
          {ag.active && <button onClick={slot} className="rounded-xl bg-white/10 py-2 text-sm active:scale-95">+ ที่เพิ่ม 200 บาท</button>}
          <button onClick={onWallet} className="rounded-xl bg-white/10 py-2 text-sm active:scale-95">💰 รายได้ / กระเป๋า</button>
        </div>
      </section>

      <section className="space-y-2 rounded-2xl bg-white/5 p-3 ring-1 ring-white/10">
        <p className="text-sm font-semibold">เชิญน้องเข้าสังกัด</p>
        <p className="text-xs text-neutral-400">ส่งลิงก์/QR/Flex ให้น้อง น้องกดสมัครด้วย LINE ของตัวเองแล้วเข้าสังกัดอัตโนมัติ (รอแอดมินอนุมัติโปรไฟล์) น้องที่เคยออกไปแล้วอยากกลับ ส่งลิงก์ให้อีกครั้งแล้วให้กด "ยอมรับเข้าสังกัด"</p>
        <button onClick={() => setShare(true)} className="w-full rounded-xl bg-line py-2 font-bold text-black active:scale-95">ส่งลิงก์เชิญน้อง</button>
      </section>
      {share && <ShareModal agencyCode={ag.code} onClose={() => setShare(false)} />}
    </div>
  )
}
