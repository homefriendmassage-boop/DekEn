// Display-only constant. The REAL fee is enforced server-side by the
// jobs_before_insert trigger (public.platform_booking_fee()). Keep them in sync.
export const BOOKING_FEE = 500

export const LIFF_ID = import.meta.env.VITE_LIFF_ID
export const USE_MOCK_LIFF = import.meta.env.VITE_USE_MOCK_LIFF === 'true'


