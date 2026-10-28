import { supabase } from '../supabaseClient'

// Agency logos live in the public bucket `agency-logos` (one file per agency: <user id>/logo.jpg).
export const logoUrl = (path) => (path ? supabase.storage.from('agency-logos').getPublicUrl(path).data.publicUrl : null)

// Squares the picked image to 256x256 JPEG (small, and nothing odd is stored).
export async function logoBlob(file) {
  const bmp = await createImageBitmap(file)
  const size = Math.min(bmp.width, bmp.height)
  const canvas = document.createElement('canvas')
  canvas.width = canvas.height = 256
  canvas.getContext('2d').drawImage(bmp, (bmp.width - size) / 2, (bmp.height - size) / 2, size, size, 0, 0, 256, 256)
  return new Promise((resolve, reject) => canvas.toBlob((b) => (b ? resolve(b) : reject(new Error('logo'))), 'image/jpeg', 0.85))
}
