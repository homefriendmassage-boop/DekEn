import { useState } from 'react'
import { supabase } from '../supabaseClient'
import SupportChat from '../components/SupportChat'

const PRESETS = [
  ['⚠️ ห้ามส่งช่องทางติดต่อ', 'แจ้งเตือน: ห้ามส่งเบอร์โทร/LINE/ไอดีในห้องแชต การทำซ้ำอาจถูกระงับห้องแชต'],
  ['🚫 แจ้งห้องแชตถูกระงับ', 'ห้องแชตของคุณถูกระงับ เพราะตรวจพบการส่งข้อมูลติดต่อ หากไม่เห็นด้วยหรือต้องการชี้แจง พิมพ์ตอบข้อความนี้ได้เลย แอดมินจะพิจารณาเปิดห้องให้หลังตกลงกัน'],
  ['⚠️ ตักเตือนเรื่องผิดนัด', 'แจ้งเตือน: ตรวจพบการผิดนัดลูกค้า กรุณาตอบรับงานเฉพาะที่ไปได้จริง การผิดนัดซ้ำจะมีค่าปรับและถูกบล็อกตามกติกา'],
  ['🖼️ ขอให้แก้รูปโปรไฟล์', 'รูปโปรไฟล์ของคุณยังไม่เรียบร้อย กรุณาแก้ไขรูปและวางโมเสกให้ครอบใบหน้า หากต้องการให้แอดมินช่วย พิมพ์ตอบข้อความนี้ได้'],
  ['💬 ให้ทัก LINE DekEn โดยตรง', 'กรุณาแชตกับแอดมินที่ LINE DekEn ไอดี @deken เพื่อสอบถามหรือส่งข้อมูลเพิ่มเติม (ระบบแชตในแอปไม่อนุญาตให้ส่งช่องทางติดต่อ)'],
  ['📞 ขอให้ติดต่อกลับ', 'ขอให้คุณพิมพ์ตอบข้อความนี้ เพื่อให้แอดมินสอบถามรายละเอียดเพิ่มเติม'],
]

// The admin writes to ONE member (a warning or a notice). A LINE Flex tells him; he answers in "แชทกับแอดมิน". "เปิดแชต" continues the conversation.
export default function Compose({ userId, name, onClose, toast }) {
  const [text, setText] = useState('')
  const [push, setPush] = useState(true)
  const [busy, setBusy] = useState(false)
  const [thread, setThread] = useState(null)

  async function send() {
    setBusy(true)
    const { error } = await supabase.rpc('admin_message_user', { p_user: userId, p_body: text.trim(), p_push: push })
    setBusy(false)
    if (error) return toast(error.message.includes('BAD_MESSAGE') ? 'ข้อความต้องยาว 1–1000 ตัวอักษร' : 'ส่งไม่สำเร็จ')
    toast(push ? 'ส่งแล้ว (แจ้งเตือนทาง LINE)' : 'ส่งแล้ว'); setText(''); await openChat()
  }
  async function openChat() {
    const { data, error } = await supabase.rpc('admin_support_open', { p_user: userId })
    if (error) return toast('เปิดแชตไม่ได้')
    setThread(data)
  }

  if (thread) return <SupportChat threadId={thread} title={name ?? 'สมาชิก'} isAdmin onClose={() => { setThread(null); onClose() }} />
  return (
    <div className="fixed inset-0 z-[60] flex items-end justify-center bg-black/70 sm:items-center sm:p-4" onClick={(e) => { e.stopPropagation(); onClose() }}>
      <div onClick={(e) => e.stopPropagation()} className="max-h-[90vh] w-full max-w-md space-y-3 overflow-y-auto rounded-t-3xl bg-neutral-900 p-5 sm:rounded-3xl">
        <div className="flex items-center justify-between"><h3 className="text-lg font-bold">✉️ ทักแชต: {name ?? 'สมาชิก'}</h3><button onClick={onClose} className="rounded-full bg-white/10 px-3 py-1 text-sm">✕</button></div>
        <p className="text-xs text-neutral-400">ข้อความเข้า "แชทกับแอดมิน" ของสมาชิก เขาตอบกลับได้ในที่เดียวกัน เหมาะกับการตักเตือน แจ้งการถูกระงับ/ปิดห้อง หรือตกลงเพื่อเปิดห้องให้ใหม่</p>
        <div className="flex flex-wrap gap-1.5">{PRESETS.map(([label, body]) => <button key={label} onClick={() => setText(body)} className="rounded-full bg-white/10 px-2.5 py-1 text-xs active:scale-95">{label}</button>)}</div>
        <textarea rows={5} maxLength={1000} value={text} onChange={(e) => setText(e.target.value)} placeholder="พิมพ์ข้อความถึงสมาชิก" className="w-full rounded-xl bg-white/10 px-3 py-2 text-base outline-none ring-1 ring-white/10 focus:ring-line" />
        <label className="flex items-center gap-2 text-sm"><input type="checkbox" checked={push} onChange={(e) => setPush(e.target.checked)} /> แจ้งเตือนทาง LINE (Flex)</label>
        <div className="grid grid-cols-2 gap-2">
          <button onClick={openChat} className="rounded-xl bg-white/10 py-2.5 text-sm">เปิดแชต (อ่านประวัติ)</button>
          <button onClick={send} disabled={!text.trim() || busy} className="rounded-xl bg-line py-2.5 text-sm font-bold text-black disabled:opacity-40">{busy ? '…' : 'ส่งข้อความ'}</button>
        </div>
      </div>
    </div>
  )
}
