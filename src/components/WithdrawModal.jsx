import { useCallback, useEffect, useState } from 'react'
import { supabase } from '../supabaseClient'
import { useI18n } from '../i18n'
import Certificate from './Certificate'

const input = 'mt-1 w-full rounded-xl bg-white/10 px-3 py-2.5 text-base outline-none ring-1 ring-white/10 focus:ring-line'
const baht = (n) => `${Number(n ?? 0).toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 })} บาท`
const ST = { pending: ['รอโอน', 'bg-amber-400/20 text-amber-200'], paid: ['โอนแล้ว', 'bg-green-500/20 text-green-300'], rejected: ['ถูกปฏิเสธ', 'bg-red-500/20 text-red-300'], cancelled: ['ยกเลิก', 'bg-neutral-600/40 text-neutral-300'] }

// Thai national ID: 13 digits, the last one is a check digit (same rule as the database)
export function thaiIdValid(id) {
  if (!/^\d{13}$/.test(id)) return false
  let s = 0
  for (let i = 0; i < 12; i++) s += Number(id[i]) * (13 - i)
  return (11 - (s % 11)) % 10 === Number(id[12])
}
const ERR = {
  NOT_VERIFIED: 'ยังไม่ได้ยืนยันตัวตน', BELOW_MIN: 'ยอดต่ำกว่าขั้นต่ำ หรือหลังหักภาษีและค่าธรรมเนียมแล้วไม่เหลือ', ONCE_A_DAY: 'ถอนได้วันละ 1 ครั้ง',
  INSUFFICIENT_BONUS: 'ยอดในกระเป๋าโบนัสไม่พอ', SUSPENDED: 'บัญชีถูกระงับ', BAD_NAME: 'ชื่อ-นามสกุลไม่ถูกต้อง (ไม่ใส่ตัวเลข)', BAD_ID: 'เลขบัตรประชาชนไม่ถูกต้อง',
  BAD_ADDRESS: 'ที่อยู่สั้นเกินไป', BAD_PROMPTPAY: 'พร้อมเพย์ต้องเป็นเบอร์โทร 10 หลัก หรือเลขบัตร 13 หลัก', ALREADY_VERIFIED: 'ยืนยันตัวตนแล้ว',
}
const errText = (m = '') => Object.entries(ERR).find(([k]) => m.includes(k))?.[1] ?? 'ทำรายการไม่สำเร็จ'

