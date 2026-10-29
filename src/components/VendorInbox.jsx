import Support from '../admin/Support'

// A seller's staff answer the customers of THEIR seller (support chats). Opened from the seller's own LIFF app.
export default function VendorInbox({ vendor, openThread, onClose, onChanged }) {
  return (
    <div className="fixed inset-0 z-50 flex items-end justify-center bg-black/70 sm:items-center sm:p-4" onClick={onClose} role="dialog" aria-modal="true">
      <div onClick={(e) => e.stopPropagation()} className="max-h-[92vh] w-full max-w-lg space-y-3 overflow-y-auto rounded-t-3xl bg-neutral-900 p-5 pb-[calc(1.25rem+env(safe-area-inset-bottom))] shadow-2xl sm:rounded-3xl">
        <div className="flex items-center justify-between">
          <h2 className="text-xl font-bold">💬 กล่องข้อความลูกค้า</h2>
          <button onClick={onClose} className="rounded-full bg-white/10 px-3 py-1 text-sm active:scale-95">✕</button>
        </div>
        <p className="text-xs text-neutral-400">ข้อความจากลูกค้าของคุณที่กดแชตหาแอดมิน เมื่อมีข้อความใหม่ ระบบส่งแจ้งเตือนทาง LINE OA ของคุณ</p>
        <Support vendor={vendor} openThread={openThread} onChanged={onChanged} />
      </div>
    </div>
  )
}
