import { useCallback, useEffect, useState } from 'react'
import { supabase } from '../supabaseClient'

const baht = (n) => `${Number(n ?? 0).toLocaleString('en-US')} บาท`
const STAGE = ['', 'ส่งขอยืนยันแล้ว (30 วัน)', 'เตือนสุดท้ายแล้ว (45 วัน)', 'ซ่อนแล้ว (60 วัน)']

// Providers who have gone quiet: 30 d confirm Flex · 45 d last warning · 60 d hidden + chat closed · 90 d profile deleted (+ the optional balance forfeiture).
export default function Inactive({ toast }) {
  const [data, setData] = useState(null)
  const load = useCallback(async () => { const { data: d } = await supabase.rpc('admin_inactive_list'); setData(d ?? { rows: [] }) }, [])
  useEffect(() => { load() }, [load])

  async function reset(r) { await supabase.rpc('admin_alive_reset', { p_user: r.user_id }); toast('ต่ออายุให้แล้ว เริ่มนับใหม่'); load() }
  async function exempt(r) { await supabase.rpc('admin_alive_exempt', { p_user: r.user_id, p_on: !r.exempt }); toast(r.exempt ? 'ยกเลิกการยกเว้น' : 'ยกเว้นแล้ว (ไม่ถูกซ่อน/ลบ)'); load() }
  async function toggleForfeit() {
    const on = !data.forfeit
    const msg = on
      ? 'เปิดการยกเลิกยอดเงิน: เมื่อโปรไฟล์ถูกลบเพราะไม่ใช้งานครบ 90 วัน ยอด Wallet และโบนัสทั้งหมดของบัญชีนั้นจะเป็น 0 และเป็นรายได้แพลตฟอร์ม\n\nควรให้ทนายหรือผู้ทำบัญชีดู และต้องมีข้อความนี้ในข้อตกลงการใช้งานที่ผู้ใช้กดยอมรับ ยืนยันเปิด?'
      : 'ปิดการยกเลิกยอดเงิน (ยอดเงินจะคงอยู่แม้โปรไฟล์ถูกลบ)?'
    if (!window.confirm(msg)) return
    const { error } = await supabase.rpc('admin_set_inactive_forfeit', { p_on: on })
    if (error) return toast('ทำรายการไม่สำเร็จ')
    toast(on ? 'เปิดการยกเลิกยอดเงินแล้ว' : 'ปิดแล้ว'); load()
  }

  if (data === null) return <p className="py-10 text-center text-neutral-500">กำลังโหลด…</p>
  return (
    <div className="space-y-4">
      <p className="text-xs text-neutral-400">นับจากวันที่น้องไม่มีความเคลื่อนไหว (เปิดแอป, เปิดออนไลน์, ตอบแชต, รับ/จบงาน) 30 วัน = ส่ง Flex ขอยืนยัน · 45 วัน = เตือนสุดท้าย · 60 วัน = ซ่อนจากหน้าลูกค้าและปิดแชต/การจอง (ส่ง Flex แจ้ง) · 90 วัน = ลบโปรไฟล์และรูปถาวร ประวัติเงินและการจองยังเก็บไว้ น้องกลับมาเปิดแอปเมื่อไรก็นับใหม่และโปรไฟล์กลับมาแสดงทันที</p>

      <section className={`space-y-2 rounded-2xl p-3 ring-1 ${data.forfeit ? 'bg-red-500/10 ring-red-400/40' : 'bg-white/5 ring-white/10'}`}>
        <p className="text-sm font-semibold">💰 ยกเลิกยอดเงินเมื่อลบโปรไฟล์ (90 วัน): <b className={data.forfeit ? 'text-red-300' : 'text-neutral-300'}>{data.forfeit ? 'เปิดอยู่' : 'ปิดอยู่'}</b></p>
        <p className="text-xs text-neutral-400">เปิดแล้ว ยอด Wallet และโบนัสของบัญชีที่ถูกลบจะเป็น 0 ทั้งหมดและนับเป็นรายได้แพลตฟอร์ม (ยกเลิกยอดแล้วทั้งหมด {baht(data.forfeited_total)}) การริบเงินผู้ใช้มีความเสี่ยงทางกฎหมาย ควรให้ทนาย/ผู้ทำบัญชีตรวจ และใส่ในข้อตกลงที่ผู้ใช้ยอมรับก่อนเปิด</p>
        <button onClick={toggleForfeit} className={`rounded-xl px-4 py-2 text-sm font-bold active:scale-95 ${data.forfeit ? 'bg-white/10' : 'bg-red-500/80'}`}>{data.forfeit ? 'ปิด' : 'เปิด'}</button>
      </section>

      {data.rows.length === 0 ? <p className="rounded-2xl bg-white/5 p-6 text-center text-neutral-500">ยังไม่มีน้องที่ใกล้ถูกซ่อน/ลบ</p> : (
        <ul className="grid gap-3 md:grid-cols-2">
          {data.rows.map((r) => (
            <li key={r.user_id} className="space-y-1.5 rounded-2xl bg-white/5 p-3 ring-1 ring-white/10">
              <div className="flex items-center justify-between gap-2">
                <p className="truncate font-bold">{r.display_name}</p>
                <span className="shrink-0 rounded-full bg-white/10 px-2 py-0.5 text-[11px]">เงียบมา {r.days} วัน</span>
              </div>
              <p className={`text-xs ${r.hidden ? 'text-red-300' : 'text-amber-200'}`}>{r.exempt ? '🛡️ ยกเว้น' : STAGE[r.stage] || 'ใกล้ครบ 30 วัน'}</p>
              <p className="text-[11px] text-neutral-500">Wallet {baht(r.wallet_balance)} · โบนัส {baht(r.bonus_balance)}</p>
              <div className="flex gap-2 pt-1">
                <button onClick={() => reset(r)} className="rounded-lg bg-line px-3 py-1 text-xs font-bold text-black active:scale-95">ต่ออายุให้ (นับใหม่)</button>
                <button onClick={() => exempt(r)} className="rounded-lg bg-white/10 px-3 py-1 text-xs active:scale-95">{r.exempt ? 'ยกเลิกยกเว้น' : 'ยกเว้น'}</button>
              </div>
            </li>
          ))}
        </ul>
      )}
    </div>
  )
}
