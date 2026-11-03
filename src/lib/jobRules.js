import { useEffect, useState } from 'react'
import { supabase } from '../supabaseClient'

// The booking rules (numbers set by the admin) and the texts that explain them. Loaded once.
let cache = null
let pending = null
export function loadJobRules() {
  if (cache) return Promise.resolve(cache)
  if (!pending) pending = supabase.rpc('job_rules').then(({ data }) => { cache = data ?? DEFAULTS; pending = null; return cache }, () => { pending = null; return DEFAULTS })
  return pending
}
export const DEFAULTS = { response_minutes: 30, autocomplete_hours: 3, free_cancel_minutes: 2, cancel_fee: 100, early_cancel_hours: 24, noshow_wait_minutes: 30, objection_hours: 6, resched_notice_hours: 3, comp_max: 500, booking_fee: 500 }
export function useJobRules() {
  const [r, setR] = useState(cache ?? DEFAULTS)
  useEffect(() => { let on = true; loadJobRules().then((x) => on && setR(x)); return () => { on = false } }, [])
  return r
}
export const CANCEL_REASONS = ['ติดธุระกะทันหัน', 'เปลี่ยนแผน', 'จองผิดวัน/เวลา', 'ติดต่อน้องไม่ได้', 'อื่น ๆ']
export const PROBLEM_KINDS = [
  ['worker_noshow', 'น้องไม่มาตามนัด'],
  ['imposter', 'คนอื่นมาแทน / ไม่ใช่คนในโปรไฟล์'],
  ['mismatch', 'ไม่ตรงปกมาก'],
  ['other', 'ปัญหาอื่น'],
]

// What happens to the fee if the customer cancels this booking now
export function cancelOutcome(job, rules) {
  const fee = Number(job.booking_fee ?? rules.booking_fee)
  const keep = Number(rules.cancel_fee)
  if (job.status === 'pending') {
    const mins = (Date.now() - new Date(job.created_at).getTime()) / 60000
    return mins <= Number(rules.free_cancel_minutes) ? { refund: fee, text: `ยกเลิกฟรี คืนค่าจอง ${fee} บาท (ภายใน ${rules.free_cancel_minutes} นาทีแรก)` } : { refund: fee - keep, text: `คืนค่าจอง ${fee - keep} บาท (หักค่ายกเลิก ${keep} บาท)` }
  }
  const early = job.scheduled_at && new Date(job.scheduled_at).getTime() - Date.now() >= Number(rules.early_cancel_hours) * 3600e3
  return early
    ? { refund: fee - keep, text: `ยกเลิกล่วงหน้าเกิน ${rules.early_cancel_hours} ชม.: คืนค่าจอง ${fee - keep} บาท (หักค่ายกเลิก ${keep} บาท)` }
    : { refund: 0, text: `ยกเลิกใกล้เวลานัด (ไม่ถึง ${rules.early_cancel_hours} ชม.): ค่าจอง ${fee} บาท ไม่คืน` }
}

export const JOB_ERR = {
  DISPUTE_OPEN: 'งานนี้มีข้อพิพาทรอแอดมินตรวจสอบ ทำรายการไม่ได้ในตอนนี้',
  TOO_EARLY: 'ยังไม่ถึงเวลาที่ทำรายการนี้ได้',
  TOO_LATE: 'เลยเวลาที่ทำรายการนี้ได้แล้ว',
  BAD_TIME: 'วันเวลาไม่ถูกต้อง',
  INSUFFICIENT_BALANCE: 'ยอด Wallet ไม่พอ',
  CONTACT_IN_BOOKING: 'ห้ามใส่เบอร์โทร/LINE ในข้อความ',
  ILLEGAL_STATUS_TRANSITION: 'ทำรายการนี้ไม่ได้ในสถานะปัจจุบัน',
  WORKER_BLOCKED: 'น้องคนนี้ไม่พร้อมรับงานชั่วคราว',
  BOOKING_PAUSED: 'บัญชีของคุณถูกพักการจองชั่วคราว เพราะยกเลิก/ไม่มาตามนัดหลายครั้ง',
  BAD_INPUT: 'ข้อมูลไม่ถูกต้อง',
  FORBIDDEN: 'ทำรายการนี้ไม่ได้',
}
export const jobErr = (m = '') => Object.entries(JOB_ERR).find(([k]) => m.includes(k))?.[1] ?? 'ทำรายการไม่สำเร็จ'

