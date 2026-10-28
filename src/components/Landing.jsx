import { LangSwitcher, useI18n } from '../i18n'

// First screen: customer or provider.
export default function Landing({ displayName, role, onCustomer, onWorker }) {
  const { t } = useI18n()
  const isWorker = role === 'worker'

  return (
    <div className="flex min-h-screen flex-col px-5 pb-8 pt-4">
      <div className="flex items-center justify-between">
        <p className="truncate text-xs text-neutral-400">{t('hello', { name: displayName })}</p>
        <LangSwitcher />
      </div>

      <div className="flex flex-1 flex-col justify-center gap-4">
        <h1 className="mb-2 text-center text-2xl font-extrabold">{t('landingTitle')}</h1>

        <Choice emoji="🛍️" title={t('imCustomer')} sub={t('imCustomerSub')} onClick={onCustomer} primary />
        <Choice
          emoji={isWorker ? '💼' : '📝'}
          title={isWorker ? t('workerArea') : t('imWorker')}
          sub={isWorker ? t('workerAreaSub') : t('imWorkerSub')}
          onClick={onWorker}
        />
      </div>
    </div>
  )
}

function Choice({ emoji, title, sub, onClick, primary }) {
  return (
    <button
      onClick={onClick}
      className={`flex w-full items-center gap-4 rounded-3xl p-5 text-left transition active:scale-[0.98] ${
        primary ? 'bg-line text-black' : 'bg-white/10 text-white ring-1 ring-white/15'
      }`}
    >
      <span className="text-4xl">{emoji}</span>
      <span>
        <span className="block text-lg font-bold">{title}</span>
        <span className={`block text-sm ${primary ? 'text-black/70' : 'text-neutral-400'}`}>{sub}</span>
      </span>
    </button>
  )
}
