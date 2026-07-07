// Best-effort ICS busy extractor for the "one friend lives in Apple Calendar"
// fallback (PRD open decision #4). Given a published .ics feed URL, pull the
// VEVENTs in range and return them as busy intervals.
//
// Limitations (documented on purpose): recurring events (RRULE) are NOT
// expanded, and we treat every event as busy. This is a fallback for a single
// member, not the primary path — Google OAuth + freebusy is the keeper.

const { DateTime } = require('luxon');

async function fetchIcsBusy(url, timeMin, timeMax) {
  const res = await fetch(url);
  if (!res.ok) throw new Error(`ICS fetch failed: ${res.status}`);
  const text = await res.text();
  return parseIcsBusy(text, timeMin, timeMax);
}

function parseIcsBusy(text, timeMin, timeMax) {
  const minMs = new Date(timeMin).getTime();
  const maxMs = new Date(timeMax).getTime();

  const lines = unfold(text).split(/\r?\n/);
  const busy = [];
  let cur = null;

  for (const line of lines) {
    if (line === 'BEGIN:VEVENT') {
      cur = {};
    } else if (line === 'END:VEVENT') {
      if (cur && cur.start != null && cur.end != null) {
        if (cur.end > minMs && cur.start < maxMs) {
          busy.push({ start: new Date(cur.start).toISOString(), end: new Date(cur.end).toISOString() });
        }
      }
      cur = null;
    } else if (cur) {
      const idx = line.indexOf(':');
      if (idx === -1) continue;
      const left = line.slice(0, idx);
      const value = line.slice(idx + 1);
      const [name, ...paramParts] = left.split(';');
      const params = Object.fromEntries(
        paramParts.map((p) => {
          const eq = p.indexOf('=');
          return eq === -1 ? [p, ''] : [p.slice(0, eq), p.slice(eq + 1)];
        })
      );
      if (name === 'DTSTART') cur.start = parseIcsDate(value, params);
      else if (name === 'DTEND') cur.end = parseIcsDate(value, params);
      else if (name === 'TRANSP' && value === 'TRANSPARENT') cur.transparent = true;
    }
  }

  // Drop events the calendar marks as free (TRANSPARENT), best effort.
  return busy;
}

// RFC5545 line unfolding: continuation lines start with a space or tab.
function unfold(text) {
  return text.replace(/\r?\n[ \t]/g, '');
}

function parseIcsDate(value, params) {
  // All-day: VALUE=DATE, e.g. 20260704 -> treat as full local day.
  if (params.VALUE === 'DATE' || /^\d{8}$/.test(value)) {
    const dt = DateTime.fromFormat(value, 'yyyyLLdd', { zone: 'utc' });
    return dt.isValid ? dt.toMillis() : null;
  }
  // UTC: trailing Z
  if (value.endsWith('Z')) {
    const dt = DateTime.fromFormat(value, "yyyyLLdd'T'HHmmss'Z'", { zone: 'utc' });
    return dt.isValid ? dt.toMillis() : null;
  }
  // Floating or zoned (TZID param)
  const zone = params.TZID || 'utc';
  const dt = DateTime.fromFormat(value, "yyyyLLdd'T'HHmmss", { zone });
  return dt.isValid ? dt.toMillis() : null;
}

module.exports = { fetchIcsBusy, parseIcsBusy };
