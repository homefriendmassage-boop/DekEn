// Withholding-tax certificate (ใบหัก ณ ที่จ่าย) for one withdrawal: on screen and printable (window.print() / save as PDF).
const baht = (n) => Number(n ?? 0).toLocaleString('th-TH', { minimumFractionDigits: 2, maximumFractionDigits: 2 })
const day = (v) => new Date(v).toLocaleDateString('th-TH', { dateStyle: 'long', timeZone: 'Asia/Bangkok' })

export default function Certificate({ cert, adminView = false, onClose }) {
  const fmtId = (id) => (id && id.length === 13 ? `${id[0]}-${id.slice(1, 5)}-${id.slice(5, 10)}-${id.slice(10, 12)}-${id[12]}` : id ?? '')
  return (
    <div className="fixed inset-0 z-[85] overflow-y-auto bg-black/80 p-3 print:static print:bg-white print:p-0" onClick={onClose}>
      <div onClick={(e) => e.stopPropagation()} className="mx-auto max-w-lg space-y-3">
        <div className="cert-print rounded-xl bg-white p-5 text-[13px] leading-relaxed text-black shadow-xl">
          <h2 className="text-center text-base font-bold">หนังสือรับรองการหักภาษี ณ ที่จ่าย</h2>
          <p className="text-center text-xs text-neutral-600">เลขที่ {cert.cert_no} · วันที่จ่าย {day(cert.paid_at)}</p>

          <div className="mt-3 space-y-1 rounded-lg border border-neutral-300 p-3">
            <p className="font-bold">ผู้มีหน้าที่หักภาษี ณ ที่จ่าย (ผู้จ่ายเงิน)</p>
            <p>ชื่อ: {cert.payer.name}</p>
            {cert.payer.tax_id && <p>เลขประจำตัวผู้เสียภาษี: {cert.payer.tax_id}</p>}
            {cert.payer.address && <p>ที่อยู่: {cert.payer.address}</p>}
          </div>
          <div className="mt-2 space-y-1 rounded-lg border border-neutral-300 p-3">
            <p className="font-bold">ผู้ถูกหักภาษี ณ ที่จ่าย (ผู้รับเงิน)</p>
            <p>ชื่อ: {cert.payee.name}</p>
            <p>เลขประจำตัวประชาชน: {fmtId(cert.payee.national_id)}</p>
            <p>ที่อยู่: {cert.payee.address}</p>
          </div>

          <table className="mt-2 w-full border-collapse text-left text-[12px]">
            <thead><tr className="bg-neutral-100"><th className="border border-neutral-300 p-1.5">ประเภทเงินได้</th><th className="border border-neutral-300 p-1.5 text-right">จำนวนเงินที่จ่าย</th><th className="border border-neutral-300 p-1.5 text-right">อัตรา</th><th className="border border-neutral-300 p-1.5 text-right">ภาษีที่หัก</th></tr></thead>
            <tbody><tr>
              <td className="border border-neutral-300 p-1.5">{cert.income_type}</td>
              <td className="border border-neutral-300 p-1.5 text-right">{baht(cert.amount)}</td>
              <td className="border border-neutral-300 p-1.5 text-right">{Number(cert.tax_percent)}%</td>
              <td className="border border-neutral-300 p-1.5 text-right font-bold">{baht(cert.tax_amount)}</td>
            </tr></tbody>
          </table>
          <p className="mt-2 text-xs text-neutral-600">ออกโดยระบบ DekEn ตามรายการถอนเงินที่โอนแล้ว</p>
        </div>
        {adminView && <p className="rounded-lg bg-amber-100 p-2 text-[11px] text-amber-900 print:hidden">หมายเหตุสำหรับแอดมิน: รูปแบบเอกสารและอัตราหักภาษีนี้ควรให้ผู้ทำบัญชีตรวจยืนยันก่อนใช้จริง</p>}
        <div className="grid grid-cols-2 gap-2 print:hidden">
          <button onClick={() => window.print()} className="rounded-xl bg-line py-3 font-bold text-black active:scale-95">🖨️ พิมพ์ / บันทึก PDF</button>
          <button onClick={onClose} className="rounded-xl bg-white/15 py-3 font-semibold text-white active:scale-95">ปิด</button>
        </div>
      </div>
    </div>
  )
}
