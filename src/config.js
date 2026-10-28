// Display-only constant. The REAL fee is enforced server-side by the
// jobs_before_insert trigger (public.platform_booking_fee()). Keep them in sync.
export const BOOKING_FEE = 500

export const LIFF_ID = import.meta.env.VITE_LIFF_ID
export const USE_MOCK_LIFF = import.meta.env.VITE_USE_MOCK_LIFF === 'true'
// Where "contact admin to subscribe" points, e.g. https://line.me/R/ti/p/@youroa
export const LINE_OA_URL = import.meta.env.VITE_LINE_OA_URL

export const CATEGORIES = ['bartender', 'ent', 'masseuse', 'spa']

// ---- Membership (mirrors public.can_view_category in migration_002.sql) ----
// The database is the authority; this copy only drives UI locks and demo data.
export const MEMBERSHIP_DAYS = 30
export const FREE_RANK_LIMIT = 10
// Display names/looks for the three paid tiers (the DB only knows tier 1/2/3).
export const PLAN_META = {
  1: { name: 'Gold', icon: '🥇', badge: 'bg-gradient-to-r from-yellow-200 via-amber-300 to-amber-500 text-black', ring: 'ring-amber-400', soft: 'bg-amber-400/10' },
  2: { name: 'Platinum', icon: '💠', badge: 'bg-gradient-to-r from-slate-100 via-slate-300 to-slate-400 text-black', ring: 'ring-slate-300', soft: 'bg-slate-300/10' },
  3: { name: 'Diamond', icon: '💎', badge: 'bg-gradient-to-r from-cyan-200 via-sky-300 to-fuchsia-400 text-black', ring: 'ring-cyan-300', soft: 'bg-cyan-300/10' },
}
export const PLANS = [
  { tier: 1, price: 100 },
  { tier: 2, price: 200 },
  { tier: 3, price: 300 },
]
// Lowest tier that can open each category at all.
export const MIN_TIER = { bartender: 0, ent: 0, masseuse: 2, spa: 3 }

export const canViewWorker = (category, rank, tier) =>
  tier >= (MIN_TIER[category] ?? 3) && (tier > 0 || rank <= FREE_RANK_LIMIT)

// Effective tier of a users row (expired membership => 0).
export const tierOf = (me) =>
  me?.vip_expires_at && new Date(me.vip_expires_at) > new Date() ? me.vip_tier : 0
