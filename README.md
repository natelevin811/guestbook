# FreeWindow 📅

Four friends connect their calendars once. A scheduled job finds windows where
**everyone is free** and pings the group on Telegram so they can actually hang.

Designed for a small, high-trust friend group (starts at 4, not hardcoded to 4).
It only ever reads **free/busy** times — never event titles or details.

> Note: this lives in the `guestbook` repo (repurposed). Nothing of the old
> guestbook app remains.

---

## How it works

1. A friend opens the connect page and taps **Connect Google Calendar**.
2. The OAuth callback stores their **encrypted refresh token** in Supabase.
3. A weekly Vercel Cron job refreshes each token, pulls `freebusy` for everyone
   over the next 14 days, and computes the windows where all of them are free
   inside "hangable hours" (≥ 90 min).
4. New windows (not previously sent) get posted to the group's Telegram chat.
5. Anyone can reply `/stop` to mute the digest.

The overlap engine is the heart of the project and is fully unit-tested
(`npm test`). The two integration points — **calendar in** (Google freebusy)
and **messages out** (Telegram) — are deliberately the cheapest working version.

---

## Project layout

```
api/
  connect.js            GET  /api/connect?name=…   → redirect to Google consent
  oauth/callback.js     GET  /api/oauth/callback   → store encrypted refresh token
  cron/digest.js        GET  /api/cron/digest      → the scheduled digest job
  telegram/webhook.js   POST /api/telegram/webhook → /stop /start /windows /ping
  members.js            GET  /api/members          → who's connected (names only)
lib/
  overlap.js            interval math + hangable-hours + MIN_DURATION  (the engine)
  config.js             tunables (timezone, lookahead, hangable hours, min duration)
  google.js             OAuth + freebusy.query via fetch
  digest.js             gather busy → compute → dedupe → notify
  format.js             window hashing (dedupe) + human message copy
  telegram.js           sendMessage
  crypto.js             AES-256-GCM for refresh tokens at rest
  state.js              HMAC-signed OAuth state
  supabase.js           service-role client
  ics.js                best-effort ICS fallback (Apple/Outlook friends)
index.html, app.js, style.css   the one-button connect page
supabase/migrations/    app_users, sent_windows, mutes
test/                   node --test unit tests
scripts/run-digest.js   run the digest locally
```

---

## Setup (v1)

### 1. Supabase
- Create a project. Run the migration in `supabase/migrations/` (via
  `supabase db push` or paste the SQL into the SQL editor).
- Grab `SUPABASE_URL` and the **service role** key (Project Settings → API).

### 2. Google Cloud
- New project → **OAuth consent screen**, publishing status **Testing**.
  Add your friends as **test users** (no Google verification needed under 100).
- **Credentials → Create OAuth client ID → Web application.**
  Authorized redirect URI: `https://<your-app>.vercel.app/api/oauth/callback`.
- Copy the client id + secret.
- Scope used: `calendar.freebusy` (+ `openid`/`email` to label members). The app
  only ever sees busy blocks.

### 3. Telegram
- Talk to [@BotFather](https://t.me/BotFather) → `/newbot` → copy the token.
- Add the bot to your group chat.
- Find the group `chat_id` (e.g. send a message, then GET
  `https://api.telegram.org/bot<TOKEN>/getUpdates`, look for `chat.id` — group
  ids are negative).
- Register the webhook for the mute/opt-out path:
  ```
  curl "https://api.telegram.org/bot<TOKEN>/setWebhook?url=https://<your-app>.vercel.app/api/telegram/webhook&secret_token=<TELEGRAM_WEBHOOK_SECRET>"
  ```

### 4. Encryption key
```
openssl rand -hex 32     # → TOKEN_ENC_KEY
```

### 5. Vercel
- Import the repo. Set every env var from `.env.example` in Project Settings.
- The weekly cron is declared in `vercel.json` (`Sun 12:00 UTC ≈ 8am ET`).
  Set `CRON_SECRET` so the endpoint is protected; Vercel Cron sends it
  automatically.
- Deploy. Share `https://<your-app>.vercel.app` with your friends.

---

## Environment variables

See [`.env.example`](./.env.example). Summary:

| Var | What |
| --- | --- |
| `PUBLIC_BASE_URL` | deployment URL (used to build the OAuth redirect) |
| `GOOGLE_CLIENT_ID` / `GOOGLE_CLIENT_SECRET` | OAuth client |
| `SUPABASE_URL` / `SUPABASE_SERVICE_ROLE_KEY` | database (service role, server-only) |
| `TOKEN_ENC_KEY` | 32-byte hex key encrypting refresh tokens |
| `TELEGRAM_BOT_TOKEN` / `TELEGRAM_CHAT_ID` | bot + target group |
| `TELEGRAM_WEBHOOK_SECRET` | verifies incoming Telegram webhooks |
| `CRON_SECRET` | protects `/api/cron/digest` |
| `GROUP_TIMEZONE` | default `America/New_York` |
| `LOOKAHEAD_DAYS` | default `14` |
| `MIN_DURATION_MINUTES` | default `90` |
| `HANGABLE_HOURS` | JSON override of per-weekday windows |

---

## Local development

```
npm install
npm test                       # run the unit tests (no network/env needed)

# with a .env file populated:
npm run digest -- --compute    # print current free-for-all windows
npm run digest -- --dry        # compute, but don't send or record
npm run digest                 # compute + send to Telegram + record
```

You can also trigger the cron endpoint manually once deployed:
`GET /api/cron/digest?secret=<CRON_SECRET>` (add `&dry=1` to skip sending).

---

## Tunables

All in `lib/config.js`, overridable by env:

- **Hangable hours** — default weekday evenings 18:00–22:00, weekends
  11:00–22:00, in `GROUP_TIMEZONE`. Override with `HANGABLE_HOURS` (JSON keyed
  by day-of-week, Sunday = 0).
- **Lookahead** — 14 days.
- **Minimum duration** — 90 minutes.

---

## Notes & non-goals

- **Digest, not push-on-change.** Calendars shift constantly; a per-change model
  spams the group. The cron is weekly and `window_hash` dedupe means a window
  that survives between runs isn't re-announced.
- **Apple/Outlook friends.** If someone isn't on Google, give their row an
  `ics_url` (a published private calendar feed) instead of a refresh token. ICS
  parsing is best-effort and does not expand recurring (`RRULE`) events.
- It suggests windows; it does **not** book, RSVP, or hold time.
- SMS (Twilio / 10DLC) is intentionally out of scope for v1 — Telegram ships today.

---

## Build checklist (v1) — status

- [x] `/connect` page with one Google button
- [x] OAuth start + callback storing an **encrypted** refresh token
- [x] Token refresh helper
- [x] `freebusy.query` over a 14-day range
- [x] Overlap algorithm + hangable-hours config + `MIN_DURATION`
- [x] `sent_windows` dedupe via `window_hash`
- [x] Telegram bot `sendMessage` to one group chat
- [x] Vercel cron wired to the weekly digest
- [x] Mute / opt-out path (`/stop`)
- [ ] External setup you do by hand: create the Google/Supabase/Telegram
      projects and set env vars (see Setup above)
