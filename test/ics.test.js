const test = require('node:test');
const assert = require('node:assert');
const { parseIcsBusy } = require('../lib/ics');

const SAMPLE = [
  'BEGIN:VCALENDAR',
  'BEGIN:VEVENT',
  'DTSTART:20260709T230000Z',
  'DTEND:20260710T000000Z',
  'SUMMARY:Dinner',
  'END:VEVENT',
  'BEGIN:VEVENT',
  'DTSTART;VALUE=DATE:20260711',
  'DTEND;VALUE=DATE:20260712',
  'SUMMARY:All day offsite',
  'END:VEVENT',
  'END:VCALENDAR',
].join('\r\n');

test('parseIcsBusy extracts UTC events in range', () => {
  const busy = parseIcsBusy(SAMPLE, '2026-07-01T00:00:00Z', '2026-07-20T00:00:00Z');
  assert.strictEqual(busy.length, 2);
  assert.strictEqual(busy[0].start, '2026-07-09T23:00:00.000Z');
  assert.strictEqual(busy[0].end, '2026-07-10T00:00:00.000Z');
});

test('parseIcsBusy excludes events outside the range', () => {
  const busy = parseIcsBusy(SAMPLE, '2026-08-01T00:00:00Z', '2026-08-20T00:00:00Z');
  assert.strictEqual(busy.length, 0);
});

test('parseIcsBusy handles folded lines', () => {
  const folded = [
    'BEGIN:VEVENT',
    'DTSTART:20260709T2300',
    ' 00Z',
    'DTEND:20260710T000000Z',
    'END:VEVENT',
  ].join('\r\n');
  const busy = parseIcsBusy(folded, '2026-07-01T00:00:00Z', '2026-07-20T00:00:00Z');
  assert.strictEqual(busy.length, 1);
  assert.strictEqual(busy[0].start, '2026-07-09T23:00:00.000Z');
});
