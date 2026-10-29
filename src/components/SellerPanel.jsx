import { useEffect, useState } from 'react'
import { supabase } from '../supabaseClient'
import { useI18n } from '../i18n'
import ShareModal from './ShareModal'

const VIA = { vendor: 'เซลล์ที่มี OA', provider: 'ผู้ให้บริการ', approved: 'เซลล์ที่อนุมัติแล้ว' }

// "My commission": am I a seller, what did the people I invited earn me (bookings 40 %, packages 20 %), and how to share my link.
export default function SellerPanel({ onClose, walletBalance = 0, onTopUp, onChanged }) {
  const { money, fmtDate } = useI18n()
  const [st, setSt] = useState(null)
  const [rep, setRep] = useState(null)
  const [busy, setBusy] = useState(false)
  const [share, setShare] = useState(false)
  const [msg, setMsg] = useState(null)

  const load = async () => {
    const [a, b] = await Promise.all([supabase.rpc('my_seller_status'), supabase.rpc('my_commission_report')])
    setSt(a.data ?? null); setRep(b.data ?? null)
  }
  useEffect(() => { load() }, [])

  async function buy() {
    setBusy(true); setMsg(null)
    const { error } = await supabase.rpc('buy_seller_plan')
    setBusy(false)
    if (error) return setMsg(/INSUFFICIENT/.test(error.message) ? 'ยอด Wallet ไม่พอ กรุณาเติมเงินก่อน' : /ALREADY_SELLER/.test(error.message) ? 'คุณเป็นเซลล์อยู่แล้ว ไม่ต้องชำระ' : 'ทำรายการไม่สำเร็จ')
    setMsg('✓ เป็นเซลล์เรียบร้อย ระบบส่ง Flex แนะนำการใช้งานไปที่ LINE ของคุณแล้ว')
    onChanged?.()
    load()
  }

  const price = st?.price ?? 500
  const short = walletBalance < price
  return (
    <div className="fixed inset-0 z-[55] flex items-end justify-center bg-black/70 sm:items-center sm:p-4" onClick={onClose} role="dialog" aria-modal="true">
      <div onClick={(e) => e.stopPropagation()}
        className="max-h-[92vh] w-full max-w-md space-y-3 overflow-y-auto rounded-t-3xl bg-neutral-900 p-5 pb-[calc(1.25rem+env(safe-area-inset-bottom))] shadow-2xl sm:rounded-3xl">
        <div className="flex items-center justify-between">
          <h2 className="text-lg font-bold">🤝 ส่วนแบ่งของฉัน</h2>
          <button onClick={onClose} className="rounded-full bg-white/10 px-3 py-1 text-sm">✕</button>
        </div>

        <button onClick={() => setShare(true)} className="w-full rounded-xl bg-line py-3 font-bold text-black active:scale-95">🔗 แชร์ลิงก์ชวนเพื่อน</button>

        <ul className="space-y-1 rounded-2xl bg-white/5 p-3 text-xs text-neutral-300">
          <li>• <b>ค่าแพ็กเกจ 20%</b> ของคนที่คุณชวน (ครั้งแรก) เข้าโบนัสทุกครั้งที่เขาจ่ายหรือต่ออายุ</li>
          <li>• <b>ค่าจอง 40%</b> เฉพาะ "เซลล์" ได้ เมื่อลูกค้าที่คุณชวนจองในแอปกลาง หรือจองผ่านลิงก์ของคุณ</li>
        </ul>

        {!st ? <p className="text-center text-sm text-neutral-500">กำลังโหลด…</p> : st.is_seller && st.via !== 'paid' ? (
          <p className="rounded-xl bg-green-500/10 p-3 text-sm text-green-200">✓ คุณเป็นเซลล์อยู่แล้ว ({VIA[st.via] ?? '—'}) ไม่ต้องชำระค่าบริการ</p>
        ) : (
          <div className="space-y-2 rounded-2xl bg-white/5 p-3">
            {st.expired && (
              <p className="rounded-xl bg-red-500/15 p-3 text-xs font-semibold text-red-200">⚠️ แพ็กเกจเซลล์หมดอายุแล้ว ลูกค้าที่จองผ่านลิงก์ของคุณยังจองได้ตามปกติ แต่ช่วงที่ขาดอายุคุณไม่ได้ส่วนแบ่ง 40% (ตกเป็นของแพลตฟอร์มทันที) ต่ออายุเพื่อรับต่อ</p>
            )}
            {st.is_seller
              ? <p className="text-sm text-green-200">✓ คุณเป็นเซลล์ ใช้งานได้ถึง <b>{fmtDate(st.until)}</b></p>
              : <p className="text-sm font-semibold">{st.expired ? 'แพ็กเกจเซลล์หมดอายุแล้ว' : 'อยากรับ 40% ของค่าจอง? สมัครเป็นเซลล์'}</p>}
            <p className="text-[11px] text-neutral-400">ค่าบริการ {money(price)} ต่อ {st.days} วัน หักจาก Wallet แล้วเป็นเซลล์ได้ทันที ไม่ต้องรออนุมัติ · เซลล์แชร์ลิงก์หาลูกค้าได้อย่างเดียว ไม่สามารถเพิ่มน้องเข้าสังกัดได้ · ต่ออายุก่อนหมดได้ วันจะบวกต่อให้</p>
            <p className="text-xs text-neutral-300">Wallet ของคุณ: <b>{money(walletBalance)}</b></p>
            {short ? (
              <button onClick={onTopUp} className="w-full rounded-xl bg-amber-400 py-2.5 text-sm font-bold text-black active:scale-95">เติม Wallet ก่อน</button>
            ) : (
              <button disabled={busy} onClick={buy} className="w-full rounded-xl bg-line py-2.5 text-sm font-bold text-black active:scale-95 disabled:opacity-50">
                {busy ? '…' : st.is_seller ? `ต่ออายุ +${st.days} วัน (${money(price)})` : `สมัครเป็นเซลล์ ${money(price)} / ${st.days} วัน`}
              </button>
            )}
          </div>
        )}
        {msg && <p className="text-center text-xs text-amber-200">{msg}</p>}

        {rep && (
          <>
            <div className="grid grid-cols-2 gap-2 text-center">
              <div className="rounded-xl bg-white/5 p-3"><p className="text-[11px] text-neutral-400">ค่าจอง (40%)</p><p className="text-lg font-bold">{money(rep.booking_total)}</p></div>
              <div className="rounded-xl bg-white/5 p-3"><p className="text-[11px] text-neutral-400">ค่าแพ็กเกจ (20%)</p><p className="text-lg font-bold">{money(rep.package_total)}</p></div>
            </div>
            {rep.missed_count > 0 && (
              <p className="rounded-xl bg-amber-400/10 p-3 text-xs text-amber-200">ที่ผ่านมามี {rep.missed_count} การจองจากลูกค้าที่คุณชวนที่คุณไม่ได้ส่วนแบ่ง (ประมาณ {money(rep.missed_amount)}) เพราะยังไม่ได้เป็นเซลล์หรือแพ็กเกจหมดอายุในขณะนั้น</p>
            )}
            <List title="รายการค่าจองล่าสุด" rows={rep.bookings} fmtDate={fmtDate} money={money} sub={(r) => (r.via === 'link' ? 'จองผ่านลิงก์ของคุณ' : 'ลูกค้าที่คุณชวน')} />
            <List title="รายการค่าแพ็กเกจล่าสุด" rows={rep.packages} fmtDate={fmtDate} money={money} />
          </>
        )}
      </div>
      {share && <ShareModal onClose={() => setShare(false)} />}
    </div>
  )
}

function List({ title, rows, fmtDate, money, sub }) {
  if (!rows?.length) return null
  return (
    <div className="space-y-1">
      <p className="text-sm font-semibold">{title}</p>
      <ul className="space-y-1">
        {rows.map((r, i) => (
          <li key={i} className="flex items-center justify-between rounded-xl bg-white/5 px-3 py-2 text-sm">
            <span className="min-w-0"><b className="block truncate">{r.customer ?? '—'}</b><span className="text-[11px] text-neutral-400">{fmtDate(r.at)}{sub ? ` · ${sub(r)}` : ''}</span></span>
            <span className="shrink-0 font-semibold text-green-300">+{money(r.amount)}</span>
          </li>
        ))}
      </ul>
    </div>
  )
}
