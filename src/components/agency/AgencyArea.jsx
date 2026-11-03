import DraftsPanel from '../DraftsPanel'
import { useCallback, useEffect, useRef, useState } from 'react'
import { supabase } from '../../supabaseClient'
import { logoBlob, logoUrl } from '../../lib/logo'
import { useI18n } from '../../i18n'
import ChatModal from '../ChatModal'
import ShareModal from '../ShareModal'
import WorkerDetail from '../WorkerDetail'

const ERRORS = {
  INSUFFICIENT_BALANCE: 'ยอด Wallet ไม่พอ กรุณาเติมเงินก่อน',
  PLAN_INACTIVE: 'แพ็กเกจสังกัดหมดอายุ กรุณาชำระ/ต่ออายุก่อน',
  NOT_APPROVED: 'ยังไม่ได้รับอนุมัติจากแอดมิน',
  ALREADY_APPROVED: 'สังกัดนี้ได้รับอนุมัติแล้ว',
  SUSPENDED: 'บัญชีถูกระงับ',
  BAD_INPUT: 'ข้อมูลไม่ถูกต้อง',
  NOT_FOUND: 'ไม่พบรายการ (อาจถูกจัดการไปแล้ว)',
  NO_CHANGE: 'ยังไม่ได้เปลี่ยนชื่อหรือโลโก้',
  NO_FREE_SEAT: 'ที่นั่งฟรีเต็มแล้ว (10 ที่) เลือกน้องที่จะเปลี่ยนออก หรือซื้อที่นั่งเพิ่ม',
  SEAT_TOO_NEW: 'ที่นั่งนี้ยังไม่ครบ 30 วัน เปลี่ยนไม่ได้',
  ALREADY_SEATED: 'น้องคนนี้มีที่นั่งแล้ว',
  REQUEST_PENDING: 'ส่งคำขอยินยอมไปแล้ว รอน้องตอบ',
  SLOTS_FULL: 'ที่ลำดับแรกเต็มแล้ว (3 ที่) รอให้มีที่ว่าง',
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
      <p className="text-sm text-neutral-400">หลังแอดมินอนุมัติ สร้างแบบร่างใบสมัครส่งให้น้องได้ทันที ชำระแพ็กเกจ 1,000 บาท / 30 วัน (จาก Wallet) เพื่อรับส่วนแบ่ง 40% ค่าจองของน้องในสังกัด และให้โลโก้ขึ้นแถบ/หน้าสังกัดของลูกค้า รวมน้อง 10 คน เกินคนละ 200 บาท / 30 วัน น้องสมัครด้วย LINE ของตัวเองผ่านลิงก์ที่คุณส่งให้ ระบบรับเข้าสังกัดอัตโนมัติ</p>
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
  const [missed, setMissed] = useState(null)      // what this agency missed this month while it is not eligible for the 40 %
  useEffect(() => { supabase.rpc('agency_missed').then(({ data }) => setMissed(data ?? null)) }, [ag.active])
  const tabs = [['girls', '👯 น้อง'], ['seats', '💺 ที่นั่ง'], ['reqs', '⏳ รออนุมัติ'], ['drafts', '📝 ร่างใบสมัคร'], ['chat', '💬 แชต'], ['plan', '🧾 แพ็กเกจ'], ['settings', '⚙️ ตั้งค่า']]
  return (
    <div>
      <nav className="flex gap-2 overflow-x-auto px-4 py-3">
        {tabs.map(([id, label]) => (
          <button key={id} onClick={() => setTab(id)} className={`shrink-0 rounded-full px-4 py-1.5 text-sm font-semibold ${tab === id ? 'bg-line text-black' : 'bg-white/10'}`}>{label}</button>
        ))}
      </nav>
      {(!ag.active || (missed && !missed.eligible)) && (
        <div className="mx-4 mb-3 space-y-1 rounded-xl bg-amber-400/10 p-3 text-xs text-amber-200">
          {!ag.active ? (
            <p>ยังไม่ได้ชำระแพ็กเกจสังกัด: สร้างแบบร่างและส่งลิงก์ให้น้องได้ น้องในสังกัด (สูงสุด 10 คน) ยังแสดงให้ลูกค้าเห็นและมีป้ายสังกัดบนรูป แต่ <b>ส่วนแบ่ง 40% ค่าจองของน้องตกเป็นของแพลตฟอร์ม ไม่มีโลโก้ในแถบ/หน้าสังกัด และอ่าน/ตอบแชต/ดูรายละเอียดน้องไม่ได้</b> (ส่วนแบ่ง 40% จากลูกค้าที่จองผ่านลิงก์ของคุณ ได้เหมือนเซลล์) ชำระที่แท็บ "แพ็กเกจ"</p>
          ) : (
            <p>แพ็กเกจชำระแล้ว แต่ส่วนแบ่ง 40% ค่าจองน้องจะเริ่มเมื่อมีน้องในสังกัดอย่างน้อย 1 คนที่ไม่ใช่บัญชีของคุณเอง</p>
          )}
          {missed && missed.jobs > 0 && <p className="text-sm font-bold text-amber-100">เดือนนี้น้องของคุณมีงาน {missed.jobs} งาน คุณพลาดส่วนแบ่ง {Number(missed.amount).toLocaleString('en-US')} บาท</p>}
        </div>
      )}
      <div className="px-4">
        {tab === 'girls' && <Girls flash={flash} reload={reload} paid={ag.active} />}
        {tab === 'seats' && <Seats ag={ag} me={me} flash={flash} reload={reload} onChanged={onChanged} />}
        {tab === 'reqs' && <Requests flash={flash} reload={reload} />}
        {tab === 'drafts' && <DraftsPanel mode="agency" toast={flash} />}
        {tab === 'chat' && (ag.active ? <AgencyChats me={me} onTopUp={onTopUp} /> : <p className="rounded-2xl bg-white/5 p-6 text-center text-sm text-neutral-300">🔒 ชำระแพ็กเกจสังกัดก่อน จึงจะอ่านและตอบแชตแทนน้องได้ (ค่าแชต 30 บาทเข้าบัญชีน้องผู้ลงทะเบียนเท่านั้น)</p>)}
        {tab === 'settings' && <Settings ag={ag} me={me} reload={reload} flash={flash} />}
        {tab === 'plan' && <Plan ag={ag} me={me} reload={reload} flash={flash} onTopUp={onTopUp} onWallet={onWallet} onChanged={onChanged} />}
      </div>
    </div>
  )
}

