import { useCallback, useEffect, useState } from 'react'
import { supabase } from '../supabaseClient'
import { fmtDate } from './format'

const ERR = {
  OWNER_REQUIRED: 'ต้องเลือกเจ้าของเซลล์ (บัญชีของเซลล์ในระบบ) เพื่อรับค่าคอม',
  vendors_liff_id_check: 'LIFF ID ไม่ถูกรูปแบบ ต้องเป็นเลขช่อง-ตัวอักษร เช่น 1234567890-AbCdEfGh',
  vendors_liff_id_key: 'LIFF ID นี้ถูกใช้กับเซลล์อื่นแล้ว',
  vendors_name_check: 'ชื่อเซลล์ต้องยาว 2-60 ตัวอักษร',
}
const errText = (m = '') => ERR[Object.keys(ERR).find((k) => m.includes(k))] ?? 'บันทึกไม่สำเร็จ'
const CODE = { NO_TOKEN: 'ยังไม่ได้ใส่ token', LINE_REJECTED: 'LINE ไม่ยอมรับ token นี้', ERROR: 'เกิดข้อผิดพลาด', FORBIDDEN: 'ไม่มีสิทธิ์', UNAUTHORIZED: 'ไม่ได้ล็อกอิน', BAD_INPUT: 'ข้อมูลไม่ถูกต้อง' }

// Sellers with their own LINE Official Account. The seller sends us his LIFF ID and his OA's channel access token (kept in Vault).
export default function Vendors({ toast }) {
  const [rows, setRows] = useState(null)
  const [editing, setEditing] = useState(null)      // null | 'new' | vendor row
  const [staffOf, setStaffOf] = useState(null)        // vendor row whose staff are being managed
  const load = useCallback(async () => { const { data } = await supabase.rpc('admin_vendor_list'); setRows(data ?? []) }, [])
  useEffect(() => { load() }, [load])

  const endpoint = (id) => `${window.location.origin}${import.meta.env.BASE_URL}?vendor=${id}`
  const copy = async (text, ok) => { try { await navigator.clipboard.writeText(text); toast(ok) } catch { window.prompt('คัดลอก', text) } }

  async function test(v) {
    const { data, error } = await supabase.functions.invoke('vendor-admin', { body: { action: 'test', vendor_id: v.id } })
    if (error || !data) return toast('เรียกฟังก์ชัน vendor-admin ไม่สำเร็จ (deploy แล้วหรือยัง?)')
    if (!data.ok) return toast(`❌ ${CODE[data.code] ?? data.code}${data.detail ? `: ${data.detail}` : ''}`)
    toast(`✅ เชื่อมต่อ OA "${data.displayName ?? ''}" ${data.basicId ?? ''} สำเร็จ`)
    load()
  }
  async function setStatus(v, status) {
    await supabase.rpc('admin_vendor_set_status', { p_id: v.id, p_status: status })
    load()
  }

  return (
    <div className="space-y-4">
      <div className="flex items-center justify-between gap-2">
        <p className="text-xs text-neutral-400">เซลล์แต่ละคนมี LINE OA และ LIFF ของตัวเอง ลูกค้าที่เข้าจากลิงก์ของเขาเป็นลูกค้าของเขา (บัญชีและ Wallet แยก) ค่าคอมเข้าเจ้าของเซลล์อัตโนมัติ</p>
        <button onClick={() => setEditing('new')} className="shrink-0 rounded-xl bg-pink-500 px-4 py-2 text-sm font-bold active:scale-95">➕ เพิ่มเซลล์</button>
      </div>

      {rows === null ? <p className="py-10 text-center text-neutral-500">กำลังโหลด…</p> : rows.length === 0 ? (
        <p className="rounded-2xl bg-white/5 p-6 text-center text-neutral-500">ยังไม่มีเซลล์</p>
      ) : (
        <ul className="grid gap-3 md:grid-cols-2">
          {rows.map((v) => (
            <li key={v.id} className={`space-y-2 rounded-2xl p-3 ring-1 ${v.status === 'active' ? 'bg-white/5 ring-white/10' : 'bg-neutral-800/60 ring-white/5 opacity-70'}`}>
              <div className="flex items-center justify-between gap-2">
                <p className="truncate font-bold">{v.name}</p>
                <span className={`rounded-full px-2 py-0.5 text-[11px] font-semibold ${v.status === 'active' ? 'bg-green-500/20 text-green-300' : 'bg-neutral-600/40 text-neutral-300'}`}>{v.status === 'active' ? 'เปิดใช้' : 'ปิด'}</span>
              </div>
              <p className="text-xs text-neutral-400">รหัส <b className="text-white">{v.id}</b> · เจ้าของ: {v.owner_name ?? '—'} · ลูกค้า {v.customers} คน · เพิ่ม {fmtDate(v.created_at)}</p>
              <p className="text-xs text-neutral-400">LIFF: {v.liff_id} · token: {v.has_token ? '✅ เก็บใน Vault' : '❌ ยังไม่มี'}{v.oa_basic_id ? ` · OA ${v.oa_basic_id}` : ''}</p>
              <div className="flex flex-wrap gap-2">
                <button onClick={() => copy(endpoint(v.id), 'คัดลอก Endpoint URL แล้ว (ไปใส่ใน LIFF ของเซลล์)')} className="rounded-lg bg-white/10 px-3 py-1.5 text-xs font-semibold active:scale-95">📋 Endpoint URL</button>
                <button onClick={() => copy(`https://liff.line.me/${v.liff_id}`, 'คัดลอกลิงก์ลูกค้าแล้ว')} className="rounded-lg bg-white/10 px-3 py-1.5 text-xs font-semibold active:scale-95">🔗 ลิงก์ลูกค้า</button>
                <button onClick={() => test(v)} className="rounded-lg bg-white/10 px-3 py-1.5 text-xs font-semibold active:scale-95">🧪 ทดสอบ token</button>
                <button onClick={() => setStaffOf(v)} className="rounded-lg bg-white/10 px-3 py-1.5 text-xs font-semibold active:scale-95">👥 แอดมินเซลล์</button>
                <button onClick={() => setEditing(v)} className="rounded-lg bg-white/10 px-3 py-1.5 text-xs font-semibold active:scale-95">✏️ แก้ไข</button>
                <button onClick={() => setStatus(v, v.status === 'active' ? 'disabled' : 'active')} className="rounded-lg bg-white/10 px-3 py-1.5 text-xs font-semibold active:scale-95">{v.status === 'active' ? 'ปิด' : 'เปิด'}</button>
              </div>
            </li>
          ))}
        </ul>
      )}

      {staffOf && <StaffModal vendor={staffOf} toast={toast} onClose={() => setStaffOf(null)} />}
      {editing && <VendorForm vendor={editing === 'new' ? null : editing} endpoint={endpoint} onClose={() => setEditing(null)} onSaved={(msg) => { setEditing(null); toast(msg); load() }} />}
    </div>
  )
}

