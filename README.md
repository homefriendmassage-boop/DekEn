# LINE LIFF Booking App

Vite + React + Tailwind + Supabase + LINE LIFF. Customers pay a 500 THB platform
fee from an in-app wallet; the service fee is paid in cash to the worker.

```
supabase/schema.sql              Tables, triggers, RLS, column grants   (Part 1)
supabase/seed.sql                Dev-only demo workers
supabase/migration_002.sql       Categories, membership tiers, photo storage, worker apps (run after schema.sql)
supabase/seed2.sql               Dev-only: 21 more demo workers (tests the top-10 free limit)
supabase/migration_003.sql       Remove ENT Plus, rename Spa, service area, members-only chat (run after migration_002)
supabase/migration_004.sql       Multi-category providers, phone + LINE ID, editable applications, promo photo (run after 003)
supabase/migration_005.sql       Admin back office: admins, payment ledger, review/payment functions (run after 004)
supabase/migration_006.sql       LINE profile picture + last seen; admin user list shows recent users (run after 005)
supabase/migration_007.sql       Automatic payment: unique-amount requests, slip ledger (run after 006)
supabase/migration_008.sql       Idempotent admin payment entry: double tap can't apply twice (run after 007)
supabase/migration_009.sql       Slip review (amount mismatch -> admin) + support chat with admin (run after 008)
supabase/migration_010.sql       Per-role chat lists, self-chat error, renewal notice ledger (run after 009)
supabase/migration_011.sql       Payment requests are reusable (same amount when you come back); late slips go to review (run after 010)
supabase/migration_012.sql       Upgrade by paying the difference (same expiry); admin cancel/change plan + suspend accounts (run after 011)
supabase/migration_013.sql       Suspended providers are hidden from the feed and cannot be booked/chatted (run after 012)
supabase/migration_014.sql       Two balances (Wallet + Bonus) and a ledger of every money movement (run after 013)
supabase/migration_015.sql       Share links (link/Flex/QR), sales attribution, 20% membership referral reward, pay packages from the Wallet (run after 014)
supabase/migration_016.sql       Paid chat: 40 THB hold -> 30 to the provider / 10 platform when they reply, refund after 3 h (run after 015)
supabase/migration_017.sql       Bonus -> Wallet after 30 inactive days; optional 6-month Wallet expiry (off by default) (run after 016)
supabase/functions/send-renewal/ Edge Function (admin only): LINE Flex renewal reminder with a button to the plan picker
supabase/functions/verify-slip/  Edge Function: verifies the slip with Thunder, opens the plan / credits the wallet
admin.html + src/admin/          Separate admin page (not linked from the customer app)
supabase/functions/line-auth/    Edge Function: LIFF ID token -> Supabase session
src/lib/auth.js                  LIFF init, ?ref capture, mock login    (Part 2)
src/App.jsx                      App shell, data loading, realtime      (Part 2)
src/supabaseClient.js
src/components/HomeFeed.jsx      Feed, VIP blur, Top Rank badge         (Part 3)
src/components/BookingModal.jsx  Deposit explainer + Confirm Booking    (Part 3)
```

## Run locally (mock login, no LINE needed)

1. **Supabase**: create a project. SQL Editor → run `supabase/schema.sql`, then `supabase/seed.sql`.
   Authentication → Providers → enable **Allow anonymous sign-ins** (mock login uses it).
2. `cp .env.example .env.local` and fill in `VITE_SUPABASE_URL` / `VITE_SUPABASE_ANON_KEY`
   (Project Settings → API). Keep `VITE_USE_MOCK_LIFF=true`.
