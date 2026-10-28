import { useCallback, useEffect, useState } from 'react'
import { supabase } from '../supabaseClient'
import { BANK, LINE_OA_URL, MEMBERSHIP_DAYS, PLAN_META, PROMPTPAY_ID } from '../config'
import { promptPayPayload } from '../lib/promptpay'
import { useI18n } from '../i18n'

const TOPUP_CHOICES = [100, 300, 500, 1000]
const KNOWN_ERRORS = ['SLIP_REJECTED', 'WRONG_RECEIVER', 'AMOUNT_MISMATCH', 'DUPLICATE_SLIP', 'NO_PENDING_INTENT',
  'RATE_LIMIT', 'UPSTREAM_ERROR', 'CONFIG_MISSING', 'BAD_PAYLOAD', 'SERVER_ERROR', 'UNAUTHORIZED', 'ALREADY_UNDER_REVIEW', 'SLIP_PENDING']

// Read the QR code printed on a bank-transfer slip (browser-side; only the decoded text is sent to the server).
async function decodeSlipQr(file) {
  const url = URL.createObjectURL(file)
  try {
    const img = await new Promise((res, rej) => {
      const i = new Image()
      i.onload = () => res(i)
      i.onerror = rej
      i.src = url
    })
    const { default: jsQR } = await import('jsqr')
    // Slips are tall and the QR is small: try a few resolutions.
    for (const maxSide of [1800, 1200, 800]) {
      const scale = Math.min(1, maxSide / Math.max(img.naturalWidth, img.naturalHeight))
      const w = Math.round(img.naturalWidth * scale)
      const h = Math.round(img.naturalHeight * scale)
      const canvas = document.createElement('canvas')
      canvas.width = w
      canvas.height = h
      const ctx = canvas.getContext('2d', { willReadFrequently: true })
      ctx.drawImage(img, 0, 0, w, h)
      const code = jsQR(ctx.getImageData(0, 0, w, h).data, w, h, { inversionAttempts: 'attemptBoth' })
      if (code?.data) return code.data
    }
    return null
  } finally {
    URL.revokeObjectURL(url)
  }
}

const HAS_QR = Boolean(PROMPTPAY_ID)
const HAS_BANK = Boolean(BANK.no)
const READY = HAS_QR || HAS_BANK

function InfoRow({ label, value }) {
  return (
    <div className="text-sm">
      <span className="block text-[11px] text-neutral-500">{label}</span>
      <span className="block break-words font-semibold">{value}</span>
    </div>
  )
}

function CopyRow({ label, value }) {
  const { t } = useI18n()
  const [done, setDone] = useState(false)
  return (
    <div className="flex items-center justify-between gap-2 text-sm">
      <span className="min-w-0">
        <span className="block text-[11px] text-neutral-500">{label}</span>
        <span className="block truncate font-semibold">{value}</span>
      </span>
      <button type="button" className="shrink-0 rounded-lg bg-white/10 px-3 py-1 text-xs active:scale-95"
        onClick={async () => { try { await navigator.clipboard.writeText(String(value)); setDone(true); setTimeout(() => setDone(false), 1500) } catch { /* ignore */ } }}>
        {done ? t('copied') : t('copy')}
      </button>
    </div>
  )
}

