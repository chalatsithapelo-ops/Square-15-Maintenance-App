// ─── Cross-path artisan-acceptance dedup (May 14 2026) ───
// Two code paths can send the "Great news! artisan accepted" message:
//   1) HTTP webhook POST /api/artisan-accepted (artisan app)
//   2) Firestore snapshot listener startArtisanAcceptanceListener
// They previously raced (both read wa_artisan_acceptance_sent_at as unset,
// both proceeded → customer got 2× message + 2× artisan photo). Fix here:
// atomic check-and-set via Firestore transaction + shared in-memory Set.
//
// Exported as a module so it can be unit-tested without starting the bot.

'use strict';

const _acceptanceNotifyInFlight = new Set();

function _hasFlag(data) {
  return !!(data && data.wa_artisan_acceptance_sent_at);
}

/**
 * Try to claim the right to send the artisan-acceptance WhatsApp message
 * for a single booking. Atomic across:
 *   - in-memory (same process, millisecond-tight races)
 *   - Firestore (cross-process, listener vs HTTP webhook, restarts)
 *
 * @param {object} firestore  admin.firestore() instance (must support .runTransaction).
 * @param {string} bookingId  futureBookings doc id.
 * @param {object} admin      firebase-admin module (for FieldValue if needed). Optional.
 * @returns {Promise<{claimed:boolean, reason?:string, data?:object, error?:Error}>}
 */
async function claimArtisanAcceptanceSend(firestore, bookingId, admin) {
  if (!firestore || !bookingId) return { claimed: false, reason: 'bad_args' };
  if (_acceptanceNotifyInFlight.has(bookingId)) {
    return { claimed: false, reason: 'in_flight' };
  }
  _acceptanceNotifyInFlight.add(bookingId);
  try {
    const ref = firestore.collection('futureBookings').doc(bookingId);
    const stamp = new Date().toISOString();
    const result = await firestore.runTransaction(async (tx) => {
      const snap = await tx.get(ref);
      const data = snap.exists ? (snap.data() || {}) : {};
      if (_hasFlag(data)) {
        return { ok: false, reason: 'already_sent', data };
      }
      tx.set(ref, { wa_artisan_acceptance_sent_at: stamp }, { merge: true });
      return { ok: true, data };
    });
    if (!result.ok) {
      _acceptanceNotifyInFlight.delete(bookingId);
      return { claimed: false, reason: result.reason, data: result.data };
    }
    return { claimed: true, data: result.data };
  } catch (e) {
    _acceptanceNotifyInFlight.delete(bookingId);
    return { claimed: false, reason: 'tx_error', error: e };
  }
}

/**
 * Release the in-memory claim. If `rollback: true`, also clear the Firestore
 * dedup flag so a retry / subsequent listener tick can re-attempt the send
 * (used when the WhatsApp send itself fails).
 */
async function releaseArtisanAcceptanceClaim(firestore, bookingId, opts) {
  _acceptanceNotifyInFlight.delete(bookingId);
  if (opts && opts.rollback && firestore && bookingId) {
    try {
      const admin = require('firebase-admin');
      await firestore.collection('futureBookings').doc(bookingId)
        .update({ wa_artisan_acceptance_sent_at: admin.firestore.FieldValue.delete() });
    } catch (_) { /* best-effort */ }
  }
}

// Test-only hook to reset module state between unit tests.
function _resetInFlightForTests() {
  _acceptanceNotifyInFlight.clear();
}

module.exports = {
  claimArtisanAcceptanceSend,
  releaseArtisanAcceptanceClaim,
  _resetInFlightForTests,
};
