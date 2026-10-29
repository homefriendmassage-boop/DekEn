import { BOOKING_FEE } from '../config'

// Massage and spa carry a higher platform fee (the database charges the same: booking_fee_for()).
export const PREMIUM_FEE = 700
export const isPremium = (categories) => (categories ?? []).some((c) => c === 'masseuse' || c === 'spa')
export const feeFor = (categories) => (isPremium(categories) ? PREMIUM_FEE : BOOKING_FEE)

// What the customer sees = what the provider receives in cash + the platform fee (paid from the Wallet when booking).
export const withFee = (cash, categories) => Number(cash) + feeFor(categories)

export const fmtWhen = (v, lang = 'th') => new Date(v).toLocaleString(lang === 'th' ? 'th-TH' : undefined, { dateStyle: 'medium', timeStyle: 'short' })

// A Google Maps link for a provider to navigate to: the pasted link, else the GPS pin.
export const mapsLink = (j) => j.place_url || (j.place_lat != null && j.place_lng != null ? `https://www.google.com/maps?q=${j.place_lat},${j.place_lng}` : null)

// minutes left to answer a pending booking
export const minutesLeft = (expiresAt) => Math.max(0, Math.ceil((new Date(expiresAt) - Date.now()) / 60000))

export const BOOKING_ERRORS = {
  INSUFFICIENT_BALANCE: 'errInsufficient', WORKER_UNAVAILABLE: 'errUnavailable', LOCKED: 'errLocked', UNCLAIMED: 'errUnclaimed',
  BAD_RATE: 'errBadRate', BAD_TIME: 'errBadTime', CONTACT_IN_BOOKING: 'errBookingContact', PLACE_REQUIRED: 'errPlaceRequired',
  BAD_MAP_LINK: 'errBadMapLink', BAD_PHONE: 'errBadPhone', BAD_PLACE: 'errBadPlace', SUSPENDED: 'errSuspendedBooking',
}
export const bookingErrorKey = (msg = '') => BOOKING_ERRORS[Object.keys(BOOKING_ERRORS).find((k) => msg.includes(k))] ?? 'errGeneric'
