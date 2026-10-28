import { useCallback, useEffect, useState } from 'react'
import { supabase } from '../supabaseClient'
import { MEMBERSHIP_DAYS, PLAN_META, PLANS } from '../config'
import { baht, fmtDateTime, fmtDate, ago } from './format'

const METHODS = { promptpay: 'PromptPay', bank_transfer: 'โอนธนาคาร', cash: 'เงินสด', other: 'อื่นๆ' }
const ERRORS = {
  DUPLICATE_REFERENCE: 'เลขอ้างอิงนี้ถูกบันทึกแล้วในวิธีชำระเดียวกัน (กันสลิปซ้ำ)',
  USER_NOT_FOUND: 'ไม่พบผู้ใช้',
  BAD_INPUT: 'ข้อมูลไม่ถูกต้อง',
  FORBIDDEN: 'ไม่มีสิทธิ์',
}
const errText = (m = '') => Object.entries(ERRORS).find(([k]) => m.includes(k))?.[1] ?? 'บันทึกไม่สำเร็จ ตรวจสอบจำนวนเงิน/วิธีชำระ'

// Record a payment you verified (slip / bank statement). One click applies it:
// membership => extends or starts the plan; wallet top-up => credits the wallet. Every entry is kept in the ledger.
function Avatar({ u }) {
  return u.picture_url
    ? <img src={u.picture_url} alt="" referrerPolicy="no-referrer" className="h-10 w-10 shrink-0 rounded-full object-cover" />
    : <span className="flex h-10 w-10 shrink-0 items-center justify-center rounded-full bg-white/10 text-sm font-bold">{(u.display_name ?? '?').slice(0, 1)}</span>
}

