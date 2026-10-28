# LINE LIFF Booking App

Vite + React + Tailwind + Supabase + LINE LIFF. Customers pay a 500 THB platform
fee from an in-app wallet; the service fee is paid in cash to the worker.

```
supabase/schema.sql              Tables, triggers, RLS, column grants   (Part 1)
supabase/seed.sql                Dev-only demo workers
supabase/migration_002.sql       Categories, membership tiers, photo storage, worker apps (run after schema.sql)
supabase/seed2.sql               Dev-only: 21 more demo workers (tests the top-10 free limit)
supabase/migration_003.sql       Remove ENT Plus, rename Spa, service area, members-only chat (run after migration_002)
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

| Plan | Sees |
|---|---|
| Free | Bartender + ENT, only the top 10 of each category |
| VIP 100 | Bartender + ENT, everyone |
| VIP 200 | + Masseuse |
| VIP 300 | Everything (incl. Spa) |

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
