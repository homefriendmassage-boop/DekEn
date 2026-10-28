import { LangSwitcher, useI18n } from '../i18n'

// Sticky top bar shared by every screen: back button, language switcher, tier + wallet chips.
export default function Header({ title, onBack, displayName, tier, expiresAt, walletBalance, onTierClick, onChatClick, chatUnread }) {
  const { t, money, fmtDate } = useI18n()

  return (
    <header className="sticky top-0 z-30 border-b border-white/10 bg-neutral-950/90 px-4 py-3 backdrop-blur">
      <div className="flex items-center justify-between gap-3">
        <p className="min-w-0 truncate text-xs text-neutral-400">{t('hello', { name: displayName })}</p>
        <LangSwitcher />
      </div>
      <div className="mt-1 flex items-center justify-between gap-3">
        <div className="flex min-w-0 items-center gap-2">
          {onBack && (
            <button onClick={onBack} aria-label={t('back')} className="rounded-full bg-white/10 px-2.5 py-1 text-sm active:scale-95">←</button>
          )}
          <h1 className="truncate text-lg font-bold leading-tight">{title}</h1>
        </div>
        {walletBalance !== undefined && (
          <div className="flex shrink-0 items-center gap-2">
            {onChatClick && (
              <button onClick={onChatClick} aria-label="chat" className="relative rounded-full bg-white/10 px-2.5 py-1 text-sm active:scale-95">
                💬
                {chatUnread > 0 && <span className="absolute -right-1 -top-1 rounded-full bg-red-500 px-1.5 text-[10px] font-bold">{chatUnread}</span>}
              </button>
            )}
            <button
              onClick={onTierClick}
              className={`rounded-full px-2 py-0.5 text-[10px] font-extrabold ${
                tier > 0 ? 'bg-gradient-to-r from-yellow-300 to-amber-500 text-black' : 'bg-white/10 text-neutral-300'
              }`}
            >
              {tier > 0 ? `VIP ${tier * 100}` : t('freePlan')}
            </button>
            <span className="rounded-full bg-white/10 px-3 py-1 text-sm font-semibold">💰 {money(walletBalance)}</span>
          </div>
        )}
      </div>
      {tier > 0 && expiresAt && (
        <p className="mt-1 text-right text-[10px] text-amber-300/80">{t('expires', { date: fmtDate(expiresAt) })}</p>
      )}
    </header>
  )
}
