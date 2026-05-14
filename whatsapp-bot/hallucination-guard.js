// ─── Hallucination-guard helpers (May 14 2026) ───
// Pure helpers for the price-hallucination guard in handleMessage().
// Extracted to a module so the logic can be unit-tested without booting
// the bot. The guard rewrites Lizzy's reply when it contains an R-price
// but no pricing tool was called this turn (or no pricing tool returned a
// price). See server.js handleMessage() for the call site.
//
// Two regressions this module exists to prevent (May 14 2026 screenshot):
//   1. User typed an R-amount as their budget; Lizzy echoes it in her
//      reply; old guard stripped the entire reply and emitted a canned
//      RFQ-confirm prompt. (FIX: collectUserPricesFromContext)
//   2. The canned prompt was emitted EVERY turn → bot looped because each
//      Lizzy reply re-echoed the user's price. (FIX: lastAssistantIsCannedPrompt)

'use strict';

// Match formats: R1200, R 1 200, R12,000, R12 000.00, R0.50, etc.
const PRICE_RE_GLOBAL = /R\s*(\d{1,3}(?:[ ,]\d{3})*(?:\.\d{1,2})?|\d+(?:\.\d{1,2})?)/gi;
const PRICE_RE = /\bR\s*\d{1,3}(?:[ ,]\d{3})*(?:\.\d{1,2})?\b/i;

// CANNED replacement: ASK for a photo. The previous version promised
// "Let me file a quick RFQ" / "Let me get that RFQ filed" without ever
// invoking submit_rfq — a false claim, and it skipped the photo-ask
// step that the RFQ flow legitimately needs (audit 2026-05-15 regression
// report: photo prompt disappeared because guard replaced Lizzy's draft
// with a fake "RFQ filed" message). Asking for a photo is honest (no
// promise of action) AND lines up with the server-side PHOTO GATE in
// submit_rfq, so the rest of the flow works naturally on the next turn.
const CANNED_RFQ_PROMPT_PREFIX = "I don't have a fixed price for that exact job";
const CANNED_RFQ_PROMPT = "I don't have a fixed price for that exact job in our catalog yet — our admin will need to put together a proper quote. Could you send me a quick photo of the spot where the work is needed? It helps our team scope and price it accurately.";
// LOOP_BREAK_ACK kept exported for backwards-compat with tests, but no
// longer emitted: on loop detection the guard now ALLOWS the original
// reply through (the loop itself proves the canned prompt was the wrong
// intervention). Keeping a fabricated ack would compound the lie.
const LOOP_BREAK_ACK = "Got it — thanks for confirming. Let me get that RFQ filed; our admin will review and send a proper quote here on WhatsApp shortly. 🙏";

// Normalise an R-amount capture so "R12,000" and "R12 000" both → "12000".
function normalisePrice(captured) {
  return String(captured).replace(/[\s,]/g, '');
}

// Extract the set of normalised R-amounts mentioned in arbitrary text.
function collectPrices(text) {
  const out = new Set();
  if (!text || typeof text !== 'string') return out;
  const re = new RegExp(PRICE_RE_GLOBAL.source, 'gi');
  let m;
  while ((m = re.exec(text)) !== null) {
    out.add(normalisePrice(m[1]));
  }
  return out;
}

// Walk back through `sessionMessages` and `currentUserMessage`, collecting
// every R-amount the user has mentioned in the recent context. Used to
// detect when Lizzy is echoing a user-supplied number rather than
// hallucinating a price.
function collectUserPricesFromContext(sessionMessages, currentUserMessage, maxUserMessages = 4) {
  const out = new Set();
  if (typeof currentUserMessage === 'string') {
    for (const v of collectPrices(currentUserMessage)) out.add(v);
  }
  if (Array.isArray(sessionMessages)) {
    let seen = 0;
    for (let i = sessionMessages.length - 1; i >= 0 && seen < maxUserMessages; i--) {
      const m = sessionMessages[i];
      if (m && m.role === 'user' && typeof m.content === 'string') {
        for (const v of collectPrices(m.content)) out.add(v);
        seen++;
      }
    }
  }
  return out;
}

// True if EVERY R-amount in `reply` was already mentioned by the user in
// the recent context (and there is at least one such R-amount).
function allReplyPricesAreUserEcho(reply, userPricesInContext) {
  const replyPrices = [...collectPrices(reply)];
  if (replyPrices.length === 0) return false;
  return replyPrices.every((p) => userPricesInContext.has(p));
}

// True if the immediately-previous assistant message is the same canned
// RFQ-confirm prompt we're about to send. Used to break the guard loop.
function lastAssistantIsCannedPrompt(sessionMessages) {
  if (!Array.isArray(sessionMessages)) return false;
  for (let i = sessionMessages.length - 1; i >= 0; i--) {
    const m = sessionMessages[i];
    if (m && m.role === 'assistant') {
      const c = typeof m.content === 'string' ? m.content : '';
      return c.startsWith(CANNED_RFQ_PROMPT_PREFIX);
    }
  }
  return false;
}

/**
 * Decide what the guard should do.
 *
 * @param {object} args
 * @param {string} args.reply              Lizzy's draft reply
 * @param {boolean} args.toolReturnedPrice Whether a pricing tool returned a price this turn
 * @param {Array}   args.sessionMessages   session.messages array
 * @param {string}  args.userMessage       current user message (raw text)
 * @returns {{ action:'allow'|'replace'|'break_loop', safeReply:string, reason?:string }}
 */
function decideGuardAction({ reply, toolReturnedPrice, sessionMessages, userMessage }) {
  if (!reply || typeof reply !== 'string') {
    return { action: 'allow', safeReply: reply || '', reason: 'empty_reply' };
  }
  if (!PRICE_RE.test(reply)) {
    return { action: 'allow', safeReply: reply, reason: 'no_price_in_reply' };
  }
  if (toolReturnedPrice) {
    return { action: 'allow', safeReply: reply, reason: 'tool_returned_price' };
  }
  const userPrices = collectUserPricesFromContext(sessionMessages, userMessage);
  if (allReplyPricesAreUserEcho(reply, userPrices)) {
    return { action: 'allow', safeReply: reply, reason: 'user_echo' };
  }
  if (lastAssistantIsCannedPrompt(sessionMessages)) {
    // Loop detected: the previous turn already replaced Lizzy's reply
    // with the photo-ask canned prompt and the model is STILL emitting
    // an R-price. Sending another canned reply would loop AND a fake
    // ack ("Let me get that RFQ filed") would lie about an action that
    // never happened. Let the model's reply through — at this point any
    // residual hallucinated price is less harmful than a false promise.
    return { action: 'allow', safeReply: reply, reason: 'loop_detected_passthrough' };
  }
  return { action: 'replace', safeReply: CANNED_RFQ_PROMPT, reason: 'hallucinated_price' };
}

module.exports = {
  PRICE_RE,
  PRICE_RE_GLOBAL,
  CANNED_RFQ_PROMPT,
  CANNED_RFQ_PROMPT_PREFIX,
  LOOP_BREAK_ACK,
  normalisePrice,
  collectPrices,
  collectUserPricesFromContext,
  allReplyPricesAreUserEcho,
  lastAssistantIsCannedPrompt,
  decideGuardAction,
};
