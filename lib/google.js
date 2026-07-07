// Minimal Google OAuth 2.0 + Calendar freebusy client, using plain fetch.
// We deliberately avoid the heavy googleapis SDK.
//
// Scopes: we request `calendar.freebusy` (busy blocks only, never event
// details) plus openid/email so we can label members by their Google email.

const SCOPES = [
  'openid',
  'email',
  'https://www.googleapis.com/auth/calendar.freebusy',
];

function getClientId() {
  const id = process.env.GOOGLE_CLIENT_ID;
  if (!id) throw new Error('GOOGLE_CLIENT_ID is not set');
  return id;
}

function getClientSecret() {
  const secret = process.env.GOOGLE_CLIENT_SECRET;
  if (!secret) throw new Error('GOOGLE_CLIENT_SECRET is not set');
  return secret;
}

// Where Google sends the user back. Must exactly match an authorized redirect
// URI in the OAuth client config.
function getRedirectUri() {
  if (process.env.GOOGLE_REDIRECT_URI) return process.env.GOOGLE_REDIRECT_URI;
  const base = process.env.PUBLIC_BASE_URL;
  if (!base) throw new Error('Set GOOGLE_REDIRECT_URI or PUBLIC_BASE_URL');
  return `${base.replace(/\/$/, '')}/api/oauth/callback`;
}

function getAuthUrl(state) {
  const params = new URLSearchParams({
    client_id: getClientId(),
    redirect_uri: getRedirectUri(),
    response_type: 'code',
    scope: SCOPES.join(' '),
    access_type: 'offline', // we need a refresh token
    prompt: 'consent', // force refresh_token even on repeat connects
    include_granted_scopes: 'true',
    state: state || '',
  });
  return `https://accounts.google.com/o/oauth2/v2/auth?${params.toString()}`;
}

async function exchangeCode(code) {
  const res = await fetch('https://oauth2.googleapis.com/token', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      code,
      client_id: getClientId(),
      client_secret: getClientSecret(),
      redirect_uri: getRedirectUri(),
      grant_type: 'authorization_code',
    }),
  });
  const data = await res.json();
  if (!res.ok) throw new Error(`Token exchange failed: ${data.error_description || data.error || res.status}`);
  return data; // { access_token, refresh_token, id_token, expires_in, ... }
}

async function refreshAccessToken(refreshToken) {
  const res = await fetch('https://oauth2.googleapis.com/token', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      refresh_token: refreshToken,
      client_id: getClientId(),
      client_secret: getClientSecret(),
      grant_type: 'refresh_token',
    }),
  });
  const data = await res.json();
  if (!res.ok) {
    const err = new Error(`Token refresh failed: ${data.error_description || data.error || res.status}`);
    err.googleError = data.error;
    throw err;
  }
  return data.access_token;
}

// Decode the email out of the id_token (no verification needed — it came
// straight from Google's token endpoint over TLS).
function emailFromIdToken(idToken) {
  if (!idToken) return null;
  try {
    const payload = idToken.split('.')[1];
    const json = JSON.parse(Buffer.from(payload, 'base64').toString('utf8'));
    return json.email || null;
  } catch {
    return null;
  }
}

// Query busy blocks for the user's primary calendar over [timeMin, timeMax].
// Returns [{ start, end }] ISO strings. freebusy never returns event details.
async function queryFreeBusy(accessToken, timeMin, timeMax) {
  const res = await fetch('https://www.googleapis.com/calendar/v3/freeBusy', {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${accessToken}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({
      timeMin: new Date(timeMin).toISOString(),
      timeMax: new Date(timeMax).toISOString(),
      items: [{ id: 'primary' }],
    }),
  });
  const data = await res.json();
  if (!res.ok) throw new Error(`freeBusy query failed: ${data.error?.message || res.status}`);
  const cal = data.calendars?.primary;
  if (cal?.errors?.length) {
    throw new Error(`freeBusy calendar error: ${cal.errors.map((e) => e.reason).join(', ')}`);
  }
  return (cal?.busy || []).map((b) => ({ start: b.start, end: b.end }));
}

module.exports = {
  SCOPES,
  getAuthUrl,
  getRedirectUri,
  exchangeCode,
  refreshAccessToken,
  emailFromIdToken,
  queryFreeBusy,
};