export default function Payments({ prefill, clearPrefill, onChanged, toast }) {
  const [q, setQ] = useState('')
  const [results, setResults] = useState([])
  const [user, setUser] = useState(null)
  const [kind, setKind] = useState('membership')
  const [tier, setTier] = useState(1)
  const [days, setDays] = useState(MEMBERSHIP_DAYS)
  const [amount, setAmount] = useState(String(PLANS[0].price))
  const [method, setMethod] = useState('promptpay')
  const [reference, setReference] = useState('')
  const [note, setNote] = useState('')
  const [busy, setBusy] = useState(false)
  const [ledger, setLedger] = useState(null)
  const [failed, setFailed] = useState([])

  const loadLedger = useCallback(async () => {
    const { data } = await supabase.rpc('admin_list_payments', { p_limit: 100 })
    setLedger(data ?? [])
    const f = await supabase.rpc('admin_list_slip_attempts', { p_limit: 30 })
    setFailed(f.data ?? [])
  }, [])
  useEffect(() => { loadLedger() }, [loadLedger])

  // "Renew" from the Members tab
  useEffect(() => {
    if (!prefill) return
    setUser(prefill.user)
    pickTier(prefill.tier || 1)
    setKind('membership')
    clearPrefill()
  }, [prefill]) // eslint-disable-line react-hooks/exhaustive-deps

  // Debounced user search
  useEffect(() => {
    const h = setTimeout(async () => {
      const { data } = await supabase.rpc('admin_search_users', { p_q: q })
      setResults(data ?? [])
    }, q ? 300 : 0)
    return () => clearTimeout(h)
  }, [q])

  function pickTier(t) {
    setTier(t)
    setAmount(String(PLANS.find((p) => p.tier === t).price)) // default to the list price; editable
  }

  async function submit(e) {
    e.preventDefault()
    if (!user) return toast('เลือกผู้ใช้ก่อน')
    const amt = Number(amount)
    if (!(amt > 0)) return toast('จำนวนเงินต้องมากกว่า 0')
    const summary = kind === 'membership'
      ? `ให้ ${user.display_name} เป็น ${PLAN_META[tier].name} เพิ่ม ${days} วัน`
      : `เติม Wallet ให้ ${user.display_name}`
    if (!window.confirm(`${summary}\nรับชำระ ${baht(amt)} (${METHODS[method]})${reference ? `\nอ้างอิง ${reference}` : ''}\n\nยืนยัน?`)) return

    setBusy(true)
    const { error } = await supabase.rpc('admin_record_payment', {
      p_user: user.id, p_kind: kind, p_tier: kind === 'membership' ? tier : null, p_days: kind === 'membership' ? Number(days) : null,
      p_amount: amt, p_method: method, p_reference: reference || null, p_note: note || null,
    })
    setBusy(false)
    if (error) return toast(errText(error.message))

    toast('บันทึกแล้ว')
    setReference('')
    setNote('')
    // refresh the selected user's numbers
    const { data } = await supabase.rpc('admin_search_users', { p_q: user.line_user_id })
    setUser(data?.find((u) => u.id === user.id) ?? user)
    loadLedger()
    onChanged()
  }

  const input = 'w-full rounded-xl bg-white/10 px-3 py-2.5 text-base outline-none ring-1 ring-white/10 focus:ring-line'

  return (
    <div className="space-y-6">
      <form onSubmit={submit} className="space-y-4 rounded-2xl bg-white/5 p-4 ring-1 ring-white/10">
        <h2 className="text-base font-bold">บันทึกการรับชำระเงิน</h2>

        {/* 1) who */}
        {user ? (
          <div className="flex items-center justify-between gap-3 rounded-xl bg-line/15 p-3 ring-1 ring-line/40">
            <Avatar u={user} />
            <div className="min-w-0 flex-1 text-sm">
              <p className="truncate font-bold">{user.display_name ?? '—'}</p>
              <p className="truncate text-[11px] text-neutral-400">{user.line_user_id}</p>
              <p className="text-xs">
                {user.vip_tier > 0 && new Date(user.vip_expires_at) > new Date()
                  ? `${PLAN_META[user.vip_tier].name} หมด ${fmtDate(user.vip_expires_at)}` : 'ไม่มีแพ็กเกจ'}
                {' · '}Wallet {baht(user.wallet_balance)}
              </p>
            </div>
            <button type="button" onClick={() => setUser(null)} className="shrink-0 rounded-lg bg-white/10 px-3 py-1 text-sm">เปลี่ยน</button>
          </div>
        ) : (
          <div>
            <input value={q} onChange={(e) => setQ(e.target.value)} placeholder="ค้นหาชื่อ LINE หรือ LINE user id" className={input} />
            <p className="mt-2 text-[11px] text-neutral-500">{q ? 'ผลการค้นหา' : 'ผู้ใช้ที่เข้าแอปล่าสุด — แตะเพื่อเลือก'}</p>
            {results.length > 0 && (
              <ul className="mt-1 max-h-72 divide-y divide-white/10 overflow-y-auto rounded-xl bg-neutral-900 ring-1 ring-white/10">
                {results.map((u) => (
                  <li key={u.id}>
                    <button type="button" onClick={() => { setUser(u); setQ('') }} className="flex w-full items-center gap-3 px-3 py-2 text-left text-sm hover:bg-white/5">
                      <Avatar u={u} />
                      <span className="min-w-0 flex-1">
                        <span className="block truncate font-semibold">{u.display_name ?? '—'}</span>
                        <span className="block truncate text-[11px] text-neutral-500">
                          {u.role} · …{u.line_user_id.slice(-6)} · {u.last_seen_at ? `เข้าล่าสุด ${ago(u.last_seen_at)}` : 'ไม่ทราบเวลาเข้า'}
                        </span>
                      </span>
                      {u.vip_tier > 0 && new Date(u.vip_expires_at) > new Date() && (
                        <span className="shrink-0 text-[11px]">{PLAN_META[u.vip_tier].icon}</span>
                      )}
                    </button>
                  </li>
                ))}
              </ul>
            )}
          </div>
        )}

        {/* 2) what */}
        <div className="flex gap-2">
          {[['membership', 'ค่าสมาชิก'], ['wallet_topup', 'เติม Wallet']].map(([id, label]) => (
            <button key={id} type="button" onClick={() => setKind(id)} className={`flex-1 rounded-xl py-2 text-sm font-semibold ${kind === id ? 'bg-white text-black' : 'bg-white/10'}`}>{label}</button>
          ))}
        </div>

        {kind === 'membership' && (
          <div className="grid grid-cols-3 gap-2">
            {PLANS.map((p) => {
              const m = PLAN_META[p.tier]
              return (
                <button key={p.tier} type="button" onClick={() => pickTier(p.tier)}
                  className={`rounded-xl p-2 text-center text-sm ring-2 ${tier === p.tier ? m.ring : 'ring-transparent'} ${m.soft}`}>
                  <span className="block font-bold">{m.icon} {m.name}</span>
                  <span className="text-xs text-neutral-400">{p.price} บาท</span>
                </button>
              )
            })}
          </div>
        )}

        <div className="grid grid-cols-2 gap-3">
          <label className="text-sm">จำนวนเงินที่ได้รับ (บาท)
            <input type="number" min="1" step="any" inputMode="decimal" required value={amount} onChange={(e) => setAmount(e.target.value)} className={`${input} mt-1`} />
          </label>
          {kind === 'membership' ? (
            <label className="text-sm">จำนวนวัน
              <input type="number" min="1" max="365" required value={days} onChange={(e) => setDays(e.target.value)} className={`${input} mt-1`} />
            </label>
          ) : <div />}
          <label className="text-sm">วิธีชำระ
            <select value={method} onChange={(e) => setMethod(e.target.value)} className={`${input} mt-1`}>
              {Object.entries(METHODS).map(([k, v]) => <option key={k} value={k} className="text-black">{v}</option>)}
            </select>
          </label>
          <label className="text-sm">เลขอ้างอิง / สลิป
            <input value={reference} onChange={(e) => setReference(e.target.value)} placeholder="กันบันทึกซ้ำ" className={`${input} mt-1`} />
          </label>
        </div>
        <label className="block text-sm">หมายเหตุ
          <input value={note} onChange={(e) => setNote(e.target.value)} className={`${input} mt-1`} />
        </label>

        <button disabled={busy || !user} className="w-full rounded-xl bg-line py-3 font-bold text-black active:scale-95 disabled:opacity-50">
          {busy ? 'กำลังบันทึก…' : 'ยืนยันรับชำระและเปิดสิทธิ์'}
        </button>
      </form>

      {/* Ledger */}
      <section>
        <h2 className="mb-2 text-base font-bold">ประวัติรับชำระล่าสุด</h2>
        {ledger === null ? <p className="py-6 text-center text-neutral-500">กำลังโหลด…</p>
          : ledger.length === 0 ? <p className="rounded-2xl bg-white/5 p-6 text-center text-neutral-500">ยังไม่มีรายการ</p>
          : (
            <div className="overflow-x-auto rounded-2xl ring-1 ring-white/10">
              <table className="w-full min-w-[640px] text-left text-sm">
                <thead className="bg-white/5 text-xs text-neutral-400">
                  <tr><th className="p-2">เวลา</th><th className="p-2">ผู้ใช้</th><th className="p-2">รายการ</th><th className="p-2 text-right">จำนวนเงิน</th><th className="p-2">วิธี / อ้างอิง</th><th className="p-2">บันทึกโดย</th></tr>
                </thead>
                <tbody className="divide-y divide-white/10">
                  {ledger.map((p) => (
                    <tr key={p.id}>
                      <td className="whitespace-nowrap p-2 text-xs text-neutral-400">{fmtDateTime(p.created_at)}</td>
                      <td className="p-2">{p.user_name ?? '—'}</td>
                      <td className="p-2">{p.kind === 'membership' ? `${PLAN_META[p.tier].name} +${p.days} วัน` : 'เติม Wallet'}{p.note ? <span className="block text-[11px] text-neutral-500">{p.note}</span> : null}</td>
                      <td className="whitespace-nowrap p-2 text-right font-semibold">{baht(p.amount)}</td>
                      <td className="p-2 text-xs">{METHODS[p.method]}{p.reference ? <span className="block text-neutral-500">{p.reference}</span> : null}</td>
                      <td className="p-2 text-xs text-neutral-400">{p.source === 'slip_auto' ? '🤖 อัตโนมัติ (สลิป)' : p.admin_name}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
      </section>

      {/* Slips that did NOT pass automatic verification: the admin can settle these by hand above */}
      {failed.length > 0 && (
        <section>
          <h2 className="mb-1 text-base font-bold">สลิปที่ระบบอัตโนมัติไม่ผ่านล่าสุด</h2>
          <p className="mb-2 text-xs text-neutral-500">ถ้าลูกค้าโอนจริงแต่ไม่ผ่าน ตรวจสลิปกับบัญชีแล้วบันทึกด้วยมือในฟอร์มด้านบนได้</p>
          <ul className="space-y-2">
            {failed.map((f) => (
              <li key={f.id} className="rounded-xl bg-white/5 p-3 text-sm ring-1 ring-white/10">
                <div className="flex items-center justify-between gap-2">
                  <span className="font-semibold">{f.user_name ?? '—'}</span>
                  <span className="shrink-0 rounded-full bg-red-500/20 px-2 py-0.5 text-[11px] text-red-300">{f.result}</span>
                </div>
                <p className="text-[11px] text-neutral-500">
                  {fmtDateTime(f.created_at)}{f.trans_ref ? ` · ref ${f.trans_ref}` : ''}
                  {f.detail?.paid != null ? ` · สลิป ${baht(f.detail.paid)}` : ''}
                  {f.detail?.expected ? ` · ต้องโอน ${f.detail.expected.map(baht).join(' / ')}` : ''}
                  {f.detail?.receiverName ? ` · ผู้รับในสลิป: ${f.detail.receiverName} (${f.detail.receiverBank ?? '?'})` : ''}
                </p>
              </li>
            ))}
          </ul>
        </section>
      )}
    </div>
  )
}
