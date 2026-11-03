import WithdrawModal from './WithdrawModal'
import ShareModal from './ShareModal'
import { rateMinutes } from '../lib/booking'
import { useCallback, useEffect, useState } from 'react'
import { supabase } from '../supabaseClient'
import { useI18n } from '../i18n'
import ThreadList from './ThreadList'
import ChatModal from './ChatModal'
import RankBoost from './RankBoost'
import ProfileSection from './ProfileSection'
import WorkerJobs from './WorkerJobs'
import { logoUrl } from '../lib/logo'
import { clearAgencyCode, getAgencyCode, isOaFriend, takeSeatAnswer } from '../lib/auth'
import { LINE_OA_URL } from '../config'

// Provider home: online switch, profile edit, photo upload, live job inbox.
export default function WorkerDashboard({ userId, onTopUp, me, onWallet, openChat, highlightJob }) {
  const { t, money, catName, statusName } = useI18n()
  const [worker, setWorker] = useState(null)
  const [jobs, setJobs] = useState([])
  const [chat, setChat] = useState(openChat ?? null)      // openChat: arrived from a "new message" LINE push
  const [showWd, setShowWd] = useState(false)
  const [recruit, setRecruit] = useState(false)    // my own link that brings a friend to the application form
  const [friendGate, setFriendGate] = useState(false)   // she must follow the OA to receive job notifications
  const [note, setNote] = useState(null)
  const [invite, setInvite] = useState(() => getAgencyCode())      // invitation link opened earlier
  const [inviteAgency, setInviteAgency] = useState(null)
  const [aff, setAff] = useState(null)   // my_worker_agency(): { agency_name, logo_path, plan_expires_at, can_leave }
  const [error, setError] = useState(null)

  const loadWorker = useCallback(async () => {
    const { data, error } = await supabase.from('workers').select('*').eq('user_id', userId).single()
    if (error) return setError(t('errGeneric'))
    setWorker(data)
  }, [userId]) // eslint-disable-line

  const loadJobs = useCallback(async () => {
    const { data } = await supabase.rpc('my_worker_jobs')
    setJobs(data ?? [])
  }, [])

  const [seatReqs, setSeatReqs] = useState([])
  const [strike, setStrike] = useState(null)         // my_strike_status(): warnings, block, fine
  const [strikeReason, setStrikeReason] = useState('')
  const loadStrike = useCallback(() => supabase.rpc('my_strike_status').then(({ data }) => setStrike(data?.[0] ?? null), () => {}), [])
  useEffect(() => { loadStrike() }, [loadStrike])
  async function payFine() {
    if (!window.confirm(`ชำระค่าปรับ ${strike.fine_due} บาท? ระบบหักจากกระเป๋าโบนัสก่อน ส่วนที่เหลือหักจาก Wallet`)) return
    const { error } = await supabase.rpc('worker_pay_fine')
    if (error) return setError(error.message.includes('INSUFFICIENT') ? 'ยอดไม่พอ กรุณาเติม Wallet ก่อน' : t('errGeneric'))
    setNote('ชำระค่าปรับแล้ว กลับมารับงานได้'); loadStrike()
  }
  async function saveReason() {
    const { error } = await supabase.rpc('worker_strike_reason', { p_event: strike.last_event, p_text: strikeReason })
    if (error) return setError(error.message.includes('CONTACT') ? 'ห้ามใส่เบอร์/LINE ในข้อความ' : t('errGeneric'))
    setNote('บันทึกเหตุผลแล้ว'); setStrikeReason(''); loadStrike()
  }
  const [teaserFlag, setTeaserFlag] = useState(null)     // the admin asked her to redo the mosaic of her public photo
  useEffect(() => { supabase.rpc('my_teaser_flag').then(({ data }) => setTeaserFlag(data?.[0] ?? null), () => {}) }, [])
  const loadAff = useCallback(() => {
    supabase.rpc('my_worker_agency').then(({ data }) => setAff(data?.[0] ?? null))
    supabase.rpc('my_seat_requests').then(({ data }) => setSeatReqs(data ?? []))
  }, [])
  async function answerSeat(r, accept) {
    const { error } = await supabase.rpc('answer_seat_request', { p_id: r.id, p_accept: accept })
    if (error) return setError(t('errGeneric'))
    setNote(accept ? 'รับที่นั่งแล้ว' : 'ปฏิเสธแล้ว')
    loadAff()
  }
  useEffect(() => { loadWorker(); loadJobs(); loadAff() }, [loadWorker, loadJobs, loadAff])
  // the tapped button of the seat Flex is her answer
  useEffect(() => {
    const a = takeSeatAnswer()
    if (a) supabase.rpc('answer_seat_request', { p_id: a.id, p_accept: a.accept }).then(({ error }) => {
      if (error) return setError('คำขอที่นั่งนี้ไม่มีแล้ว (ตอบไปแล้วหรือหมดอายุ)')
      setNote(a.accept ? 'ยินยอมเข้าสังกัดแล้ว ได้ที่นั่งเรียบร้อย' : 'ไม่ยินยอมแล้ว'); loadAff()
    })
  }, []) // eslint-disable-line react-hooks/exhaustive-deps
  // approval puts her online by itself: if she has not added the OA yet, ask her to (she would miss the job pushes)
  useEffect(() => { if (worker?.is_online) isOaFriend().then((ok) => { if (!ok) setFriendGate(true) }) }, [worker?.is_online]) // eslint-disable-line react-hooks/exhaustive-deps

  useEffect(() => {
    if (!invite) return setInviteAgency(null)
    supabase.rpc('agency_public', { p_code: invite }).then(({ data }) => setInviteAgency(data?.[0] ?? null))
  }, [invite])

  async function joinAgency() {
    const { error } = await supabase.rpc('worker_join_agency', { p_code: invite })
    if (error) return setError(t(error.message.includes('AGENCY_FULL') ? 'errAgencyFull' : error.message.includes('ALREADY_IN_AGENCY') ? 'errAlreadyInAgency' : 'errGeneric'))
    clearAgencyCode(); setInvite(null)
    setNote(t('joinedAgency'))
    loadAff()
  }

  async function leaveAgency() {
    if (!window.confirm(t('leaveAgencyConfirm'))) return
    const { error } = await supabase.rpc('worker_leave_agency')
    if (error) return setError(t('errGeneric'))
    setNote(t('leftAgency'))
    loadAff()
  }

  // New bookings / status changes appear instantly (RLS lets the worker see their own jobs).
  useEffect(() => {
    const ch = supabase.channel('worker-jobs')
      .on('postgres_changes', { event: '*', schema: 'public', table: 'jobs', filter: `worker_id=eq.${userId}` }, loadJobs)
      .subscribe()
    return () => { supabase.removeChannel(ch) }
  }, [userId, loadJobs])

  async function update(patch) {
    setError(null)
    const { error } = await supabase.from('workers').update(patch).eq('user_id', userId)
    if (error) return setError(t('errGeneric'))
    setNote(t('saved'))
    setTimeout(() => setNote(null), 2000)
    loadWorker()
  }

  if (!worker) return <p className="py-20 text-center text-neutral-500">{error ?? t('loading')}</p>

  return (
    <div className="space-y-5 p-4">
      {/* My money: the Bonus wallet is where chat income, commissions and referral rewards land */}
      {me && (
        <section className="space-y-2 rounded-2xl bg-amber-400/10 p-3 ring-1 ring-amber-400/30">
          <div className="grid grid-cols-2 gap-2">
            <div><p className="text-[11px] text-amber-200">🎁 {t('bonusWallet')}</p><p className="text-xl font-extrabold text-amber-300">{money(me.bonus_balance ?? 0)}</p></div>
            <div><p className="text-[11px] text-neutral-400">💰 {t('walletMain')}</p><p className="text-xl font-extrabold">{money(me.wallet_balance ?? 0)}</p></div>
          </div>
          <p className="text-[11px] text-neutral-400">{t('bonusWhere')}</p>
          <div className="grid grid-cols-2 gap-2">
            <button onClick={onWallet} className="rounded-xl bg-white/10 py-2 text-sm font-semibold active:scale-95">{t('walletHistory')}</button>
            <button onClick={() => setShowWd(true)} className="rounded-xl bg-amber-400 py-2 text-sm font-bold text-black active:scale-95">{t('withdraw')}</button>
            <button onClick={() => setRecruit(true)} className="col-span-2 rounded-xl bg-pink-500 py-2 text-sm font-bold active:scale-95">💃 {t('recruitButton')}</button>
          </div>
        </section>
      )}

      {/* Online switch */}
      <button
        onClick={async () => { if (!worker.is_online && !(await isOaFriend())) return setFriendGate(true); update({ is_online: !worker.is_online }) }}
        className={`flex w-full items-center justify-between rounded-2xl p-4 text-left ${worker.is_online ? 'bg-green-500/15 ring-1 ring-green-400' : 'bg-white/5 ring-1 ring-white/10'}`}
      >
        <span className="text-sm font-semibold">{worker.is_online ? t('onlineNow') : t('offlineNow')}</span>
        <span className={`relative h-7 w-12 shrink-0 rounded-full transition ${worker.is_online ? 'bg-line' : 'bg-neutral-600'}`}>
          <span className={`absolute top-0.5 h-6 w-6 rounded-full bg-white transition-all ${worker.is_online ? 'left-[22px]' : 'left-0.5'}`} />
        </span>
      </button>

      {worker.is_online && jobs.some((j) => j.status === 'matched' && j.scheduled_at && Date.now() >= new Date(j.scheduled_at) - 3600e3 && Date.now() <= +new Date(j.scheduled_at) + (rateMinutes(j.rate_label) + 120) * 60e3) && (
        <p className="rounded-xl bg-amber-400/15 p-3 text-sm font-semibold text-amber-200">🟠 {t('busyNow')} · {t('busyNote')}</p>
      )}

      {worker.admin_hidden && <p className="rounded-xl bg-red-500/15 p-3 text-sm font-semibold text-red-200">🛡️ {t('profileHiddenByAdmin')}</p>}
      {friendGate && (
        <div className="space-y-2 rounded-2xl bg-amber-400/10 p-3 ring-1 ring-amber-400/30">
          <p className="text-sm font-semibold text-amber-200">{t('onlineNeedFriend')}</p>
          <div className="grid grid-cols-2 gap-2">
            {LINE_OA_URL && <a href={LINE_OA_URL} className="rounded-xl bg-line py-2 text-center text-sm font-bold text-black active:scale-95">{t('friendGateAdd')}</a>}
            <button onClick={async () => { if (await isOaFriend()) { setFriendGate(false); update({ is_online: true }) } else setError(t('friendGateStill')) }} className="rounded-xl bg-white/10 py-2 text-sm font-semibold active:scale-95">{t('friendAdded')}</button>
          </div>
        </div>
      )}
      {error && <p className="rounded-lg bg-red-500/10 p-2 text-sm text-red-300">{error}</p>}
      {note && <p className="rounded-lg bg-green-500/10 p-2 text-sm text-green-300">{note}</p>}

      {/* Invitation from an agency (also how a girl who left comes back) */}
      {invite && inviteAgency && !aff && (
        <section className="space-y-2 rounded-2xl bg-amber-400/10 p-3 ring-1 ring-amber-400/30">
          <div className="flex items-center gap-3">
            {inviteAgency.logo_path && <img src={logoUrl(inviteAgency.logo_path)} alt="" className="h-10 w-10 rounded-full object-cover" />}
            <p className="font-semibold">{t('invitedBy', { name: inviteAgency.name })}</p>
          </div>
          <div className="grid grid-cols-2 gap-2">
            <button onClick={joinAgency} className="rounded-xl bg-line py-2 text-sm font-bold text-black active:scale-95">{t('joinAgencyBtn')}</button>
            <button onClick={() => { clearAgencyCode(); setInvite(null) }} className="rounded-xl bg-white/10 py-2 text-sm active:scale-95">{t('joinLater')}</button>
          </div>
        </section>
      )}

      {strike && (strike.blocked || strike.strikes > 0) && (
        <section className={`space-y-2 rounded-2xl p-3 ring-1 ${strike.blocked ? 'bg-red-500/10 ring-red-400/40' : 'bg-amber-400/10 ring-amber-400/30'}`}>
          {strike.blocked && strike.block_kind === 'fine' && (
            <>
              <p className="font-semibold text-red-200">🚫 บัญชีถูกบล็อกชั่วคราว (ผิดนัด {strike.strikes} ครั้ง)</p>
              <p className="text-sm text-neutral-200">ค่าปรับ <b>{strike.fine_due} บาท</b> หักจากกระเป๋าโบนัสก่อน (มี {Number(strike.bonus_balance).toFixed(0)}) ส่วนที่เหลือหักจาก Wallet (มี {Number(strike.wallet_balance).toFixed(0)}) เมื่อชำระแล้วโปรไฟล์กลับมาแสดงและรับงานได้ทันที</p>
              {Number(strike.bonus_balance) + Number(strike.wallet_balance) >= Number(strike.fine_due)
                ? <button onClick={payFine} className="w-full rounded-xl bg-line py-2.5 text-sm font-bold text-black active:scale-95">ชำระค่าปรับ {strike.fine_due} บาท</button>
                : <button onClick={onTopUp} className="w-full rounded-xl bg-amber-400 py-2.5 text-sm font-bold text-black active:scale-95">เติม Wallet ก่อน (ยอดไม่พอ)</button>}
            </>
          )}
          {strike.blocked && strike.block_kind === 'imposter' && (
            <>
              <p className="font-semibold text-red-200">🚫 บัญชีถูกบล็อก (แอดมินยืนยันว่ามีคนอื่นไปแทนตัวจริง)</p>
              <p className="text-sm text-neutral-200">กรุณาติดต่อแอดมินผ่านปุ่ม "แชทกับแอดมิน" ด้านบน และส่งเซลฟีสดยืนยันตัวตน แอดมินจะปลดบล็อกให้เมื่อยืนยันแล้ว</p>
            </>
          )}
          {!strike.blocked && (
            <>
              <p className="font-semibold text-amber-200">⚠️ คุณผิดนัดแล้ว {strike.strikes} ครั้ง</p>
              <p className="text-xs text-neutral-300">ครั้งถัดไปบัญชีจะถูกบล็อกและมีค่าปรับ (ครั้งที่ 2 = 200 บาท เพิ่มครั้งละ 100) การยกเลิกหลังรับงาน ลูกค้าจะได้รับเงินค่าจองคืนเต็มจำนวน</p>
              {strike.last_event && !strike.last_reason && (
                <div className="space-y-1">
                  <input value={strikeReason} maxLength={300} onChange={(e) => setStrikeReason(e.target.value)} placeholder="เหตุผลที่ผิดนัด (แอดมินเห็น)" className="w-full rounded-xl bg-white/10 px-3 py-2 text-base outline-none ring-1 ring-white/10 focus:ring-line" />
                  <button disabled={!strikeReason.trim()} onClick={saveReason} className="w-full rounded-xl bg-white/10 py-2 text-sm font-semibold active:scale-95 disabled:opacity-40">บันทึกเหตุผล</button>
                </div>
              )}
              {strike.last_reason && <p className="text-[11px] text-neutral-400">เหตุผลที่บันทึกไว้: {strike.last_reason}</p>}
            </>
          )}
        </section>
      )}
      {teaserFlag && (
        <section className="space-y-1 rounded-2xl bg-amber-400/10 p-3 ring-1 ring-amber-400/30">
          <p className="font-semibold">🖼️ แอดมินขอให้แก้โมเสกรูปตัวอย่าง</p>
          <p className="text-sm text-neutral-200">{teaserFlag.note || 'รูปตัวอย่างยังเห็นหน้า กรุณาวางโมเสกให้ครอบใบหน้าทุกคนในรูป'}</p>
          <p className="text-xs text-neutral-400">ไปที่โปรไฟล์ของฉัน → แก้ไขรูป แล้วอัปโหลดรูปใหม่พร้อมวางโมเสก (หรือแจ้งแอดมินให้วางให้ได้)</p>
        </section>
      )}
      {seatReqs.map((r) => (
        <section key={r.id} className="space-y-2 rounded-2xl bg-amber-400/10 p-3 ring-1 ring-amber-400/30">
          <p className="font-semibold">💺 {r.agency_name} ขอให้ที่นั่งสังกัดแก่คุณ</p>
          <p className="text-xs text-neutral-300">ถ้ายินยอม คุณจะเป็นน้องที่นั่ง (มีป้ายสังกัด) และต้องอยู่ในสังกัดอย่างน้อย {'15'} วันก่อนออกได้ ถ้าไม่ยินยอม คุณยังอยู่ในสังกัดแบบรอที่นั่งและออกได้ทุกเมื่อ</p>
          <div className="grid grid-cols-2 gap-2">
            <button onClick={() => answerSeat(r, true)} className="rounded-xl bg-line py-2 text-sm font-bold text-black active:scale-95">ยินยอม</button>
            <button onClick={() => answerSeat(r, false)} className="rounded-xl bg-white/10 py-2 text-sm active:scale-95">ไม่ยินยอม</button>
          </div>
        </section>
      ))}

      {/* Agency affiliation: she can leave after the waiting period (or when the agency's plan is not active) */}
      {aff && (
        <section className="space-y-2 rounded-2xl bg-white/5 p-3 ring-1 ring-white/10">
          <div className="flex items-center gap-3">
            {aff.logo_path && <img src={logoUrl(aff.logo_path)} alt="" className="h-10 w-10 rounded-full object-cover" />}
            <div className="min-w-0">
              <p className="text-xs text-neutral-400">{t('myAgency')}</p>
              <p className="truncate font-bold">{aff.agency_name}</p>
            </div>
          </div>
          <button disabled={!aff.can_leave} onClick={leaveAgency}
            className="w-full rounded-xl bg-white/10 py-2 text-sm font-semibold active:scale-95 disabled:opacity-40">{t('leaveAgency')}</button>
          {!aff.has_seat && <p className="text-[11px] text-neutral-500">คุณอยู่แบบรอที่นั่ง ออกจากสังกัดได้ทุกเมื่อ</p>}
          {!aff.can_leave && aff.can_leave_at && (
            <p className="text-[11px] text-neutral-500">{t('leaveAgencyFrom', { date: new Date(aff.can_leave_at).toLocaleDateString() })}</p>
          )}
        </section>
      )}

      <BookingContact worker={worker} onSaved={loadWorker} />

      {/* Inbox */}
      <section>
        <h2 className="mb-2 text-base font-bold">{t('jobs')}</h2>
        <WorkerJobs jobs={jobs} reload={loadJobs} highlightId={highlightJob} onError={setError} />
      </section>

      {/* Messages from members (in-app chat; a LINE push with a button to the room is sent by notify-chat, migration_027) */}
      <section>
        <h2 className="mb-2 text-base font-bold">{t('messages')}</h2>
        <ThreadList role="worker" onOpen={(th) => setChat(th)} />
      </section>

      {/* Profile: locked, changes are requests the admin approves */}
      <ProfileSection worker={worker} userId={userId} onChanged={loadWorker} onTopUp={onTopUp} />

      {/* Buying a rank comes last: finish and save the profile first */}
      <RankBoost worker={worker} userId={userId} onTopUp={onTopUp} />

      {chat && <ChatModal threadId={chat.id} title={chat.other_name} meId={userId} onClose={() => setChat(null)} />}
      {recruit && <ShareModal recruit onClose={() => setRecruit(false)} />}
      {showWd && <WithdrawModal onClose={() => setShowWd(false)} onChanged={() => { loadWorker() }} />}
    </div>
  )
}

