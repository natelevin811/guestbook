// GET /api/oauth/callback?code=...&state=...
// Google redirects here after consent. We exchange the code, encrypt the
// refresh token, and upsert the member.

const google = require('../../lib/google');
const { decodeState } = require('../../lib/state');
const { encrypt } = require('../../lib/crypto');
const { getSupabase } = require('../../lib/supabase');

function redirect(res, location) {
  res.writeHead(302, { Location: location });
  res.end();
}

module.exports = async (req, res) => {
  try {
    const { code, state, error } = req.query || {};
    if (error) return redirect(res, `/?error=${encodeURIComponent(error)}`);
    if (!code) return redirect(res, '/?error=missing_code');

    const decoded = decodeState(state);
    if (!decoded?.name) return redirect(res, '/?error=bad_state');

    const tokens = await google.exchangeCode(code);
    if (!tokens.refresh_token) {
      // No refresh token means we can't query later. Usually happens if the
      // user previously consented; prompt=consent should prevent it.
      return redirect(res, '/?error=no_refresh_token');
    }

    const email = google.emailFromIdToken(tokens.id_token);
    const supabase = getSupabase();

    // Upsert on google_email so reconnecting updates the token instead of
    // creating a duplicate. Fall back to name if email is unavailable.
    const row = {
      name: decoded.name,
      google_email: email,
      refresh_token: encrypt(tokens.refresh_token),
    };

    if (email) {
      await supabase.from('app_users').upsert(row, { onConflict: 'google_email' });
    } else {
      await supabase.from('app_users').insert(row);
    }

    return redirect(res, '/?connected=1');
  } catch (err) {
    return redirect(res, `/?error=${encodeURIComponent(err.message)}`);
  }
};