function VendorForm({ vendor, endpoint, onClose, onSaved }) {
  const [name, setName] = useState(vendor?.name ?? '')
  const [liff, setLiff] = useState(vendor?.liff_id ?? '')
  const [token, setToken] = useState('')
  const [owner, setOwner] = useState(vendor ? { id: vendor.owner_id, name: vendor.owner_name } : null)
  const [q, setQ] = useState('')
  const [found, setFound] = useState([])
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState(null)
  const input = 'mt-1 w-full rounded-xl bg-white/10 px-3 py-2.5 text-base outline-none ring-1 ring-white/10 focus:ring-line'

  useEffect(() => {
    if (q.trim().length < 2) return setFound([])
    const h = setTimeout(() => supabase.rpc('admin_search_users', { p_q: q }).then(({ data }) => setFound(data ?? [])), 300)
    return () => clearTimeout(h)
  }, [q])

  async function save() {
    setError(null)
    if (!owner?.id) return setError(ERR.OWNER_REQUIRED)
    if (!vendor && !token.trim()) return setError('ใส่ Channel access token ของ OA เซลล์')
    setBusy(true)
    const { data, error: e } = await supabase.rpc('admin_vendor_save', { p_id: vendor?.id ?? null, p_name: name, p_owner: owner.id, p_liff_id: liff, p_token: token.trim() || null })
    setBusy(false)
    if (e) return setError(errText(e.message))
    onSaved(vendor ? 'บันทึกแล้ว' : `เพิ่มเซลล์แล้ว รหัส ${data} — เอา Endpoint URL ไปใส่ใน LIFF ของเซลล์`)
  }

  return (
    <div className="fixed inset-0 z-50 flex items-end justify-center bg-black/70 sm:items-center sm:p-4" onClick={onClose}>
      <div onClick={(e) => e.stopPropagation()} className="max-h-[94vh] w-full max-w-md space-y-3 overflow-y-auto rounded-t-3xl bg-neutral-900 p-5 shadow-2xl sm:rounded-3xl">
        <div className="flex items-center justify-between"><h2 className="text-lg font-bold">{vendor ? 'แก้ไขเซลล์' : 'เพิ่มเซลล์ (LINE OA ของตัวเอง)'}</h2><button onClick={onClose} className="rounded-full bg-white/10 px-3 py-1 text-sm">✕</button></div>

        <label className="block text-sm">ชื่อเซลล์ (น้องจะเห็นเป็น "ลูกค้าจาก: …")
          <input maxLength={60} value={name} onChange={(e) => setName(e.target.value)} placeholder="เช่น นางฟ้า" className={input} />
        </label>

        <div className="space-y-2">
          <p className="text-sm">เจ้าของเซลล์ (รับค่าคอมของลูกค้าทุกคนของเซลล์นี้)</p>
          {owner?.id && <p className="rounded-lg bg-green-500/10 p-2 text-sm text-green-300">✓ {owner.name ?? owner.id} <button onClick={() => setOwner(null)} className="ml-2 underline">เปลี่ยน</button></p>}
          {!owner?.id && (
            <>
              <input value={q} onChange={(e) => setQ(e.target.value)} placeholder="🔍 ค้นหาบัญชีของเซลล์ (ชื่อ LINE)" className={input} />
              <ul className="space-y-1">{found.map((f) => <li key={f.id}><button onClick={() => { setOwner({ id: f.id, name: f.display_name }); setQ(''); setFound([]) }} className="w-full rounded-xl bg-white/5 px-3 py-2 text-left text-sm active:scale-95">{f.display_name ?? '—'}</button></li>)}</ul>
              <p className="text-[11px] text-neutral-500">เซลล์ต้องเคยเปิดแอปกลางด้วย LINE ของตัวเองหนึ่งครั้ง ถึงจะค้นเจอ</p>
            </>
          )}
        </div>

        <label className="block text-sm">LIFF ID ของเซลล์
          <input value={liff} onChange={(e) => setLiff(e.target.value)} placeholder="1234567890-AbCdEfGh" className={input} />
        </label>
        <label className="block text-sm">Channel access token (long-lived) ของ LINE OA เซลล์
          <input type="password" autoComplete="off" value={token} onChange={(e) => setToken(e.target.value)} placeholder={vendor ? 'เว้นว่าง = ใช้ token เดิม' : 'วางที่นี่ ระบบเก็บใน Vault'} className={input} />
        </label>
        <p className="text-[11px] text-neutral-500">token ถูกเก็บเข้ารหัสในฝั่งเซิร์ฟเวอร์ และจะไม่แสดงกลับมาอีก</p>

        {vendor && (
          <div className="space-y-1 rounded-xl bg-white/5 p-3 text-xs">
            <p className="font-semibold">Endpoint URL สำหรับ LIFF ของเซลล์</p>
            <p className="break-all text-neutral-300">{endpoint(vendor.id)}</p>
          </div>
        )}
        <details className="rounded-xl bg-white/5 p-3 text-xs text-neutral-300">
          <summary className="cursor-pointer font-semibold">รายการที่เซลล์ต้องทำใน LINE Developers</summary>
          <ol className="mt-2 list-decimal space-y-1 pl-4">
            <li>สร้าง Provider ของตัวเอง ใส่ทั้ง LINE OA (เปิด Messaging API) และช่อง LINE Login ไว้ใน Provider เดียวกัน</li>
            <li>ในช่อง LINE Login สร้าง LIFF app: Endpoint URL = ลิงก์ด้านบน, Scope = openid + profile, Bot link feature = Normal และเลือก OA ของตัวเอง</li>
            <li>เปลี่ยนสถานะช่อง LINE Login เป็น Published (ถ้ายังเป็น Developing จะมีแต่แอดมินช่องที่ล็อกอินได้)</li>
            <li>ส่ง LIFF ID และ Channel access token (long-lived) ของ OA ให้แอดมิน</li>
          </ol>
        </details>

        {error && <p className="rounded-lg bg-red-500/10 p-2 text-sm text-red-300">{error}</p>}
        <button disabled={busy} onClick={save} className="w-full rounded-xl bg-line py-3 font-bold text-black active:scale-95 disabled:opacity-50">{busy ? 'กำลังบันทึก…' : 'บันทึก'}</button>
      </div>
    </div>
  )
}

