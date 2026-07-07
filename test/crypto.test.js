const test = require('node:test');
const assert = require('node:assert');

process.env.TOKEN_ENC_KEY = process.env.TOKEN_ENC_KEY
  || '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

const { encrypt, decrypt } = require('../lib/crypto');
const { encodeState, decodeState } = require('../lib/state');

test('encrypt/decrypt round-trips', () => {
  const secret = '1//refresh-token-value-abc123';
  const enc = encrypt(secret);
  assert.notStrictEqual(enc, secret);
  assert.match(enc, /^v1:/);
  assert.strictEqual(decrypt(enc), secret);
});

test('decrypt rejects tampered ciphertext', () => {
  const enc = encrypt('hello');
  const parts = enc.split(':');
  parts[3] = Buffer.from('tampered').toString('base64');
  assert.throws(() => decrypt(parts.join(':')));
});

test('state encode/decode round-trips and is tamper-evident', () => {
  const state = encodeState({ name: 'Alex', nonce: 'abc' });
  assert.deepStrictEqual(decodeState(state), { name: 'Alex', nonce: 'abc' });
  // Flip a character in the body -> signature no longer matches.
  const broken = 'x' + state.slice(1);
  assert.strictEqual(decodeState(broken), null);
});
