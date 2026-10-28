import { createContext, useCallback, useContext, useMemo, useState } from 'react'

// Lightweight i18n (no library). To add a language: add an entry to `dict` and LANGS.
export const LANGS = { th: 'ไทย', en: 'EN', zh: '中文' }
const STORAGE_KEY = 'lang'

const dict = {
  th: {
    hello: 'สวัสดี, {name}',
    discover: 'ค้นหา',
    blurNotice: '🔒 ภาพถูกเบลอ อัปเกรดเป็น VIP เพื่อดูโปรไฟล์เต็ม',
    noWorkers: 'ขณะนี้ยังไม่มีผู้ให้บริการที่พร้อม',
    vipOnly: '🔒 เฉพาะ VIP',
    topRank: '🔥 อันดับต้น',
    online: 'ออนไลน์',
    offline: 'ออฟไลน์',
    from: 'เริ่มต้น',
    book: 'จอง',
    unavailable: 'ไม่ว่าง',
    currency: 'บาท',
    bookTitle: 'จอง {name}',
    reviewPayment: 'ตรวจสอบวิธีชำระเงินก่อนยืนยัน',
    platformFee: 'ค่าธรรมเนียมแพลตฟอร์ม (หักจาก Wallet)',
    payWorker: 'จ่ายตรงให้ผู้ให้บริการ (เงินสด เมื่อพบกัน)',
    walletBalance: 'ยอดเงินใน Wallet ของคุณ',
    feeNote: 'ค่าธรรมเนียม {fee} ใช้เพื่อยืนยันการจอง ส่วนค่าบริการจ่ายเป็นเงินสดให้ {name} โดยตรง ไม่ผ่านแอปนี้',
    lowBalance: 'ยอด Wallet ต่ำกว่า {fee} กรุณาเติมเงินก่อน',
    cancel: 'ยกเลิก',
    confirm: 'ยืนยันการจอง',
    booking: 'กำลังจอง…',
    errInsufficient: 'ยอดเงินใน Wallet ไม่พอ กรุณาเติมเงินแล้วลองอีกครั้ง',
    errUnavailable: 'ผู้ให้บริการเพิ่งออฟไลน์ กรุณาเลือกคนอื่น',
    errGeneric: 'เกิดข้อผิดพลาด กรุณาลองอีกครั้ง',
    booked: 'จองสำเร็จ! แจ้งผู้ให้บริการแล้ว',
    startFail: 'เริ่มต้นแอปไม่สำเร็จ',
    retry: 'ลองอีกครั้ง',
    svc: { massage: 'นวด', singer: 'นักร้อง', mc: 'พิธีกร', spa: 'สปา', dancer: 'นักเต้น' },
  },
  en: {
    hello: 'Hello, {name}',
    discover: 'Discover',
    blurNotice: '🔒 Photos are blurred. Upgrade to VIP to view full profiles.',
    noWorkers: 'No one is available right now.',
    vipOnly: '🔒 VIP only',
    topRank: '🔥 Top Rank',
    online: 'Online',
    offline: 'Offline',
    from: 'From',
    book: 'Book',
    unavailable: 'Unavailable',
    currency: 'THB',
    bookTitle: 'Book {name}',
    reviewPayment: 'Review how payment works before confirming.',
    platformFee: 'Platform fee (deducted from Wallet)',
    payWorker: 'Pay directly to worker (cash, on meeting)',
    walletBalance: 'Your wallet balance',
    feeNote: 'The {fee} fee secures your booking. The service fee is paid in cash directly to {name} — never through this app.',
    lowBalance: 'Wallet balance is below {fee}. Please top up first.',
    cancel: 'Cancel',
    confirm: 'Confirm Booking',
    booking: 'Booking…',
    errInsufficient: 'Your wallet balance is too low. Please top up and try again.',
    errUnavailable: 'This worker just went offline. Please pick someone else.',
    errGeneric: 'Something went wrong. Please try again.',
    booked: 'Booking confirmed! The worker has been notified.',
    startFail: "Couldn't start the app",
    retry: 'Retry',
    svc: { massage: 'Massage', singer: 'Singer', mc: 'MC', spa: 'Spa', dancer: 'Dancer' },
  },
  zh: {
    hello: '你好，{name}',
    discover: '发现',
    blurNotice: '🔒 照片已模糊。升级 VIP 即可查看完整资料。',
    noWorkers: '目前没有可预约的人员。',
    vipOnly: '🔒 仅限 VIP',
    topRank: '🔥 置顶推荐',
    online: '在线',
    offline: '离线',
    from: '起价',
    book: '预约',
    unavailable: '不可预约',
    currency: '泰铢',
    bookTitle: '预约 {name}',
    reviewPayment: '确认前请先了解付款方式。',
    platformFee: '平台费（从钱包扣除）',
    payWorker: '直接支付给服务人员（见面时现金支付）',
    walletBalance: '您的钱包余额',
    feeNote: '{fee} 平台费用于确认预约。服务费将以现金直接支付给 {name}，不经过本应用。',
    lowBalance: '钱包余额低于 {fee}，请先充值。',
    cancel: '取消',
    confirm: '确认预约',
    booking: '预约中…',
    errInsufficient: '钱包余额不足，请充值后重试。',
    errUnavailable: '该人员刚刚下线，请选择其他人。',
    errGeneric: '出错了，请重试。',
    booked: '预约成功！已通知服务人员。',
    startFail: '应用启动失败',
    retry: '重试',
    svc: { massage: '按摩', singer: '歌手', mc: '主持', spa: '水疗', dancer: '舞者' },
  },
}

// Saved choice > phone/LINE language > Thai.
function detectLang() {
  try {
    const saved = localStorage.getItem(STORAGE_KEY)
    if (saved && dict[saved]) return saved
  } catch { /* storage blocked */ }
  for (const l of navigator.languages ?? [navigator.language]) {
    const code = String(l).toLowerCase().slice(0, 2)
    if (dict[code]) return code
  }
  return 'th'
}

const I18nContext = createContext(null)

export function I18nProvider({ children }) {
  const [lang, setLangState] = useState(detectLang)

  const setLang = useCallback((l) => {
    setLangState(l)
    try { localStorage.setItem(STORAGE_KEY, l) } catch { /* ignore */ }
    document.documentElement.lang = l
  }, [])

  const value = useMemo(() => {
    const d = dict[lang]
    // t('key', { name }) -> replaces {name}
    const t = (key, vars = {}) =>
      String(d[key] ?? dict.en[key] ?? key).replace(/\{(\w+)\}/g, (_, k) => vars[k] ?? '')
    const money = (n) => `${Number(n).toLocaleString('en-US')} ${d.currency}`
    const service = (s) => d.svc[s] ?? s // unknown types fall back to the raw value
    return { lang, setLang, t, money, service }
  }, [lang, setLang])

  return <I18nContext.Provider value={value}>{children}</I18nContext.Provider>
}

export const useI18n = () => useContext(I18nContext)

export function LangSwitcher() {
  const { lang, setLang } = useI18n()
  return (
    <div className="flex overflow-hidden rounded-full bg-white/10 text-[11px] font-semibold">
      {Object.entries(LANGS).map(([code, label]) => (
        <button
          key={code}
          onClick={() => setLang(code)}
          className={`px-2 py-1 ${lang === code ? 'bg-line text-black' : 'text-neutral-300'}`}
        >
          {label}
        </button>
      ))}
    </div>
  )
}