// The seller's own admins: they answer his customers' chats (in his LIFF) and get the Flex pushes through his OA.
function StaffModal({ vendor, toast, onClose }) {
  const [staff, setStaff] = useState(null)
  const [q, setQ] = useState('')
  const [found, setFound] = useState([])
  const load = useCallback(async () => { const { data } = await supabase.rpc('admin_vendor_staff_list', { p_vendor: vendor.id }); setStaff(data ?? []) }, [vendor.id])
  useEffect(() => { load() }, [load])
  useEffect(() => {
    const h = setTimeout(() => supabase.rpc('admin_search_vendor_users', { p_vendor: vendor.id, p_q: q }).then(({ data }) => setFound(data ?? [])), 250)
    return () => clearTimeout(h)
  }, [q, vendor.id])

  async function add(u) {
    const { error } = await supabase.rpc('admin_vendor_staff_add', { p_vendor: vendor.id, p_user: u.id })
    if (error) return toast('เพิ่มไม่สำเร็จ')
    toast(`เพิ่ม ${u.display_name ?? 'แอดมิน'} แล้ว`); setQ(''); load()
  }
  async function remove(u) {
    if (!window.confirm(`เอา ${u.name ?? 'แอดมิน'} ออก? จะไม่ได้รับแจ้งเตือนและตอบแชตไม่ได้`)) return
    await supabase.rpc('admin_vendor_staff_remove', { p_vendor: vendor.id, p_user: u.user_id })
    load()
  }

  return (
    <div className="fixed inset-0 z-50 flex items-end justify-center bg-black/70 sm:items-center sm:p-4" onClick={onClose}>
      <div onClick={(e) => e.stopPropagation()} className="max-h-[92vh] w-full max-w-md space-y-3 overflow-y-auto rounded-t-3xl bg-neutral-900 p-5 shadow-2xl sm:rounded-3xl">
        <div className="flex items-center justify-between"><h2 className="text-lg font-bold">👥 แอดมินของ {vendor.name}</h2><button onClick={onClose} className="rounded-full bg-white/10 px-3 py-1 text-sm">✕</button></div>
        <p className="text-xs text-neutral-400">ลูกค้าของเซลล์ที่กดแชตหาแอดมินจะคุยกับคนในรายการนี้ (ไม่ใช่แอดมินกลาง) เมื่อลูกค้าส่งข้อความ ระบบส่ง Flex ผ่าน OA ของเซลล์ถึง User ID LINE ของแต่ละคน (ไม่เกิน 1 ครั้งต่อห้องต่อ 10 นาที)</p>

        {staff === null ? <p className="text-center text-sm text-neutral-500">กำลังโหลด…</p> : staff.length === 0 ? (
          <p className="rounded-xl bg-white/5 p-3 text-center text-sm text-neutral-500">ยังไม่มีแอดมินของเซลล์นี้</p>
        ) : (
          <ul className="space-y-2">
            {staff.map((u) => (
              <li key={u.user_id} className="flex items-center justify-between gap-2 rounded-xl bg-white/5 p-3">
                <span className="min-w-0 text-sm"><b className="block truncate">{u.name ?? '—'}</b>
                  <span className="block truncate text-[11px] text-neutral-400">User ID: {u.line_id}</span>
                  <span className={`text-[11px] ${u.push_ready ? 'text-green-300' : 'text-red-300'}`}>{u.push_ready ? '✓ พร้อมรับ push' : '✗ รหัส LINE ไม่ถูกต้อง'}</span></span>
                <button onClick={() => remove(u)} className="shrink-0 rounded-lg bg-red-500/10 px-3 py-1 text-xs text-red-300 active:scale-95">ออก</button>
              </li>
            ))}
          </ul>
        )}

        <div className="space-y-2 rounded-2xl bg-white/5 p-3">
          <p className="text-sm font-semibold">เพิ่มแอดมินเซลล์</p>
          <input value={q} onChange={(e) => setQ(e.target.value)} placeholder="🔍 ค้นชื่อ LINE ของคนที่เคยเปิดแอป" className="w-full rounded-xl bg-white/10 px-3 py-2 text-sm" />
          <ul className="space-y-1">
            {found.map((f) => <li key={f.id}><button onClick={() => add(f)} className="flex w-full items-center justify-between rounded-xl bg-white/5 px-3 py-2 text-left text-sm active:scale-95"><span>{f.display_name ?? '—'}</span><span className="text-[10px] text-neutral-500">{f.line_id.slice(0, 10)}…</span></button></li>)}
          </ul>
          <p className="text-[11px] text-neutral-500">คนที่จะเป็นแอดมินเซลล์ต้องเคยเปิดแอป (ลิงก์ของเซลล์หรือของ DekEn) ด้วย LINE ของตัวเองหนึ่งครั้ง จึงจะค้นเจอ และต้องเพิ่มเพื่อน LINE OA ของเซลล์ เพื่อรับ push</p>
        </div>
      </div>
    </div>
  )
}