function Girls({ flash, reload, paid }) {
  const [rows, setRows] = useState(null)
  const [detail, setDetail] = useState(null)       // her full profile (photos + details): an agency sees its own girls only
  async function openDetail(g) {
    if (!paid) return flash('ชำระแพ็กเกจสังกัดก่อน จึงจะดูรูปและรายละเอียดน้องได้')
    const { data } = await supabase.rpc('get_worker', { p_worker: g.user_id })
    const r = data?.[0]
    if (!r) return flash('เปิดโปรไฟล์ไม่ได้ (น้องอาจยังไม่แสดงในระบบ)')
    setDetail({ ...r, canView: true, image: r.profile_image })
  }
  const load = useCallback(() => supabase.rpc('agency_girls').then(({ data }) => setRows(data ?? [])), [])
  useEffect(() => { load() }, [load])
  async function remove(g) {
    if (!window.confirm(`เอา ${g.display_name} ออกจากสังกัด? เธอจะกลับไปเป็นน้องอิสระ`)) return
    const { error } = await supabase.rpc('agency_remove_girl', { p_worker: g.user_id })
    if (error) return flash(errText(error.message))
    flash('นำออกจากสังกัดแล้ว'); load(); reload()
  }
  const [ordering, setOrdering] = useState(false)
  if (rows === null) return <p className="py-8 text-center text-neutral-500">กำลังโหลด…</p>
  if (rows.length === 0) return <p className="rounded-2xl bg-white/5 p-6 text-center text-neutral-500">ยังไม่มีน้องในสังกัด ส่งลิงก์ให้น้องที่แท็บ "แพ็กเกจ"</p>
  return (
    <>
    {detail && <WorkerDetail worker={detail} agencyView onClose={() => setDetail(null)} />}
    {ordering && <OrderSheet flash={flash} onClose={() => setOrdering(false)} />}
    <button onClick={() => (paid ? setOrdering(true) : flash('ชำระแพ็กเกจสังกัดก่อน จึงจะจัดอันดับน้องได้'))} className={`mb-2 w-full rounded-xl py-2.5 text-sm font-bold active:scale-95 ${paid ? 'bg-pink-500' : 'bg-white/10 text-neutral-400'}`}>{paid ? '↕️ จัดอันดับน้อง (เรียงโชว์ในหน้าสังกัด)' : '🔒 จัดอันดับน้อง (ต้องชำระแพ็กเกจ)'}</button>
    <ul className="space-y-2">
      {rows.map((g) => (
        <li key={g.user_id} className="rounded-2xl bg-white/5 p-3 ring-1 ring-white/10">
          <div className="flex items-center justify-between gap-2">
            <div className="flex min-w-0 items-center gap-2">
              <div className="h-12 w-10 shrink-0 overflow-hidden rounded-lg bg-neutral-800">{g.profile_image && <img src={g.profile_image} alt="" className="h-full w-full object-cover" />}</div>
              <p className="truncate font-semibold">{g.display_name}</p>
            </div>
            <span className={`rounded-full px-2 py-0.5 text-[11px] ${g.listed ? 'bg-green-500/20 text-green-300' : 'bg-neutral-600/40 text-neutral-300'}`}>{g.listed ? 'แสดงอยู่' : 'ไม่แสดง'}</span>
          </div>
          <p className="mt-1 text-xs text-neutral-400">จองเดือนนี้ {g.jobs_month} ครั้ง · ส่วนแบ่งสะสม {baht(g.earned)}</p>
          <div className="mt-2 flex gap-2">
            <button onClick={() => openDetail(g)} className={`rounded-lg px-3 py-1 text-xs font-semibold active:scale-95 ${paid ? 'bg-pink-500' : 'bg-white/10 text-neutral-400'}`}>{paid ? 'ดูรูปและรายละเอียด' : '🔒 ดูรูปและรายละเอียด'}</button>
            <button onClick={() => remove(g)} className="rounded-lg bg-white/10 px-3 py-1 text-xs active:scale-95">นำออกจากสังกัด</button>
          </div>
        </li>
      ))}
    </ul>
    </>
  )
}