3. `npm install && npm run dev`, open the printed URL (use phone-size devtools).
4. Try attribution: `http://localhost:5173/?ref=sales01` — the yellow dev bar shows the captured ref.
5. Fund the mock user to test booking: in SQL Editor,
   `update public.users set wallet_balance = 2000 where line_user_id like 'U_mock_%';`
   (and `set is_vip = true` to see unblurred photos, or use the dev bar's "Preview as VIP").
   To test attribution, make a partner:
   `update public.users set role='partner', partner_ref_code='sales01' where id='<some user id>';`

## Run inside LINE

1. [LINE Developers Console](https://developers.line.biz/) → Provider → create a **LINE Login** channel
   (enable *OpenID Connect* / email not required) → **LIFF** tab → Add app.
   - Endpoint URL: your deployed HTTPS URL (e.g. `https://<user>.github.io/<repo>/`) — or an
     `ngrok`/Cloudflare tunnel URL while developing. Scope: `profile openid`.
   - Copy the LIFF ID → `VITE_LIFF_ID`; set `VITE_USE_MOCK_LIFF=false`.
2. Deploy the Edge Function (needs the [Supabase CLI](https://supabase.com/docs/guides/cli)):
   ```
   supabase link --project-ref <ref>
   supabase functions deploy line-auth --no-verify-jwt
   supabase secrets set LINE_CHANNEL_ID=<LINE Login Channel ID> PASSWORD_PEPPER=$(openssl rand -hex 32)
   ```
3. Link the LIFF URL from your LINE OA (rich menu / message). Partner links look like
   `https://liff.line.me/<LIFF_ID>?ref=sales01`.

## Deploy to GitHub Pages

1. Push this folder to a GitHub repo whose default branch is `main`.
2. Settings → Pages → **Source: GitHub Actions**.
3. Settings → Secrets and variables → Actions → add secrets
   `VITE_SUPABASE_URL`, `VITE_SUPABASE_ANON_KEY`, `VITE_LIFF_ID`.
4. Push to `main`. `.github/workflows/deploy.yml` builds with `VITE_BASE=/<repo>/` and publishes.
5. Put the resulting URL into the LIFF app's **Endpoint URL**.

## Things to know before going live

- **Wallet is server-authoritative.** Clients cannot write `wallet_balance`, `role`, `is_vip`, or
  `is_boosted` (column grants). The `jobs` insert trigger checks and deducts the fee atomically
  and ignores the client-sent fee. Top-ups/VIP/boost must be done by an admin or a payment webhook
  using the service role (not built yet).
- **VIP blur is cosmetic.** The image URL is still downloadable. Serve blurred thumbnails to
  non-VIPs for real protection.
- **Not implemented (needs product decisions):** wallet top-up / membership payment, wallet transaction
  ledger, notifying providers via LINE push, partner commission reporting.
- Restrict CORS in `line-auth` to your Pages origin, and ensure your use case complies with LINE's
  Official Account / LIFF terms of service and Thai law for the services offered.

## Categories, membership, providers (migration_002)

Run `supabase/migration_002.sql` once after `schema.sql`, then `migration_003.sql` (and optionally `seed2.sql`).

| Plan | Price | Sees |
|---|---|---|
| Free | 0 | Bartender + ENT, only the top 10 of each category |
| 🥇 Gold (tier 1) | 100 | Bartender + ENT, everyone |
| 💠 Platinum (tier 2) | 200 | + Masseuse |
| 💎 Diamond (tier 3) | 300 | Everything (incl. Spa) |

Plan names/looks live in `PLAN_META` in `src/config.js` (the database only knows tier 1/2/3).

Each plan lasts 30 days. Payment is manual for now; activate / extend from the SQL Editor:

```sql
select public.set_membership('<user id>', 1, 30);   -- tier 1/2/3, days
```

Providers: the user taps **Apply** in the app, which creates a row in `worker_applications`; you approve it:

```sql
select id, display_name, category, contact from public.worker_applications where status = 'pending';
select public.approve_worker('<application id>');
```

Photos: the provider drops a circle over their face; the browser mosaics that area for the public
photo (`worker-public` bucket) and stores the full photo in the private `worker-originals` bucket,
which only members allowed to see that provider can read (signed URL). Optional env:
`VITE_LINE_OA_URL` (admin contact link shown in the membership sheet).

A pending job that is declined or cancelled is refunded to the customer's wallet; an accepted job
that is cancelled is not (handle manually).

## Service area and chat (migration_003)

- Providers choose a province (+ district and nearby areas) when applying; customers can filter the feed by province.
- **Chat is in-app and members-only** (paid, unexpired VIP, and only with providers that member may view).
  It deliberately does not push to LINE: a LINE OA *push* message counts against the OA's monthly
  quota (reply messages are free but need a recent message from that user), so per-message LINE alerts
  would cost money. Providers see unread counts when they open the app. Limits: 500 chars/message,
  10 messages/minute. A lapsed member can read old chats but not send.

## Applications and multi-category (migration_004)

Run `migration_004.sql` after 003. Order for a fresh project: `schema` -> `migration_002` -> (`seed`, `seed2`) -> `migration_003` -> `migration_004`.

- A provider can work in several categories; they appear in each category's feed (rank is per category).
  Categories are fixed at approval (change them as admin: `update public.workers set categories = '{ent,spa}' where user_id = '...'`).
- Applicants give phone and LINE ID separately (at least one). These stay private to the admin and are
  never copied to the public provider profile.
- While an application is `pending` the applicant can edit it and upload a promo photo (face mosaic, same as providers).
  Approval carries the photo over.

## Admin page (migration_005)

Separate page: `https://<user>.github.io/<repo>/admin.html` (also reachable as
`https://liff.line.me/<LIFF_ID>/admin.html`; on a computer, open the first URL and log in with LINE).

1. Run `migration_005.sql`.
2. Open the customer app once with your LINE account so your `users` row exists, then make yourself admin:
   ```sql
   select id, display_name from public.users;                       -- find your id
   insert into public.admins (user_id) values ('<your id>');
   ```
3. Open `admin.html`. Anyone not in `public.admins` sees "no access"; every `admin_*` function also
   checks this server-side.

What it does: review applications (see contact details and the un-mosaicked photo, approve or reject with a
reason the applicant sees); record verified payments (membership or wallet top-up) in a ledger that also applies
them in one step; duplicate transfer references are rejected; list active members with expiry and renew them.
Payments are recorded by the admin after checking a slip/bank statement; there is no automatic payment
gateway or customer slip upload yet.

## Automatic payment (migration_007 + `verify-slip`)

Flow: the customer taps a plan (or the wallet chip) -> the server creates a payment request with a unique amount
(e.g. 100.37) -> the app shows a PromptPay QR with that amount pre-filled -> they pay and attach the slip ->
the browser reads the slip's QR text -> the `verify-slip` Edge Function asks Thunder (`POST /v2/verify/bank`) ->
if the slip is genuine, paid **to your account**, for **exactly** that amount, and its transfer reference was never used,
the plan opens (or the wallet is credited) in one database transaction.

Setup:
1. Run `supabase/migration_007.sql`.
2. Deploy the function `verify-slip` (Edge Functions > Via Editor, paste `supabase/functions/verify-slip/index.ts`, turn **off** Verify JWT).
3. Edge Functions > Secrets: `THUNDER_API_KEY`, plus `RECEIVER_NAME_CONTAINS` (text that must appear in the receiver
   name on the slip) and/or `RECEIVER_ACCOUNT_DIGITS` (visible digits of your account number); optionally `RECEIVER_BANK`
   (e.g. `KBANK`). The bank code alone is refused: it would accept a slip paid to any account at that bank.
4. GitHub secrets: `VITE_PROMPTPAY_ID` (PromptPay phone / 13-digit ID / e-wallet ID; gives a QR with the amount filled in) and/or
   `VITE_BANK_NAME`, `VITE_BANK_ACCOUNT_NO`, `VITE_BANK_ACCOUNT_NAME` (shows your account with copy buttons for manual transfer).
   A bank account number alone cannot make a PromptPay QR; register the account with PromptPay (phone / ID) to get one.
   Optional: `VITE_LINE_OA_URL`.
5. Make one small real test payment, then check **Admin > Payments > failed slips** to tune the receiver check.

Safety: the Thunder key stays server-side; amounts come from a server-side price list; a slip can't be replayed
(unique amount per open request + unique transfer reference); 8 attempts/hour/user protect your Thunder quota;
every failed attempt is listed for the admin, who can still record a payment by hand.
Only bank-transfer slips are supported (not TrueMoney wallet slips).

Manual payment entry is idempotent (migration_008): every submit carries a request id; a double tap or retry is refused with
"already recorded" and nothing changes. The form clears after a save, so the next one is a new entry. If an entry was
recorded twice before this fix, remove the extra one by hand:

```sql
select id, created_at, amount from public.payments where user_id = '<user id>' order by created_at;
delete from public.payments where id = '<the duplicate payment id>';
update public.users set vip_expires_at = vip_expires_at - interval '30 days' where id = '<user id>';   -- membership duplicate
-- wallet duplicate: update public.users set wallet_balance = wallet_balance - <amount> where id = '<user id>';
```

## Slip outcomes, review and support chat (migration_009)

| Slip | Result |
|---|---|
| duplicate / fake or unverifiable / wrong receiver account or name | refused: the customer attaches a new slip |
| genuine, paid to our account, but the amount matches no open request | sent to the admin (Admin > Slip review) and a popup offers the chat with the admin |
| amount matches | plan opened / wallet credited automatically |

A slip under review can never also be auto-approved (its transfer reference is reserved). The admin approves (choosing
plan/days or a wallet credit; the slip amount is what is recorded) or rejects with a reason; the customer gets a message in
their support chat either way. Support chat is in-app (Realtime), open to every user (a free user paying for the first
time needs it) and does not push to LINE. Redeploy `verify-slip` after this migration: it now routes mismatches to review.

## Renewal reminders (migration_010 + `send-renewal`)

Admin > Members > **📣 แจ้งต่ออายุ** sends the customer a LINE Flex Message ("your Gold plan ends in N days") whose
button opens `https://liff.line.me/<LIFF_ID>?open=plans` (the app opens the plan picker). There is also a bulk button for
everyone ending within 7 days. This is a LINE **push** message: it uses the OA's monthly message quota, and only reaches
users who added the OA as a friend and haven't blocked it. Duplicates are suppressed (24 h single, 3 days bulk).
Secrets for the function: `LINE_CHANNEL_ACCESS_TOKEN` (Messaging API channel of the OA, same LINE provider as the LIFF app) and `LIFF_ID`.

## Coming back after paying (migration_011)

`create_payment_intent` returns the SAME open request (same amount, same expiry) when the customer asks again for the same plan
or top-up amount, so leaving the app to transfer and returning never changes the amount to match. A different plan makes a
different request (the earlier one stays valid; at most 2 older ones are kept). A genuine slip that arrives after the request
expired is not rejected: it goes to Admin > Slip review, linked to the customer's latest request of the last 24 hours.

## Upgrades, cancelling and suspending (migration_012)
- **Upgrade**: a member on Gold who picks Platinum pays only the price difference (e.g. 200 − 100 = 100). The slip is verified automatically like any payment and the plan changes immediately; the **expiry date stays the same**. Buying a lower plan than the active one is refused (`ALREADY_HIGHER`). If the lower plan lapsed before the slip arrived, the slip goes to admin review.
- **Admin → สมาชิก → ⚙️ จัดการ** (or search any user): set a plan + expiry date (fixes a wrong upgrade), cancel the plan now, or suspend the account for 3/7/30 days or permanently (can be lifted). A reason is required and every action is stored in `membership_events`.
- A suspended account sees a "suspended" screen, loses membership benefits, cannot book, pay or chat with providers, but can still chat with the admin. Admin accounts cannot be suspended. Refunds are not automatic.
- **Suspending a provider** (migration_013): same ⚙️ จัดการ button (search the provider by name). They disappear from the feed, can't be booked or messaged by customers, and stop taking a rank slot; lifting the suspension restores them.

## Wallets and ledger (migration_014)
- **Wallet** (`wallet_balance`): top-ups; pays for packages, bookings and chat; not withdrawable. **Bonus wallet** (`bonus_balance`): referral fees, commissions and chat income; moved one way into the Wallet (a withdrawal flow comes later: min 200, fee 20).
- Every change of either balance is written to `wallet_ledger` by a trigger on `users`, so no code path can move money without a trace. Code that changes a balance sets `app.ledger_kind` / `app.ledger_ref` / `app.ledger_note` first (see `jobs_before_insert`, `apply_slip_payment`, `transfer_bonus_to_wallet`).
- Customers see both balances and their history by tapping the 💰 chip. Admins correct a balance with `admin_adjust_balance(user, 'wallet'|'bonus', ±amount, reason)` (reason required, ledgered).
- Existing balances get an `opening` ledger row, so the ledger always adds up to the balance.

## Sharing, sales and referral rewards (migration_015)
- Everyone has a share code (`my_share_code()`); the link is `https://liff.line.me/<LIFF_ID>?ref=<code>`. 💰 → "ชวนเพื่อน" offers copy, QR and a LINE Flex message (share target picker; enable it in the LIFF settings).
- **Whose customer is this?** (`users.referred_by` = the customer's *sales*). Registering through a link makes that person the sales at once. A later click on another link (`referral_clicks`) takes over only if the customer pays for a package (or books) within **24 hours** of the click; otherwise it is forgotten. Top-ups never change it, existing accounts are not re-attributed retroactively. The latest link wins.
- **Reward:** every membership payment (slip, admin, wallet) pays 20% to the sales' bonus wallet (`referral_rewards`, one per payment, rate in `referral_membership_rate()`), unlimited renewals.
- **Pay from the Wallet:** `buy_membership_with_wallet(tier)` — new, renew or upgrade (difference, same expiry). Always allowed while the Wallet has enough money.

## Paid chat (migration_016)
- The customer's first message of a conversation sets 40 THB aside from the Wallet (consent popup; the server refuses without `p_accept_fee`). The provider's first valid reply within 3 hours (>= 2 letters/digits, not one repeated character; emoji and punctuation ignored) settles it: 30 THB to the provider's bonus wallet, 10 THB stays with the platform (`chat_fees.platform_amount`). The conversation is then free for 24 hours; after that the next message sets 40 THB aside again.
- No valid reply within 3 hours: the 40 THB returns to the Wallet. This happens when either side opens the chat, when the wallet or app is opened, and every 10 minutes if **pg_cron** is enabled (Supabase: Database > Extensions > pg_cron, then run migration_016 again or `select cron.schedule('release-chat-holds','*/10 * * * *','select public.release_expired_chat_holds()')`).
- A booking the provider accepts opens the chat for 72 hours at no charge (a pending hold counts as settled by the acceptance).
- All amounts and hours live in the small `chat_*()` functions at the top of the migration.

## Inactivity rules (migration_017)
- **Bonus -> Wallet:** a customer whose membership has expired and who has not renewed or paid in for 30 days (counted from the later of the expiry date and the last payment; from sign-up if there is no history) has the whole bonus balance moved into the Wallet by a daily job (`sweep_inactive_bonus`). Providers are exempt. The app warns with the date.
- **Wallet expiry (OFF by default):** after 6 months with no top-up / package / booking / chat fee / payment the Wallet balance is written off as `wallet_expired` in the ledger (`expire_inactive_wallets`). Have a lawyer review the terms first, then enable with `update public.app_settings set value = 'true' where key = 'wallet_expiry_enabled';` (also exposed as `admin_set_setting`). Turning it on shows the terms next to top-ups and the expiry date in the wallet screen.
- Both jobs are scheduled with pg_cron when it is enabled (Database > Extensions); otherwise call the functions from any scheduler.

## Booking fee sharing and agencies (migrations 018 and 019)
- **018** — when a provider accepts a booking the 500 THB fee is shared: 40% to her *recruiter* (whoever's link she came through; 90 days from approval, renewed automatically for another 90 when she had at least one booking in the 30 days before the window ended), 40% to the customer's *sales*, 20% platform. Unowned shares stay with the platform. Shares go to the bonus wallet (`booking_shares`, ledger kinds `booking_share_recruiter` / `booking_share_sales`). A pending booking that is declined is refunded in full. `my_earnings()` feeds the "earnings by source" box in the wallet screen.
- **019** — modelling agencies (`agencies`): the agency applies (name + logo), an admin approves (admin tab 🏢 สังกัด), the agency pays 1,000 THB / 30 days from its Wallet (10 girls included, +200 per extra girl: `agency_pay_plan`, `agency_buy_slot`). Girls open `?agency=<code>`, apply with their own LINE account, the agency confirms (`agency_review_girl`), an admin approves as usual. Agency girls show the agency logo on their card; while the plan is inactive (or the agency suspended) they are hidden. The agency is the recruiter (40%, `agency_share`) for its girls for as long as they belong to it, can read and answer their chats (the 30 THB chat income still goes to the girl), can remove a girl any time; a girl can leave only after the plan period ended (`worker_leave_agency`). Agency back office = "🏢 โมเดลลิ่ง / สังกัด" on the landing screen (Thai only). The logo is only changeable while the application is pending/rejected.

## Agency joining, simplified (migration_020)
- A girl who applies through an agency's own link is accepted by that agency automatically (only the admin's profile approval remains). If the agency has no free place (10 included + paid slots) the application is refused until the agency buys a slot. There is no "self / agency" choice and no code typing: the link decides; "apply on my own" ignores the link.
- She can leave from `agency_leave_days` (default 15, `app_settings`) after joining, or at any time once the agency plan is inactive, and then stays online on her own. To come back (or for an already approved independent girl to join) the agency sends the link again and she taps "accept" (`worker_join_agency`): no application, no admin step.
- The agency can withdraw a girl whose profile is waiting for approval and remove any girl at any time.

## Paid ranking and slip reading (migration_021)
- **Buy a rank** (provider dashboard, "ซื้ออันดับ"): block A = positions 1-4 at 90 THB/day, B = 5-8 at 60, C = 9-12 at 30; 1 / 3 / 7 days (7 days = pay for 5); 4 places per block and category; one block per category at a time (buying the same block extends it). Paid from the bonus wallet first, the rest from the Wallet (`rank_boost` in the ledger). A bought place is a fixed position; unsold positions are filled by the normal order (online first, then oldest). Admin-pinned (`is_boosted`) providers stay on top. Prices/capacity live in `rank_block_price()` / `rank_block_capacity()`. The ranking is computed in one place (`ranked_workers()`), which also decides the free "top 10" rule.
- **Slip QR reading** (`src/lib/slipQr.js`): native BarcodeDetector when the browser has it, then jsQR on the whole picture at several sizes, then on the regions where the QR usually sits (enlarged, also contrast-stretched). When a picture still cannot be read the app sends only its size/type to `report_slip_problem()`, shown under "สลิปที่ระบบอัตโนมัติไม่ผ่านล่าสุด" in the admin payments tab (result `CLIENT_NO_QR`).

## Profiles, location and "near me" (migration_022)
- **Profile:** gender (female / male / lgbt), age (20+), height, weight, measurements, presentation tags (`playful, fun_talk, not_picky, sing, dance, drinks, friendly`) plus a free text; **prices**: hourly (`price`, shown as the "from" price) plus optional 4 h / 6 h and up to 5 custom rows in `price_options` (`@4h` / `@6h` are fixed labels, the rest free text). The application requires accepting the terms (entertainment / lawful services only, 20+). Customers get the details only for providers they may open (same rule as the full photo).
- **Location:** the application/profile form asks for the phone's GPS position. The server derives the province from it (nearest provincial seat in `province_centroids`, so the typed province is only a fallback when GPS is refused) and stores the position only **approximately** (snapped to a ~500 m grid + jitter). Customers see at most a distance rounded up to whole km.
- **Near me:** the feed has a "📍 ใกล้ฉัน ≤ 50 กม." toggle (`list_workers_near`, radius up to 100 km, nearest first). The customer's position is used for that request only and never stored.
- **Details page:** the card button is now "ดูรายละเอียดคนนี้"; the page shows photo, facts, tags, text and the price table, with "แชตคุยตรงกับคนนี้" and "จองคนนี้".

## Free faces rotate daily; verified location (migration_023)
- A free (non-subscribed) viewer sees the **clear face of 10 providers per category per day**, and which 10 changes at midnight (Thailand time): a stable daily shuffle (`ranked_workers().free_rank`, seeded by `rotation_day()`), independent of the paid list order. Everyone can open any profile and read the details, tags, text and prices; only the clear photo is withheld (the provider's own face-mosaic is shown instead). Chat needs the membership, booking needs the clear-face right (`can_view_worker`).
- **Location badge:** `loc_verified` is true only when the position came from the phone's GPS. A province typed by hand (or changed later) drops the old GPS point and the profile shows "province self-declared" with a warning, and is left out of "near me".

## Free faces 6-10, agency logo upload (migration_024) and provider-side layout
- **Free viewers' clear faces per category per day:** 6 drawn by the daily shuffle when nobody bought a rank; providers with a bought rank (or admin-pinned) take the clear-face places first (block A, B, C, then purchase time) and the shuffle fills the rest up to 6; more than 6 bought ranks widen it, never above 10 (`ranked_workers().free_rank`).
- **Agency logo upload** failed because a storage upsert needs a SELECT policy too; added `agency-logos_select`. The agency form shows a preview of the chosen logo and the real error text.
- **Provider side** is one screen with two tabs: "สมัครด้วยตัวเอง / โปรไฟล์ของฉัน" and "โมเดลลิ่ง / สังกัด" (the landing screen has two choices plus the DekN logo). "ซื้ออันดับ" sits at the very bottom, after the profile and photo; if the balance is short a popup offers the Wallet top-up.
- **Photo mosaic:** only the yellow circle is draggable (touch-action none on the circle alone), the photo is capped to ~52% of the screen height and the page keeps bottom padding, so swiping elsewhere scrolls the page and tapping the photo no longer moves the circle.

## Controlled provider profiles (migration_025)
- **Applying:** the form needs 1-5 promo pictures (picked and mosaicked on the phone, uploaded right after the application is created) so the admin reviews them with the form. Pictures live in `profile_photos` (`application` / `live` / `pending_add`); live picture no. 1 is the card photo (`workers.profile_image`).
- **Age:** `approve_worker` refuses (`AGE_NOT_VERIFIED`) until the admin recorded how the age was confirmed (`admin_verify_age`: photo / video call / in person / ID card). If unsure the admin asks for an ID + selfie (`admin_request_age_proof`, the applicant sends them with `submit_age_proof` into the private bucket `id-docs`, only admins can open them, and the admin's confirm button can delete the files; the paths are cleared from the database on confirmation).
- **Locked profile:** after approval a provider can only switch online/offline directly (`workers` column grants). Everything else is an **edit request** (`submit_profile_edit`: changed fields + photos to add/remove, max 5 live photos) that an admin approves or rejects (admin tab ✏️ แก้ไข/ลบโปรไฟล์; the live profile stays until then). The first approved request is free, each later request costs 20 THB from the Wallet at submission (refunded when rejected or cancelled); the admin is told through the support chat, the provider is notified there too.
- **Remove me:** `request_profile_deletion` hides the profile at once (blocked while a booking is pending/accepted); an admin removes it, otherwise `process_profile_deletions()` (pg_cron, hourly, also run when an admin opens the list) removes it after 24 h: the profile is blanked and soft-deleted, the user becomes a customer again and can re-apply. Files in storage are not removed by the automatic path.

## migration_026 — starting rate, nicer Flex, share a provider

Run `supabase/migration_026.sql` once, after migration_025.

- **Starting rate (mandatory):** a provider ticks which rate a first hire starts at (1 hour / 4 h / 6 h / one of her own rows). Stored in `workers.start_rate` / `worker_applications.start_rate`; the feed card shows "from <that price>", the details page marks the row; changing it later goes through an admin-approved profile edit.
- **Invite Flex:** hero picture with the DekN logo (`public/flex-hero.jpg`, `public/dekn-logo.jpg` are served with the site so LINE can fetch them over https).
- **Share this provider:** button on the details page (Flex only, needs the LIFF share target picker). The card carries her public (face-mosaicked) photo and details, never price or location. The button opens `?ref=<my code>&worker=<id>`; the app asks the viewer to add the official account as a friend first (`liff.getFriendship`, needs `VITE_LINE_OA_URL`) and then opens that profile through `get_worker()`, which applies the usual visibility rules. In the LIFF settings also set "Add friend option" to On (normal/aggressive) and link the official account.

## migration_027 — one price is enough, chat push, bonus card, expired LINE login

Run `supabase/migration_027.sql` once, after migration_026.

- **Prices:** only one rate has to be filled in (4 h / 6 h / hourly / own rows). Every rate is a `price_options` row (`1h`, `@4h`, `@6h`, own label); the first hire starts at the ticked row, else the first filled in the order 4 h → 6 h → hourly → own rows. `workers.price` always mirrors the starting rate (bookings and the feed read it). Existing hourly prices are moved into `price_options` as the `1h` row.
- **Chat push (Flex):** trigger `notify_chat_message` on `chat_messages` calls the Edge Function `notify-chat` (through pg_net) which pushes a Flex "new message from <name>" with the button "เปิดห้องแชต" → `https://liff.line.me/<LIFF_ID>?chat=<thread id>`. At most one push per chat and recipient every 10 minutes (`chat_push_log`), so the OA's push quota is not eaten by every line.
  Setup (once): deploy `supabase/functions/notify-chat` with "Verify JWT" OFF; Edge Function secrets `LINE_CHANNEL_ACCESS_TOKEN`, `LIFF_ID`, `CHAT_NOTIFY_SECRET` (any long random text) and optional `APP_URL`; then in the SQL Editor run
  `select public.configure_chat_notify('https://<project>.supabase.co/functions/v1/notify-chat', '<the same CHAT_NOTIFY_SECRET>');`
- **Provider money card:** the provider dashboard shows the Bonus wallet and the Wallet, a history button and a withdraw button (withdrawals themselves are step 6, still on hold).
- **"The access token expired":** `signIn()` now logs out of LIFF and logs in again when LINE says the login ticket is expired.

## migration_028 — no contact details in chat or profile text

Run `supabase/migration_028.sql` once, after migration_027. `contact_problem(text)` returns `NUMBER`, `LINK`, `HANDLE`, `WORD` or null. It blocks 9+ digits in a row (Thai digits, full-width digits, number words in Thai/English, separators `space . - _ ( ) +`), every link except Google Maps (`maps.app.goo.gl`, `maps.google.com`, `google.com/maps`, `goo.gl/maps`; the host must end there), `@handles`, e-mail and words like line id / whatsapp / telegram / wechat / เบอร์โทร / เลขบัญชี / promptpay.
`send_message` raises `CONTACT_BLOCKED` before any fee is held; `normalize_worker_profile` raises `CONTACT_IN_PROFILE` for the name / about / nearby / district when they are new or changed. Known limits: a number split over several messages or hidden between letters is not caught, and a list of several 4-digit prices separated only by spaces counts as a number.

## migration_029 — fuzzier contact filter

Run `supabase/migration_029.sql` once, after migration_028. Words are matched after removing tone marks and spaces/dots/dashes between letters, and as stems (`เบอ`, `ไอดี`, `ไลน`, `โทรหา/โทรมา`, `line`, `ig`, `fb`, `id:` …; "ออนไลน์" and "เบอร์เกอร์" are excluded). `send_message` also adds up the sender's earlier number-only messages from the last 30 minutes: the message that brings the total to 9 digits is refused (`CONTACT_BLOCKED`).

## migration_030 — chat moderation (flags, reports, admin review, suspension)

Run `supabase/migration_030.sql` once, after migration_029.

- **Flags:** every refused contact attempt (`chat_flag_events`, with the refused text) raises the thread's flag per sender: 1 noted, 2 yellow, 3 orange, 4 red. Red suspends the thread (`chat_threads.status = 'suspended'`): nobody can send, `notify_chat_message` sends no push, and held chat fees are frozen (`release_chat_holds` skips non-open threads). `send_message` now returns text (`OK`, `CONTACT_BLOCKED:<n>`, `THREAD_SUSPENDED`) because a refusal that raised an error would roll the log back.
- **Reports:** `report_thread(thread, reason, note)` (button in the chat window).
- **Admin tab "🚩 แชตที่ติดธง":** queue of flagged / reported / suspended chats; `admin_open_chat` only opens those, needs a written reason and logs every opening (`chat_admin_views`); `admin_chat_action` = suspend / unblock (flag reset, held-fee deadline extended by the frozen time) / close for good (held fee refunded to the customer).
- **Terms:** customers accept the customer terms once (`users.customer_terms_at`, `accept_customer_terms()`); the provider terms and the chat window state that chats may be reviewed only after a complaint, fraud or a suspected rule breach.
