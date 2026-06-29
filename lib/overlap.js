// The overlap engine — the heart of FreeWindow.
//
// Given a set of members, each with a list of busy intervals, find the windows
// inside "hangable hours" where EVERYONE is free for at least MIN_DURATION.
//
// "Everyone free" == hangable time minus the UNION of every member's busy time.
//
// All interval math is done in epoch-millis (timezone-agnostic instants).
// Building the hangable windows is the only timezone-aware step, and luxon
// handles DST / wall-clock -> instant conversion for us.

const { DateTime } = require('luxon');

// --- interval helpers (operate on {start, end} in epoch ms) ----------------

// Merge overlapping or touching intervals. Returns a new sorted array.
function mergeIntervals(intervals) {
  if (intervals.length === 0) return [];
  const sorted = intervals
    .filter((iv) => iv.end > iv.start)
    .sort((a, b) => a.start - b.start);
  if (sorted.length === 0) return [];

  const merged = [{ ...sorted[0] }];
  for (let i = 1; i < sorted.length; i++) {
    const last = merged[merged.length - 1];
    const cur = sorted[i];
    if (cur.start <= last.end) {
      last.end = Math.max(last.end, cur.end);
    } else {
      merged.push({ ...cur });
    }
  }
  return merged;
}

// Subtract a sorted, merged list of busy intervals from a single free window.
// Returns the remaining free sub-windows (possibly empty).
function subtractBusy(freeWindow, mergedBusy) {
  const result = [];
  let cursor = freeWindow.start;
  const end = freeWindow.end;

  for (const busy of mergedBusy) {
    if (busy.end <= cursor) continue; // entirely before the cursor
    if (busy.start >= end) break; // past the window; nothing more applies
    if (busy.start > cursor) {
      result.push({ start: cursor, end: Math.min(busy.start, end) });
    }
    cursor = Math.max(cursor, busy.end);
    if (cursor >= end) break;
  }
  if (cursor < end) result.push({ start: cursor, end });
  return result;
}

// --- hangable window construction ------------------------------------------

// Build every hangable window across the lookahead range, as epoch-ms intervals.
// Windows are clipped so we never suggest a time in the past.
function buildHangableWindows({ now, lookaheadDays, timezone, hangableHours }) {
  const nowDt = DateTime.fromMillis(now, { zone: timezone });
  const nowMs = now;
  const windows = [];

  // iterate today through today + lookaheadDays (inclusive)
  let day = nowDt.startOf('day');
  for (let i = 0; i <= lookaheadDays; i++) {
    const dow = day.weekday % 7; // luxon: 1=Mon..7=Sun -> 0=Sun..6=Sat
    const ranges = hangableHours[dow] || [];
    for (const [startHour, endHour] of ranges) {
      if (endHour <= startHour) continue; // ignore malformed / overnight ranges
      const winStart = day.set({ hour: startHour, minute: 0, second: 0, millisecond: 0 });
      const winEnd = day.set({ hour: endHour, minute: 0, second: 0, millisecond: 0 });
      let startMs = winStart.toMillis();
      const endMs = winEnd.toMillis();
      if (startMs < nowMs) startMs = nowMs; // clip past time
      if (startMs >= endMs) continue;
      windows.push({ start: startMs, end: endMs });
    }
    day = day.plus({ days: 1 });
  }
  return windows;
}

// --- public API ------------------------------------------------------------

// members: [{ busy: [{ start, end }] }] where start/end are ISO strings or
//          Date objects or epoch ms. Busy intervals across ALL members are
//          unioned, because a window only counts if NO member is busy.
//
// returns: [{ start, end, startMs, endMs, durationMinutes }] sorted by start.
function computeOverlapWindows(members, opts) {
  const {
    now,
    lookaheadDays,
    timezone,
    hangableHours,
    minDurationMinutes,
  } = opts;

  const minDurationMs = minDurationMinutes * 60 * 1000;

  // Flatten + normalize every member's busy intervals into one list, then merge.
  const allBusy = [];
  for (const member of members) {
    for (const iv of member.busy || []) {
      const start = toMs(iv.start);
      const end = toMs(iv.end);
      if (Number.isFinite(start) && Number.isFinite(end) && end > start) {
        allBusy.push({ start, end });
      }
    }
  }
  const mergedBusy = mergeIntervals(allBusy);

  const hangable = buildHangableWindows({ now, lookaheadDays, timezone, hangableHours });

  const free = [];
  for (const window of hangable) {
    for (const sub of subtractBusy(window, mergedBusy)) {
      if (sub.end - sub.start >= minDurationMs) {
        free.push({
          startMs: sub.start,
          endMs: sub.end,
          start: new Date(sub.start).toISOString(),
          end: new Date(sub.end).toISOString(),
          durationMinutes: Math.round((sub.end - sub.start) / 60000),
        });
      }
    }
  }

  free.sort((a, b) => a.startMs - b.startMs);
  return free;
}

function toMs(value) {
  if (value instanceof Date) return value.getTime();
  if (typeof value === 'number') return value;
  if (typeof value === 'string') return new Date(value).getTime();
  return NaN;
}

module.exports = {
  computeOverlapWindows,
  buildHangableWindows,
  mergeIntervals,
  subtractBusy,
};
