// Tamper-proof OAuth `state`: carries the member's chosen name through the
// Google round-trip, HMAC-signed so a returned state can't be forged.

const crypto = require('crypto');

function secret() {
  // Reuse the encryption key material as the HMAC secret.
  return process.env.TOKEN_ENC_KEY || process.env.GOOGLE_CLIENT_SECRET || 'freewindow-dev';
}

function b64url(buf) {
  return Buffer.from(buf).toString('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

function encodeState(payload) {
  const body = b64url(JSON.stringify(payload));
  const sig = b64url(crypto.createHmac('sha256', secret()).update(body).digest());
  return `${body}.${sig}`;
}

function decodeState(state) {
  if (!state || typeof state !== 'string' || !state.includes('.')) return null;
  const [body, sig] = state.split('.');
  const expected = b64url(crypto.createHmac('sha256', secret()).update(body).digest());
  if (!crypto.timingSafeEqual(Buffer.from(sig), Buffer.from(expected))) return null;
  try {
    return JSON.parse(Buffer.from(body.replace(/-/g, '+').replace(/_/g, '/'), 'base64').toString('utf8'));
  } catch {
    return null;
  }
}

module.exports = { encodeState, decodeState };
