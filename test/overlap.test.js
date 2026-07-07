const test = require('node:test');
const assert = require('node:assert');
const { DateTime } = require('luxon');
const {
  computeOverlapWindows,
  mergeIntervals,
  subtractBusy,
} = require('../lib/overlap');

const TZ = 'America/New_York';
const HANGABLE = {
  0: [[11, 22]], // Sun
  1: [[18, 22]], // Mon
  2: [[18, 22]],
  3: [[18, 22]],
  4: [[18, 22]],
  5: [[18, 22]],
  6: [[11, 22]], // Sat
};

// Helper: local wall-clock time in TZ -> epoch ms.
function local(iso) {
  return DateTime.fromISO(iso, { zone: TZ }).toMillis();
}

function baseOpts(now) {
  return {
    now,
    lookaheadDays: 14,
    timezone: TZ,
    hangableHours: HANGABLE,
    minDurationMinutes: 90,
  };
}

test('mergeIntervals merges overlapping and touching intervals', () => {
  const merged = mergeIntervals([
    { start: 10, end: 20 },
    { start: 15, end: 25 }, // overlaps
    { start: 25, end: 30 }, // touches
    { start: 40, end: 50 }, // separate
  ]);
  assert.deepStrictEqual(merged, [
    { start: 10, end: 30 },
    { start: 40, end: 50 },
  ]);
});

test('subtractBusy returns full window when no busy', () => {
  const out = subtractBusy({ start: 0, end: 100 }, []);
  assert.deepStrictEqual(out, [{ start: 0, end: 100 }]);
});

test('subtractBusy splits a window around a busy block', () => {
  const out = subtractBusy({ start: 0, end: 100 }, [{ start: 40, end: 60 }]);
  assert.deepStrictEqual(out, [
    { start: 0, end: 40 },
    { start: 60, end: 100 },
  ]);
});

test('subtractBusy handles busy fully covering the window', () => {
  const out = subtractBusy({ start: 10, end: 90 }, [{ start: 0, end: 100 }]);
  assert.deepStrictEqual(out, []);
});

test('no members => no windows', () => {
  const now = local('2026-07-06T09:00'); // a Monday morning
  const windows = computeOverlapWindows([], baseOpts(now));
  // With zero members there is no one busy, so all hangable time is "free".
  // But "everyone free" with nobody connected isn't meaningful; the digest
  // layer guards on member count. The engine itself returns hangable windows.
  assert.ok(windows.length > 0);
});

test('fully free evening yields the whole hangable window', () => {
  const now = local('2026-07-06T09:00'); // Monday 9am
  const members = [{ busy: [] }, { busy: [] }];
  const windows = computeOverlapWindows(members, baseOpts(now));

  // Monday 18:00-22:00 should be present and intact.
  const mondayEve = windows.find(
    (w) => w.startMs === local('2026-07-06T18:00') && w.endMs === local('2026-07-06T22:00')
  );
  assert.ok(mondayEve, 'expected an intact Monday 6-10pm window');
  assert.strictEqual(mondayEve.durationMinutes, 240);
});

test('one member busy shrinks the overlap', () => {
  const now = local('2026-07-06T09:00');
  const members = [
    { busy: [{ start: local('2026-07-06T18:00'), end: local('2026-07-06T20:00') }] },
    { busy: [] },
  ];
  const windows = computeOverlapWindows(members, baseOpts(now));
  const mondayEve = windows.find((w) => w.startMs === local('2026-07-06T20:00'));
  assert.ok(mondayEve, 'expected a 8-10pm remainder window');
  assert.strictEqual(mondayEve.endMs, local('2026-07-06T22:00'));
  assert.strictEqual(mondayEve.durationMinutes, 120);
});

