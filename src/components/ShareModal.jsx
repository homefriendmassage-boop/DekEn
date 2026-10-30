import { useEffect, useState } from 'react'
import liff from '@line/liff'
import { supabase } from '../supabaseClient'
import { USE_MOCK_LIFF } from '../config'
import { getActiveLiffId } from '../lib/vendor'
import { useI18n } from '../i18n'
import { inviteBubble } from '../lib/flex'

const APP_NAME = 'DekEn'

// Share my link: copy, LINE Flex message (share target picker) or QR code.
// Whoever opens the link and registers / pays through it counts as my customer (server-side rules, migration_015).
export default function ShareModal({ onClose, agencyCode }) {
  const { t, money } = useI18n()
  const [stats, setStats] = useState(null)
  const [qr, setQr] = useState(null)
  const [copied, setCopied] = useState(false)
  const [note, setNote] = useState(null)

  useEffect(() => {
    if (agencyCode) return setStats({ code: agencyCode })     // agency invitation: no referral numbers
    supabase.rpc('my_referral_stats').then(({ data }) => setStats(data?.[0] ?? null))
  }, [agencyCode])

  const param = agencyCode ? 'agency' : 'ref'
  const extra = agencyCode ? '&only=apply' : ''     // an agency's invitation opens the application form and nothing else
  const link = stats?.code
    ? USE_MOCK_LIFF || !getActiveLiffId()
      ? `${window.location.origin}${window.location.pathname}?${param}=${stats.code}${extra}`
      : `https://liff.line.me/${getActiveLiffId()}?${param}=${stats.code}${extra}`
    : null

  const canFlex = !USE_MOCK_LIFF && (() => { try { return liff.isApiAvailable('shareTargetPicker') } catch { return false } })()

  async function copy() {
    try { await navigator.clipboard.writeText(link); setCopied(true); setTimeout(() => setCopied(false), 1500) } catch { setNote(link) }
  }

  async function sendFlex() {
    try {
      await liff.shareTargetPicker([{
        type: 'flex',
        altText: t('shareFlexAlt', { app: APP_NAME }),
        contents: inviteBubble({
          tagline: t('shareLogoNote'), title: APP_NAME, uri: link,
          body: t(agencyCode ? 'agencyFlexBody' : 'shareFlexBody'), button: t('shareFlexButton'),
        }),
      }])
    } catch { setNote(t('shareFailed')) }
  }

  async function showQr() {
    if (qr) return setQr(null)
    const QR = await import('qrcode')
    setQr(await QR.toDataURL(link, { width: 280, margin: 2 }))
  }

  return (
    <div className="fixed inset-0 z-[55] flex items-end justify-center bg-black/70 sm:items-center sm:p-4" onClick={onClose} role="dialog" aria-modal="true">
      <div onClick={(e) => e.stopPropagation()}
        className="max-h-[92vh] w-full max-w-md space-y-4 overflow-y-auto rounded-t-3xl bg-neutral-900 p-5 pb-[calc(1.25rem+env(safe-area-inset-bottom))] shadow-2xl sm:rounded-3xl">
        <div className="mx-auto h-1.5 w-10 rounded-full bg-white/20 sm:hidden" />
        <h2 className="text-xl font-bold">{agencyCode ? '🏢' : '🎁'} {t(agencyCode ? 'agencyInviteTitle' : 'shareTitle')}</h2>
        <p className="text-sm text-neutral-400">{t(agencyCode ? 'agencyInviteBody' : 'shareBody')}</p>

        {!stats ? <p className="py-6 text-center text-neutral-500">{t('loading')}</p> : (
          <>
            {!agencyCode && <div className="grid grid-cols-2 gap-2 text-center">
              <div className="rounded-2xl bg-white/5 p-3"><p className="text-xs text-neutral-400">{t('shareFriends')}</p><p className="text-xl font-bold">{stats.friends}</p></div>
              <div className="rounded-2xl bg-amber-400/10 p-3"><p className="text-xs text-amber-200">{t('shareEarned')}</p><p className="text-xl font-bold text-amber-300">{money(stats.earned)}</p></div>
            </div>}

            <p className="break-all rounded-xl bg-white/5 p-3 text-xs text-neutral-300">{link}</p>
            <div className="grid grid-cols-2 gap-2">
              <button onClick={copy} className="rounded-xl bg-white/10 py-2 text-sm font-semibold active:scale-95">{copied ? t('copied') : t('shareCopy')}</button>
              <button onClick={showQr} className="rounded-xl bg-white/10 py-2 text-sm font-semibold active:scale-95">{t('shareQr')}</button>
              {canFlex && <button onClick={sendFlex} className="col-span-2 rounded-xl bg-line py-2 text-sm font-bold text-black active:scale-95">{t('shareFlex')}</button>}
            </div>
            {qr && <img src={qr} alt="QR" className="mx-auto w-56 rounded-xl bg-white p-2" />}
            {note && <p className="break-all text-xs text-amber-200">{note}</p>}
            {!agencyCode && <p className="text-[11px] text-neutral-500">{t('shareRule')}</p>}
          </>
        )}
        <button onClick={onClose} className="w-full rounded-xl bg-white/10 py-3 font-semibold active:scale-95">{t('close')}</button>
      </div>
    </div>
  )
}
