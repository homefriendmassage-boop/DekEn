import { useEffect, useState } from 'react'
import liff from '@line/liff'
import { supabase } from '../supabaseClient'

// How-to clips (YouTube). The admin manages the list (admin → 📺 วิธีใช้งาน); the files stay on YouTube, the app only holds the links.
let cache = null
let pending = null
function load() {
  if (cache) return Promise.resolve(cache)
  if (!pending) pending = supabase.rpc('help_videos_list').then(({ data }) => { cache = data ?? []; pending = null; return cache }, () => { pending = null; return [] })
  return pending
}
export function useHelpVideos() {
  const [rows, setRows] = useState(cache ?? [])
  useEffect(() => { let on = true; load().then((r) => on && setRows(r)); return () => { on = false } }, [])
  return rows
}

function openVideo(url) {
  try { if (liff.isInClient()) { liff.openWindow({ url, external: true }); return } } catch { /* fall through */ }
  window.open(url, '_blank', 'noopener')
}

const GROUPS = [['customer', '🛍️ ลูกค้า'], ['worker', '👯 น้อง / ผู้ให้บริการ'], ['seller', '🤝 เซลล์'], ['agency', '🏢 สังกัด / โมเดลลิ่ง'], ['all', '📌 ทั่วไป']]

// The pop-up: choose a topic, the clip opens in YouTube.
function Popup({ title, videos, grouped, onClose }) {
  return (
    <div className="fixed inset-0 z-[70] flex items-end justify-center bg-black/70 sm:items-center sm:p-4" onClick={onClose} role="dialog" aria-modal="true">
      <div onClick={(e) => e.stopPropagation()} className="max-h-[85vh] w-full max-w-md space-y-3 overflow-y-auto rounded-t-3xl bg-neutral-900 p-5 pb-[calc(1.25rem+env(safe-area-inset-bottom))] shadow-2xl sm:rounded-3xl">
        <div className="flex items-center justify-between"><h2 className="text-lg font-bold">📺 {title}</h2><button onClick={onClose} className="rounded-full bg-white/10 px-3 py-1 text-sm">✕</button></div>
        <p className="text-xs text-neutral-400">เลือกหัวข้อที่ต้องการดู คลิปจะเปิดใน YouTube</p>
        {(grouped ? GROUPS : [[null, null]]).map(([g, label]) => {
          const list = g ? videos.filter((v) => v.audience === g) : videos
          if (list.length === 0) return null
          return (
            <div key={g ?? 'x'} className="space-y-2">
              {label && <p className="text-sm font-semibold text-neutral-300">{label}</p>}
              {list.map((v) => (
                <button key={v.id} onClick={() => openVideo(v.url)} className="flex w-full items-center gap-3 rounded-2xl bg-white/5 px-4 py-3 text-left ring-1 ring-white/10 active:scale-[0.98]">
                  <span className="text-xl">▶️</span><span className="min-w-0 flex-1 text-sm font-semibold">{v.title}</span>
                </button>
              ))}
            </div>
          )
        })}
      </div>
    </div>
  )
}

// A one-tap bar at the place people get stuck. One clip opens at once, several open the pop-up. Nothing shows when there is no clip for the spot.
export function HelpBar({ spot, className = '' }) {
  const videos = useHelpVideos().filter((v) => v.spot === spot)
  const [open, setOpen] = useState(false)
  if (videos.length === 0) return null
  return (
    <>
      <button type="button" onClick={() => (videos.length === 1 ? openVideo(videos[0].url) : setOpen(true))}
        className={`flex w-full items-center justify-center gap-2 rounded-2xl bg-sky-500/15 px-4 py-2.5 text-sm font-semibold text-sky-200 ring-1 ring-sky-400/30 active:scale-[0.98] ${className}`}>
        📺 {videos.length === 1 ? videos[0].title : 'ดูวิธีทำ'} <span className="text-xs font-normal text-sky-300/80">(กดดูคลิป)</span>
      </button>
      {open && <Popup title="วิธีทำ" videos={videos} onClose={() => setOpen(false)} />}
    </>
  )
}

// The button in the top bar: every clip, grouped by who it is for.
export function HelpHub() {
  const videos = useHelpVideos()
  const [open, setOpen] = useState(false)
  if (videos.length === 0) return null
  return (
    <>
      <button onClick={() => setOpen(true)} aria-label="how to" className="rounded-full bg-white/10 px-2.5 py-1 text-xs font-semibold active:scale-95">📺 วิธีใช้งาน</button>
      {open && <Popup title="วิธีใช้งาน" videos={videos} grouped onClose={() => setOpen(false)} />}
    </>
  )
}
