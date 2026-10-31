import { useState } from 'react'
import liff from '@line/liff'
import { useI18n } from '../i18n'
import { canShareFlex } from '../lib/flex'
import { USE_MOCK_LIFF } from '../config'

/**
 * One place for "a link somebody must open": copy it, send it as a LINE Flex card, or show a QR code to scan (with a download link).
 * Props: title, intro, link, flex (a Flex message object for liff.shareTargetPicker, optional), onClose
 */
export default function LinkSheet({ title, intro, link, flex = null, onClose }) {
  const { t } = useI18n()
  const [qr, setQr] = useState(null)
  const [copied, setCopied] = useState(false)
  const [note, setNote] = useState(null)

  async function copy() {
    try { await navigator.clipboard.writeText(link); setCopied(true); setTimeout(() => setCopied(false), 1500) } catch { setNote(link) }
  }
  async function sendFlex() {
    try { await liff.shareTargetPicker([flex], { isMultiple: true }) } catch (e) { setNote(`${t('shareFailed')} (${e?.code ?? e?.message ?? 'error'}) — ใช้ปุ่ม "ส่งเป็นข้อความ LINE" แทนได้`) }
  }
  // Plain-text share through LINE's own share URL: needs no popup, so it still works where the Flex picker window is blocked
  function sendText() {
    const url = `https://line.me/R/share?text=${encodeURIComponent(`${title}\n${link}`)}`
    try { liff.openWindow({ url, external: false }) } catch { window.location.href = url }
  }
  async function showQr() {
    if (qr) return setQr(null)
    const QR = await import('qrcode')
    setQr(await QR.toDataURL(link, { width: 480, margin: 2 }))
  }

  return (
    <div className="fixed inset-0 z-[75] flex items-end justify-center bg-black/70 sm:items-center sm:p-4" onClick={onClose} role="dialog" aria-modal="true">
      <div onClick={(e) => e.stopPropagation()}
        className="max-h-[92vh] w-full max-w-md space-y-3 overflow-y-auto rounded-t-3xl bg-neutral-900 p-5 pb-[calc(1.25rem+env(safe-area-inset-bottom))] shadow-2xl sm:rounded-3xl">
        <div className="mx-auto h-1.5 w-10 rounded-full bg-white/20 sm:hidden" />
        <h2 className="text-lg font-bold">🔗 {title}</h2>
        {intro && <p className="text-sm text-neutral-400">{intro}</p>}
        <p className="break-all rounded-xl bg-white/5 p-3 text-xs text-neutral-300">{link}</p>
        <div className="grid grid-cols-2 gap-2">
          <button onClick={copy} className="rounded-xl bg-white/10 py-2 text-sm font-semibold active:scale-95">{copied ? t('copied') : t('shareCopy')}</button>
          <button onClick={showQr} className="rounded-xl bg-white/10 py-2 text-sm font-semibold active:scale-95">{t('shareQr')}</button>
          {flex && canShareFlex() && <button onClick={sendFlex} className="col-span-2 rounded-xl bg-line py-2 text-sm font-bold text-black active:scale-95">{t('shareFlex')}</button>}
          {!USE_MOCK_LIFF && <button onClick={sendText} className="col-span-2 rounded-xl bg-white/10 py-2 text-sm font-semibold active:scale-95">💬 ส่งเป็นข้อความ LINE (ถ้าปุ่ม Flex ขึ้นหน้าขาว)</button>}
        </div>
        {qr && (
          <div className="space-y-2 text-center">
            <img src={qr} alt="QR" className="mx-auto w-56 rounded-xl bg-white p-2" />
            <a href={qr} download="qr.png" className="inline-block rounded-lg bg-white/10 px-3 py-1 text-xs font-semibold active:scale-95">⬇️ {t('saveQr')}</a>
          </div>
        )}
        {note && <p className="break-all text-xs text-amber-200">{note}</p>}
        <button onClick={onClose} className="w-full rounded-xl bg-white/10 py-3 font-semibold active:scale-95">{t('close')}</button>
      </div>
    </div>
  )
}
