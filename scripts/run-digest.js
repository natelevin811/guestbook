#!/usr/bin/env node
// Run the digest locally / manually. Loads .env if present.
//
//   node scripts/run-digest.js            # compute + send + record
//   node scripts/run-digest.js --dry      # compute only, no send / no record
//   node scripts/run-digest.js --compute  # just print the windows
//
// Requires the same env vars as production (see .env.example).

const fs = require('fs');
const path = require('path');

// Tiny .env loader (no dependency).
const envPath = path.join(__dirname, '..', '.env');
if (fs.existsSync(envPath)) {
  for (const line of fs.readFileSync(envPath, 'utf8').split('\n')) {
    const m = line.match(/^\s*([A-Z0-9_]+)\s*=\s*(.*)\s*$/);
    if (m && !process.env[m[1]]) {
      process.env[m[1]] = m[2].replace(/^["']|["']$/g, '');
    }
  }
}

const { runDigest, computeWindows } = require('../lib/digest');
const { formatWindow } = require('../lib/format');
const config = require('../lib/config');

async function main() {
  const args = process.argv.slice(2);
  if (args.includes('--compute')) {
    const { windows, members, errors } = await computeWindows();
    console.log(`members: ${members.length}, windows: ${windows.length}`);
    for (const w of windows) console.log('  •', formatWindow(w, config.GROUP_TIMEZONE), `(${w.durationMinutes}m)`);
    if (errors.length) console.warn('errors:', errors);
    return;
  }
  const dry = args.includes('--dry');
  const result = await runDigest({ send: !dry, record: !dry });
  console.log(JSON.stringify(result, null, 2));
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