const mmss = (ms) => {
  const s = Math.max(0, Math.floor(ms / 1000))
  return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, '0')}`
}

/**
 * Pay for a membership plan or top up the wallet.
 * 1) server creates a request with a unique amount (e.g. 100.37)  2) QR with that amount  3) slip upload -> verified server-side.
 * kind: 'membership' (+ tier) | 'wallet_topup'
 */
export default function PaymentModal({ kind, tier, onClose, onPaid, onOpenSupport }) {
  const { t, money } = useI18n()
  const [step, setStep] = useState(kind === 'membership' ? 'creating' : 'choose') // choose | creating | pay | verifying | done
  const [topup, setTopup] = useState(500)
  const [intent, setIntent] = useState(null) // { amount, expires }
  const [qr, setQr] = useState(null)
  const [error, setError] = useState(null)
  const [now, setNow] = useState(Date.now())
  const [result, setResult] = useState(null)
  const [review, setReview] = useState(null) // { paid, expected } when the slip was sent to the admin

  const create = useCallback(async () => {
    setStep('creating')
    setError(null)
    const { data, error } = await supabase.rpc('create_payment_intent', {
      p_kind: kind,
      p_tier: kind === 'membership' ? tier : null,
      p_amount: kind === 'wallet_topup' ? topup : null,
    })
    const row = data?.[0]
    if (error || !row) {
      setError(t(error?.message?.includes('BUSY') ? 'payErr_BUSY' : 'errGeneric'))
      return setStep(kind === 'membership' ? 'error' : 'choose')
    }
    const amount = Number(row.intent_amount)
    if (HAS_QR) {
      const QR = await import('qrcode')
      setQr(await QR.toDataURL(promptPayPayload(PROMPTPAY_ID, amount), { width: 320, margin: 1 }))
    }
    setIntent({ amount, expires: new Date(row.intent_expires_at).getTime() })
    setStep('pay')
  }, [kind, tier, topup, t])

  useEffect(() => { if (kind === 'membership' && READY) create() }, []) // eslint-disable-line react-hooks/exhaustive-deps
  useEffect(() => {
    if (step !== 'pay') return
    const h = setInterval(() => setNow(Date.now()), 1000)
    return () => clearInterval(h)
  }, [step])

  async function onSlip(e) {
    const file = e.target.files?.[0]
    e.target.value = ''
    if (!file) return
    setError(null)
    setStep('verifying')
    let payload = null
    try { payload = await decodeSlipQr(file) } catch { /* unreadable image */ }
    if (!payload) {
      setError(t('payErr_NO_QR'))
      return setStep('pay')
    }
    const { data, error } = await supabase.functions.invoke('verify-slip', { body: { payload } })
    if (error || !data) {
      setError(t('errGeneric'))
      return setStep('pay')
    }
    if (data.code === 'REVIEW_SUBMITTED') {
      // Genuine slip to our account, wrong amount: a human decides. Pop up the chat with the admin.
      setReview({ paid: money(data.paid), expected: (data.expected ?? []).map(money).join(' / '), expired: !(data.expected ?? []).length })
      return setStep('pay')
    }
    if (!data.ok) {
      const code = KNOWN_ERRORS.includes(data.code) ? data.code : 'SERVER_ERROR'
      setError(t(`payErr_${code}`, { paid: data.paid != null ? money(data.paid) : '', expected: (data.expected ?? []).map(money).join(' / ') }))
      return setStep('pay')
    }
    setResult(data)
    setStep('done')
    onPaid?.(data)
  }

  const expired = step === 'pay' && intent && now >= intent.expires
  const title = kind === 'membership' ? t('payMembership', { plan: PLAN_META[tier].name }) : t('payTopup')

  return (
    <div className="fixed inset-0 z-50 flex items-end justify-center bg-black/70 sm:items-center sm:p-4" onClick={onClose} role="dialog" aria-modal="true">
      <div onClick={(e) => e.stopPropagation()}
        className="max-h-[92vh] w-full max-w-md overflow-y-auto rounded-t-3xl bg-neutral-900 p-5 pb-[calc(1.25rem+env(safe-area-inset-bottom))] shadow-2xl sm:rounded-3xl">
        <div className="mx-auto mb-4 h-1.5 w-10 rounded-full bg-white/20 sm:hidden" />
        <h2 className="text-xl font-bold">{kind === 'membership' ? PLAN_META[tier].icon : '💰'} {title}</h2>

        {!READY ? (
          <div className="mt-4 space-y-3">
            <p className="rounded-xl bg-amber-400/10 p-3 text-sm text-amber-200">{t('payNotConfigured')}</p>
            {LINE_OA_URL && <a href={LINE_OA_URL} target="_blank" rel="noreferrer" className="block rounded-xl bg-line py-3 text-center font-bold text-black">{t('contactAdmin')}</a>}
          </div>
        ) : step === 'choose' ? (
          <div className="mt-4 space-y-4">
            <p className="text-sm text-neutral-400">{t('chooseTopup')}</p>
            <div className="grid grid-cols-4 gap-2">
              {TOPUP_CHOICES.map((n) => (
                <button key={n} onClick={() => setTopup(n)}
                  className={`rounded-xl py-3 text-sm font-bold ring-2 ${topup === n ? 'bg-line text-black ring-line' : 'bg-white/10 ring-transparent'}`}>{n}</button>
              ))}
            </div>
            {error && <p className="rounded-lg bg-red-500/10 p-2 text-sm text-red-300">{error}</p>}
            <button onClick={create} className="w-full rounded-xl bg-line py-3 font-bold text-black active:scale-95">{t('next')}</button>
          </div>
        ) : step === 'creating' ? (
          <p className="py-16 text-center text-neutral-400">{t('loading')}</p>
        ) : step === 'error' ? (
          <p className="mt-4 rounded-lg bg-red-500/10 p-3 text-sm text-red-300">{error}</p>
        ) : step === 'done' ? (
          <div className="mt-4 space-y-4 text-center">
            <p className="text-5xl">✅</p>
            <p className="text-lg font-bold">
              {result?.kind === 'membership' ? t('paySuccessMembership', { plan: PLAN_META[result.tier]?.name ?? '' }) : t('paySuccessTopup', { amount: money(result?.paid ?? 0) })}
            </p>
            {result?.kind === 'membership' && <p className="text-sm text-neutral-400">{t('membershipSub', { days: result.days ?? MEMBERSHIP_DAYS })}</p>}
            <button onClick={onClose} className="w-full rounded-xl bg-line py-3 font-bold text-black active:scale-95">{t('close')}</button>
          </div>
        ) : (
          <div className="mt-4 space-y-4">
            <div className="rounded-2xl bg-amber-400/10 p-3 text-center ring-1 ring-amber-400/40">
              <p className="text-xs text-amber-200">{t('payExact')}</p>
              <p className="mt-1 text-3xl font-extrabold text-amber-300">{money(intent.amount)}</p>
            </div>

            {expired ? (
              <div className="space-y-3 text-center">
                <p className="text-sm text-red-300">{t('payExpired')}</p>
                <button onClick={create} className="w-full rounded-xl bg-line py-3 font-bold text-black active:scale-95">{t('payNew')}</button>
              </div>
            ) : (
              <>
                {HAS_QR && <img src={qr} alt="PromptPay QR" className="mx-auto w-56 rounded-xl bg-white p-2" />}
                <p className="text-center text-xs text-neutral-400">{HAS_QR ? t('payExactHint') : t('payExactHintBank')}</p>
                {HAS_BANK && (
                  <div className="space-y-2 rounded-2xl bg-white/5 p-3 ring-1 ring-white/10">
                    <p className="text-xs font-semibold text-neutral-300">{HAS_QR ? t('orBank') : t('bankTransfer')}</p>
                    {BANK.name && <InfoRow label={t('bankName')} value={BANK.name} />}
                    <CopyRow label={t('accountNo')} value={BANK.no} />
                    {BANK.holder && <InfoRow label={t('accountName')} value={BANK.holder} />}
                    <InfoRow label={t('amountLabel')} value={intent.amount.toFixed(2)} />
                  </div>
                )}
                <p className="text-center text-xs text-neutral-500">{t('payExpires', { time: mmss(intent.expires - now) })}</p>

                <label className={`block w-full cursor-pointer rounded-xl py-3 text-center font-bold active:scale-95 ${step === 'verifying' ? 'bg-neutral-700 text-neutral-300' : 'bg-line text-black'}`}>
                  {step === 'verifying' ? t('verifying') : `📎 ${t('attachSlip')}`}
                  <input type="file" accept="image/*" className="hidden" disabled={step === 'verifying'} onChange={onSlip} />
                </label>
                <p className="text-center text-[11px] text-neutral-500">{t('attachSlipHint')}</p>
              </>
            )}
            {error && <p className="rounded-lg bg-red-500/10 p-2 text-sm text-red-300">{error}</p>}
            <button onClick={onClose} className="w-full rounded-xl bg-white/10 py-2.5 text-sm font-semibold active:scale-95">{t('close')}</button>
          </div>
        )}
      </div>

      {/* Popup: slip sent to the admin because the amount did not match */}
      {review && (
        <div className="fixed inset-0 z-[65] flex items-center justify-center bg-black/80 p-5" onClick={(e) => e.stopPropagation()}>
          <div className="w-full max-w-sm space-y-4 rounded-3xl bg-neutral-900 p-5 text-center shadow-2xl ring-1 ring-white/10">
            <p className="text-4xl">📨</p>
            <h3 className="text-lg font-bold">{t('payReviewTitle')}</h3>
            <p className="text-sm text-neutral-300">{t(review.expired ? 'payReviewBodyExpired' : 'payReviewBody', review)}</p>
            <button onClick={() => { onOpenSupport?.(); onClose() }}
              className="w-full rounded-xl bg-line py-3 font-bold text-black active:scale-95">{t('chatAdmin')}</button>
            <button onClick={() => { setReview(null); onClose() }} className="w-full rounded-xl bg-white/10 py-2.5 text-sm font-semibold active:scale-95">{t('close')}</button>
          </div>
        </div>
      )}
    </div>
  )
}
