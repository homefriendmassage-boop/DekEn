export const baht = (n) => `${Number(n ?? 0).toLocaleString('en-US')} บาท`
export const fmtDateTime = (v) => new Date(v).toLocaleString('th-TH', { dateStyle: 'medium', timeStyle: 'short' })
export const fmtDate = (v) => new Date(v).toLocaleDateString('th-TH', { dateStyle: 'medium' })

// "5 นาทีที่แล้ว" style relative time
export const ago = (v) => {
  const s = Math.max(0, (Date.now() - new Date(v)) / 1000)
  if (s < 60) return 'เมื่อสักครู่'
  if (s < 3600) return `${Math.floor(s / 60)} นาทีที่แล้ว`
  if (s < 86400) return `${Math.floor(s / 3600)} ชม.ที่แล้ว`
  return `${Math.floor(s / 86400)} วันที่แล้ว`
}
