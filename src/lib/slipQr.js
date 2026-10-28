// Reads the QR code printed on a bank-transfer slip, in the browser (only the decoded text is sent to the server).
//
// Slips are tall images with a small, dense QR in a corner, and phones hand over very different files
// (full-resolution screenshots, images LINE already shrank, photos with the wrong orientation). One decode of the
// downscaled image is not enough, so this tries, cheapest first:
//   1. the browser's native BarcodeDetector (Chrome / Android WebView), when present
//   2. jsQR on the whole image at a few sizes
//   3. jsQR on regions where the QR usually sits (bottom half, bottom-right, ...), enlarged so the dots are big enough,
//      also with the contrast stretched
// It returns the text, or null; `info` (optional object) receives the image size for diagnostics.

const MAX_SIDE = 3000   // memory guard for 12 MP photos

async function loadBitmap(file) {
  if (typeof createImageBitmap === 'function') {
    try { return await createImageBitmap(file, { imageOrientation: 'from-image' }) } catch { /* fall back to <img> */ }
  }
  const url = URL.createObjectURL(file)
  try {
    return await new Promise((res, rej) => {
      const i = new Image()
      i.onload = () => res(i)
      i.onerror = rej
      i.src = url
    })
  } finally {
    setTimeout(() => URL.revokeObjectURL(url), 0)
  }
}

const sizeOf = (b) => ({ w: b.width ?? b.naturalWidth, h: b.height ?? b.naturalHeight })

function draw(src, sx, sy, sw, sh, outW, outH) {
  const canvas = document.createElement('canvas')
  canvas.width = outW
  canvas.height = outH
  const ctx = canvas.getContext('2d', { willReadFrequently: true })
  ctx.imageSmoothingEnabled = true
  ctx.imageSmoothingQuality = 'high'
  ctx.fillStyle = '#fff'
  ctx.fillRect(0, 0, outW, outH)
  ctx.drawImage(src, sx, sy, sw, sh, 0, 0, outW, outH)
  return { canvas, ctx }
}

// Stretch the contrast so a washed-out / dim screenshot still has black and white modules.
function stretch(img) {
  const d = img.data
  let lo = 255, hi = 0
  for (let i = 0; i < d.length; i += 4) {
    const g = (d[i] * 299 + d[i + 1] * 587 + d[i + 2] * 114) / 1000
    if (g < lo) lo = g
    if (g > hi) hi = g
  }
  const span = Math.max(1, hi - lo)
  for (let i = 0; i < d.length; i += 4) {
    const g = (d[i] * 299 + d[i + 1] * 587 + d[i + 2] * 114) / 1000
    const v = Math.max(0, Math.min(255, ((g - lo) * 255) / span))
    d[i] = d[i + 1] = d[i + 2] = v
  }
  return img
}

export async function decodeSlipQr(file, info = {}) {
  const bmp = await loadBitmap(file)
  const { w: W, h: H } = sizeOf(bmp)
  info.width = W
  info.height = H
  info.type = file.type
  info.bytes = file.size
  const fit = Math.min(1, MAX_SIDE / Math.max(W, H))

  // 1) native detector
  try {
    if ('BarcodeDetector' in window) {
      const det = new window.BarcodeDetector({ formats: ['qr_code'] })
      const found = await det.detect(bmp)
      if (found?.[0]?.rawValue) return found[0].rawValue
    }
  } catch { /* not usable here */ }

  const { default: jsQR } = await import('jsqr')
  const tryRegion = (sx, sy, sw, sh, targetSide, contrast) => {
    const k = targetSide / Math.max(sw, sh)
    const outW = Math.max(1, Math.round(sw * k))
    const outH = Math.max(1, Math.round(sh * k))
    const { ctx } = draw(bmp, sx, sy, sw, sh, outW, outH)
    let img = ctx.getImageData(0, 0, outW, outH)
    if (contrast) img = stretch(img)
    const code = jsQR(img.data, outW, outH, { inversionAttempts: 'attemptBoth' })
    return code?.data || null
  }

  // 2) whole image, a few sizes (never enlarge the whole picture beyond 1.5x: it only costs time)
  for (const side of [Math.round(Math.max(W, H) * fit), 1800, 1200]) {
    const s = Math.min(side, Math.round(Math.max(W, H) * 1.5))
    const r = tryRegion(0, 0, W, H, s, false)
    if (r) return r
  }

  // 3) regions where the QR usually is, enlarged to ~1000 px on the long side
  const regions = [
    [0, H * 0.5, W, H * 0.5],             // bottom half
    [W * 0.4, H * 0.5, W * 0.6, H * 0.5], // bottom right
    [0, H * 0.5, W * 0.6, H * 0.5],       // bottom left
    [0, H * 0.7, W, H * 0.3],             // bottom third
    [W * 0.5, H * 0.7, W * 0.5, H * 0.3], // bottom-right corner
    [0, 0, W, H * 0.5],                   // top half (some banks)
    [W * 0.25, H * 0.25, W * 0.5, H * 0.5], // centre
  ]
  for (const contrast of [false, true]) {
    for (const [sx, sy, sw, sh] of regions) {
      for (const side of [1000, 1600]) {
        const r = tryRegion(Math.round(sx), Math.round(sy), Math.round(sw), Math.round(sh), side, contrast)
        if (r) return r
      }
    }
  }
  return null
}
