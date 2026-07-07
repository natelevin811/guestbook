// Orchestration: gather everyone's busy time, compute overlap windows, dedupe
// against what we've already announced, and (optionally) push a digest to the
// group's Telegram chat.

const config = require('./config');
const { getSupabase } = require('./supabase');
const { decrypt } = require('./crypto');
const google = require('./google');
const { fetchIcsBusy } = require('./ics');
const { computeOverlapWindows } = require('./overlap');
const { windowHash, buildDigestMessage } = require('./format');
const { sendMessage } = require('./telegram');

// Pull busy intervals for every connected member over [timeMin, timeMax].
// A member connects either via Google (refresh_token) or an ICS feed (ics_url).
// Returns { members: [{ id, name, busy }], errors: [{ name, error }] }.
async function gatherBusy(timeMin, timeMax) {
  const supabase = getSupabase();
  const { data: rows, error } = await supabase
    .from('app_users')
    .select('id, name, google_email, refresh_token, ics_url');
  if (error) throw new Error(`Failed to load members: ${error.message}`);

  const members = [];
  const errors = [];

  for (const row of rows || []) {
    try {
      let busy;
      if (row.refresh_token) {
        const accessToken = await google.refreshAccessToken(decrypt(row.refresh_token));
        busy = await google.queryFreeBusy(accessToken, timeMin, timeMax);
      } else if (row.ics_url) {
        busy = await fetchIcsBusy(row.ics_url, timeMin, timeMax);
      } else {
        continue; // nothing to query for this member
      }
      members.push({ id: row.id, name: row.name, busy });
    } catch (err) {
      errors.push({ name: row.name, error: err.message });
    }
  }
  return { members, errors };
}

// Compute the current free-for-all windows (read-only, no DB writes / sends).
async function computeWindows(now = Date.now()) {
  const timeMin = now;
  const timeMax = now + config.LOOKAHEAD_DAYS * 24 * 60 * 60 * 1000;
  const { members, errors } = await gatherBusy(timeMin, timeMax);

  const windows = computeOverlapWindows(members, {
    now,
    lookaheadDays: config.LOOKAHEAD_DAYS,
    timezone: config.GROUP_TIMEZONE,
    hangableHours: config.HANGABLE_HOURS,
    minDurationMinutes: config.MIN_DURATION_MINUTES,
  });

  return { windows, members, errors };
}

async function isMuted(chatId) {
  const supabase = getSupabase();
  const { data } = await supabase
    .from('mutes')
    .select('muted')
    .eq('chat_id', String(chatId))
    .maybeSingle();
  return Boolean(data?.muted);
}

// Full digest run: compute, dedupe against sent_windows, send the new ones.
// opts.send (default true) — actually post to Telegram.
// opts.record (default true) — persist newly-announced windows for dedupe.
async function runDigest(opts = {}) {
  const { send = true, record = true, now = Date.now() } = opts;
  const supabase = getSupabase();

  const { windows, members, errors } = await computeWindows(now);

  if (members.length === 0) {
    return { status: 'no-members', windows: [], newWindows: [], errors };
  }

  // Dedupe: drop windows we've already announced.
  const hashed = windows.map((w) => ({ ...w, hash: windowHash(w) }));
  const hashes = hashed.map((w) => w.hash);

  let alreadySent = new Set();
  if (hashes.length > 0) {
    const { data: existing } = await supabase
      .from('sent_windows')
      .select('window_hash')
      .in('window_hash', hashes);
    alreadySent = new Set((existing || []).map((r) => r.window_hash));
  }
  const newWindows = hashed.filter((w) => !alreadySent.has(w.hash));

  const chatId = process.env.TELEGRAM_CHAT_ID;
  let sent = false;
  let muted = false;

  if (newWindows.length > 0) {
    const message = buildDigestMessage(newWindows, config.GROUP_TIMEZONE);

    if (send && chatId) {
      muted = await isMuted(chatId);
      if (!muted) {
        await sendMessage(chatId, message);
        sent = true;
      }
    }

    if (record) {
      const payload = newWindows.map((w) => ({
        window_hash: w.hash,
        start_at: w.start,
        end_at: w.end,
      }));
      // Ignore conflicts in case two runs race.
      await supabase.from('sent_windows').upsert(payload, { onConflict: 'window_hash', ignoreDuplicates: true });
    }
  }

  return {
    status: 'ok',
    memberCount: members.length,
    windowCount: windows.length,
    newWindowCount: newWindows.length,
    sent,
    muted,
    errors,
    newWindows: newWindows.map((w) => ({ start: w.start, end: w.end })),
  };
}

module.exports = { runDigest, computeWindows, gatherBusy, isMuted };
