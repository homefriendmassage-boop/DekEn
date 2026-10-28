import { useCallback, useEffect, useRef, useState } from 'react'
import { supabase } from '../supabaseClient'
import { useI18n } from '../i18n'

const BLOCKS = [['A', 'rankBlockA'], ['B', 'rankBlockB'], ['C', 'rankBlockC']]
const PACKS = [[1, 'rankDay1'], [3, 'rankDay3'], [7, 'rankDay7']]

// "ซื้ออันดับ": a provider buys a fixed place in her category's list (positions 1-4 / 5-8 / 9-12, 4 places each).
// Paid from the bonus wallet first, the rest from the Wallet. The server decides everything; this only asks.
export default function RankBoost({ worker, userId, onTopUp }) {
  const { t, money, catName } = useI18n()
  const cats = worker.categories ?? []
  const [cat, setCat] = useState(cats[0] ?? null)
  const [slots, setSlots] = useState(null)
  const [mine, setMine] = useState([])
  const [bal, setBal] = useState({ wallet: 0, bonus: 0 })
  const [busy, setBusy] = useState(false)
  const [msg, setMsg] = useState(null)
  const guard = useRef(false)

  const load = useCallback(async () => {
    if (!cat) return
    const [s, m, u] = await Promise.all([
      supabase.rpc('rank_boost_slots', { p_category: cat }),
      supabase.rpc('my_rank_boosts'),
      supabase.from('users').select('wallet_balance, bonus_balance').eq('id', userId).single(),
    ])
    setSlots(s.data ?? [])
    setMine(m.data ?? [])
    if (u.data) setBal({ wallet: Number(u.data.wallet_balance), bonus: Number(u.data.bonus_balance) })
  }, [cat, userId])
  useEffect(() => { load() }, [load])

  async function buy(block, days, price) {
    if (guard.current) return
    if (!window.confirm(t('rankConfirm', { price: money(price), cat: catName(cat), block }))) return
    guard.current = true
    setBusy(true)
    setMsg(null)
    const { data, error } = await supabase.rpc('buy_rank_boost', { p_category: cat, p_block: block, p_days: days })
    guard.current = false
    setBusy(false)
    if (error) {
      const code = ['INSUFFICIENT_BALANCE', 'SLOTS_FULL', 'ALREADY_BOOSTED', 'NOT_LISTED', 'SUSPENDED'].find((c) => error.message.includes(c))
      if (code === 'INSUFFICIENT_BALANCE' && onTopUp && window.confirm(t('rankNeedTopup'))) return onTopUp()
      return setMsg(t(code ? `rankErr_${code}` : 'errGeneric'))
    }
    setMsg(t('rankBought', { date: new Date(data).toLocaleDateString() }))
    load()
  }

  if (!cat) return null
  const active = mine.find((b) => b.category === cat)

  return (
    <section className="space-y-3 rounded-2xl bg-white/5 p-3 ring-1 ring-white/10">
      <div>
        <h2 className="text-base font-bold">⭐ {t('rankTitle')}</h2>
        <p className="text-xs text-neutral-400">{t('rankHint')}</p>
        <p className="mt-1 text-[11px] text-amber-200/80">{t('rankAfterSave')}</p>
      </div>

      {cats.length > 1 && (
        <div className="flex flex-wrap gap-2">
          {cats.map((c) => (
            <button key={c} onClick={() => setCat(c)} className={`rounded-full px-3 py-1 text-sm font-semibold ${cat === c ? 'bg-line text-black' : 'bg-white/10'}`}>{catName(c)}</button>
          ))}
        </div>
      )}

      <p className="text-[11px] text-neutral-400">{t('rankBalances', { bonus: money(bal.bonus), wallet: money(bal.wallet) })}</p>
      {active && <p className="rounded-lg bg-green-500/10 p-2 text-xs text-green-300">{t('rankActive', { block: active.block, date: new Date(active.ends_at).toLocaleDateString() })}</p>}

      {slots === null ? <p className="py-3 text-center text-sm text-neutral-500">{t('loading')}</p> : (
        <ul className="space-y-2">
          {BLOCKS.map(([block, labelKey]) => {
            const s = slots.find((x) => x.block === block)
            if (!s) return null
            const left = s.capacity - s.taken
            const locked = !!active && active.block !== block        // one block per category at a time
            const full = left <= 0 && !(active && active.block === block)
            return (
              <li key={block} className="rounded-xl bg-white/5 p-3">
                <div className="flex items-center justify-between gap-2">
                  <p className="font-semibold">{t(labelKey)}</p>
                  <span className={`text-xs ${full ? 'text-red-300' : 'text-neutral-400'}`}>
                    {full ? t('rankFull', { date: s.free_at ? new Date(s.free_at).toLocaleDateString() : '' }) : t('rankLeft', { n: left })}
                  </span>
                </div>
                <p className="text-xs text-neutral-400">{t('rankPerDay', { price: money(s.price_day) })}</p>
                <div className="mt-2 grid grid-cols-3 gap-2">
                  {PACKS.map(([days, key]) => {
                    const price = Number(s.price_day) * (days === 7 ? 5 : days)
                    return (
                      <button key={days} disabled={busy || full || locked} onClick={() => buy(block, days, price)}
                        className="rounded-lg bg-line px-1 py-2 text-center text-xs font-bold text-black active:scale-95 disabled:bg-neutral-700 disabled:text-neutral-400">
                        {t(key)}<span className="block font-normal">{money(price)}</span>
                      </button>
                    )
                  })}
                </div>
              </li>
            )
          })}
        </ul>
      )}
      {msg && <p className="rounded-lg bg-white/10 p-2 text-xs">{msg}</p>}
    </section>
  )
}