// The text under a cancelled booking (customer side / provider side), by cancel_reason
export function cancelText(j, side) {
  const v2 = j.rules_v2
  const r = j.cancel_reason ?? 'admin'
  const why = j.cancel_note ? ` เหตุผล: ${j.cancel_note}` : ''
  if (side === 'customer') {
    return ({
      customer: v2 ? 'คุณยกเลิกคำขอ ค่าจองคืนเข้า Wallet ตามเงื่อนไขแล้ว' : 'คุณยกเลิกคำขอ ค่าธรรมเนียมคืนเข้า Wallet แล้ว',
      customer_early: 'คุณยกเลิกล่วงหน้า คืนค่าจองเข้า Wallet ตามเงื่อนไขแล้ว',
      customer_late: 'คุณยกเลิกใกล้เวลานัด ค่าจองไม่คืน',
      customer_noshow: 'น้องรายงานว่าคุณไม่มาตามนัด ค่าจองไม่คืน',
      declined: 'น้องปฏิเสธงาน ค่าธรรมเนียมคืนเข้า Wallet แล้ว',
      expired: 'น้องไม่ตอบภายในเวลาที่กำหนด ยกเลิกและคืนค่าธรรมเนียมเข้า Wallet แล้ว',
      worker_cancelled: v2 ? 'น้องยกเลิกหลังรับงาน คืนค่าจองเต็มจำนวนเข้า Wallet แล้ว' : 'น้องยกเลิกหลังรับงาน กรุณาติดต่อแอดมินเพื่อขอคืนค่าธรรมเนียม',
      worker_noshow: 'น้องไม่มาตามนัด คืนค่าจองเต็มจำนวนเข้า Wallet แล้ว',
      imposter: 'แอดมินยืนยันว่ามีคนอื่นมาแทน คืนค่าจองเต็มจำนวนเข้า Wallet แล้ว',
      mismatch: 'แอดมินยืนยันว่าไม่ตรงปก คืนค่าจองเต็มจำนวนเข้า Wallet แล้ว',
      worker_fault_other: 'แอดมินตรวจสอบแล้ว คืนค่าจองเต็มจำนวนเข้า Wallet แล้ว',
      admin_refund: 'แอดมินตรวจสอบแล้ว คืนค่าจองเต็มจำนวนเข้า Wallet',
      admin: 'ยกเลิกโดยผู้ดูแล',
    }[r] ?? 'ยกเลิกแล้ว')
  }
  return ({
    customer: 'ลูกค้ายกเลิกคำขอ' + why,
    customer_early: 'ลูกค้ายกเลิกล่วงหน้า' + why,
    customer_late: 'ลูกค้ายกเลิกใกล้เวลานัด' + why,
    customer_noshow: 'บันทึกว่าลูกค้าไม่มาตามนัด',
    declined: 'คุณปฏิเสธงานนี้',
    expired: 'ไม่ได้ตอบภายในเวลาที่กำหนด งานถูกยกเลิก',
    worker_cancelled: 'คุณยกเลิกงานหลังรับ (นับเป็นผิดนัด 1 ครั้ง ค่าจองคืนลูกค้าแล้ว)',
    worker_noshow: 'ลูกค้ารายงานว่าคุณไม่ไปตามนัด (นับเป็นผิดนัด 1 ครั้ง ค่าจองคืนลูกค้าแล้ว)',
    imposter: 'แอดมินยืนยันว่ามีคนอื่นไปแทน บัญชีถูกบล็อก ติดต่อแอดมินเพื่อยืนยันตัวตน',
    mismatch: 'แอดมินยืนยันว่ารูปไม่ตรงปก (นับเป็นผิดนัด 1 ครั้ง) กรุณาแก้รูปโปรไฟล์',
    worker_fault_other: 'แอดมินตรวจสอบแล้ว นับเป็นผิดนัด 1 ครั้ง',
    admin_refund: 'แอดมินตรวจสอบแล้ว ไม่ถือเป็นความผิดของฝ่ายใด คืนค่าจองให้ลูกค้า',
    admin: 'ยกเลิกโดยผู้ดูแล',
  }[r] ?? 'ยกเลิกแล้ว')
}