// Cash withdrawal from the Bonus wallet: identity (once) -> request -> the admin transfers by PromptPay -> certificate.
export default function WithdrawModal({ onClose, onChanged }) {
  const { t } = useI18n()
  const [st, setSt] = useState(null)
  const [list, setList] = useState([])
  const [form, setForm] = useState({ name: '', id: '', address: '', promptpay: '' })
  const [amount, setAmount] = useState('')
  const [busy, setBusy] = useState(false)
  const [msg, setMsg] = useState(null)
  const [cert, setCert] = useState(null)

  const load = useCallback(async () => {
    const [a, b] = await Promise.all([supabase.rpc('my_payout_status'), supabase.rpc('my_withdrawals')])
    setSt(a.data ?? null); setList(b.data ?? [])
  }, [])
  useEffect(() => { load() }, [load])
  const set = (k) => (e) => setForm((f) => ({ ...f, [k]: e.target.value }))

  async function submitIdentity(e) {
    e.preventDefault(); setMsg(null)
    const id = form.id.replace(/\D/g, '')
    if (!thaiIdValid(id)) return setMsg('เลขบัตรประชาชนไม่ถูกต้อง')
    setBusy(true)
    const { error } = await supabase.rpc('payout_submit', { p_name: form.name, p_national_id: id, p_address: form.address, p_promptpay: form.promptpay })
    setBusy(false)
    if (error) return setMsg(errText(error.message))
    setForm({ name: '', id: '', address: '', promptpay: '' }); load()
  }
  async function withdraw() {
    setMsg(null)
    const n = Number(amount)
    if (!(n > 0)) return
    if (!window.confirm(`ถอน ${baht(n)} ? หักภาษี ${baht(tax)} และค่าธรรมเนียม ${baht(st.fee)} รับสุทธิ ${baht(net)}`)) return
    setBusy(true)
    const { error } = await supabase.rpc('request_withdrawal', { p_amount: n })
    setBusy(false)
    if (error) return setMsg(errText(error.message))
    setAmount(''); setMsg('ส่งคำขอถอนเงินแล้ว แอดมินจะโอนเข้าพร้อมเพย์ของคุณ'); load(); onChanged?.()
  }
  async function cancel(w) {
    if (!window.confirm('ยกเลิกคำขอถอนเงินนี้? ยอดคืนเข้ากระเป๋าโบนัส')) return
    const { error } = await supabase.rpc('cancel_withdrawal', { p_id: w.id })
    if (error) return setMsg(errText(error.message))
    load(); onChanged?.()
  }
  async function openCert(w) {
    const { data, error } = await supabase.rpc('my_certificate', { p_withdrawal: w.id })
    if (error || !data) return setMsg('เปิดใบหัก ณ ที่จ่ายไม่สำเร็จ')
    setCert(data)
  }

  const n = Number(amount) || 0
  const tax = st ? Math.round(n * Number(st.tax_percent)) / 100 : 0
  const net = st ? n - tax - Number(st.fee) : 0
  const p = st?.profile

  return (
    <div className="fixed inset-0 z-[60] flex items-end justify-center bg-black/70 sm:items-center sm:p-4" onClick={onClose} role="dialog" aria-modal="true">
      <div onClick={(e) => e.stopPropagation()} className="max-h-[92vh] w-full max-w-md space-y-3 overflow-y-auto rounded-t-3xl bg-neutral-900 p-5 pb-[calc(1.25rem+env(safe-area-inset-bottom))] shadow-2xl sm:rounded-3xl">
        <div className="flex items-center justify-between"><h2 className="text-lg font-bold">💸 {t('withdraw')}</h2><button onClick={onClose} className="rounded-full bg-white/10 px-3 py-1 text-sm">✕</button></div>
        {!st ? <p className="py-6 text-center text-neutral-500">{t('loading')}</p> : (
          <>
            <div className="rounded-2xl bg-amber-400/10 p-3 text-center ring-1 ring-amber-400/30">
              <p className="text-xs text-amber-200">🎁 {t('bonusWallet')} (ถอนได้)</p>
              <p className="text-2xl font-extrabold text-amber-300">{baht(st.bonus)}</p>
            </div>

            {(!p || p.status === 'rejected') && (
              <form onSubmit={submitIdentity} className="space-y-3 rounded-2xl bg-white/5 p-3">
                <p className="text-sm font-semibold">ยืนยันตัวตนก่อนถอนครั้งแรก (ทำครั้งเดียว)</p>
                {p?.status === 'rejected' && <p className="rounded-lg bg-red-500/10 p-2 text-xs text-red-300">ข้อมูลก่อนหน้าไม่ผ่าน{p.reject_reason ? `: ${p.reject_reason}` : ''} กรุณาแก้ไขแล้วส่งใหม่</p>}
                <p className="text-[11px] text-neutral-400">ใช้ออกใบหัก ณ ที่จ่ายและโอนเงินเข้าพร้อมเพย์ ข้อมูลบัตรประชาชนและที่อยู่เข้ารหัสเก็บไว้ แอดมินเท่านั้นที่เห็น และต้องเป็นชื่อเดียวกับพร้อมเพย์</p>
                <label className="block text-sm">ชื่อ-นามสกุล (ตามบัตรประชาชน)<input required maxLength={80} value={form.name} onChange={set('name')} className={input} /></label>
                <label className="block text-sm">เลขบัตรประชาชน 13 หลัก<input required inputMode="numeric" maxLength={17} value={form.id} onChange={set('id')} className={input} /></label>
                <label className="block text-sm">ที่อยู่ตามบัตร/ที่ติดต่อได้<textarea required rows={2} maxLength={300} value={form.address} onChange={set('address')} className={input} /></label>
                <label className="block text-sm">พร้อมเพย์ (เบอร์โทร 10 หลัก หรือเลขบัตร)<input required inputMode="numeric" maxLength={17} value={form.promptpay} onChange={set('promptpay')} className={input} /></label>
                <button disabled={busy} className="w-full rounded-xl bg-line py-3 font-bold text-black active:scale-95 disabled:opacity-50">{busy ? '…' : 'ส่งข้อมูลยืนยันตัวตน'}</button>
              </form>
            )}

            {p?.status === 'pending' && (
              <div className="space-y-1 rounded-2xl bg-white/5 p-3 text-sm">
                <p className="font-semibold">⏳ รอแอดมินยืนยันตัวตน</p>
                <p className="text-xs text-neutral-300">ส่งข้อมูลแล้ว ({p.full_name} · บัตรลงท้าย {p.id_last4}) ทักปุ่ม "แชทกับแอดมิน" ในหน้าแรกเพื่อยืนยันตัวตนกับแอดมินได้เลย เมื่อผ่านแล้วจะได้รับแจ้งเตือน</p>
              </div>
            )}

            {p?.status === 'verified' && (
              <div className="space-y-3 rounded-2xl bg-white/5 p-3">
                <p className="text-xs text-green-300">✓ ยืนยันตัวตนแล้ว: {p.full_name} (บัตรลงท้าย {p.id_last4})</p>
                <label className="block text-sm font-semibold">จำนวนที่ต้องการถอน (บาท)
                  <input inputMode="decimal" value={amount} onChange={(e) => setAmount(e.target.value.replace(/[^\d.]/g, ''))} placeholder={`ขั้นต่ำ ${Number(st.min)}`} className={input} />
                </label>
                {n > 0 && (
                  <div className="space-y-1 rounded-xl bg-black/30 p-3 text-sm">
                    <p className="flex justify-between"><span>ยอดถอน</span><b>{baht(n)}</b></p>
                    <p className="flex justify-between text-neutral-300"><span>หักภาษี ณ ที่จ่าย {Number(st.tax_percent)}%</span><span>-{baht(tax)}</span></p>
                    <p className="flex justify-between text-neutral-300"><span>ค่าธรรมเนียมถอน</span><span>-{baht(st.fee)}</span></p>
                    <p className="flex justify-between border-t border-white/10 pt-1 text-base font-bold text-green-300"><span>รับสุทธิ</span><span>{baht(Math.max(0, net))}</span></p>
                  </div>
                )}
                <p className="text-[11px] text-neutral-400">ขั้นต่ำ {baht(st.min)} · ถอนได้วันละ 1 ครั้ง · โอนเข้าพร้อมเพย์ที่ลงทะเบียนไว้ · ได้รับใบหัก ณ ที่จ่ายเมื่อโอนแล้ว</p>
                <button disabled={busy || n < Number(st.min) || net <= 0 || st.today_used} onClick={withdraw} className="w-full rounded-xl bg-amber-400 py-3 font-bold text-black active:scale-95 disabled:bg-neutral-700 disabled:text-neutral-400">
                  {st.today_used ? 'วันนี้ถอนไปแล้ว' : busy ? '…' : 'ขอถอนเงิน'}
                </button>
              </div>
            )}

            {msg && <p className="rounded-xl bg-white/5 p-3 text-center text-sm text-amber-200">{msg}</p>}

            {list.length > 0 && (
              <div className="space-y-2">
                <p className="text-sm font-semibold">ประวัติการถอน</p>
                <ul className="space-y-2">
                  {list.map((w) => (
                    <li key={w.id} className="space-y-1 rounded-xl bg-white/5 p-3 text-sm">
                      <div className="flex items-center justify-between"><b>{baht(w.gross)}</b><span className={`rounded-full px-2 py-0.5 text-[11px] font-semibold ${ST[w.status][1]}`}>{ST[w.status][0]}</span></div>
                      <p className="text-xs text-neutral-400">รับสุทธิ {baht(w.net)} (ภาษี {baht(w.tax_amount)} · ค่าธรรมเนียม {baht(w.fee)}) · {new Date(w.created_at).toLocaleDateString('th-TH')}</p>
                      {w.reject_reason && <p className="text-xs text-red-300">เหตุผล: {w.reject_reason}</p>}
                      <div className="flex gap-2">
                        {w.status === 'pending' && <button onClick={() => cancel(w)} className="rounded-lg bg-white/10 px-3 py-1 text-xs active:scale-95">ยกเลิกคำขอ</button>}
                        {w.has_certificate && <button onClick={() => openCert(w)} className="rounded-lg bg-green-500/80 px-3 py-1 text-xs font-bold text-black active:scale-95">📄 ใบหัก ณ ที่จ่าย</button>}
                      </div>
                    </li>
                  ))}
                </ul>
              </div>
            )}
          </>
        )}
        <button onClick={onClose} className="w-full rounded-xl bg-white/10 py-3 font-semibold active:scale-95">{t('close')}</button>
      </div>
      {cert && <Certificate cert={cert} onClose={() => setCert(null)} />}
    </div>
  )
}
