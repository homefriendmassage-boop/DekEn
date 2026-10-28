// PromptPay (EMVCo) QR payload generator: phone number, national/tax ID (13 digits) or e-wallet ID (15 digits).
// Verified against the `promptpay-qr` package for all three ID types, with and without an amount.

const tlv = (tag, value) => tag + String(value.length).padStart(2, '0') + value

// CRC-16/CCITT-FALSE, as required by EMVCo
function crc16(str) {
  let crc = 0xffff
  for (let i = 0; i < str.length; i++) {
    crc ^= str.charCodeAt(i) << 8
    for (let b = 0; b < 8; b++) crc = crc & 0x8000 ? ((crc << 1) ^ 0x1021) & 0xffff : (crc << 1) & 0xffff
  }
  return crc.toString(16).toUpperCase().padStart(4, '0')
}

export function promptPayPayload(id, amount) {
  const digits = String(id).replace(/[^0-9]/g, '')
  let target
  if (digits.length >= 15) target = tlv('03', digits)                                  // e-wallet
  else if (digits.length >= 13) target = tlv('02', digits)                             // national / tax ID
  else target = tlv('01', ('0066' + digits.replace(/^0/, '')).slice(-13))              // mobile: 0066 + number without leading 0

  const body =
    tlv('00', '01') +
    tlv('01', amount ? '12' : '11') +                                                  // 12 = one-time (amount given)
    tlv('29', tlv('00', 'A000000677010111') + target) +
    tlv('58', 'TH') +
    tlv('53', '764') +
    (amount ? tlv('54', Number(amount).toFixed(2)) : '')
  const withCrcTag = body + '6304'
  return withCrcTag + crc16(withCrcTag)
}
