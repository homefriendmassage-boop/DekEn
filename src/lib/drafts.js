import { supabase } from '../supabaseClient'
import { appLink } from './flex'

// Same two files as uploadPhoto(), but under <draft id>/ (the storage policy lets the draft's creator write there).
export async function uploadDraftPhoto(draftId, { orig, pub }) {
  const ts = `${Date.now()}${Math.floor(Math.random() * 1000)}`
  const origPath = `${draftId}/${ts}.jpg`
  const pubPath = `${draftId}/${ts}-public.jpg`
  const a = await supabase.storage.from('worker-originals').upload(origPath, orig, { contentType: 'image/jpeg' })
  if (a.error) throw a.error
  const b = await supabase.storage.from('worker-public').upload(pubPath, pub, { contentType: 'image/jpeg' })
  if (b.error) throw b.error
  const url = supabase.storage.from('worker-public').getPublicUrl(pubPath).data.publicUrl
  const { data, error } = await supabase.rpc('draft_attach_photo', { p_draft: draftId, p_public_url: url, p_original_path: origPath })
  if (error) throw error
  return data
}

export async function removeDraftPhoto(photoId) {
  const { data, error } = await supabase.rpc('draft_remove_photo', { p_photo: photoId })
  if (error) throw error
  if (data) {
    supabase.storage.from('worker-originals').remove([data]).then(() => {}, () => {})
    supabase.storage.from('worker-public').remove([data.replace(/\.jpg$/, '-public.jpg')]).then(() => {}, () => {})
  }
}

// The link the girl opens with her own LINE.
export const draftLink = (token) => appLink({ draft: token })

export const DRAFT_STATUS = {
  draft: ['ร่าง', 'bg-white/10 text-neutral-300'],
  submitted: ['รอแอดมินตรวจ', 'bg-amber-400/20 text-amber-200'],
  approved: ['ออกลิงก์แล้ว รอน้องกดรับ', 'bg-green-500/20 text-green-300'],
  rejected: ['แอดมินตีกลับ', 'bg-red-500/20 text-red-300'],
  claimed: ['น้องกดรับแล้ว', 'bg-sky-500/20 text-sky-200'],
  expired: ['ลิงก์หมดอายุ', 'bg-orange-500/20 text-orange-200'],
  cancelled: ['ยกเลิก', 'bg-neutral-600/40 text-neutral-400'],
}
