import { useState } from 'react'
import { useI18n } from '../i18n'
import { logoUrl } from '../lib/logo'
import { appLink, inviteBubble } from '../lib/flex'
import LinkSheet from './LinkSheet'

// Horizontal strip of the agencies that have girls in this group (tap = that agency's page).
export function AgencyStrip({ agencies, category, onOpen }) {
  const { t } = useI18n()
  const list = agencies.filter((a) => a.cats.includes(category))
  if (list.length === 0) return null
  return (
    <div className="pt-3">
      <p className="px-3 pb-1.5 text-xs font-semibold text-neutral-400">🏢 {t('agencyStrip')}</p>
      <ul className="flex gap-3 overflow-x-auto px-3 pb-1">
        {list.map((a) => (
          <li key={a.id} className="shrink-0">
            <button onClick={() => onOpen(a.id)} className="flex w-20 flex-col items-center gap-1 active:scale-95">
              {a.logo ? <img src={logoUrl(a.logo)} alt="" className="h-14 w-14 rounded-full object-cover ring-2 ring-white/20" />
                : <span className="flex h-14 w-14 items-center justify-center rounded-full bg-white/10 text-2xl">🏢</span>}
              <span className="w-full truncate text-center text-[11px] font-semibold">{a.name}</span>
              {a.girls && <span className="text-[10px] text-neutral-400">{t('agencyGirls', { n: a.girls[category] ?? 0 })}</span>}
            </button>
          </li>
        ))}
      </ul>
    </div>
  )
}

// Top of an agency's page: logo, name, introduction, the groups it has (tap to switch), share.
export function AgencyHeader({ agency, category, onCategory, catName }) {
  const { t } = useI18n()
  const [sheet, setSheet] = useState(false)
  const link = appLink({ agencypage: agency.id })
  return (
    <div className="space-y-3 border-b border-white/10 px-4 py-4">
      <div className="flex items-center gap-3">
        {agency.logo ? <img src={logoUrl(agency.logo)} alt="" className="h-16 w-16 shrink-0 rounded-full object-cover ring-2 ring-white/20" />
          : <span className="flex h-16 w-16 shrink-0 items-center justify-center rounded-full bg-white/10 text-3xl">🏢</span>}
        <div className="min-w-0">
          <h2 className="truncate text-lg font-bold">{agency.name}</h2>
          {agency.girls && <p className="text-xs text-neutral-400">{t('agencyGirls', { n: Object.values(agency.girls).reduce((x, y) => x + y, 0) })}</p>}
        </div>
      </div>
      {agency.intro && <p className="whitespace-pre-wrap break-words text-sm text-neutral-300">{agency.intro}</p>}
      <div className="flex flex-wrap items-center gap-2">
        {agency.cats.length > 1 && agency.cats.map((c) => (
          <button key={c} onClick={() => onCategory(c)} className={`rounded-full px-3 py-1.5 text-sm font-semibold ${category === c ? 'bg-line text-black' : 'bg-white/10'}`}>
            {catName(c)}{agency.girls ? ` · ${agency.girls[c] ?? 0}` : ''}
          </button>
        ))}
        <button onClick={() => setSheet(true)} className="ml-auto rounded-full bg-white/10 px-3 py-1.5 text-sm font-semibold active:scale-95">{t('agencyShare')}</button>
      </div>
      {sheet && (
        <LinkSheet
          title={t('agencyShareTitle', { name: agency.name })}
          intro={t('agencyShareIntro')}
          link={link}
          flex={{ type: 'flex', altText: `DekEn: ${agency.name}`, contents: inviteBubble({ tagline: 'DekEn', title: agency.name, body: agency.intro || t('agencyShareIntro'), button: t('agencyOpenPage'), uri: link }) }}
          onClose={() => setSheet(false)}
        />
      )}
    </div>
  )
}
