# LINE LIFF Booking App

Vite + React + Tailwind + Supabase + LINE LIFF. Customers pay a 500 THB platform
fee from an in-app wallet; the service fee is paid in cash to the worker.

```
supabase/schema.sql              Tables, triggers, RLS, column grants   (Part 1)
supabase/seed.sql                Dev-only demo workers
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
- **Not implemented (needs product decisions):** refunds on cancel/decline, wallet transaction
  ledger, worker-side job inbox, partner commission reporting, payment/top-up flow.
- Restrict CORS in `line-auth` to your Pages origin, and ensure your use case complies with LINE's
  Official Account / LIFF terms of service and Thai law for the services offered.
