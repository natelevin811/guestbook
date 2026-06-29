// Server-side Supabase client using the service role key. All FreeWindow
// tables have RLS enabled with no policies, so only the service role (used
// here, server-side only) can read/write them. The service role key must
// NEVER be exposed to the browser.

const { createClient } = require('@supabase/supabase-js');

let cached = null;

function getSupabase() {
  if (cached) return cached;
  const url = process.env.SUPABASE_URL;
  const key = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!url || !key) {
    throw new Error('SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY must be set');
  }
  cached = createClient(url, key, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  return cached;
}

module.exports = { getSupabase };
