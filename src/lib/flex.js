import liff from '@line/liff'
import { LIFF_ID, USE_MOCK_LIFF } from '../config'

// Files in /public are served next to the app, so LINE can fetch them over https.
// LINE caches Flex images by URL: bump ASSET_VERSION whenever a picture in /public is replaced.
const ASSET_VERSION = 2
export const assetUrl = (name) => `${window.location.origin}${import.meta.env.BASE_URL}${name}?v=${ASSET_VERSION}`

export const canShareFlex = () => {
  if (USE_MOCK_LIFF) return false
  try { return liff.isApiAvailable('shareTargetPicker') } catch { return false }
}

// https://liff.line.me/<id>?ref=<my code>&worker=<provider id>   (mock mode: the page itself)
export function appLink(params) {
  const q = new URLSearchParams(params).toString()
  return USE_MOCK_LIFF || !LIFF_ID ? `${window.location.origin}${window.location.pathname}?${q}` : `https://liff.line.me/${LIFF_ID}?${q}`
}

const PINK = '#ec4899'
const txt = (text, o = {}) => ({ type: 'text', text, wrap: true, ...o })

// Invitation card: hero picture with the logo, headline, short pitch and one big button.
export function inviteBubble({ title, body, button, uri, tagline }) {
  return {
    type: 'bubble', size: 'mega',
    hero: { type: 'image', url: assetUrl('flex-hero.jpg'), size: 'full', aspectRatio: '3:2', aspectMode: 'cover', action: { type: 'uri', uri } },
    body: {
      type: 'box', layout: 'vertical', spacing: 'md', paddingAll: '20px',
      contents: [
        txt(tagline, { size: 'xs', color: PINK, weight: 'bold' }),
        txt(title, { weight: 'bold', size: 'xl' }),
        txt(body, { size: 'sm', color: '#666666' }),
      ],
    },
    footer: {
      type: 'box', layout: 'vertical', paddingAll: '16px',
      contents: [{ type: 'button', style: 'primary', color: PINK, height: 'md', action: { type: 'uri', label: button, uri } }],
    },
  }
}

// One provider's card: her PUBLIC (face-mosaicked) photo and details, never price or location.
export function workerBubble({ w, facts, tags, about, button, uri, logoLabel }) {
  const contents = [
    txt(w.display_name, { weight: 'bold', size: 'xl' }),
    ...(facts ? [txt(facts, { size: 'sm', color: '#444444' })] : []),
    ...(tags ? [txt(tags, { size: 'xs', color: PINK })] : []),
    ...(about ? [txt(about.length > 120 ? `${about.slice(0, 120)}…` : about, { size: 'xs', color: '#777777' })] : []),
  ]
  return {
    type: 'bubble', size: 'mega',
    hero: { type: 'image', url: w.profile_image, size: 'full', aspectRatio: '3:4', aspectMode: 'cover', action: { type: 'uri', uri } },
    body: { type: 'box', layout: 'vertical', spacing: 'sm', paddingAll: '18px', contents },
    footer: {
      type: 'box', layout: 'vertical', spacing: 'sm', paddingAll: '16px',
      contents: [
        { type: 'button', style: 'primary', color: PINK, action: { type: 'uri', label: button, uri } },
        { type: 'box', layout: 'horizontal', spacing: 'sm', margin: 'md', justifyContent: 'center', alignItems: 'center', contents: [
          { type: 'image', url: assetUrl('dekn-logo.jpg'), size: '24px', flex: 0, aspectMode: 'cover', aspectRatio: '1:1' },
          txt(logoLabel, { size: 'xxs', color: '#999999', flex: 0, gravity: 'center' }),
        ] },
      ],
    },
  }
}
