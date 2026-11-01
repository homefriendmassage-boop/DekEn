import { useCallback, useEffect, useState } from 'react'
import { supabase } from '../supabaseClient'

const SPOTS = [['', 'ไม่วางที่จุดใด (อยู่ในรายการ "วิธีใช้งาน" เท่านั้น)'], ['apply', 'หน้าสมัคร (ก่อนเลือกหมวด)'], ['topup', 'หน้าเติมเงิน'], ['book', 'หน้าจองน้อง'], ['withdraw', 'หน้าถอนเงิน'], ['share', 'หน้าแชร์ลิงก์']]
const AUDIENCES = [['customer', 'ลูกค้า'], ['worker', 'น้อง / ผู้ให้บริการ'], ['seller', 'เซลล์'], ['agency', 'สังกัด'], ['all', 'ทั่วไป']]
const EMPTY = { id: null, title: '', url: '', spot: '', audience: 'customer', sort_no: 100, active: true }

// How-to clips: the files are on YouTube (set "Unlisted"); here we only keep the links.
export default function HelpVideos({ toast }) {
  const [rows, setRows] = useState(null)
  const [f, setF] = useState(null)
  const load = useCallback(() => supabase.rpc('admin_help_videos').then(({ data }) => setRows(data ?? [])), [])
  useEffect(() => { load() }, [load])
  const input = 'mt-1 w-full rounded-xl bg-white/10 px-3 py-2 text-base outline-none ring-1 ring-white/10 focus:ring-line'

  async function save() {
    const { error } = await supabase.rpc('admin_help_save', { p_id: f.id, p_title: f.title, p_url: f.url, p_spot: f.spot, p_audience: f.audience, p_sort: Number(f.sort_no) || 100, p_active: f.active })
    if (error) return toast(error.message.includes('check') ? 'ลิงก์ต้องเป็น YouTube (https://youtube.com/… หรือ https://youtu.be/…) และชื่อไม่เกิน 80 ตัวอักษร' : 'บันทึกไม่สำเร็จ')
    toast('บันทึกแล้ว'); setF(null); load()
  }
  async function del(r) {
    if (!window.confirm(`ลบคลิป "${r.title}"?`)) return
    await supabase.rpc('admin_help_delete', { p_id: r.id }); toast('ลบแล้ว'); load()
  }
  const spotName = (s) => SPOTS.find(([k]) => k === (s ?? ''))?.[1]?.split(' (')[0] ?? ''
  if (rows === null) return <p className="py-8 text-center text-neutral-500">กำลังโหลด…</p>
  return (
    <div className="space-y-3 p-3">
      <button onClick={() => setF({ ...EMPTY })} className="rounded-xl bg-line px-4 py-2 font-bold text-black active:scale-95">+ เพิ่มคลิป</button>
      <p className="text-xs text-neutral-400">อัปโหลดที่ YouTube ตั้งเป็น "ไม่แสดงในรายการ" แล้วนำลิงก์มาวาง คลิปที่เลือกจุดไว้จะขึ้นเป็นแถบ "📺" ตรงจุดนั้น ทุกคลิปอยู่ในปุ่ม "📺 วิธีใช้งาน" ที่แถบด้านบนด้วย</p>
      {rows.length === 0 && <p className="rounded-2xl bg-white/5 p-6 text-center text-neutral-500">ยังไม่มีคลิป</p>}
      <ul className="space-y-2">
        {rows.map((r) => (
          <li key={r.id} className={`rounded-2xl bg-white/5 p-3 ring-1 ring-white/10 ${r.active ? '' : 'opacity-50'}`}>
            <p className="font-semibold">{r.title} <span className="text-xs font-normal text-neutral-400">· ลำดับ {r.sort_no}{r.active ? '' : ' · ซ่อน'}</span></p>
            <p className="break-all text-xs text-sky-300">{r.url}</p>
            <p className="text-xs text-neutral-400">จุดวาง: {spotName(r.spot) || '—'} · กลุ่ม: {AUDIENCES.find(([k]) => k === r.audience)?.[1]}</p>
            <div className="mt-2 flex gap-2">
              <button onClick={() => setF({ ...r, spot: r.spot ?? '' })} className="rounded-lg bg-white/10 px-3 py-1 text-xs active:scale-95">แก้ไข</button>
              <button onClick={() => del(r)} className="rounded-lg bg-red-500/20 px-3 py-1 text-xs text-red-300 active:scale-95">ลบ</button>
            </div>
          </li>
        ))}
      </ul>
      {f && (
        <div className="fixed inset-0 z-50 flex items-end justify-center bg-black/70 sm:items-center" onClick={() => setF(null)}>
          <div onClick={(e) => e.stopPropagation()} className="max-h-[90vh] w-full max-w-md space-y-2 overflow-y-auto rounded-t-3xl bg-neutral-900 p-5 sm:rounded-3xl">
            <h3 className="text-lg font-bold">{f.id ? 'แก้ไขคลิป' : 'เพิ่มคลิป'}</h3>
            <label className="block text-sm">ชื่อหัวข้อ<input className={input} value={f.title} maxLength={80} onChange={(e) => setF({ ...f, title: e.target.value })} /></label>
            <label className="block text-sm">ลิงก์ YouTube<input className={input} value={f.url} placeholder="https://youtube.com/..." onChange={(e) => setF({ ...f, url: e.target.value })} /></label>
            <label className="block text-sm">วางที่จุดไหน
              <select className={input} value={f.spot} onChange={(e) => setF({ ...f, spot: e.target.value })}>{SPOTS.map(([k, l]) => <option key={k} value={k} className="text-black">{l}</option>)}</select></label>
            <label className="block text-sm">กลุ่มผู้ใช้ (ในรายการ "วิธีใช้งาน")
              <select className={input} value={f.audience} onChange={(e) => setF({ ...f, audience: e.target.value })}>{AUDIENCES.map(([k, l]) => <option key={k} value={k} className="text-black">{l}</option>)}</select></label>
            <label className="block text-sm">ลำดับ (เลขน้อยขึ้นก่อน)<input type="number" className={input} value={f.sort_no} onChange={(e) => setF({ ...f, sort_no: e.target.value })} /></label>
            <label className="flex items-center gap-2 text-sm"><input type="checkbox" checked={f.active} onChange={(e) => setF({ ...f, active: e.target.checked })} /> แสดงในแอป</label>
            <div className="grid grid-cols-2 gap-2 pt-2">
              <button onClick={save} disabled={!f.title.trim() || !f.url.trim()} className="rounded-xl bg-line py-2 font-bold text-black disabled:opacity-40">บันทึก</button>
              <button onClick={() => setF(null)} className="rounded-xl bg-white/10 py-2">ยกเลิก</button>
            </div>
          </div>
        </div>
      )}
    </div>
  )
}
