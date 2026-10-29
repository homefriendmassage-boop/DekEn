import { useEffect, useState } from 'react'
import { supabase } from '../supabaseClient'

// "Whose customers?": the central ones, or one seller's. Keeps the lists short (a seller can have thousands of customers).
export default function VendorSelect({ value, onChange }) {
  const [vendors, setVendors] = useState([])
  useEffect(() => { supabase.rpc('admin_vendor_list').then(({ data }) => setVendors(data ?? [])) }, [])
  if (vendors.length === 0) return null
  return (
    <label className="flex items-center gap-2 text-xs text-neutral-400">ลูกค้าของ
      <select value={value ?? ''} onChange={(e) => onChange(e.target.value || null, vendors.find((v) => v.id === e.target.value)?.name ?? null)} className="rounded-xl bg-white/10 px-3 py-1.5 text-sm text-white">
        <option value="" className="text-black">ส่วนกลาง (ไม่มีเซลล์)</option>
        {vendors.map((v) => <option key={v.id} value={v.id} className="text-black">🏪 {v.name} ({v.customers})</option>)}
      </select>
    </label>
  )
}
