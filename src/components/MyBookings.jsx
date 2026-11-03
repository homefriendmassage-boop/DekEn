import { useCallback, useEffect, useState } from 'react'
import { supabase } from '../supabaseClient'
import { useI18n } from '../i18n'
import { fmtWhen, mapsLink, minutesLeft } from '../lib/booking'
import { cancelText, useJobRules } from '../lib/jobRules'
import { CancelSheet, ProblemSheet, ReschedSheet, answerResched } from './JobSheets'

const BADGE = { pending: 'bg-amber-400/20 text-amber-200', matched: 'bg-green-500/20 text-green-300', completed: 'bg-sky-500/20 text-sky-200', cancelled: 'bg-neutral-600/40 text-neutral-300' }

// The customer's bookings: status, countdown while the provider has not answered, and the provider's contact once she accepted.
export default function MyBookings({ onClose, highlightId }) {
  const { t, money, lang } = useI18n()
  const [rows, setRows] = useState(null)
  const [, tick] = useState(0)
  const rules = useJobRules()
  const [sheet, setSheet] = useState(null)      // { type: 'cancel' | 'problem' | 'resched', job }
  const [msg, setMsg] = useState(null)
  const flash = (m) => { setMsg(m); setTimeout(() => setMsg(null), 4000) }

  const load = useCallback(async () => {
    const { data } = await supabase.rpc('my_customer_jobs')
    setRows(data ?? [])
  }, [])
  useEffect(() => { load() }, [load])
  useEffect(() => {          // status changes (accepted / declined / expired / arrived) arrive live
    const ch = supabase.channel('my-bookings').on('postgres_changes', { event: '*', schema: 'public', table: 'jobs' }, load).subscribe()
    const id = setInterval(() => tick((n) => n + 1), 30000)
    return () => { supabase.removeChannel(ch); clearInterval(id) }
  }, [load])

  async function cancel(j) {
    if (!j.rules_v2) {            // a booking made before the new rules: the old behaviour
      if (!window.confirm(t('bkCancelConfirm'))) return
      await supabase.from('jobs').update({ status: 'cancelled' }).eq('id', j.id)
      return load()
    }
    setSheet({ type: 'cancel', job: j })
  }
  async function done(j) {
    if (!window.confirm('ยืนยันว่าพบกันแล้ว/งานเสร็จสิ้น?')) return
    const { error } = await supabase.rpc('customer_confirm_done', { p_job: j.id })
    flash(error ? 'ทำรายการไม่สำเร็จ' : 'ขอบคุณที่ใช้บริการ'); load()
  }
  async function objectNoshow(j) {
    const note = window.prompt('คุณไม่ได้ผิดนัด? ใส่รายละเอียดสั้น ๆ (ห้ามใส่เบอร์/LINE) แอดมินจะตรวจสอบ', '')
    if (note === null) return
    const { error } = await supabase.rpc('customer_object_noshow', { p_job: j.id, p_note: note })
    flash(error ? 'ทำรายการไม่สำเร็จ' : 'ส่งให้แอดมินตรวจสอบแล้ว'); load()
  }

  return (
    <div className="fixed inset-0 z-50 flex items-end justify-center bg-black/70 sm:items-center sm:p-4" onClick={onClose} role="dialog" aria-modal="true">
      <div onClick={(e) => e.stopPropagation()} className="max-h-[92vh] w-full max-w-md space-y-3 overflow-y-auto rounded-t-3xl bg-neutral-900 p-5 pb-[calc(1.25rem+env(safe-area-inset-bottom))] shadow-2xl sm:rounded-3xl">
        <div className="mx-auto h-1.5 w-10 rounded-full bg-white/20 sm:hidden" />
        <h2 className="text-xl font-bold">📅 {t('myBookings')}</h2>
        {msg && <p className="rounded-xl bg-white/10 p-2 text-center text-sm">{msg}</p>}
        {rows === null ? <p className="py-8 text-center text-neutral-500">{t('loading')}</p> : rows.length === 0 ? (
          <p className="rounded-2xl bg-white/5 p-6 text-center text-sm text-neutral-500">{t('bkNone')}</p>
        ) : (
          <ul className="space-y-3">
            {rows.map((j) => (
              <li key={j.id} className={`space-y-2 rounded-2xl p-3 ring-1 ${j.id === highlightId ? 'bg-pink-500/10 ring-pink-400/60' : 'bg-white/5 ring-white/10'}`}>
                <div className="flex items-center gap-3">
                  <div className="h-12 w-10 shrink-0 overflow-hidden rounded-lg bg-neutral-800">{j.worker_image && <img src={j.worker_image} alt="" className="h-full w-full object-cover" />}</div>
                  <div className="min-w-0 flex-1">
                    <p className="truncate font-bold">{j.worker_name}</p>
                    <p className="text-xs text-neutral-400">{fmtWhen(j.scheduled_at, lang)}</p>
                  </div>
                  <span className={`shrink-0 rounded-full px-2 py-0.5 text-[11px] font-semibold ${BADGE[j.status]}`}>{t(`bkStatus_${j.status}`)}</span>
                </div>
                <p className="text-xs text-neutral-300">{t('bkRateLine', { rate: j.rate_label ? t(`rate_${j.rate_label}`) === `rate_${j.rate_label}` ? j.rate_label : t(`rate_${j.rate_label}`) : '', price: money(Number(j.service_price) + Number(j.fee ?? 500)), cash: money(j.service_price) })}</p>
                {j.place_note && <p className="text-xs text-neutral-400">📍 {j.place_note}</p>}
                {j.travel_mode === 'customer_goes' && j.status === 'pending' && <p className="text-xs text-sky-300">{t('travelCustPending')}</p>}

                {j.status === 'pending' && (
                  <>
                    <p className="rounded-lg bg-amber-400/10 p-2 text-xs text-amber-200">⏳ {t('bkWaiting', { min: minutesLeft(j.expires_at) })}</p>
                    <button onClick={() => cancel(j)} className="w-full rounded-xl bg-white/10 py-2 text-sm font-semibold active:scale-95">{t('bkCancel')}</button>
                  </>
                )}
                {(j.status === 'matched' || j.status === 'completed') && (
                  <div className="space-y-1 rounded-xl bg-green-500/10 p-3 text-sm">
                    <p className="text-xs font-semibold text-green-300">{t('bkContactTitle')}</p>
                    {j.worker_phone && <a href={`tel:${j.worker_phone}`} className="block font-bold text-green-200 underline">📞 {j.worker_phone}</a>}
                    {j.worker_line_id && <p>LINE: <b>{j.worker_line_id}</b></p>}
                    {!j.worker_phone && !j.worker_line_id && <p className="text-xs text-neutral-400">{t('bkNoContact')}</p>}
                    {j.worker_place && (
                      <p className="text-sm">🚶 {t('workerPlaceLabel')}: <b>{j.worker_place}</b>{j.worker_place_url && <> · <a href={j.worker_place_url} target="_blank" rel="noreferrer" className="font-semibold text-green-200 underline">🗺️ {t('jobOpenMap')}</a></>}</p>
                    )}
                    {j.arrived_at && <p className="text-xs font-semibold text-green-300">📍 {t('bkArrived')}</p>}
                    <p className="text-[11px] text-neutral-400">{t('bkPayCash', { cash: money(j.service_price) })}</p>
                  </div>
                )}
                {j.status === 'matched' && j.rules_v2 && (() => {
                  const start = j.scheduled_at ? new Date(j.scheduled_at).getTime() : 0
                  const canResched = !j.resched_status && !j.dispute_open && start && Date.now() <= start - Number(rules.resched_notice_hours) * 3600e3
                  const canReport = !j.dispute_open && start && Date.now() >= start && Date.now() <= start + Number(rules.autocomplete_hours) * 3600e3
                  const canDone = !j.dispute_open && start && Date.now() >= start - 30 * 60000
                  return (
                    <div className="space-y-2">
                      {j.dispute_open && <p className="rounded-lg bg-amber-400/10 p-2 text-xs font-semibold text-amber-200">⚖️ เรื่องนี้รอแอดมินตรวจสอบ (พักเงินไว้ จะแจ้งผลทาง LINE)</p>}
                      {j.customer_noshow_at && !j.dispute_open && new Date(j.objection_until) > new Date() && (
                        <div className="space-y-1 rounded-lg bg-red-500/10 p-2 text-xs text-red-200">
                          <p>น้องแจ้งว่าคุณไม่มาตามนัด ถ้าไม่จริง กดคัดค้านภายใน {fmtWhen(j.objection_until, lang)} มิฉะนั้นค่าจองไม่คืน</p>
                          <button onClick={() => objectNoshow(j)} className="w-full rounded-lg bg-red-500 py-1.5 font-bold text-white active:scale-95">ไม่จริง ขอให้แอดมินตรวจสอบ</button>
                        </div>
                      )}
                      {j.resched_status === 'pending' && j.resched_by === 'worker' && (
                        <div className="space-y-1 rounded-lg bg-sky-500/10 p-2 text-xs text-sky-100">
                          <p>🔁 น้องขอเลื่อนนัดเป็น <b>{fmtWhen(j.resched_to, lang)}</b></p>
                          <p className="text-amber-200">ถ้ารับ งานนี้ถือว่าเสร็จสิ้น ค่าจองไม่คืน และนัดใหม่อยู่นอกการคุ้มครองของแพลตฟอร์ม</p>
                          <div className="grid grid-cols-2 gap-2">
                            <button onClick={async () => { if (await answerResched(j, true, 'customer', flash)) load() }} className="rounded-lg bg-line py-1.5 font-bold text-black active:scale-95">รับเลื่อนนัด</button>
                            <button onClick={async () => { if (await answerResched(j, false, 'customer', flash)) load() }} className="rounded-lg bg-white/10 py-1.5 active:scale-95">ไม่รับ</button>
                          </div>
                        </div>
                      )}
                      {j.resched_status === 'pending' && j.resched_by === 'customer' && <p className="rounded-lg bg-sky-500/10 p-2 text-xs text-sky-100">🔁 คุณขอเลื่อนเป็น {fmtWhen(j.resched_to, lang)} รอน้องตอบ</p>}
                      {j.resched_status === 'declined' && <p className="text-[11px] text-neutral-400">คำขอเลื่อนนัดถูกปฏิเสธ นัดเดิมยังอยู่</p>}
                      <div className="grid grid-cols-2 gap-2">
                        {canDone && <button onClick={() => done(j)} className="rounded-lg bg-line py-2 text-xs font-bold text-black active:scale-95">✓ เจอน้องแล้ว/งานเสร็จ</button>}
                        {canResched && <button onClick={() => setSheet({ type: 'resched', job: j })} className="rounded-lg bg-white/10 py-2 text-xs font-semibold active:scale-95">🔁 ขอเลื่อนนัด</button>}
                        {canReport && <button onClick={() => setSheet({ type: 'problem', job: j })} className="rounded-lg bg-amber-400/20 py-2 text-xs font-semibold text-amber-200 active:scale-95">⚠️ แจ้งปัญหา</button>}
                        {!j.dispute_open && <button onClick={() => cancel(j)} className="rounded-lg bg-white/10 py-2 text-xs font-semibold active:scale-95">ยกเลิกนัด</button>}
                      </div>
                    </div>
                  )
                })()}
                {j.status === 'cancelled' && <p className="rounded-lg bg-white/5 p-2 text-xs text-neutral-300">{j.rules_v2 ? cancelText(j, 'customer') : t(`bkCancel_${j.cancel_reason ?? 'admin'}`)}</p>}
              </li>
            ))}
          </ul>
        )}
        <button onClick={onClose} className="w-full rounded-xl bg-white/10 py-3 font-semibold active:scale-95">{t('close')}</button>
      </div>
      {sheet?.type === 'cancel' && <CancelSheet job={sheet.job} flash={flash} onClose={() => setSheet(null)} onDone={() => { setSheet(null); load() }} />}
      {sheet?.type === 'problem' && <ProblemSheet job={sheet.job} flash={flash} onClose={() => setSheet(null)} onDone={() => { setSheet(null); load() }} />}
      {sheet?.type === 'resched' && <ReschedSheet job={sheet.job} role="customer" flash={flash} onClose={() => setSheet(null)} onDone={() => { setSheet(null); load() }} />}
    </div>
  )
}
