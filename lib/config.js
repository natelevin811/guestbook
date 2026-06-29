// Central config + tunables for FreeWindow.
// Everything here is overridable via env so nothing about "4 friends" or
// "evenings" is hardcoded into the engine.

const LOOKAHEAD_DAYS = parseInt(process.env.LOOKAHEAD_DAYS || '14', 10);
const MIN_DURATION_MINUTES = parseInt(process.env.MIN_DURATION_MINUTES || '90', 10);

// IANA timezone the group lives in. Hangable hours below are expressed in this
// zone; the engine converts to UTC instants (DST-aware) before doing math.
const GROUP_TIMEZONE = process.env.GROUP_TIMEZONE || 'America/New_York';

// Hangable hours: which local-time windows are even worth suggesting.
// Keyed by day of week, Sunday = 0 ... Saturday = 6 (JS getDay convention).
// Each day maps to an array of [startHour, endHour] windows (24h local time).
// Default: weekday evenings 18:00-22:00, weekends 11:00-22:00.
const DEFAULT_HANGABLE_HOURS = {
  0: [[11, 22]], // Sun
  1: [[18, 22]], // Mon
  2: [[18, 22]], // Tue
  3: [[18, 22]], // Wed
  4: [[18, 22]], // Thu
  5: [[18, 22]], // Fri
  6: [[11, 22]], // Sat
};

function loadHangableHours() {
  if (!process.env.HANGABLE_HOURS) return DEFAULT_HANGABLE_HOURS;
  try {
    const parsed = JSON.parse(process.env.HANGABLE_HOURS);
    // normalize keys to numbers
    const out = {};
    for (const k of Object.keys(parsed)) out[Number(k)] = parsed[k];
    return out;
  } catch (err) {
    console.warn('Invalid HANGABLE_HOURS env, falling back to defaults:', err.message);
    return DEFAULT_HANGABLE_HOURS;
  }
}

const HANGABLE_HOURS = loadHangableHours();

module.exports = {
  LOOKAHEAD_DAYS,
  MIN_DURATION_MINUTES,
  GROUP_TIMEZONE,
  HANGABLE_HOURS,
  DEFAULT_HANGABLE_HOURS,
};
