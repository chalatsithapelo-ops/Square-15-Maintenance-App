const test = require('node:test');
const assert = require('node:assert/strict');

const app = require('../server');

test('stableStringify produces deterministic output for objects', () => {
  const { stableStringify } = app._internals;
  const a = { b: 2, a: 1, c: { y: 2, x: 1 } };
  const b = { c: { x: 1, y: 2 }, a: 1, b: 2 };
  assert.equal(stableStringify(a), stableStringify(b));
});

test('sha256Hex returns 64 hex chars', () => {
  const { sha256Hex } = app._internals;
  const h = sha256Hex('hello');
  assert.equal(typeof h, 'string');
  assert.equal(h.length, 64);
  assert.match(h, /^[0-9a-f]{64}$/);
});

test('normalizeRole canonicalizes common role strings', () => {
  const { normalizeRole } = app._internals;
  assert.equal(normalizeRole({ role: 'ADMIN' }), 'admin');
  assert.equal(normalizeRole({ user_type: 'user' }), 'client');
  assert.equal(normalizeRole({ user_role: 'provider' }), 'artisan');
});

test('ensureActionAllowed enforces action/role policy', () => {
  const { ensureActionAllowed } = app._internals;
  assert.deepEqual(ensureActionAllowed({ action: 'create_order_booking', actorRole: 'client' }), { ok: true });
  assert.equal(ensureActionAllowed({ action: 'create_order_booking', actorRole: 'artisan' }).ok, false);
  assert.equal(ensureActionAllowed({ action: 'unknown_action', actorRole: 'admin' }).ok, false);
});
