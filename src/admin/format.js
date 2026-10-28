export const baht = (n) => `${Number(n ?? 0).toLocaleString('en-US')} บาท`
export const fmtDateTime = (v) => new Date(v).toLocaleString('th-TH', { dateStyle: 'medium', timeStyle: 'short' })
export const fmtDate = (v) => new Date(v).toLocaleDateString('th-TH', { dateStyle: 'medium' })
