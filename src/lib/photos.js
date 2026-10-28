import { supabase } from '../supabaseClient'

// Upload one prepared picture ({ orig, pub } JPEG blobs) and attach it to the application ('application')
// or to a pending edit ('pending_add'). Both files live under <user id>/ (the storage policies require that folder).
export async function uploadPhoto(userId, { orig, pub }, state) {
  const ts = `${Date.now()}${Math.floor(Math.random() * 1000)}`
  const origPath = `${userId}/${ts}.jpg`
  const pubPath = `${userId}/${ts}-public.jpg`
  const a = await supabase.storage.from('worker-originals').upload(origPath, orig, { contentType: 'image/jpeg' })
  if (a.error) throw a.error
  const b = await supabase.storage.from('worker-public').upload(pubPath, pub, { contentType: 'image/jpeg' })
  if (b.error) throw b.error
  const url = supabase.storage.from('worker-public').getPublicUrl(pubPath).data.publicUrl
  const { data, error } = await supabase.rpc('attach_photo', { p_state: state, p_public_url: url, p_original_path: origPath })
  if (error) throw error
  return data
}

// Remove a picture that was attached but not submitted yet (also deletes its private original, best effort).
export async function removeStaged(photoId) {
  const { data, error } = await supabase.rpc('delete_staged_photo', { p_id: photoId })
  if (error) throw error
  if (data) supabase.storage.from('worker-originals').remove([data]).then(() => {}, () => {})
}

// Shrink a phone picture (long side <= maxSide) to a JPEG blob; used for the ID documents.
export async function shrinkImage(file, maxSide = 1600) {
  const bmp = await createImageBitmap(file, { imageOrientation: 'from-image' }).catch(() => null)
  if (!bmp) throw new Error('unreadable image')
  const k = Math.min(1, maxSide / Math.max(bmp.width, bmp.height))
  const c = document.createElement('canvas')
  c.width = Math.round(bmp.width * k)
  c.height = Math.round(bmp.height * k)
  c.getContext('2d').drawImage(bmp, 0, 0, c.width, c.height)
  return new Promise((res, rej) => c.toBlob((b) => (b ? res(b) : rej(new Error('encode failed'))), 'image/jpeg', 0.85))
}