// What a customer sees ONLY after she accepted a booking. Starts as what she wrote in her application; she can change it any time.
function BookingContact({ worker, onSaved }) {
  const { t } = useI18n()
  const [phone, setPhone] = useState(worker.booking_phone ?? '')
  const [line, setLine] = useState(worker.booking_line_id ?? '')
  const [busy, setBusy] = useState(false)
  const [msg, setMsg] = useState(null)
  const input = 'mt-1 w-full rounded-xl bg-white/10 px-3 py-2 text-base outline-none ring-1 ring-white/10 focus:ring-line'
  async function save() {
    setBusy(true); setMsg(null)
    const { error } = await supabase.rpc('update_my_booking_contact', { p_phone: phone, p_line_id: line })
    setBusy(false)
    setMsg(error ? t(error.message.includes('BAD_PHONE') ? 'errBadPhone' : 'errGeneric') : t('saved'))
    if (!error) onSaved?.()
  }
  return (
    <section className="space-y-2 rounded-2xl bg-white/5 p-3 ring-1 ring-white/10">
      <h2 className="text-sm font-bold">📞 {t('bcTitle')}</h2>
      <p className="text-[11px] text-neutral-400">{t('bcHint')}</p>
      <div className="grid grid-cols-2 gap-2">
        <label className="block text-xs">{t('fPhone')}<input type="tel" inputMode="tel" maxLength={20} value={phone} onChange={(e) => setPhone(e.target.value)} className={input} /></label>
        <label className="block text-xs">{t('fLineId')}<input maxLength={40} value={line} onChange={(e) => setLine(e.target.value)} className={input} /></label>
      </div>
      <button onClick={save} disabled={busy} className="w-full rounded-xl bg-white/10 py-2 text-sm font-semibold active:scale-95 disabled:opacity-50">{t('saveChanges')}</button>
      {msg && <p className="text-xs text-amber-200">{msg}</p>}
    </section>
  )
}