// Put the girls in the order the agency wants on its own page; "reset" gives the order back to the system (random every day).
function OrderSheet({ flash, onClose }) {
  const [list, setList] = useState(null)
  const [hasOrder, setHasOrder] = useState(false)
  useEffect(() => { supabase.rpc('agency_order_list').then(({ data }) => { setList(data ?? []); setHasOrder((data ?? []).some((r) => r.pos != null)) }) }, [])
  const move = (i, d) => setList((l) => { const j = i + d; if (j < 0 || j >= l.length) return l; const n = [...l]; [n[i], n[j]] = [n[j], n[i]]; return n })
  async function save() {
    const { error } = await supabase.rpc('agency_set_order', { p_order: list.map((r) => r.user_id) })
    if (error) return flash(errText(error.message))
    flash('บันทึกลำดับแล้ว หน้าสังกัดจะเรียงตามนี้'); onClose()
  }
  async function reset() {
    if (!window.confirm('ล้างลำดับ ให้ระบบสุ่มเรียงให้เองทุกวัน?')) return
    const { error } = await supabase.rpc('agency_reset_order')
    if (error) return flash(errText(error.message))
    flash('กลับเป็นการสุ่มอัตโนมัติแล้ว'); onClose()
  }
  return (
    <div className="fixed inset-0 z-50 flex items-end justify-center bg-black/70 sm:items-center sm:p-4" onClick={onClose}>
      <div onClick={(e) => e.stopPropagation()} className="max-h-[88vh] w-full max-w-md space-y-3 overflow-y-auto rounded-t-3xl bg-neutral-900 p-5 sm:rounded-3xl">
        <div className="flex items-center justify-between"><h3 className="text-lg font-bold">↕️ จัดอันดับน้อง</h3><button onClick={onClose} className="rounded-full bg-white/10 px-3 py-1 text-sm">✕</button></div>
        <p className="text-xs text-neutral-400">เรียงน้องที่ต้องการให้ขึ้นก่อนในหน้าสังกัดของคุณ (กดลูกศรขึ้น-ลง) ใช้กับหน้าสังกัดของคุณเท่านั้น ไม่กระทบฟีดรวม ถ้าไม่จัด หรือกดล้างลำดับ ระบบจะสุ่มให้เองทุกวัน น้องใหม่ที่ยังไม่ได้จัดจะอยู่ต่อท้าย</p>
        {list === null ? <p className="py-6 text-center text-neutral-500">กำลังโหลด…</p> : (
          <ul className="space-y-1.5">
            {list.map((r, i) => (
              <li key={r.user_id} className="flex items-center gap-2 rounded-xl bg-white/5 px-3 py-2 text-sm">
                <span className="w-6 shrink-0 text-center text-xs text-neutral-400">{i + 1}</span>
                <span className="min-w-0 flex-1 truncate font-semibold">{r.display_name}</span>
                <button disabled={i === 0} onClick={() => move(i, -1)} className="rounded-lg bg-white/10 px-2.5 py-1 disabled:opacity-30">▲</button>
                <button disabled={i === list.length - 1} onClick={() => move(i, 1)} className="rounded-lg bg-white/10 px-2.5 py-1 disabled:opacity-30">▼</button>
              </li>
            ))}
          </ul>
        )}
        <div className="grid grid-cols-2 gap-2 pt-1">
          <button onClick={save} disabled={!list?.length} className="rounded-xl bg-line py-2.5 font-bold text-black disabled:opacity-40">บันทึกลำดับ</button>
          <button onClick={reset} disabled={!hasOrder} className="rounded-xl bg-white/10 py-2.5 text-sm disabled:opacity-40">ล้างลำดับ (สุ่มเอง)</button>
        </div>
      </div>
    </div>
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
  const [custShare, setCustShare] = useState(false)
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

  return (
    <div className="space-y-3">
      <section className="space-y-1 rounded-2xl bg-white/5 p-3 ring-1 ring-white/10 text-sm">
        <p>สถานะ: <b className={ag.active ? 'text-green-300' : 'text-red-300'}>{ag.active ? 'เปิดใช้งาน' : 'ยังไม่เปิด / หมดอายุ'}</b></p>
        {ag.plan_expires_at && <p>หมดอายุ: {fmtDate(ag.plan_expires_at)}</p>}
        <p>น้องในสังกัด: {ag.girls} คน · ที่นั่งสิทธิพิเศษ {ag.capacity} ที่ (ฟรี 10 + ซื้อเพิ่ม {ag.extra_slots})</p>
        <p>ค่าแพ็กเกจ 30 วัน: <b>{baht(ag.renewal_price)}</b> <span className="text-xs text-neutral-400">(ที่นั่งเพิ่มซื้อทีละคนที่แท็บ "ที่นั่ง")</span></p>
        {ag.promo && !ag.active && <p className="rounded-lg bg-amber-400/10 p-2 text-xs text-amber-200">🎉 ช่วงโปรโมชัน: ยังไม่จ่ายแพ็กเกจก็ได้ 40% ต่อเนื่องจากน้องที่มีที่นั่ง (10 ที่ฟรี)</p>}
        <p>Wallet: {baht(wallet)}</p>
        <div className="grid grid-cols-2 gap-2 pt-2">
          <button disabled={busy} onClick={pay} className="rounded-xl bg-line py-2 font-bold text-black active:scale-95 disabled:opacity-50">{ag.active ? 'ต่ออายุ' : 'ชำระแพ็กเกจ'}</button>
          <button onClick={onTopUp} className="rounded-xl bg-white/10 py-2 font-semibold active:scale-95">เติมเงิน</button>
          <button onClick={onWallet} className="rounded-xl bg-white/10 py-2 text-sm active:scale-95">💰 รายได้ / กระเป๋า</button>
        </div>
      </section>

      <section className="space-y-2 rounded-2xl bg-white/5 p-3 ring-1 ring-white/10">
        <p className="text-sm font-semibold">เชิญน้องเข้าสังกัด</p>
        <p className="text-xs text-neutral-400">ส่งลิงก์/QR/Flex ให้น้อง น้องกดสมัครด้วย LINE ของตัวเองแล้วเข้าสังกัดอัตโนมัติ (รอแอดมินอนุมัติโปรไฟล์) น้องที่เคยออกไปแล้วอยากกลับ ส่งลิงก์ให้อีกครั้งแล้วให้กด "ยอมรับเข้าสังกัด"</p>
        <button onClick={() => setShare(true)} className="w-full rounded-xl bg-line py-2 font-bold text-black active:scale-95">ส่งลิงก์เชิญน้อง</button>
      </section>
      <section className="space-y-2 rounded-2xl bg-white/5 p-3 ring-1 ring-white/10">
        <p className="text-sm font-semibold">ลิงก์ชวนลูกค้า (ได้ส่วนแบ่งเหมือนเซลล์)</p>
        <p className="text-xs text-neutral-400">ลูกค้าที่เข้าผ่านลิงก์ของคุณแล้วจองน้อง คุณได้ 40% ของค่าจอง และ 20% ของค่าแพ็กเกจที่เขาซื้อ ไม่ต้องชำระแพ็กเกจสังกัดก็ได้</p>
        <button onClick={() => setCustShare(true)} className="w-full rounded-xl bg-white/10 py-2 text-sm font-bold active:scale-95">🔗 แชร์ลิงก์ชวนลูกค้า</button>
      </section>
      {custShare && <ShareModal onClose={() => setCustShare(false)} />}
      {ag.active && <BoostCard flash={flash} onChanged={onChanged} />}
      {share && <ShareModal agencyCode={ag.code} onClose={() => setShare(false)} />}
    </div>
  )
}

// The seat board: 10 free seats + paid seats. A girl with a seat has the badge, the leave lock and (paid / promo) the continuing 40 %.
function Seats({ ag, flash, reload, onChanged }) {
  const [rows, setRows] = useState(null)
  const [pick, setPick] = useState(null)      // a waiting girl the agency wants to seat for free by swapping
  const load = useCallback(() => supabase.rpc('agency_seat_board').then(({ data }) => setRows(data ?? [])), [])
  useEffect(() => { load() }, [load])
  async function give(g, kind, release = null) {
    const msg = kind === 'paid' ? `ซื้อที่นั่งให้ ${g.display_name} 200 บาท (30 วัน หรือถึงวันหมดแพ็กเกจ) จาก Wallet?` : `ให้ที่นั่งฟรีแก่ ${g.display_name}?`
    if (!window.confirm(msg)) return
    const { data, error } = await supabase.rpc('agency_give_seat', { p_worker: g.user_id, p_kind: kind, p_release: release })
    if (error) return flash(errText(error.message))
    flash(data === 'requested' ? 'ส่งคำขอความยินยอมให้น้องแล้ว (ค่าที่นั่งถูกกันไว้ คืนอัตโนมัติถ้าน้องไม่ตอบ/ปฏิเสธ)' : 'ให้ที่นั่งแล้ว')
    setPick(null); load(); reload(); onChanged?.()
  }
  async function cancelReq(g) {
    const { error } = await supabase.rpc('agency_cancel_seat_request', { p_worker: g.user_id })
    if (error) return flash(errText(error.message))
    flash('ยกเลิกคำขอแล้ว'); load(); reload(); onChanged?.()
  }
  if (rows === null) return <p className="py-8 text-center text-neutral-500">กำลังโหลด…</p>
  const seated = rows.filter((r) => r.seat_kind)
  const waiting = rows.filter((r) => !r.seat_kind)
  const free = seated.filter((r) => r.seat_kind === 'free')
  const fmt = (d) => (d ? new Date(d).toLocaleDateString('th-TH') : '')
  const row = (g, isSeated) => (
    <li key={g.user_id} className="rounded-2xl bg-white/5 p-3 ring-1 ring-white/10 text-sm">
      <div className="flex items-center justify-between gap-2">
        <p className="min-w-0 truncate font-semibold">#{g.pos} {g.display_name}</p>
        <span className="shrink-0 text-[11px] text-neutral-400">เข้า {fmt(g.joined_at)}</span>
      </div>
      <p className="mt-1 text-xs text-neutral-400">
        {isSeated ? (g.seat_kind === 'free' ? `ที่นั่งฟรี · เปลี่ยนคนได้ตั้งแต่ ${fmt(g.can_swap_at)}` : `ที่นั่งเสียเงิน · หมด ${fmt(g.seat_expires)}`) : 'รอที่นั่ง · น้องยกเลิกสังกัดเองได้ทุกเมื่อ'}
        {g.via_link && g.invite_until && new Date(g.invite_until) > new Date() ? ` · สังกัดชวนมาเอง ได้ 40% ถึง ${fmt(g.invite_until)}` : ''}
      </p>
      {!isSeated && (
        <div className="mt-2 flex flex-wrap gap-2">
          {g.request_status ? (
            <><span className="rounded-lg bg-amber-400/20 px-3 py-1 text-xs text-amber-200">⏳ รอน้องยินยอม</span>
              <button onClick={() => cancelReq(g)} className="rounded-lg bg-white/10 px-3 py-1 text-xs active:scale-95">ยกเลิกคำขอ</button></>
          ) : (
            <>
              {free.length < 10 && <button onClick={() => give(g, 'free')} className="rounded-lg bg-line px-3 py-1 text-xs font-bold text-black active:scale-95">ให้ที่นั่งฟรี</button>}
              {free.length >= 10 && <button onClick={() => setPick(g)} className="rounded-lg bg-white/10 px-3 py-1 text-xs active:scale-95">สลับเข้าที่ฟรี</button>}
              {ag.active && <button onClick={() => give(g, 'paid')} className="rounded-lg bg-pink-500 px-3 py-1 text-xs font-bold active:scale-95">ซื้อที่นั่ง 200 บาท</button>}
            </>
          )}
        </div>
      )}
    </li>
  )
  return (
    <div className="space-y-3">
      <section className="rounded-2xl bg-white/5 p-3 text-xs text-neutral-300 ring-1 ring-white/10 space-y-1">
        <p>💺 ที่นั่งฟรี <b>{free.length}/10</b> · ที่นั่งเสียเงิน <b>{seated.length - free.length}</b></p>
        <p>น้องที่มีที่นั่ง: ป้ายสังกัด, ล็อกก่อนออก, และ {ag.active ? 'คุณได้ 40% ต่อเนื่อง (จ่ายแพ็กเกจแล้ว)' : ag.promo ? 'คุณได้ 40% ต่อเนื่อง (ช่วงโปรโมชัน)' : 'ได้ 40% ต่อเนื่องเมื่อจ่ายแพ็กเกจ'}</p>
        <p>น้องรอที่นั่ง: ยังมีป้าย แต่น้องออกได้ทุกเมื่อ และคุณได้ 40% เฉพาะน้องที่คุณชวนมาเองภายใน 90 วัน</p>
        <p>ที่นั่งฟรีเปลี่ยนคนได้ทุก 30 วัน นับจากวันที่เลือก · ที่นั่งเสียเงินหมดตามวันหมดแพ็กเกจ</p>
      </section>
      {rows.length === 0 && <p className="rounded-2xl bg-white/5 p-6 text-center text-neutral-500">ยังไม่มีน้องในสังกัด</p>}
      {seated.length > 0 && <><p className="px-1 text-sm font-semibold">มีที่นั่ง ({seated.length})</p><ul className="space-y-2">{seated.map((g) => row(g, true))}</ul></>}
      {waiting.length > 0 && <><p className="px-1 text-sm font-semibold">รอที่นั่ง ({waiting.length})</p><ul className="space-y-2">{waiting.map((g) => row(g, false))}</ul></>}
      {pick && (
        <div className="fixed inset-0 z-50 flex items-end bg-black/60" onClick={() => setPick(null)}>
          <div className="max-h-[70vh] w-full space-y-2 overflow-y-auto rounded-t-3xl bg-neutral-900 p-4" onClick={(e) => e.stopPropagation()}>
            <p className="font-semibold">สลับ {pick.display_name} เข้าที่นั่งฟรี แทนใคร?</p>
            {free.map((f) => {
              const ok = f.can_swap_at && new Date(f.can_swap_at) <= new Date()
              return (
                <button key={f.user_id} disabled={!ok} onClick={() => give(pick, 'free', f.user_id)}
                  className="flex w-full items-center justify-between rounded-xl bg-white/10 px-3 py-2 text-left text-sm disabled:opacity-40">
                  <span>{f.display_name}</span><span className="text-xs text-neutral-400">{ok ? 'เปลี่ยนได้' : `ได้ตั้งแต่ ${fmt(f.can_swap_at)}`}</span>
                </button>
              )
            })}
            <button onClick={() => setPick(null)} className="w-full rounded-xl bg-white/5 py-2 text-sm">ปิด</button>
          </div>
        </div>
      )}
    </div>
  )
}

// Change the name / logo: the live ones stay until an admin approves the request.
function Settings({ ag, me, reload, flash }) {
  const [req, setReq] = useState(undefined)   // latest pending / rejected request
  const [name, setName] = useState(ag.name)
  const [file, setFile] = useState(null)
  const [preview, setPreview] = useState(null)
  const [busy, setBusy] = useState(false)
  const [disp, setDisp] = useState(null)        // { show_badge, show_count, intro } as it is live now
  const [intro, setIntro] = useState('')
  const input = 'mt-1 w-full rounded-xl bg-white/10 px-3 py-2.5 text-base outline-none ring-1 ring-white/10 focus:ring-line'
  useEffect(() => { supabase.rpc('agency_display').then(({ data }) => { setDisp(data ?? null); setIntro(data?.intro ?? '') }) }, [])
  async function toggle(key) {
    const next = { ...disp, [key]: !disp[key] }
    setDisp(next)
    const { error } = await supabase.rpc('agency_set_display', { p_badge: next.show_badge, p_count: next.show_count })
    if (error) { setDisp(disp); return flash('บันทึกไม่สำเร็จ') }
    flash('บันทึกแล้ว')
  }
  const loadReq = useCallback(() => supabase.rpc('agency_my_edit').then(({ data }) => setReq(data ?? null)), [])
  useEffect(() => { loadReq() }, [loadReq])

  async function submit(e) {
    e.preventDefault()
    if (busy) return
    setBusy(true)
    let path = null
    if (file) {
      path = `${me.id}/pending-${Date.now()}.jpg`
      let blob
      try { blob = await logoBlob(file) } catch { setBusy(false); return flash('อ่านรูปนี้ไม่ได้ กรุณาเลือกรูป JPG หรือ PNG') }
      const { error } = await supabase.storage.from('agency-logos').upload(path, blob, { contentType: 'image/jpeg' })
      if (error) { setBusy(false); return flash(`อัปโหลดโลโก้ไม่สำเร็จ: ${error.message}`.slice(0, 140)) }
    }
    const { error } = await supabase.rpc('agency_request_edit', { p_name: name, p_logo_path: path, p_intro: intro.trim() !== (disp?.intro ?? '') ? intro.trim() : null })
    setBusy(false)
    if (error) return flash(errText(error.message))
    flash('ส่งให้แอดมินอนุมัติแล้ว')
    setFile(null); setPreview(null); loadReq()
  }
  async function cancel() {
    await supabase.rpc('agency_cancel_edit')
    flash('ยกเลิกคำขอแล้ว'); loadReq()
  }

  const pending = req?.status === 'pending'
  return (
    <form onSubmit={submit} className="space-y-4">
      {disp && (
        <section className="space-y-2 rounded-2xl bg-white/5 p-3 ring-1 ring-white/10">
          <p className="text-sm font-semibold">การแสดงผลหน้าลูกค้า (มีผลทันที)</p>
          {[['show_badge', 'แสดงป้ายสังกัดบนการ์ดน้อง', 'ป้ายโลโก้และชื่อสังกัดมุมรูปน้อง กดแล้วเข้าหน้าสังกัด'], ['show_count', 'แสดงจำนวนน้องในสังกัด', 'ตัวเลขบนแถบสังกัดและหน้าสังกัด']].map(([k, label, hint]) => (
            <button type="button" key={k} onClick={() => toggle(k)} className="flex w-full items-center justify-between gap-3 rounded-xl bg-white/5 px-3 py-2.5 text-left active:scale-[0.99]">
              <span><span className="block text-sm font-semibold">{label}</span><span className="block text-[11px] text-neutral-400">{hint}</span></span>
              <span className={`shrink-0 rounded-full px-3 py-1 text-xs font-bold ${disp[k] ? 'bg-line text-black' : 'bg-white/10 text-neutral-300'}`}>{disp[k] ? 'เปิด' : 'ปิด'}</span>
            </button>
          ))}
          <p className="text-[11px] text-neutral-500">หน้าสังกัดและน้องของคุณแสดงต่อลูกค้าเมื่อแพ็กเกจสังกัดชำระและยังไม่หมดอายุเท่านั้น</p>
        </section>
      )}
      <p className="text-sm text-neutral-400">แก้ชื่อ โลโก้ หรือข้อความแนะนำสังกัดได้ แต่ต้องรอแอดมินอนุมัติ ระหว่างนั้นระบบยังใช้ของเดิมอยู่</p>
      {pending && (
        <div className="space-y-2 rounded-2xl bg-amber-400/10 p-3 text-sm text-amber-200">
          <p>⏳ รอแอดมินอนุมัติ{req.new_name ? ` · ชื่อใหม่: ${req.new_name}` : ''}{req.new_logo_path ? ' · โลโก้ใหม่' : ''}{req.new_intro != null ? ' · ข้อความแนะนำใหม่' : ''}</p>
          {req.new_logo_path && <img src={logoUrl(req.new_logo_path)} alt="" className="h-14 w-14 rounded-full object-cover" />}
          <button type="button" onClick={cancel} className="rounded-lg bg-white/10 px-3 py-1 text-xs text-neutral-200 active:scale-95">ยกเลิกคำขอ</button>
        </div>
      )}
      {req?.status === 'rejected' && <p className="rounded-xl bg-red-500/10 p-2 text-sm text-red-300">คำขอล่าสุดไม่ผ่าน{req.reject_reason ? ` — ${req.reject_reason}` : ''} แก้ไขแล้วส่งใหม่ได้</p>}
      <label className="block text-sm">ชื่อสังกัด
        <input required minLength={2} maxLength={60} value={name} onChange={(e) => setName(e.target.value)} className={input} />
      </label>
      <div className="space-y-2 text-sm">
        <span>โลโก้สังกัด</span>
        <div className="flex items-center gap-3 rounded-2xl bg-white/5 p-3">
          {preview || ag.logo_path
            ? <img src={preview ?? logoUrl(ag.logo_path)} alt="logo" className="h-20 w-20 shrink-0 rounded-full object-cover ring-2 ring-white/20" />
            : <span className="flex h-20 w-20 shrink-0 items-center justify-center rounded-full bg-white/10 text-3xl">🏢</span>}
          <label className="flex-1 cursor-pointer rounded-xl bg-white/10 py-2.5 text-center font-semibold active:scale-95">
            {preview ? 'เปลี่ยนรูปอีกครั้ง' : 'เลือกโลโก้ใหม่'}
            <input type="file" accept="image/*" className="hidden"
              onChange={(e) => { const f = e.target.files?.[0] ?? null; setFile(f); setPreview((old) => { if (old) URL.revokeObjectURL(old); return f ? URL.createObjectURL(f) : null }) }} />
          </label>
        </div>
      </div>
      <label className="block text-sm">ข้อความแนะนำสังกัด (ลูกค้าเห็นบนหน้าสังกัด สูงสุด 200 ตัวอักษร ต้องผ่านแอดมิน)
        <textarea rows={3} maxLength={200} value={intro} onChange={(e) => setIntro(e.target.value)} className={input} placeholder="เช่น รับงานย่านพัทยา ดูแลโดยทีมงานมืออาชีพ" />
      </label>
      <button disabled={busy || (!file && name.trim() === ag.name && intro.trim() === (disp?.intro ?? ''))} className="w-full rounded-xl bg-line py-3 font-bold text-black active:scale-95 disabled:opacity-40">{busy ? 'กำลังส่ง…' : 'ส่งให้แอดมินอนุมัติ'}</button>
    </form>
  )
}

// Buy the first places of the agency strip on the customers' provider lists (3 places at a time; bonus wallet first, then the Wallet).
function BoostCard({ flash, onChanged }) {
  const [st, setSt] = useState(null)
  const [busy, setBusy] = useState(false)
  const load = useCallback(() => supabase.rpc('agency_boost_status').then(({ data }) => setSt(data ?? null)), [])
  useEffect(() => { load() }, [load])
  if (!st) return null
  const packs = [[1, st.price_day, '1 วัน'], [3, st.price_3, '3 วัน'], [7, st.price_7, '7 วัน (จ่าย 5 วัน)']]
  async function buy(days, price) {
    if (busy || !window.confirm(`ซื้อลำดับแรกของแถบสังกัด ${days} วัน ราคา ${baht(price)} (หักจากกระเป๋าโบนัสก่อน ที่เหลือหักจาก Wallet)?`)) return
    setBusy(true)
    const { error } = await supabase.rpc('agency_buy_boost', { p_days: days })
    setBusy(false)
    if (error) return flash(errText(error.message))
    flash('ซื้อลำดับแรกแล้ว'); load(); onChanged?.()
  }
  return (
    <section className="space-y-2 rounded-2xl bg-amber-400/10 p-3 ring-1 ring-amber-400/30">
      <p className="text-sm font-semibold text-amber-200">⭐ ซื้อลำดับแรกของแถบสังกัด</p>
      <p className="text-xs text-neutral-300">สังกัดที่ซื้อจะขึ้นก่อนสังกัดอื่นในแถบบนหน้ารายชื่อน้องของลูกค้า พร้อมป้าย "⭐ แนะนำ" มีได้ครั้งละ {st.slots} สังกัด (ตอนนี้ใช้อยู่ {st.used}/{st.slots}) ถ้าซื้อต่อ วันจะบวกเพิ่ม</p>
      {st.mine_until && <p className="text-xs font-semibold text-green-300">ของคุณใช้งานอยู่ถึง {new Date(st.mine_until).toLocaleString('th-TH', { dateStyle: 'medium', timeStyle: 'short' })}</p>}
      <div className="grid grid-cols-3 gap-2">
        {packs.map(([d, price, label]) => (
          <button key={d} disabled={busy || (!st.mine_until && st.used >= st.slots)} onClick={() => buy(d, price)} className="rounded-xl bg-amber-400 px-1 py-2 text-center text-xs font-bold text-black active:scale-95 disabled:opacity-40">
            {label}<span className="block text-[11px] font-semibold">{baht(price)}</span>
          </button>
        ))}
      </div>
    </section>
  )
}
