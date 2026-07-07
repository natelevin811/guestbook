const test = require('node:test');
const assert = require('node:assert');
const { DateTime } = require('luxon');
const { windowHash, formatWindow, buildDigestMessage } = require('../lib/format');

const TZ = 'America/New_York';
function w(startIso, endIso) {
  return {
    start: DateTime.fromISO(startIso, { zone: TZ }).toUTC().toISO(),
    end: DateTime.fromISO(endIso, { zone: TZ }).toUTC().toISO(),
  };
}

test('formatWindow collapses shared meridiem', () => {
  // Thursday 7-10pm
  assert.strictEqual(formatWindow(w('2026-07-09T19:00', '2026-07-09T22:00'), TZ), 'Thu 7–10pm');
});

test('formatWindow keeps both meridiems when they differ', () => {
  // Saturday 11am-4pm
  assert.strictEqual(formatWindow(w('2026-07-11T11:00', '2026-07-11T16:00'), TZ), 'Sat 11am–4pm');
});

test('formatWindow shows minutes when not on the hour', () => {
  assert.strictEqual(formatWindow(w('2026-07-09T19:30', '2026-07-09T21:00'), TZ), 'Thu 7:30–9pm');
});

test('windowHash is stable and rounds to the minute', () => {
  const a = windowHash(w('2026-07-09T19:00', '2026-07-09T22:00'));
  const b = windowHash(w('2026-07-09T19:00', '2026-07-09T22:00'));
  assert.strictEqual(a, b);
  assert.strictEqual(a.length, 32);
});

test('windowHash differs for different windows', () => {
  const a = windowHash(w('2026-07-09T19:00', '2026-07-09T22:00'));
  const b = windowHash(w('2026-07-09T19:00', '2026-07-09T21:00'));
  assert.notStrictEqual(a, b);
});

test('buildDigestMessage joins multiple windows naturally', () => {
  const msg = buildDigestMessage(
    [w('2026-07-09T19:00', '2026-07-09T22:00'), w('2026-07-11T14:00', '2026-07-11T18:00')],
    TZ
  );
  assert.match(msg, /you're all free Thu 7–10pm and Sat 2–6pm/);
  assert.match(msg, /\/stop/);
});

test('buildDigestMessage returns null for no windows', () => {
  assert.strictEqual(buildDigestMessage([], TZ), null);
});
