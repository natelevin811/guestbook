// Window hashing (for dedupe) and human-friendly message copy.

const crypto = require('crypto');
const { DateTime } = require('luxon');

// Stable hash of a window so we never re-announce the same one. Rounded to the
// minute so trivially-shifted boundaries don't dodge the dedupe.
function windowHash(window) {
  const start = roundIso(window.start);
  const end = roundIso(window.end);
  return crypto.createHash('sha256').update(`${start}|${end}`).digest('hex').slice(0, 32);
}

function roundIso(value) {
  const ms = value instanceof Date ? value.getTime() : new Date(value).getTime();
  const rounded = Math.round(ms / 60000) * 60000;
  return new Date(rounded).toISOString();
}

// "Thu 7–10pm" / "Sat 11am–4pm"
function formatWindow(window, timezone) {
  const start = DateTime.fromISO(toIso(window.start), { zone: timezone });
  const end = DateTime.fromISO(toIso(window.end), { zone: timezone });
  const day = start.toFormat('ccc'); // Thu

  const s = timeParts(start);
  const e = timeParts(end);
  // Collapse the meridiem when both ends share it: "7–10pm"
  const startLabel = s.meridiem === e.meridiem ? s.bare : s.full;
  return `${day} ${startLabel}–${e.full}`;
}

function timeParts(dt) {
  const meridiem = dt.toFormat('a').toLowerCase(); // am / pm
  const bare = dt.minute === 0 ? dt.toFormat('h') : dt.toFormat('h:mm');
  return { meridiem, bare, full: `${bare}${meridiem}` };
}

function toIso(value) {
  if (value instanceof Date) return value.toISOString();
  return String(value);
}

// The digest message. Kept lowercase and human, per the PRD copy.
function buildDigestMessage(windows, timezone) {
  if (windows.length === 0) return null;
  const labels = windows.map((w) => formatWindow(w, timezone));
  let list;
  if (labels.length === 1) {
    list = labels[0];
  } else if (labels.length === 2) {
    list = `${labels[0]} and ${labels[1]}`;
  } else {
    list = `${labels.slice(0, -1).join(', ')}, and ${labels[labels.length - 1]}`;
  }
  return `you're all free ${list}. someone claim one.\n\n(reply /stop to mute these)`;
}

module.exports = { windowHash, formatWindow, buildDigestMessage };