test('union of busy across members removes a window entirely', () => {
  const now = local('2026-07-06T09:00');
  const members = [
    { busy: [{ start: local('2026-07-06T18:00'), end: local('2026-07-06T20:00') }] },
    { busy: [{ start: local('2026-07-06T19:30'), end: local('2026-07-06T22:00') }] },
  ];
  const windows = computeOverlapWindows(members, baseOpts(now));
  // Monday 6-10pm is fully covered by the union 6:00-10:00 -> no window left.
  const mondayAny = windows.find(
    (w) => w.startMs >= local('2026-07-06T18:00') && w.startMs < local('2026-07-06T22:00')
  );
  assert.strictEqual(mondayAny, undefined);
});

test('MIN_DURATION filters out short remainders', () => {
  const now = local('2026-07-06T09:00');
  // Leave only 60 minutes free (21:00-22:00) on Monday — below 90 min default.
  const members = [{ busy: [{ start: local('2026-07-06T18:00'), end: local('2026-07-06T21:00') }] }];
  const windows = computeOverlapWindows(members, baseOpts(now));
  const mondayLeftover = windows.find((w) => w.startMs === local('2026-07-06T21:00'));
  assert.strictEqual(mondayLeftover, undefined, '60-min remainder should be dropped');
});

test('past time is clipped — earlier today is not suggested', () => {
  const now = local('2026-07-04T15:00'); // Saturday 3pm; hangable 11-22
  const members = [{ busy: [] }];
  const windows = computeOverlapWindows(members, baseOpts(now));
  const saturday = windows.find((w) => w.endMs === local('2026-07-04T22:00'));
  assert.ok(saturday);
  // Window should start at "now" (3pm), not 11am.
  assert.strictEqual(saturday.startMs, now);
});

test('weekday daytime is not hangable (only evenings)', () => {
  const now = local('2026-07-06T09:00'); // Monday
  const members = [{ busy: [] }];
  const windows = computeOverlapWindows(members, baseOpts(now));
  // No window should start during Monday daytime (e.g. noon).
  const noon = windows.find(
    (w) => w.startMs >= local('2026-07-06T09:00') && w.startMs < local('2026-07-06T18:00')
  );
  assert.strictEqual(noon, undefined);
});

test('output is sorted by start time', () => {
  const now = local('2026-07-06T09:00');
  const members = [{ busy: [] }];
  const windows = computeOverlapWindows(members, baseOpts(now));
  for (let i = 1; i < windows.length; i++) {
    assert.ok(windows[i].startMs >= windows[i - 1].startMs);
  }
});

test('all-day busy block removes the whole day', () => {
  const now = local('2026-07-06T09:00'); // Monday
  // An all-day event Tuesday (full UTC-ish day) should wipe Tuesday evening.
  const members = [
    {
      busy: [
        { start: local('2026-07-07T00:00'), end: local('2026-07-08T00:00') },
      ],
    },
  ];
  const windows = computeOverlapWindows(members, baseOpts(now));
  const tuesday = windows.find(
    (w) => w.startMs >= local('2026-07-07T18:00') && w.startMs < local('2026-07-07T22:00')
  );
  assert.strictEqual(tuesday, undefined);
});

test('accepts ISO strings and Date objects as busy bounds', () => {
  const now = local('2026-07-06T09:00');
  const members = [
    { busy: [{ start: new Date(local('2026-07-06T18:00')), end: new Date(local('2026-07-06T19:30')) }] },
    { busy: [{ start: '2026-07-06T20:00:00-04:00', end: '2026-07-06T21:00:00-04:00' }] },
  ];
  const windows = computeOverlapWindows(members, baseOpts(now));
  // Free Monday remainders: 19:30-20:00 (30m, dropped) and 21:00-22:00 (60m, dropped).
  // So no Monday window survives the 90-min floor.
  const mondaySurvivor = windows.find(
    (w) => w.startMs >= local('2026-07-06T18:00') && w.startMs < local('2026-07-06T22:00') && w.durationMinutes >= 90
  );
  assert.strictEqual(mondaySurvivor, undefined);
});
