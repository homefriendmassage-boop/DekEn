import { useCallback, useEffect, useState } from 'react'
import { supabase } from '../supabaseClient'
import { useI18n } from '../i18n'
import ShareModal from './ShareModal'

// Two balances: Wallet (top-ups, pays for packages / chat / booking, not withdrawable) and
// Bonus (referral + commission + chat income; moves one way into the Wallet).
export default function WalletModal({ me, onTopUp, onClose, onChanged }) {
  const { t, money } = useI18n()
  const wallet = Number(me?.wallet_balance ?? 0)
  const bonus = Number(me?.bonus_balance ?? 0)
  const [rows, setRows] = useState(null)
  const [amount, setAmount] = useState('')
  const [busy, setBusy] = useState(false)
  const [msg, setMsg] = useState(null)
  const [showShare, setShowShare] = useState(false)

  const load = useCallback(async () => {
    const { data } = await supabase.from('wallet_ledger').select('id, wallet, amount, balance_after, kind, note, created_at')
      .order('created_at', { ascending: false }).limit(30)
    setRows(data ?? [])
  }, [])
  useEffect(() => { load() }, [load, wallet, bonus])

  async function transfer() {
    const n = Number(amount)
    if (busy || !(n > 0) || n > bonus) return
    setBusy(true)
    setMsg(null)
    const { error } = await supabase.rpc('transfer_bonus_to_wallet', { p_amount: n })
    setBusy(false)
    if (error) return setMsg(t(error.message.includes('INSUFFICIENT') ? 'bonusInsufficient' : 'errGeneric'))
    setAmount('')
    setMsg(t('bonusMoved', { amount: money(n) }))
    onChanged?.()
  }

  const label = (k) => { const s = t(`ledger_${k}`); return s === `ledger_${k}` ? k : s }

  return (
    <div className="fixed inset-0 z-50 flex items-end justify-center bg-black/70 sm:items-center sm:p-4" onClick={onClose} role="dialog" aria-modal="true">
      <div onClick={(e) => e.stopPropagation()}
        className="max-h-[92vh] w-full max-w-md space-y-4 overflow-y-auto rounded-t-3xl bg-neutral-900 p-5 pb-[calc(1.25rem+env(safe-area-inset-bottom))] shadow-2xl sm:rounded-3xl">
        <div className="mx-auto h-1.5 w-10 rounded-full bg-white/20 sm:hidden" />
        <h2 className="text-xl font-bold">💰 {t('walletTitle')}</h2>

        <section className="rounded-2xl bg-white/5 p-3 ring-1 ring-white/10">
          <p className="text-xs text-neutral-400">{t('walletMain')}</p>
          <p className="text-2xl font-extrabold">{money(wallet)}</p>
          <p className="text-[11px] text-neutral-500">{t('walletMainHint')}</p>
          <button onClick={onTopUp} className="mt-2 w-full rounded-xl bg-line py-2 text-sm font-bold text-black active:scale-95">{t('topUp')}</button>
        </section>

        <section className="rounded-2xl bg-amber-400/10 p-3 ring-1 ring-amber-400/30">
          <p className="text-xs text-amber-200">{t('walletBonus')}</p>
          <p className="text-2xl font-extrabold text-amber-300">{money(bonus)}</p>
          <p className="text-[11px] text-neutral-400">{t('walletBonusHint')}</p>
          {bonus > 0 && (
            <div className="mt-2 flex gap-2">
              <input value={amount} onChange={(e) => setAmount(e.target.value.replace(/[^\d.]/g, ''))} inputMode="decimal" placeholder={t('amountLabel')}
                className="min-w-0 flex-1 rounded-xl bg-white/10 px-3 py-2 text-sm outline-none focus:ring-2 focus:ring-line" />
              <button onClick={() => setAmount(String(bonus))} className="rounded-xl bg-white/10 px-3 text-xs font-semibold active:scale-95">{t('all')}</button>
              <button disabled={busy || !(Number(amount) > 0) || Number(amount) > bonus} onClick={transfer}
                className="rounded-xl bg-amber-300 px-3 text-sm font-bold text-black active:scale-95 disabled:opacity-40">{t('moveToWallet')}</button>
            </div>
          )}
          {msg && <p className="mt-2 text-xs text-amber-100">{msg}</p>}
          <button onClick={() => setShowShare(true)} className="mt-2 w-full rounded-xl bg-white/10 py-2 text-sm font-semibold active:scale-95">🎁 {t('shareButton')}</button>
        </section>

        <section>
          <p className="mb-1 text-sm font-semibold">{t('walletHistory')}</p>
          {rows === null ? <p className="py-4 text-center text-sm text-neutral-500">{t('loading')}</p>
            : rows.length === 0 ? <p className="py-4 text-center text-sm text-neutral-500">{t('walletHistoryEmpty')}</p>
            : (
              <ul className="divide-y divide-white/5 text-sm">
                {rows.map((r) => (
                  <li key={r.id} className="flex items-center justify-between gap-3 py-2">
                    <div className="min-w-0">
                      <p className="truncate">{r.wallet === 'bonus' ? '🎁 ' : ''}{label(r.kind)}</p>
                      <p className="text-[11px] text-neutral-500">{new Date(r.created_at).toLocaleString()}{r.note ? ` · ${r.note}` : ''}</p>
                    </div>
                    <p className={`shrink-0 font-semibold ${Number(r.amount) > 0 ? 'text-green-300' : 'text-red-300'}`}>
                      {Number(r.amount) > 0 ? '+' : ''}{money(r.amount)}
                    </p>
                  </li>
                ))}
              </ul>
            )}
        </section>

        <button onClick={onClose} className="w-full rounded-xl bg-white/10 py-3 font-semibold active:scale-95">{t('close')}</button>
      </div>
      {showShare && <ShareModal onClose={() => setShowShare(false)} />}
    </div>
  )
}
