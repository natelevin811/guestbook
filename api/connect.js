// GET /api/connect?name=Alice
// Kicks off Google OAuth: redirects the friend to the consent screen.

const crypto = require('crypto');
const google = require('../lib/google');
const { encodeState } = require('../lib/state');

module.exports = (req, res) => {
  try {
    const name = (req.query?.name || '').toString().trim();
    if (!name) {
      res.writeHead(400, { 'Content-Type': 'text/plain' });
      res.end('Missing ?name');
      return;
    }
    const state = encodeState({ name, nonce: crypto.randomBytes(8).toString('hex') });
    const url = google.getAuthUrl(state);
    res.writeHead(302, { Location: url });
    res.end();
  } catch (err) {
    res.writeHead(500, { 'Content-Type': 'text/plain' });
    res.end(`connect error: ${err.message}`);
  }
};
