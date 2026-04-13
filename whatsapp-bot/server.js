/**
 * Square 15 WhatsApp Bot Server
 * ─────────────────────────────
 * Receives messages from Meta WhatsApp Cloud API, processes them with
 * OpenAI GPT-4o, and creates/manages bookings in the same Firestore
 * collections used by the Flutter apps.
 *
 * Endpoints:
 *   GET  /webhook       – Meta verification handshake
 *   POST /webhook       – Incoming messages
 *   GET  /health        – Health check for Render
 */

'use strict';

// ─── Truthy check for artisan active field ───
function isTruthyValue(v) {
  if (v === true) return true;
  if (v === false) return false;
  if (v == null) return false;
  const s = String(v).trim().toLowerCase();
  return ['true', 'yes', 'y', '1', 'active', 'online', 'available', 'on'].includes(s);
}

// ─── Prompt sanitization (prevent injection via user-supplied text) ───
function sanitizeForPrompt(text, maxLen = 500) {
  if (!text || typeof text !== 'string') return '';
  return text
    .replace(/[\x00-\x08\x0B\x0C\x0E-\x1F]/g, '') // strip control chars
    .replace(/\r\n|\r/g, '\n')                       // normalise line endings
    .slice(0, maxLen)
    .trim();
}

require('dotenv').config();
const express = require('express');
const helmet  = require('helmet');
const cors    = require('cors');
const crypto  = require('crypto');

const app = express();
app.use(helmet());
app.use(cors());
app.use(express.json({ verify: (req, _res, buf) => { req.rawBody = buf; } }));

const PORT = process.env.PORT || 3001;

// ─── Firebase Admin (lazy init, same pattern as livekit-backend) ───

const admin = require('firebase-admin');
let _firebaseReady = false;

function initFirebase() {
  if (_firebaseReady) return true;
  try {
    let sa;
    if (process.env.FIREBASE_SERVICE_ACCOUNT_JSON) {
      sa = JSON.parse(process.env.FIREBASE_SERVICE_ACCOUNT_JSON);
    } else if (process.env.FIREBASE_SERVICE_ACCOUNT_BASE64) {
      sa = JSON.parse(Buffer.from(process.env.FIREBASE_SERVICE_ACCOUNT_BASE64, 'base64').toString());
    } else if (process.env.FIREBASE_SERVICE_ACCOUNT_FILE) {
      sa = require(process.env.FIREBASE_SERVICE_ACCOUNT_FILE);
    }
    if (!sa) { console.warn('[firebase] No service account found'); return false; }
    admin.initializeApp({
      credential: admin.credential.cert(sa),
      storageBucket: 'promaintapp-b618a.firebasestorage.app',
    });
    _firebaseReady = true;
    console.log('[firebase] Initialized');
    return true;
  } catch (e) {
    console.error('[firebase] Init failed:', e.message);
    return false;
  }
}

function db() {
  if (!_firebaseReady && !initFirebase()) return null;
  return admin.firestore();
}

// ─── OpenAI ───

const OpenAI = require('openai');
const openai = new OpenAI({ apiKey: process.env.OPENAI_API_KEY });

// ─── WhatsApp Cloud API helper ───

const WA_API = 'https://graph.facebook.com/v19.0';

async function sendWhatsAppMessage(to, text) {
  const phoneId = process.env.WHATSAPP_PHONE_NUMBER_ID;
  const token   = process.env.WHATSAPP_ACCESS_TOKEN;
  if (!phoneId || !token) { console.error('[wa] Missing credentials'); return; }

  try {
    const res = await fetch(`${WA_API}/${phoneId}/messages`, {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${token}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        messaging_product: 'whatsapp',
        to,
        type: 'text',
        text: { body: text },
      }),
      signal: AbortSignal.timeout(15000),
    });
    if (!res.ok) console.error('[wa] send failed:', await res.text());
  } catch (e) {
    console.error('[wa] sendWhatsAppMessage error:', e.message);
  }
}

async function sendWhatsAppImage(to, imageUrl, caption) {
  const phoneId = process.env.WHATSAPP_PHONE_NUMBER_ID;
  const token   = process.env.WHATSAPP_ACCESS_TOKEN;
  if (!phoneId || !token) { console.error('[wa-image] Missing credentials'); return; }

  try {
    const res = await fetch(`${WA_API}/${phoneId}/messages`, {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${token}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        messaging_product: 'whatsapp',
        to,
        type: 'image',
        image: {
          link: imageUrl,
          ...(caption ? { caption } : {}),
        },
      }),
      signal: AbortSignal.timeout(15000),
    });
    if (!res.ok) console.error('[wa-image] send failed:', res.status, await res.text().catch(() => ''));
  } catch (e) {
    console.error('[wa-image] error:', e.message);
  }
}

async function sendWhatsAppInteractive(to, header, body, buttons) {
  const phoneId = process.env.WHATSAPP_PHONE_NUMBER_ID;
  const token   = process.env.WHATSAPP_ACCESS_TOKEN;
  if (!phoneId || !token) { console.error('[wa-interactive] Missing credentials'); return; }

  try {
    const res = await fetch(`${WA_API}/${phoneId}/messages`, {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${token}`,
        'Content-Type': 'application/json',
      },
      signal: AbortSignal.timeout(15000),
      body: JSON.stringify({
        messaging_product: 'whatsapp',
        to,
        type: 'interactive',
        interactive: {
          type: 'button',
          header: { type: 'text', text: header },
          body: { text: body },
          action: {
            buttons: buttons.map((b, i) => ({
              type: 'reply',
              reply: { id: b.id || `btn_${i}`, title: b.title.substring(0, 20) },
            })),
          },
        },
      }),
    });
    if (!res.ok) console.error('[wa-interactive] send failed:', res.status, await res.text().catch(() => ''));
  } catch (e) {
    console.error('[wa-interactive] network error:', e.message);
  }
}

async function sendWhatsAppList(to, header, body, buttonText, sections) {
  const phoneId = process.env.WHATSAPP_PHONE_NUMBER_ID;
  const token   = process.env.WHATSAPP_ACCESS_TOKEN;
  if (!phoneId || !token) return;

  await fetch(`${WA_API}/${phoneId}/messages`, {
    method: 'POST',
    headers: {
      'Authorization': `Bearer ${token}`,
      'Content-Type': 'application/json',
    },
    signal: AbortSignal.timeout(15000),
    body: JSON.stringify({
      messaging_product: 'whatsapp',
      to,
      type: 'interactive',
      interactive: {
        type: 'list',
        header: { type: 'text', text: header.substring(0, 60) },
        body: { text: body.substring(0, 1024) },
        action: {
          button: buttonText.substring(0, 20),
          sections: sections.map(s => ({
            title: (s.title || '').substring(0, 24),
            rows: (s.rows || []).slice(0, 10).map(r => ({
              id: (r.id || '').substring(0, 200),
              title: (r.title || '').substring(0, 24),
              description: (r.description || '').substring(0, 72),
            })),
          })),
        },
      },
    }),
  }).catch(e => console.error('[wa] list send failed:', e.message));
}

// ─── Download media from WhatsApp Cloud API ───

async function downloadWhatsAppMedia(mediaId) {
  const token = process.env.WHATSAPP_ACCESS_TOKEN;
  if (!token || !mediaId) return null;
  try {
    // Step 1: Get the media URL
    const metaRes = await fetch(`${WA_API}/${mediaId}`, {
      headers: { 'Authorization': `Bearer ${token}` },
      signal: AbortSignal.timeout(15000),
    });
    if (!metaRes.ok) { console.error('[wa-media] metadata fetch failed:', metaRes.status); return null; }
    const meta = await metaRes.json();
    const mediaUrl = meta.url;
    if (!mediaUrl) return null;

    // Step 2: Download the media binary
    const dlRes = await fetch(mediaUrl, {
      headers: { 'Authorization': `Bearer ${token}` },
      signal: AbortSignal.timeout(30000),
    });
    if (!dlRes.ok) { console.error('[wa-media] download failed:', dlRes.status); return null; }
    const buffer = Buffer.from(await dlRes.arrayBuffer());
    // Reject files larger than 10MB to prevent memory exhaustion
    if (buffer.length > 10 * 1024 * 1024) {
      console.warn(`[wa-media] Buffer too large (${(buffer.length / 1024 / 1024).toFixed(1)}MB), skipping`);
      return null;
    }
    const mimeType = meta.mime_type || 'image/jpeg';
    const base64 = buffer.toString('base64');
    return { base64, mimeType, dataUrl: `data:${mimeType};base64,${base64}`, buffer };
  } catch (e) {
    console.error('[wa-media] error:', e.message);
    // Log media download failure to admin
    logErrorToAdmin('media_download_error', 'WhatsApp media download failed', 'whatsapp_bot', e.message).catch(() => {});
    return null;
  }
}

// ─── Upload image buffer to Firebase Storage and return download URL ───

async function uploadImageToStorage(buffer, mimeType) {
  try {
    const bucket = admin.storage().bucket('promaintapp-b618a.firebasestorage.app');
    const ext = (mimeType || 'image/jpeg').includes('png') ? 'png' : 'jpg';
    const fileName = `booking_images/${Date.now()}_${Math.random().toString(36).substring(2, 10)}.${ext}`;
    const file = bucket.file(fileName);
    await file.save(buffer, {
      metadata: { contentType: mimeType || 'image/jpeg' },
      public: true,
    });
    // Get public download URL
    const url = `https://storage.googleapis.com/${bucket.name}/${fileName}`;
    console.log(`[wa-media] Uploaded image to Storage: ${fileName}`);
    return url;
  } catch (e) {
    console.error('[wa-media] Storage upload failed:', e.message);
    return null;
  }
}

// ─── Transcribe audio via Whisper ───

async function transcribeAudio(mediaId) {
  try {
    const media = await downloadWhatsAppMedia(mediaId);
    if (!media || !media.buffer) return null;

    // Whisper accepts common audio formats — WhatsApp voice notes are ogg/opus
    const ext = (media.mimeType || '').includes('ogg') ? 'ogg'
      : (media.mimeType || '').includes('mp4') ? 'mp4'
      : (media.mimeType || '').includes('mpeg') ? 'mp3' : 'ogg';

    const file = new File([media.buffer], `voice.${ext}`, { type: media.mimeType || 'audio/ogg' });
    const transcription = await openai.audio.transcriptions.create({
      model: 'whisper-1',
      file,
      language: 'en',
    });
    return transcription.text || null;
  } catch (e) {
    console.warn('[whisper] Transcription failed:', e.message);
    // Log transcription failure to admin
    logErrorToAdmin('transcription_error', 'Voice note transcription failed', 'whatsapp_bot', e.message).catch(() => {});
    return null;
  }
}

// ─── Error reporting helper — logs to Firestore for admin real-time monitoring ───

async function logErrorToAdmin(errorType, description, source, errorDetails, bookingId, severity) {
  const firestore = db();
  if (!firestore) return null;
  try {
    const errorId = firestore.collection('error_logs').doc().id;
    const sev = severity || 'medium';
    const icons = { critical: '🔴', high: '🟠', medium: '🟡', low: '🔵' };
    const labels = {
      payment_error: 'Payment Error',
      image_upload_error: 'Image Upload Failed',
      booking_error: 'Booking Creation Failed',
      media_download_error: 'Media Download Failed',
      transcription_error: 'Voice Transcription Failed',
      rfq_quote_error: 'RFQ Quote Generation Failed',
      network_error: 'Network/API Error',
    };
    const label = labels[errorType] || `System Error: ${errorType}`;

    await firestore.collection('error_logs').doc(errorId).set({
      id: errorId,
      error_type: errorType,
      description,
      source: source || 'whatsapp_bot',
      error_details: errorDetails || '',
      booking_id: bookingId || '',
      user_id: '',
      severity: sev,
      status: 'open',
      created_at: admin.firestore.FieldValue.serverTimestamp(),
    });

    await firestore.collection('Notifications').add({
      title: `${icons[sev] || '🔵'} ${label}`,
      body: description,
      type: 'error_report',
      error_id: errorId,
      booking_id: bookingId || '',
      target: 'admin',
      user_type: 'admin',
      read: false,
      timestamp: admin.firestore.FieldValue.serverTimestamp(),
      created_at: admin.firestore.FieldValue.serverTimestamp(),
    });

    return errorId;
  } catch (err) {
    console.error('[errorReport] Failed to log error:', err.message);
    return null;
  }
}

async function notifyWebhookProcessingFailure(phone, err, userText = '') {
  const detail = err?.message || String(err || 'unknown_error');
  try {
    await logErrorToAdmin(
      'network_error',
      'WhatsApp webhook processing failed',
      'whatsapp_bot',
      `phone=${phone || 'unknown'}; userText=${String(userText || '').slice(0, 200)}; error=${detail}`,
      '',
      'high'
    );
  } catch (_) {}

  if (!phone) return;
  try {
    await sendWhatsAppMessage(
      phone,
      'I hit a temporary problem while processing that message. Please try again, or send Hi to restart the chat.'
    );
  } catch (sendErr) {
    console.error('[webhook] failed to send fallback message:', sendErr?.message || sendErr);
  }
}

// ─── Session management (in-memory + Firestore backup) ───

const sessions = new Map();
const SESSION_TTL_MS = 30 * 60 * 1000; // 30 min

function getSession(phone) {
  let s = sessions.get(phone);
  if (s && Date.now() - s.lastActivity > SESSION_TTL_MS) {
    sessions.delete(phone);
    s = null;
  }
  if (!s) {
    s = {
      phone,
      messages: [],
      bookingData: {},
      linkedUserId: null,   // app account link
      promoCode: null,      // active promo for current booking
      promoDiscount: 0,
      photoUrls: [],        // Firebase Storage URLs for photos sent during this session
      lastActivity: Date.now(),
      _restored: false,     // whether Firestore restore was attempted
    };
    sessions.set(phone, s);
  }
  s.lastActivity = Date.now();
  return s;
}

// Periodic session cleanup to prevent memory leaks from abandoned sessions
setInterval(() => {
  const now = Date.now();
  for (const [phone, s] of sessions) {
    if (now - s.lastActivity > SESSION_TTL_MS) {
      sessions.delete(phone);
    }
  }
}, 10 * 60 * 1000); // every 10 minutes

// ── Artisan acceptance timeout: re-dispatch or escalate after 30 minutes ──
setInterval(async () => {
  const firestore = db();
  if (!firestore) return;
  try {
    const cutoff = new Date(Date.now() - 30 * 60 * 1000); // 30 min ago
    // Check futureBookings stuck in pending_artisan_acceptance
    const stuckSnap = await firestore.collection('futureBookings')
      .where('status', '==', 'pending_artisan_acceptance')
      .where('rfq_auto_assigned', '==', true)
      .limit(20)
      .get();
    for (const doc of stuckSnap.docs) {
      const data = doc.data();
      // Parse various timestamp formats
      let assignedAt = null;
      const raw = data.rfq_auto_assigned_at || data.accepted_at || data.updated_at || data.creation_date;
      if (raw) {
        assignedAt = raw.toDate ? raw.toDate() : new Date(raw);
      }
      if (!assignedAt || assignedAt > cutoff) continue; // Not yet timed out

      const rejCount = data.rfq_artisan_rejection_count || 0;
      console.log(`[timeout] Booking ${doc.id} stuck ${Math.round((Date.now() - assignedAt.getTime()) / 60000)}min, rejections=${rejCount}`);

      // Escalate to admin after timeout
      await doc.ref.update({
        status: 'pending_admin_review',
        rfq_status: 'timeout_escalated',
        rfq_timeout_at: new Date().toISOString(),
        rfq_timeout_reason: `No artisan accepted within 30 minutes (${rejCount} rejections)`,
        updated_at: new Date().toISOString(),
      });
      // Mirror to tasksManagement
      try {
        await firestore.collection('tasksManagement').doc(doc.id).update({
          status: 'pending_admin_review',
          rfq_status: 'timeout_escalated',
          updated_at: new Date().toISOString(),
        });
      } catch (e) { /* tasksManagement doc may not exist */ }
      // Notify admin
      await firestore.collection('notifications').add({
        title: '⏰ Artisan Acceptance Timeout',
        body: `No artisan accepted booking ${data.rfq_no || data.order_no || doc.id} within 30 minutes. Manual assignment needed.`,
        type: 'artisan_timeout',
        user_type: 'admin',
        booking_id: doc.id,
        read: false,
        created_at: admin.firestore.FieldValue.serverTimestamp(),
      });
      // Notify customer via WhatsApp
      const custPhone = data.customerPhone || data.contact || data.user_phone || '';
      if (custPhone) {
        try {
          await sendWhatsAppMessage(custPhone,
            `⏰ We're sorry — no artisan was available to accept your booking #${data.rfq_no || data.order_no || doc.id} within the expected timeframe.\n\nYour request has been escalated to our team. An admin will manually assign an artisan and notify you shortly. Thank you for your patience! 🙏`);
        } catch (e) { console.warn(`[timeout] WA notify failed for ${doc.id}:`, e.message); }
      }
      console.log(`[timeout] Escalated ${doc.id} to admin review`);
    }
  } catch (e) {
    console.warn('[timeout] Acceptance timeout check failed:', e.message);
  }
}, 15 * 60 * 1000); // check every 15 minutes

/** Restore session context from Firestore when server restarts (best-effort). */
async function restoreSessionFromFirestore(session) {
  if (session._restored) return;
  session._restored = true;
  const firestore = db();
  if (!firestore) return;
  try {
    const doc = await firestore.collection('wa_sessions').doc(session.phone).get();
    if (!doc.exists) return;
    const data = doc.data();
    // Only restore if Firestore data is recent (within TTL)
    const lastTs = data.lastActivity?.toMillis?.() || data.lastActivity || 0;
    if (Date.now() - lastTs > SESSION_TTL_MS) return;
    // Restore conversation history
    if (Array.isArray(data.messages) && data.messages.length > 0) {
      session.messages = data.messages;
    }
    // Restore linked account
    if (data.linkedUserId) session.linkedUserId = data.linkedUserId;
    // Restore photo URLs and last booking ID
    if (Array.isArray(data.photoUrls) && data.photoUrls.length > 0) {
      session.photoUrls = data.photoUrls;
    }
    if (data.lastBookingId) session.lastBookingId = data.lastBookingId;
    if (data.lastBookingCost) session.lastBookingCost = data.lastBookingCost;
    if (data.lastRfqId) session.lastRfqId = data.lastRfqId;
    if (data.pendingRatingBookingId) session.pendingRatingBookingId = data.pendingRatingBookingId;
    if (data.sharedAddress) session.sharedAddress = data.sharedAddress;
    if (data.sharedLatitude) session.sharedLatitude = data.sharedLatitude;
    if (data.sharedLongitude) session.sharedLongitude = data.sharedLongitude;
    if (data.promoCode) {
      session.promoCode = data.promoCode;
      session.promoDiscount = data.promoDiscount || 0;
      session.promoDiscountType = data.promoDiscountType || 'fixed';
    }
    console.log(`[session] Restored ${session.phone} from Firestore (${session.messages.length} msgs, ${session.photoUrls.length} photos)`);
  } catch (e) {
    console.warn('[session] Firestore restore failed:', e.message);
  }
}

// ─── Helper: find app user by phone ───

async function findUserByPhone(phone) {
  const firestore = db();
  if (!firestore) return null;
  // Normalise: strip leading '+' and country code variations
  const variants = [phone];
  if (phone.startsWith('27')) variants.push('0' + phone.slice(2), '+' + phone);
  if (phone.startsWith('+27')) variants.push('0' + phone.slice(3), phone.slice(1));
  if (phone.startsWith('0')) variants.push('27' + phone.slice(1), '+27' + phone.slice(1));

  // Also build numeric (int) variants — Flutter app stores `contact` as int
  const numericVariants = new Set();
  for (const v of variants) {
    const n = parseInt(v, 10);
    if (!isNaN(n)) numericVariants.add(n);
  }

  for (const v of variants) {
    for (const field of ['contact', 'phone', 'mobile', 'phoneNumber', 'phone_number']) {
      // Search with string value
      const snap = await firestore.collection('users').where(field, '==', v).limit(1).get();
      if (!snap.empty) return { id: snap.docs[0].id, ...snap.docs[0].data() };
    }
  }

  // Search with numeric (int) values for fields that might be stored as numbers
  for (const n of numericVariants) {
    for (const field of ['contact', 'phone', 'mobile', 'phoneNumber', 'phone_number']) {
      const snap = await firestore.collection('users').where(field, '==', n).limit(1).get();
      if (!snap.empty) return { id: snap.docs[0].id, ...snap.docs[0].data() };
    }
  }

  return null;
}

// ─── OpenAI tools for WhatsApp conversation ───

const waTools = [
  {
    type: 'function',
    function: {
      name: 'list_service_categories',
      description: 'List available service categories (plumbing, electrical, painting, etc.)',
      parameters: { type: 'object', properties: {}, required: [] },
    },
  },
  {
    type: 'function',
    function: {
      name: 'create_booking',
      description: 'Create a new maintenance booking. Collect category, description, address, urgency, and customer name before calling.',
      parameters: {
        type: 'object',
        properties: {
          category:     { type: 'string', description: 'Service category (e.g. plumbing, electrical)' },
          subcategory:  { type: 'string', description: 'Specific service needed' },
          description:  { type: 'string', description: 'Detailed description of the issue' },
          address:      { type: 'string', description: 'Full service address where the work needs to be done (street, area, city)' },
          urgency:      { type: 'string', enum: ['normal', 'urgent', 'emergency'] },
          customerName: { type: 'string', description: 'Customer full name' },
          scheduledDate:{ type: 'string', description: 'Preferred date (YYYY-MM-DD) if customer specifies' },
          scheduledTime:{ type: 'string', description: 'Preferred time (HH:MM) if customer specifies' },
        },
        required: ['category', 'description', 'address', 'customerName'],
      },
    },
  },
  {
    type: 'function',
    function: {
      name: 'check_booking_status',
      description: 'Check the status of an existing booking by booking ID or phone number',
      parameters: {
        type: 'object',
        properties: {
          bookingId: { type: 'string', description: 'Booking ID (e.g. WA-XXXXX or order number)' },
        },
      },
    },
  },
  {
    type: 'function',
    function: {
      name: 'get_my_bookings',
      description: 'List the customer\'s recent bookings (up to 5). Use this when a customer asks about their bookings.',
      parameters: { type: 'object', properties: {}, required: [] },
    },
  },
  {
    type: 'function',
    function: {
      name: 'lookup_pricing',
      description: 'MUST be called BEFORE create_booking. Looks up fixed pricing for a service. Returns the exact fixed price if available, or suggests RFQ if not.',
      parameters: {
        type: 'object',
        properties: {
          category:    { type: 'string', description: 'Service category (e.g. plumbing, electrical, painting)' },
          subcategory: { type: 'string', description: 'Specific service needed (e.g. toilet unblocking, leak repair, light installation)' },
        },
        required: ['category'],
      },
    },
  },
  {
    type: 'function',
    function: {
      name: 'apply_promo_code',
      description: 'Validate and apply a promotional/discount code to the current session',
      parameters: {
        type: 'object',
        properties: {
          code: { type: 'string', description: 'The promo code entered by the customer' },
        },
        required: ['code'],
      },
    },
  },
  {
    type: 'function',
    function: {
      name: 'request_payment_link',
      description: 'Generate a payment link for an unpaid booking so the customer can pay via card. MUST ask the customer whether they want to pay the full amount or a 35% deposit first, then pass their choice as paymentType.',
      parameters: {
        type: 'object',
        properties: {
          bookingId: { type: 'string', description: 'The booking ID to generate payment for' },
          paymentType: { type: 'string', enum: ['full', 'deposit'], description: 'Whether the customer is paying the full amount or a 35% deposit. MUST ask the customer before calling.' },
        },
        required: ['bookingId', 'paymentType'],
      },
    },
  },
  {
    type: 'function',
    function: {
      name: 'check_wallet_balance',
      description: 'Check the customer\'s wallet balance (requires linked account)',
      parameters: { type: 'object', properties: {}, required: [] },
    },
  },
  {
    type: 'function',
    function: {
      name: 'pay_with_wallet',
      description: 'Pay for a booking using wallet balance',
      parameters: {
        type: 'object',
        properties: {
          bookingId: { type: 'string', description: 'The booking ID to pay for' },
        },
        required: ['bookingId'],
      },
    },
  },
  {
    type: 'function',
    function: {
      name: 'submit_rfq',
      description: 'Submit a Request for Quote (RFQ) for complex or large maintenance jobs that need a detailed quotation before proceeding.',
      parameters: {
        type: 'object',
        properties: {
          category:     { type: 'string', description: 'Service category' },
          description:  { type: 'string', description: 'Detailed description of the work needed' },
          address:      { type: 'string', description: 'Property address' },
          customerName: { type: 'string', description: 'Customer full name' },
          materialsResponsibility: { type: 'string', enum: ['client', 'artisan'], description: 'Who provides materials' },
        },
        required: ['category', 'description', 'customerName'],
      },
    },
  },
  {
    type: 'function',
    function: {
      name: 'cancel_booking',
      description: 'Cancel a booking and initiate refund if payment was made',
      parameters: {
        type: 'object',
        properties: {
          bookingId: { type: 'string', description: 'The booking ID to cancel' },
          reason:    { type: 'string', description: 'Reason for cancellation' },
        },
        required: ['bookingId'],
      },
    },
  },
  {
    type: 'function',
    function: {
      name: 'reschedule_booking',
      description: 'Reschedule a booking to a new date and/or time',
      parameters: {
        type: 'object',
        properties: {
          bookingId:    { type: 'string', description: 'The booking ID to reschedule' },
          newDate:      { type: 'string', description: 'New date (YYYY-MM-DD)' },
          newTime:      { type: 'string', description: 'New time (HH:MM)' },
        },
        required: ['bookingId', 'newDate'],
      },
    },
  },
  {
    type: 'function',
    function: {
      name: 'rate_booking',
      description: 'Submit a rating and review for a completed job',
      parameters: {
        type: 'object',
        properties: {
          bookingId: { type: 'string', description: 'The completed booking ID' },
          rating:    { type: 'number', description: 'Rating from 1 to 5 stars' },
          comment:   { type: 'string', description: 'Optional review comment' },
        },
        required: ['bookingId', 'rating'],
      },
    },
  },
  {
    type: 'function',
    function: {
      name: 'request_refund',
      description: 'Request a refund for a booking',
      parameters: {
        type: 'object',
        properties: {
          bookingId: { type: 'string', description: 'The booking ID to refund' },
          reason:    { type: 'string', description: 'Reason for refund request' },
        },
        required: ['bookingId', 'reason'],
      },
    },
  },
  {
    type: 'function',
    function: {
      name: 'link_partner_code',
      description: 'Link a corporate partner or referral code to the customer\'s account for commission tracking and potential discounts',
      parameters: {
        type: 'object',
        properties: {
          referralCode: { type: 'string', description: 'The partner/referral code' },
        },
        required: ['referralCode'],
      },
    },
  },
  {
    type: 'function',
    function: {
      name: 'link_account',
      description: 'Link the WhatsApp number to an existing Square 15 app account. Call this when a customer wants to connect their app account.',
      parameters: { type: 'object', properties: {}, required: [] },
    },
  },
  {
    type: 'function',
    function: {
      name: 'register_account',
      description: 'Register a new Square 15 account directly via WhatsApp. Use this for customers who don\'t have the app. Collect their full name first, then optionally ask for email, address, and referral/partner code.',
      parameters: {
        type: 'object',
        properties: {
          name:         { type: 'string', description: 'Customer full name' },
          email:        { type: 'string', description: 'Email address (optional but recommended)' },
          address:      { type: 'string', description: 'Home/service address (optional)' },
          referralCode: { type: 'string', description: 'Partner or referral code if the customer has one (optional)' },
        },
        required: ['name'],
      },
    },
  },
  {
    type: 'function',
    function: {
      name: 'check_rfq_status',
      description: 'Check the status of an RFQ (Request for Quote). Returns quote details, breakdown, and acceptance status. Can look up by RFQ ID or list all RFQs for the customer.',
      parameters: {
        type: 'object',
        properties: {
          rfqId: { type: 'string', description: 'The RFQ ID or booking ID (e.g. RFQ-XXXXX). If omitted, lists all RFQs for this customer.' },
        },
      },
    },
  },
  {
    type: 'function',
    function: {
      name: 'accept_rfq_quote',
      description: 'Accept a quoted RFQ and proceed to payment. Customer confirms the AI-generated or admin-provided quote.',
      parameters: {
        type: 'object',
        properties: {
          rfqId: { type: 'string', description: 'The RFQ ID to accept' },
        },
        required: ['rfqId'],
      },
    },
  },
  {
    type: 'function',
    function: {
      name: 'reject_rfq_quote',
      description: 'Reject or request changes to an RFQ quote. Puts the RFQ into negotiation with admin.',
      parameters: {
        type: 'object',
        properties: {
          rfqId: { type: 'string', description: 'The RFQ ID to reject/negotiate' },
          reason: { type: 'string', description: 'Reason for rejection or what changes are requested' },
        },
        required: ['rfqId'],
      },
    },
  },
  {
    type: 'function',
    function: {
      name: 'explain_quote',
      description: 'Explain the quote/pricing details and cost breakdown for a booking or RFQ',
      parameters: {
        type: 'object',
        properties: {
          bookingId: { type: 'string', description: 'The booking or RFQ ID to explain the quote for' },
        },
        required: ['bookingId'],
      },
    },
  },
  {
    type: 'function',
    function: {
      name: 'check_payment',
      description: 'Check payment status, method, and history for a booking',
      parameters: {
        type: 'object',
        properties: {
          bookingId: { type: 'string', description: 'The booking ID to check payment for' },
        },
        required: ['bookingId'],
      },
    },
  },
  {
    type: 'function',
    function: {
      name: 'get_messages',
      description: 'Get messages/chat history for a booking between client and artisan',
      parameters: {
        type: 'object',
        properties: {
          bookingId: { type: 'string', description: 'The booking ID to get messages for' },
        },
        required: ['bookingId'],
      },
    },
  },
  {
    type: 'function',
    function: {
      name: 'send_message',
      description: 'Send a message to the artisan or admin related to a booking',
      parameters: {
        type: 'object',
        properties: {
          bookingId: { type: 'string', description: 'The booking ID the message relates to' },
          message: { type: 'string', description: 'The message content' },
          recipient: { type: 'string', description: 'Who to send to: artisan or admin', enum: ['artisan', 'admin'] },
        },
        required: ['bookingId', 'message'],
      },
    },
  },
  {
    type: 'function',
    function: {
      name: 'list_cases',
      description: 'List your support/complaint cases, optionally filtered by state',
      parameters: {
        type: 'object',
        properties: {
          state: { type: 'string', description: 'Filter by state: open, closed. Omit for all.' },
        },
      },
    },
  },
  {
    type: 'function',
    function: {
      name: 'reply_to_case',
      description: 'Add a reply or follow-up to an existing support case',
      parameters: {
        type: 'object',
        properties: {
          caseId: { type: 'string', description: 'The case ID to reply to' },
          message: { type: 'string', description: 'The reply message' },
        },
        required: ['caseId', 'message'],
      },
    },
  },
  {
    type: 'function',
    function: {
      name: 'get_case_details',
      description: 'Get full details and reply history for a support case',
      parameters: {
        type: 'object',
        properties: {
          caseId: { type: 'string', description: 'The case ID' },
        },
        required: ['caseId'],
      },
    },
  },
  {
    type: 'function',
    function: {
      name: 'report_issue',
      description: 'Report a technical issue the customer is experiencing (payment failure, photo upload problem, app error, etc.). Auto-creates a support case and alerts admin for real-time fixing.',
      parameters: {
        type: 'object',
        properties: {
          error_type: { type: 'string', description: 'Type of error: payment_error, image_upload_error, booking_error, network_error, app_crash, loading_error' },
          description: { type: 'string', description: 'What happened — what the customer was trying to do and what went wrong' },
          booking_id: { type: 'string', description: 'Related booking ID if applicable' },
        },
        required: ['error_type', 'description'],
      },
    },
  },
];

// ─── Builders.co.za Real-Time Pricing (same logic as Cloud Functions & client app) ───

let _waBuildersCache = { fetchedAt: 0, ttlMs: 12 * 60 * 60 * 1000, value: null };

function _str(v) { return v == null ? '' : String(v); }

function normalizeBuildersQuery(name) {
  let q = _str(name);
  q = q.replace(/\b(size\s+tbd|tbd|-\s*size\s+tbd)\b/gi, ' ');
  q = q.replace(/\([^)]*\)/g, ' ');
  q = q.replace(/\s+/g, ' ').trim();
  return q;
}

function buildersHeaders({ referer } = {}) {
  const h = {
    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36',
    Accept: 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
    'Accept-Language': 'en-ZA,en;q=0.9',
    'Cache-Control': 'no-cache',
    Pragma: 'no-cache',
  };
  if (referer) h.Referer = referer;
  h.Origin = 'https://www.builders.co.za';
  return h;
}

function buildersCorrelationId() {
  return `${Date.now().toString(36)}${Math.random().toString(36).slice(2, 14)}`;
}

async function buildersFetch(url, { method = 'GET', headers, body, timeoutMs = 15000 } = {}) {
  const controller = new AbortController();
  const id = setTimeout(() => controller.abort(), timeoutMs);
  try { return await fetch(url, { method, headers, body, signal: controller.signal }); }
  finally { clearTimeout(id); }
}

function extractLiters(s) {
  const m = _str(s).toLowerCase().match(/\b(\d{2,4})\s*(?:l|lt|litre|liter|litres|liters)\b/);
  if (!m) return null;
  const v = parseInt(m[1], 10);
  return Number.isFinite(v) && v >= 40 && v <= 600 ? v : null;
}

function buildersTokens(s) {
  const cleaned = _str(s).toLowerCase().replace(/[()[\],]/g, ' ').replace(/[^a-z0-9\s./-]/g, ' ').replace(/\s+/g, ' ').trim();
  return cleaned ? cleaned.split(' ').map(t => t.trim()).filter(t => t.length > 2) : [];
}

function parseZarPrice(raw) {
  const cleaned = _str(raw).replace(/[^0-9,.]/g, '');
  if (!cleaned) return null;
  const v = parseFloat(cleaned.replace(/,/g, ''));
  return Number.isFinite(v) ? v : null;
}

function extractRetailPriceFromHtml(html) {
  const meta = html.match(/(product:price:amount|og:price:amount|twitter:data1)"\s+content="([0-9.,]+)"/i);
  if (meta && meta[2]) { const p = parseZarPrice(meta[2]); if (p > 0) return p; }
  const jsonLd = html.match(/"price"\s*:\s*"?([0-9]{1,3}(?:,[0-9]{3})*(?:\.[0-9]{2})?)"?/i);
  if (jsonLd && jsonLd[1]) { const p = parseZarPrice(jsonLd[1]); if (p > 0) return p; }
  const visible = html.match(/R\s*([0-9]{1,3}(?:,[0-9]{3})*(?:\.[0-9]{2})?)/);
  if (visible && visible[1]) { const p = parseZarPrice(visible[1]); if (p > 0) return p; }
  return null;
}

function buildersBffHeaders({ operationName, operationHash } = {}) {
  return {
    ...buildersHeaders({ referer: 'https://www.builders.co.za/' }),
    Accept: 'application/json, text/plain, */*',
    'Content-Type': 'application/json',
    WM_TENANT_ID: '32',
    request_origin: 'web',
    'wm_qos.correlation_id': buildersCorrelationId(),
    'x-apollo-operation-name': operationName || 'search',
    'x-apollo-operation-hash': operationHash || '',
  };
}

function extractPriceFromBffItem(item) {
  const candidate = item?.price ?? item?.prices ?? item?.priceData ?? item?.pricing;
  const fromAny = (v) => {
    if (v == null) return null;
    if (typeof v === 'number') return v;
    if (typeof v === 'string') return parseZarPrice(v);
    if (typeof v === 'object') {
      for (const k of ['formattedValue', 'formatted', 'display']) { const p = parseZarPrice(v[k]); if (p > 0) return p; }
      for (const k of ['value', 'current', 'retail']) { if (typeof v[k] === 'number') return v[k]; const p = parseZarPrice(v[k]); if (p > 0) return p; }
      return null;
    }
    return null;
  };
  let p = fromAny(candidate);
  if (p > 0) return p;
  if (candidate && typeof candidate === 'object') {
    p = fromAny(candidate.retail) ?? fromAny(candidate.current) ?? fromAny(candidate.selling);
    if (p > 0) return p;
  }
  for (const k of ['formattedPrice', 'sellingPrice', 'retailPrice', 'priceInclVat', 'price_incl_vat']) {
    p = parseZarPrice(item?.[k]); if (p > 0) return p;
  }
  return null;
}

async function getBuildersBffConfig() {
  const now = Date.now();
  if (now - _waBuildersCache.fetchedAt <= _waBuildersCache.ttlMs) return _waBuildersCache.value;
  try {
    const extractScripts = (html) => {
      const out = [];
      for (const m of html.matchAll(/\bsrc="([^"]+\.js[^"]*)"/gi)) {
        const s = _str(m[1]);
        if (s && !/googletagmanager|google-analytics|gtm\.js/i.test(s)) out.push(s);
      }
      return [...new Set(out)];
    };
    const toAbs = (u) => u ? (u.startsWith('http') ? u : `https://www.builders.co.za${u.startsWith('/') ? '' : '/'}${u}`) : null;
    const bootstrapUrls = [
      'https://www.builders.co.za/',
      'https://www.builders.co.za/Plumbing-Bathroom-and-Kitchen/Geysers-and-Water-Heaters/Geysers/Kwikot-DSG-200-5-400KPA-Superline-Dual-Geyser-200-L/p/000000000000659070',
    ];
    let html = null;
    for (const u of bootstrapUrls) {
      const r = await buildersFetch(u, { headers: buildersHeaders({ referer: 'https://www.builders.co.za/' }), timeoutMs: 20000 });
      if (!r.ok || _str(r.url).includes('/blocked?')) continue;
      const t = await r.text(); if (t) { html = t; break; }
    }
    if (!html) { _waBuildersCache = { ..._waBuildersCache, fetchedAt: now, value: null }; return null; }
    const scripts = extractScripts(html).map(toAbs).filter(Boolean);
    if (!scripts.length) { _waBuildersCache = { ..._waBuildersCache, fetchedAt: now, value: null }; return null; }
    const preferred = [...scripts].sort((a, b) => {
      const sc = (u) => /\/main\.[a-z0-9]{8,40}\.js/i.test(u) ? 0 : /runtimechunk~main/i.test(u) ? 2 : /\.js$/i.test(u) ? 5 : 9;
      return sc(a) - sc(b);
    });
    let hash = null, site = null;
    for (const jsUrl of preferred.slice(0, 12)) {
      const r = await buildersFetch(jsUrl, { headers: buildersHeaders({ referer: 'https://www.builders.co.za/' }), timeoutMs: 25000 });
      if (!r.ok) continue;
      const js = await r.text(); if (!js) continue;
      const hm = js.match(/SearchHash\s*=\s*"([a-f0-9]{32,80})"/i) || js.match(/\/wmapi\/bff\/graphql\/search\/([a-f0-9]{32,80})/i);
      hash = hm ? hm[1] : null;
      const sm = js.match(/BFF_SITE_VALUE\s*=\s*"([A-Z0-9]{3,10})"/);
      site = sm ? sm[1] : null;
      if (hash) break;
    }
    if (!hash) { _waBuildersCache = { ..._waBuildersCache, fetchedAt: now, value: null }; return null; }
    const cfg = { searchKey: 'search', searchHash: hash, site: site || 'BWH1' };
    _waBuildersCache = { ..._waBuildersCache, fetchedAt: now, value: cfg };
    return cfg;
  } catch (e) {
    console.error('[wa-builders] BFF config failed:', e.message);
    _waBuildersCache = { ..._waBuildersCache, fetchedAt: now, value: null };
    return null;
  }
}

async function hydrateProductPage(candidate, { referer } = {}) {
  try {
    const r = await buildersFetch(candidate.url, { headers: buildersHeaders({ referer }), timeoutMs: 20000 });
    if (!r.ok) return null;
    const html = await r.text();
    const price = extractRetailPriceFromHtml(html);
    if (!price || price <= 0) return null;
    const og = html.match(/property="og:title"\s+content="([^"]{3,200})"/i);
    return { ...candidate, title: og?.[1] || candidate.title, priceZar: price };
  } catch { return null; }
}

async function lookupBuildersPriceOne(rawName) {
  const q = normalizeBuildersQuery(rawName);
  if (!q) return null;
  const targetL = extractLiters(q);
  const wantsKwikot = q.toLowerCase().includes('kwikot');
  const cfg = await getBuildersBffConfig();
  if (!cfg) return null;
  const uri = `https://www.builders.co.za/wmapi/bff/graphql/${cfg.searchKey}/${cfg.searchHash}`;
  let decoded;
  try {
    const r = await buildersFetch(uri, {
      method: 'POST',
      headers: buildersBffHeaders({ operationName: cfg.searchKey, operationHash: cfg.searchHash }),
      body: JSON.stringify({ variables: { keyword: q, offset: 0, pageSize: 20, dynamicPriceRange: true, site: cfg.site } }),
      timeoutMs: 12000,
    });
    if (!r.ok) { if (r.status === 412) return { blocked: true }; return null; }
    decoded = await r.json();
  } catch { return null; }
  if (decoded?.redirectUrl && _str(decoded.redirectUrl).includes('/blocked')) return { blocked: true };
  const items = decoded?.data?.search?.data?.results?.items;
  if (!Array.isArray(items) || !items.length) return null;
  const qt = new Set(buildersTokens(q));
  const referer = `https://www.builders.co.za/search?text=${encodeURIComponent(q)}`;
  const scored = [];
  for (const it of items) {
    if (!it) continue;
    const title = _str(it.name || it.title || it.productName); if (!title) continue;
    const liters = extractLiters(title);
    if (targetL != null && liters != null && liters !== targetL) continue;
    let urlPath = _str(it.url || it.productUrl || it.seoUrl || it.link);
    if (!urlPath) { const code = _str(it.code || it.id || it.productCode); if (code) urlPath = `/p/${code}`; }
    if (!urlPath) continue;
    const url = urlPath.startsWith('http') ? urlPath : `https://www.builders.co.za${urlPath.startsWith('/') ? '' : '/'}${urlPath}`;
    const tt = new Set(buildersTokens(title));
    let score = 0;
    for (const t of qt) if (tt.has(t)) score++;
    if (targetL != null) { if (liters === targetL) score += 6; if (liters == null) score -= 2; }
    if (title.toLowerCase().includes('kwikot')) score += 2;
    if (wantsKwikot && !title.toLowerCase().includes('kwikot')) score -= 3;
    const price = extractPriceFromBffItem(it);
    if (price > 0) score += 2;
    scored.push({ score, candidate: { title, url, priceZar: price > 0 ? price : 0, source: price > 0 ? 'builders_bff' : 'builders_bff_no_price' } });
  }
  if (!scored.length) return null;
  scored.sort((a, b) => b.score - a.score);
  for (const row of scored.slice(0, 4)) {
    const c = row.candidate;
    if (c.priceZar > 0) return c;
    const h = await hydrateProductPage(c, { referer });
    if (!h) continue;
    if (targetL != null) { const hl = extractLiters(h.title); if (hl != null && hl !== targetL) continue; }
    return { ...h, source: 'builders_bff_hydrated' };
  }
  return null;
}

async function buildersBatchLookup(names, concurrency = 4) {
  const results = new Array(names.length);
  let i = 0;
  const workers = new Array(Math.min(concurrency, names.length)).fill(0).map(async () => {
    while (true) { const idx = i++; if (idx >= names.length) return; try { results[idx] = await lookupBuildersPriceOne(names[idx]); } catch { results[idx] = null; } }
  });
  await Promise.all(workers);
  return results;
}

async function lookupCatalog(firestore, name) {
  if (!firestore || !name) return null;
  try {
    const normalized = name.toLowerCase().replace(/\s+/g, '_');
    let doc = await firestore.collection('materialsCatalog').doc(normalized).get();
    if (doc.exists) { const d = doc.data(); const p = parseFloat(d.unit_price || d.price_incl_vat || d.price || 0); if (p > 0) return { price: p, source: 'catalog_doc_id' }; }
    let snap = await firestore.collection('materialsCatalog').where('name_lower', '==', normalized).limit(1).get();
    if (!snap.empty) { const d = snap.docs[0].data(); const p = parseFloat(d.unit_price || d.price_incl_vat || d.price || 0); if (p > 0) return { price: p, source: 'catalog_name_lower' }; }
    snap = await firestore.collection('materialsCatalog').where('aliases', 'array-contains', name.toLowerCase()).limit(1).get();
    if (!snap.empty) { const d = snap.docs[0].data(); const p = parseFloat(d.unit_price || d.price_incl_vat || d.price || 0); if (p > 0) return { price: p, source: 'catalog_alias' }; }
  } catch (e) { console.error('[wa-catalog] lookup error:', e.message); }
  return null;
}

async function getLearningFactor(firestore, category) {
  if (!firestore) return 1.0;
  try {
    const catSlug = (category || '').toLowerCase().replace(/\s+/g, '_');
    if (!catSlug) return 1.0;
    const snap = await firestore.collection('aiQuoteCorrections').where('category_id', '==', catSlug).orderBy('created_at', 'desc').limit(20).get();
    if (snap.empty) return 1.0;
    let total = 0, count = 0;
    snap.docs.forEach(doc => { const d = doc.data(); const ai = parseFloat(d.ai_total); const admin = parseFloat(d.admin_total); if (ai > 0 && admin > 0) { total += admin / ai; count++; } });
    if (count === 0) return 1.0;
    return Math.max(0.6, Math.min(1.6, total / count));
  } catch (e) { console.error('[wa-learning] error:', e.message); return 1.0; }
}

// ─── AI Quote Generation for RFQ (with Builders.co.za real-time pricing) ───

async function generateAIQuote(category, description, materialsResponsibility, additionalContext) {
  // Sanitize user-provided inputs before injecting into AI prompts
  category = sanitizeForPrompt(category, 100);
  description = sanitizeForPrompt(description, 1000);
  materialsResponsibility = sanitizeForPrompt(materialsResponsibility, 50);
  additionalContext = sanitizeForPrompt(additionalContext, 500);

  const firestore = db();

  // 1. Look up pricing guidance from Firestore
  let laborRate = 150;
  let pricingContext = '';
  try {
    if (firestore) {
      const catSlug = (category || '').toLowerCase().replace(/\s+/g, '_');
      const guidanceDoc = await firestore.collection('pricingGuidance').doc(catSlug).get();
      if (guidanceDoc.exists) {
        const gd = guidanceDoc.data();
        laborRate = parseFloat(gd.labor_cost_per_hour || gd.laborCostPerHour || 150);
        const servicePrices = gd.service_prices || gd.servicePrices || {};
        pricingContext = `Labor rate for ${category}: R${laborRate}/hr. Known service prices: ${JSON.stringify(servicePrices)}`;
      }
    }
  } catch (e) {
    console.error('[ai-quote] pricing lookup error:', e.message);
  }

  // 2. Ask OpenAI to generate structured quote (Builders-only materials rule)
  const quotePrompt = `You are a professional maintenance quotation system for South Africa.
Generate a detailed quote for the following job:

Category: ${category}
Description: ${description}
Materials responsibility: ${materialsResponsibility || 'artisan'}
${additionalContext ? `Additional context from photos/conversation: ${additionalContext}` : ''}
${pricingContext ? `\nPricing guidance from database: ${pricingContext}` : ''}

Return a JSON object with EXACTLY this structure:
{
  "laborHours": <number>,
  "laborCostPerHour": ${laborRate},
  "complexity": <1-5>,
  "equipmentCost": <number in ZAR>,
  "scopeOfWork": "<detailed scope of work>",
  "estimatedDuration": "<e.g. 1-2 days>",
  "materialsBOM": [
    {"name": "<material name>", "qty": <number>, "unit": "<each/m/m²/L/kg>", "estimated_price": <ZAR per unit>}
  ]
}

CRITICAL: Every material in materialsBOM MUST be a real product available on builders.co.za (Builders Warehouse).
Do NOT include specialty items or proprietary accessories that Builders does not stock.
Use realistic South African pricing (ZAR). Include ALL materials needed. Return ONLY the JSON object.`;

  try {
    const completion = await openai.chat.completions.create({
      model: 'gpt-4o-mini',
      temperature: 0.3,
      max_tokens: 1500,
      response_format: { type: 'json_object' },
      messages: [
        { role: 'system', content: 'You are a South African maintenance quotation expert. Only include materials available on builders.co.za. Return only valid JSON.' },
        { role: 'user', content: quotePrompt },
      ],
    });

    const raw = completion.choices[0]?.message?.content || '{}';
    const draft = JSON.parse(raw);

    const laborHours = parseFloat(draft.laborHours) || 4;
    const laborCostPerHour = parseFloat(draft.laborCostPerHour) || laborRate;

    // 3. Look up REAL Builders.co.za prices for each BOM item
    const rawBom = draft.materialsBOM || [];
    const materialNames = rawBom.map(m => m.name || '');
    console.log(`[wa-quote] Looking up ${materialNames.length} items on Builders.co.za...`);

    let buildersResults = [];
    try {
      buildersResults = await buildersBatchLookup(materialNames, 4);
      console.log(`[wa-quote] Builders: ${buildersResults.filter(r => r && r.priceZar > 0).length}/${materialNames.length} priced`);
    } catch (e) {
      console.error('[wa-quote] Builders batch error:', e.message);
    }

    // 4. Build BOM with real prices (Builders > Catalog > AI estimate fallback)
    const materialsMultiplier = 1.5;
    let materialsSubtotal = 0;
    const materialsBOM = [];
    for (let i = 0; i < rawBom.length; i++) {
      const m = rawBom[i];
      const qty = parseFloat(m.qty) || 1;
      const aiEstimate = parseFloat(m.estimated_price) || 0;
      const br = buildersResults[i];

      let unitPrice = aiEstimate;
      let matchedBy = 'ai_estimate';
      let buildersUrl = null;

      if (br && !br.blocked && br.priceZar > 0) {
        unitPrice = br.priceZar;
        matchedBy = br.source || 'builders_bff';
        buildersUrl = br.url || null;
      } else if (firestore) {
        const cat = await lookupCatalog(firestore, m.name);
        if (cat && cat.price > 0) { unitPrice = cat.price; matchedBy = cat.source; }
      }

      const lineBase = qty * unitPrice;
      materialsSubtotal += lineBase;
      const bomItem = { name: m.name, qty, unit: m.unit || 'each', unit_price: unitPrice, line_base: lineBase, matched_by: matchedBy };
      if (buildersUrl) bomItem.builders_url = buildersUrl;
      materialsBOM.push(bomItem);
    }

    // 5. Apply learning factor from historical admin corrections
    const learningFactor = await getLearningFactor(firestore, category);
    console.log(`[wa-quote] Learning factor for ${category}: ${learningFactor.toFixed(3)}`);

    const laborCost = laborHours * laborCostPerHour * learningFactor;
    const artisanBuysMaterials = (materialsResponsibility || 'artisan') === 'artisan';
    const materialsWithMarkup = materialsSubtotal * materialsMultiplier * learningFactor;
    const materialCostForTotals = artisanBuysMaterials ? materialsWithMarkup : 0;
    const equipmentCost = (parseFloat(draft.equipmentCost) || 0) * learningFactor;

    const subtotal = laborCost + materialCostForTotals + equipmentCost;
    const contingency = subtotal * 0.15;
    const grandTotal = subtotal + contingency;

    const buildersCount = materialsBOM.filter(b => b.matched_by && b.matched_by.startsWith('builders')).length;
    const catalogCount = materialsBOM.filter(b => b.matched_by && b.matched_by.startsWith('catalog')).length;
    const aiCount = materialsBOM.filter(b => b.matched_by === 'ai_estimate').length;

    const r2 = (v) => Math.round(v * 100) / 100;
    return {
      laborHours,
      laborCostPerHour,
      laborCost: r2(laborCost),
      complexity: draft.complexity || 3,
      materialsBOM,
      materialsMultiplier,
      materials_subtotal: r2(materialsSubtotal),
      materials_with_markup: r2(materialsWithMarkup),
      materials_responsibility: materialsResponsibility || 'artisan',
      equipmentCost: r2(equipmentCost),
      subtotal: r2(subtotal),
      contingency: r2(contingency),
      grand_total: r2(grandTotal),
      scope_of_work: draft.scopeOfWork || description,
      estimated_duration: draft.estimatedDuration || 'To be determined',
      learning_factor: r2(learningFactor),
      pricing_sources: { builders: buildersCount, catalog: catalogCount, ai_estimate: aiCount },
      breakdown: [
        { description: `Labour (${laborHours}hrs @ R${laborCostPerHour}/hr${learningFactor !== 1 ? ` × ${learningFactor.toFixed(2)} adj` : ''})`, cost: laborCost.toFixed(2) },
        ...(artisanBuysMaterials && materialsBOM.length > 0
          ? [{ description: `Materials (${buildersCount} Builders-priced, ${catalogCount} catalog, ${aiCount} estimated)`, cost: materialsWithMarkup.toFixed(2) }]
          : []),
        ...(equipmentCost > 0 ? [{ description: 'Equipment & Tools', cost: equipmentCost.toFixed(2) }] : []),
        { description: 'Contingency (15%)', cost: contingency.toFixed(2) },
      ],
      disclaimer: 'Quote uses real-time Builders.co.za pricing where available. Final costs may vary based on site conditions.',
      generated_at: new Date().toISOString(),
      source: 'whatsapp_ai_builders',
    };
  } catch (e) {
    console.error('[ai-quote] generation error:', e.message);
    return null;
  }
}

function formatQuoteForWhatsApp(quote, rfqNo) {
  const lines = [
    `\u{1F4CB} *AI Quote \u2014 ${rfqNo}*`,
    '',
    `\u{1F4DD} *Scope of Work:*`,
    quote.scope_of_work,
    '',
    `\u{1F4B0} *Cost Breakdown:*`,
    `\u2022 Labour: ${quote.laborHours}hrs \u00D7 R${quote.laborCostPerHour}/hr = *R${quote.laborCost.toFixed(2)}*`,
  ];

  if (quote.materials_responsibility === 'artisan' && quote.materialsBOM.length > 0) {
    lines.push(`\u2022 Materials (${quote.materialsBOM.length} items): R${quote.materials_subtotal.toFixed(2)} \u00D7 ${quote.materialsMultiplier} markup = *R${quote.materials_with_markup.toFixed(2)}*`);
    if (quote.pricing_sources) {
      const ps = quote.pricing_sources;
      lines.push(`  \u{1F3E2} ${ps.builders} Builders-priced | ${ps.catalog} catalog | ${ps.ai_estimate} estimated`);
    }
  } else if (quote.materialsBOM.length > 0) {
    lines.push(`\u2022 Materials (client provides): ${quote.materialsBOM.length} items listed`);
  }

  if (quote.equipmentCost > 0) {
    lines.push(`\u2022 Equipment: *R${quote.equipmentCost.toFixed(2)}*`);
  }

  lines.push(`\u2022 Contingency (15%): *R${quote.contingency.toFixed(2)}*`);
  lines.push('');
  lines.push(`\u{1F3F7}\uFE0F *Estimated Total: R${quote.grand_total.toFixed(2)}*`);
  lines.push('');
  lines.push(`\u23F1 Est. Duration: ${quote.estimated_duration}`);

  if (quote.materialsBOM.length > 0 && quote.materials_responsibility === 'artisan') {
    lines.push('');
    lines.push(`\u{1F4E6} *Materials List (from Builders.co.za):*`);
    quote.materialsBOM.forEach((m, i) => {
      const src = m.matched_by && m.matched_by.startsWith('builders') ? '\u2705' : m.matched_by && m.matched_by.startsWith('catalog') ? '\u{1F4D7}' : '\u{1F4CA}';
      lines.push(`${i + 1}. ${src} ${m.name} \u2014 ${m.qty} ${m.unit} @ R${m.unit_price.toFixed(2)} = R${m.line_base.toFixed(2)}`);
    });
    lines.push('');
    lines.push('\u2705 = Builders.co.za price | \u{1F4D7} = Catalog | \u{1F4CA} = Estimated');
  }

  lines.push('');
  lines.push(`\u26A0\uFE0F ${quote.disclaimer}`);
  lines.push('');
  lines.push('Reply *ACCEPT* to approve or *NEGOTIATE* to discuss changes.');

  return lines.join('\n');
}

// ─── Tool execution engine ───

async function executeWaTool(name, args, session) {
  const firestore = db();

  // Auto-link account if not linked yet
  if (!session.linkedUserId && firestore) {
    const user = await findUserByPhone(session.phone);
    if (user) session.linkedUserId = user.id;
  }

  switch (name) {

    // ═══════════════════════════════════════════
    // 1) LIST SERVICE CATEGORIES
    // ═══════════════════════════════════════════
    case 'list_service_categories': {
      if (!firestore) return { categories: ['Plumbing', 'Electrical', 'Painting', 'Carpentry', 'Roofing', 'Tiling', 'Locksmith', 'Appliance Repair', 'Landscaping', 'General Maintenance'] };
      try {
        const snap = await firestore.collection('categories').where('parent_id', '==', '').where('status', '==', 'publish').get();
        if (snap.empty) return { categories: ['Plumbing', 'Electrical', 'Painting', 'Carpentry', 'Roofing', 'Tiling', 'General Maintenance'] };
        return { categories: snap.docs.map(d => d.data().name || d.id) };
      } catch (e) {
        return { categories: ['Plumbing', 'Electrical', 'Painting', 'Carpentry', 'Roofing', 'Tiling', 'General Maintenance'] };
      }
    }

    // ═══════════════════════════════════════════
    // 2) CREATE BOOKING (writes to both tasksManagement + futureBookings)
    // ═══════════════════════════════════════════
    case 'create_booking': {
      if (!firestore) return { error: 'Database unavailable. Please try again later.' };

      const bookingId = `WA-${Date.now().toString(36).toUpperCase()}`;
      const orderNo = `SQ15-${bookingId}`;
      const now = new Date().toISOString();

      // Look up pricing estimate — tasks collection is AUTHORITATIVE (admin-managed)
      let estimatedCost = '0';
      let pricingSource = 'none';
      try {
        const catSlug = (args.category || '').toLowerCase().replace(/\s+/g, '_');
        const subQuery = (args.subcategory || args.description || '').toLowerCase();

        // Reuse fuzzy matching helpers (stem, synonyms, fuzzyMatch)
        const _normalize = (s) => s.toLowerCase().replace(/[_\-]+/g, ' ').trim();
        const _stem = (w) => w.replace(/(ing|ed|tion|ment|ness|able|ible|er|est|ly|s)$/i, '');
        const _synonyms = {
          plumbing:    ['toilet', 'cistern', 'basin', 'bath', 'tap', 'pipe', 'drain', 'geyser', 'shower', 'sink', 'plumb', 'blocked', 'leak', 'water', 'bathroom', 'kitchen'],
          electrical:  ['light', 'switch', 'socket', 'wire', 'wiring', 'breaker', 'db board', 'plug', 'circuit', 'electric', 'power', 'volt'],
          painting:    ['paint', 'wall', 'ceiling', 'enamel', 'pva', 'varnish', 'roof', 'garage', 'door'],
          cleaning:    ['clean', 'wash', 'deep clean', 'carpet', 'window', 'scrub'],
          tiling:      ['tile', 'floor', 'grout', 'ceramic'],
          carpentry:   ['wood', 'cabinet', 'shelf', 'cupboard', 'door', 'frame', 'carpenter'],
          solar:       ['panel', 'pv', 'inverter', 'battery', 'geyser', 'energy'],
          maintenance: ['repair', 'fix', 'maintain', 'service', 'general'],
          bathroom:    ['toilet', 'cistern', 'basin', 'bath', 'shower', 'tap', 'plumb', 'blocked', 'drain'],
          kitchen:     ['tap', 'mixer', 'sink', 'faucet', 'cupboard'],
          door:        ['lock', 'handle', 'hinge', 'frame', 'door'],
          window:      ['glass', 'pane', 'frame', 'window'],
          installation:['install', 'setup', 'mount', 'fit'],
        };
        const _fuzzyMatch = (qNorm, sNorm) => {
          if (sNorm.includes(qNorm) || qNorm.includes(sNorm)) return true;
          const qW = qNorm.split(/\s+/).filter(w => w.length >= 3);
          const sW = sNorm.split(/\s+/).filter(w => w.length >= 3);
          if (qW.some(w => sNorm.includes(w)) || sW.some(w => qNorm.includes(w))) return true;
          const qS = qW.map(_stem), sS = sW.map(_stem);
          if (qS.some(qs => sS.some(ss => qs === ss || qs.includes(ss) || ss.includes(qs)))) return true;
          const expanded = new Set(qW.concat(qS));
          for (const w of qW.concat(qS)) {
            if (_synonyms[w]) _synonyms[w].forEach(s => expanded.add(s));
            // Bidirectional: if word appears in a category's synonyms, add the category key + all siblings
            for (const [key, syns] of Object.entries(_synonyms)) {
              if (syns.includes(w)) {
                expanded.add(key);
                syns.forEach(s => expanded.add(s));
              }
            }
          }
          const exp = [...expanded];
          if (exp.some(qe => sW.some(sw => sw.includes(qe) || qe.includes(sw)))
              || exp.some(qe => sS.some(ss => ss.includes(qe) || qe.includes(ss)))) return true;
          return false;
        };
        const subNorm = _normalize(subQuery);

        // Score a match by specificity (higher = better)
        const _matchScore = (qNorm, sNorm) => {
          if (sNorm === qNorm) return 100;                                   // exact
          if (sNorm.includes(qNorm)) return 90;                              // query is substring of task
          if (qNorm.includes(sNorm)) return 85;                              // task is substring of query
          const qW = qNorm.split(/\s+/).filter(w => w.length >= 3);
          const sW = sNorm.split(/\s+/).filter(w => w.length >= 3);
          // Count how many query words appear literally in the task name
          const wordHits = qW.filter(w => sNorm.includes(w)).length + sW.filter(w => qNorm.includes(w)).length;
          if (wordHits >= 2) return 70 + wordHits;                           // multiple word hits
          if (wordHits === 1) return 60;                                     // single word hit
          const qS = qW.map(_stem), sS = sW.map(_stem);
          const stemHits = qS.filter(qs => sS.some(ss => qs === ss || qs.includes(ss) || ss.includes(qs))).length;
          if (stemHits > 0) return 40 + stemHits;                            // stem match
          return 20;                                                         // synonym-only match
        };

        // SOLE SOURCE: tasks collection (admin-managed fixed prices)
        // pricingGuidance is NOT used (stale default data, deleted).
        if (subQuery) {
          const taskSnap = await firestore.collection('tasks').limit(200).get();
          let bestMatch = null;
          for (const td of taskSnap.docs) {
            const d = td.data();
            const status = (d.status || '').toLowerCase();
            if (status && status !== 'publish' && status !== 'active') continue;
            const name = (d.name || d.title || d.task_name || '').toString();
            const cost = parseFloat(d.client_rate || d.cost || d.clientRate || d.price || d.amount || 0);
            if (name && cost > 0 && _fuzzyMatch(subNorm, _normalize(name))) {
              const score = _matchScore(subNorm, _normalize(name));
              if (!bestMatch || score > bestMatch.score) {
                bestMatch = { name, cost, score };
              }
            }
          }
          if (bestMatch) {
            estimatedCost = bestMatch.cost.toString();
            pricingSource = 'fixed';
            console.log(`[create_booking] Best price match: "${bestMatch.name}" R${bestMatch.cost} (score=${bestMatch.score})`);
          }
        }
      } catch (e) {
        console.error('[create_booking] Pricing lookup error:', e.message);
      }

      // If no pricing found at all, convert to RFQ instead of creating R0 booking
      if (estimatedCost === '0' || pricingSource === 'none') {
        console.log(`[create_booking] ⚠️ No pricing found for category="${args.category}" sub="${args.subcategory}" — converting to RFQ`);
        const rfqId = `rfq_${Date.now()}_${Math.random().toString(36).substring(2, 8)}`;
        const rfqDoc = {
          id: rfqId,
          category: args.category || '',
          subcategory: args.subcategory || '',
          description: args.description || '',
          address: args.address || '',
          customerName: args.customerName || '',
          customerPhone: session.phone,
          user_id: session.linkedUserId || `wa_${session.phone}`,
          source: 'whatsapp',
          status: 'pending',
          work_images: session.photoUrls.length ? session.photoUrls : [],
          created_at: new Date().toISOString(),
        };
        await firestore.collection('rfq_requests').doc(rfqId).set(rfqDoc);
        // Notify admin
        await firestore.collection('notifications').add({
          title: 'New RFQ from WhatsApp',
          body: `Customer needs pricing for ${args.category} > ${args.subcategory}. No fixed price found.`,
          type: 'rfq_request',
          user_type: 'admin',
          rfq_id: rfqId,
          read: false,
          created_at: admin.firestore.FieldValue.serverTimestamp(),
        });
        return {
          success: true,
          rfq: true,
          rfqId,
          message: `We don't have a fixed price for "${args.subcategory || args.category}" yet. Your request has been sent to our team as a quote request (RFQ #${rfqId.substring(0, 8)}). An admin will review and provide a custom quote shortly. You'll be notified once pricing is ready.`,
        };
      }

      // Apply promo discount if active
      let finalCost = parseFloat(estimatedCost);
      let promoApplied = null;
      if (session.promoCode && session.promoDiscount > 0) {
        let discount;
        if (session.promoDiscountType === 'percentage') {
          discount = Math.round(finalCost * session.promoDiscount / 100);
        } else {
          discount = session.promoDiscount;
        }
        discount = Math.min(discount, finalCost);
        finalCost = Math.max(0, finalCost - discount);
        promoApplied = { code: session.promoCode, discount, type: session.promoDiscountType || 'fixed' };
      }

      // Core booking doc (compatible with Flutter app tasksManagement queries)
      const booking = {
        id: bookingId,
        bookingId,
        order_no: orderNo,
        category_name: args.category || '',
        category: args.category || '',
        subcategory: args.subcategory || '',
        description: args.description || '',
        address: args.address || '',
        provided_address: args.address || session.sharedAddress || '',
        user_lat: session.sharedLatitude ? String(session.sharedLatitude) : '',
        user_lng: session.sharedLongitude ? String(session.sharedLongitude) : '',
        service_on_location: (session.sharedLatitude && session.sharedLongitude) ? 'yes' : '',
        urgency: args.urgency || 'normal',
        name: args.customerName || '',
        customerName: args.customerName || '',
        customerPhone: session.phone,
        contact: session.phone,
        user_id: session.linkedUserId || `wa_${session.phone}`,
        source: 'whatsapp',
        status: 'pending',
        accept: '',
        cost: finalCost.toFixed(2),
        payment_status: 'unpaid',
        promo_code: promoApplied ? promoApplied.code : null,
        promo_discount: promoApplied ? promoApplied.discount : 0,
        // Photo URLs from customer images sent during this session
        work_images: session.photoUrls.length ? session.photoUrls : [],
        image_urls: session.photoUrls.length ? session.photoUrls : [],
        imageUrls: session.photoUrls.length ? session.photoUrls : [],
        has_photos: session.photoUrls.length ? 'yes' : 'no',
        scheduled_date: args.scheduledDate || '',
        scheduled_time: args.scheduledTime || '',
        creation_date: now,
        created_at: now,
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
        updated_at: now,
      };

      await firestore.collection('tasksManagement').doc(bookingId).set(booking);
      console.log(`[create_booking] ✅ Written tasksManagement/${bookingId} cost=${finalCost} source=whatsapp`);

      // Verify write
      const verifyDoc = await firestore.collection('tasksManagement').doc(bookingId).get();
      console.log(`[create_booking] Verify: exists=${verifyDoc.exists}`);

      // Also create futureBookings entry (modern flow)
      const futureBooking = {
        id: bookingId,
        order_no: orderNo,
        user_id: session.linkedUserId || `wa_${session.phone}`,
        user_name: args.customerName || '',
        user_phone: session.phone,
        category_name: args.category || '',
        subcategory: args.subcategory || '',
        description: args.description || '',
        address: args.address || '',
        provided_address: args.address || session.sharedAddress || '',
        user_lat: session.sharedLatitude ? String(session.sharedLatitude) : '',
        user_lng: session.sharedLongitude ? String(session.sharedLongitude) : '',
        service_on_location: (session.sharedLatitude && session.sharedLongitude) ? 'yes' : '',
        urgency: args.urgency || 'normal',
        cost: finalCost.toFixed(2),
        status: 'pending',
        payment_status: 'unpaid',
        source: 'whatsapp',
        service_provider_id: '',
        service_provider_name: '',
        scheduled_date: args.scheduledDate || '',
        scheduled_time: args.scheduledTime || '',
        is_rfq: 'no',
        promo_code: promoApplied ? promoApplied.code : null,
        promo_discount: promoApplied ? promoApplied.discount : 0,
        tasks_management_id: bookingId,
        // Photo URLs from customer images sent during this session
        work_images: session.photoUrls.length ? session.photoUrls : [],
        image_urls: session.photoUrls.length ? session.photoUrls : [],
        imageUrls: session.photoUrls.length ? session.photoUrls : [],
        has_photos: session.photoUrls.length ? 'yes' : 'no',
        creation_date: now,
        created_at: now,
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
      };

      await firestore.collection('futureBookings').doc(bookingId).set(futureBooking);

      // Clear photo URLs after storing them in the booking
      session.photoUrls = [];

      // Record promo redemption if used
      if (promoApplied && session.promoId) {
        try {
          await firestore.collection('promo_redemptions').add({
            promo_id: session.promoId,
            user_id: session.linkedUserId || session.phone,
            task_management_id: bookingId,
            job_amount: parseFloat(estimatedCost),
            discount_amount: promoApplied.discount,
            source: 'whatsapp',
            created_at: now,
          });
          await firestore.collection('promo_codes').doc(session.promoId).update({
            used_count: admin.firestore.FieldValue.increment(1),
          });
        } catch (e) { console.warn('[wa-tool] promo usage tracking failed:', e.message); }
        // Clear promo from session after use
        session.promoCode = null;
        session.promoDiscount = 0;
        session.promoDiscountType = null;
        session.promoId = null;
      }

      // Record partner commission if user is linked to a partner
      if (session.linkedUserId) {
        try {
          const userDoc = await firestore.collection('users').doc(session.linkedUserId).get();
          const partnerId = userDoc.data()?.referred_by_partner_id;
          if (partnerId) {
            const partnerDoc = await firestore.collection('corporate_partners').doc(partnerId).get();
            if (partnerDoc.exists) {
              const rate = partnerDoc.data().commission_rate || 0.05;
              const commAmt = finalCost * rate;
              await firestore.collection('commissions').add({
                partner_id: partnerId,
                user_id: session.linkedUserId,
                task_management_id: bookingId,
                job_amount: finalCost,
                commission_rate: rate,
                commission_amount: commAmt,
                status: 'pending_payout',
                source: 'whatsapp',
                created_at: now,
              });
              await firestore.collection('corporate_partners').doc(partnerId).update({
                pending_payout: admin.firestore.FieldValue.increment(commAmt),
                total_earned: admin.firestore.FieldValue.increment(commAmt),
              });
            }
          }
        } catch (e) { console.warn('[wa-tool] partner commission tracking failed:', e.message); }
      }

      // Send notification to admin
      try {
        await firestore.collection('notifications').add({
          title: 'New WhatsApp Booking',
          body: `${args.customerName} booked ${args.category} via WhatsApp. Order: ${orderNo}`,
          type: 'new_booking',
          user_type: 'admin',
          booking_id: bookingId,
          read: false,
          created_at: admin.firestore.FieldValue.serverTimestamp(),
        });
      } catch (e) { console.warn('[wa-tool] booking notification failed:', e.message); }

      // ── Dispatch: create tasksManagement bridge per artisan + FCM push ──
      // Artisan app queries tasksManagement WHERE service_provider_id == artisanId.
      // We create a separate bridge record for each matching artisan so the booking
      // appears in their "New Requests" screen. When one accepts, others get cancelled.
      let dispatchedCount = 0;
      try {
        const catSlug = (args.category || '').toLowerCase().replace(/\s+/g, '_') || 'general_maintenance';
        // Fetch all service providers and filter in-code to avoid Firestore
        // compound-inequality index issues and the != gotcha (docs without
        // the is_suspended field are excluded by Firestore != queries).
        let artisanSnap;
        try {
          artisanSnap = await firestore.collection('serviceProvider').where('status', '==', 'publish').limit(200).get();
          if (artisanSnap.empty) artisanSnap = await firestore.collection('serviceProvider').where('status', '==', 'approved').limit(200).get();
          if (artisanSnap.empty) artisanSnap = await firestore.collection('serviceProvider').limit(200).get();
        } catch (qErr) {
          console.warn('[wa-tool] artisan query fallback:', qErr.message);
          artisanSnap = await firestore.collection('serviceProvider').limit(200).get();
        }

        console.log(`[wa-tool] Found ${artisanSnap.docs.length} serviceProvider docs, catSlug=${catSlug}`);

        const photoUrls = booking.work_images || [];

        for (const artDoc of artisanSnap.docs) {
          const ad = artDoc.data() || {};
          // Filter: status must be publish/approved, not suspended, and active
          const st = (ad.status || '').toString().toLowerCase();
          if (st && st !== 'publish' && st !== 'published' && st !== 'approved' && st !== 'approve') continue;
          if (ad.is_suspended === true) continue;
          const activeField = ad.active;
          if (activeField != null && activeField !== 'y' && activeField !== true && activeField !== 'true') continue;
          const cats = (ad.categories || ad.category || '').toString().toLowerCase();
          if (cats && !cats.includes(catSlug) && catSlug !== 'general_maintenance') continue;

          // Cap dispatch at 10 artisans to avoid flooding
          if (dispatchedCount >= 10) break;

          const artisanId = artDoc.id;
          const bridgeId = `${bookingId}_${artisanId}`;

          // Create tasksManagement bridge record for this artisan
          try {
            await firestore.collection('tasksManagement').doc(bridgeId).set({
              id: bridgeId,
              bookingId: bridgeId,
              order_no: orderNo,
              future_booking_id: bookingId,
              category_name: args.category || '',
              category: args.category || '',
              subcategory: args.subcategory || '',
              description: args.description || '',
              address: args.address || '',
              urgency: args.urgency || 'normal',
              name: args.customerName || '',
              customerName: args.customerName || '',
              customerPhone: session.phone,
              contact: session.phone,
              user_id: session.linkedUserId || '',
              source: 'whatsapp',
              status: 'pending',
              accept: '',
              cost: finalCost.toFixed(2),
              payment_status: 'unpaid',
              paymentStatus: 'pending',
              service_provider_id: artisanId,
              service_provider_name: ad.name || ad.fullName || '',
              work_images: photoUrls,
              image_urls: photoUrls,
              imageUrls: photoUrls,
              has_photos: photoUrls.length > 0 ? 'yes' : 'no',
              creation_date: now,
              created_at: now,
              createdAt: admin.firestore.FieldValue.serverTimestamp(),
              updated_at: now,
            });
            dispatchedCount++;
          } catch (bridgeErr) {
            console.warn(`[wa-tool] Bridge record for artisan ${artisanId} failed:`, bridgeErr.message);
          }

          // Send FCM push notification
          const token = (ad.fcm_token || ad.deviceToken || '').toString().trim();
          if (token) {
            try {
              await admin.messaging().send({
                token,
                notification: {
                  title: '🔔 New Booking Request',
                  body: `New ${args.category || 'maintenance'} job: ${args.description || args.subcategory || 'maintenance work'}. Tap to view and accept.`,
                },
                data: {
                  type: 'new_booking',
                  booking_id: bridgeId,
                  order_no: orderNo,
                  future_booking_id: bookingId,
                  has_photos: photoUrls.length > 0 ? 'true' : 'false',
                },
                android: { notification: { channelId: 'order_request_channel', sound: 'sound' } },
              });
            } catch (fcmErr) {
              console.warn(`[wa-tool] FCM to artisan ${artDoc.id} failed:`, fcmErr.message);
            }
          }
        }
        console.log(`[wa-tool] Dispatched booking ${bookingId} to ${dispatchedCount} artisans`);
      } catch (e) { console.warn('[wa-tool] artisan dispatch failed:', e.message); }

      // Store last booking ID for quick payment follow-up
      session.lastBookingId = bookingId;
      session.lastBookingCost = finalCost;

      const depositAmount = Math.round(finalCost * 0.35 * 100) / 100;
      const balanceAmount = Math.round((finalCost - depositAmount) * 100) / 100;

      return {
        success: true,
        bookingId,
        orderNo,
        estimatedCost: `R${finalCost.toFixed(2)}`,
        depositAmount: `R${depositAmount.toFixed(2)}`,
        balanceAmount: `R${balanceAmount.toFixed(2)}`,
        promoApplied: promoApplied ? `${promoApplied.code} (-R${promoApplied.discount.toFixed(2)})` : null,
        paymentStatus: 'awaiting_artisan',
        message: `Booking ${orderNo} created! Estimated cost: R${finalCost.toFixed(2)}.\n\n⏳ *Next step:* An artisan needs to accept your job before payment. We're dispatching the nearest available artisan now — you'll be notified as soon as one accepts.\n\n🔒 *Your money is protected:* When it's time to pay, your payment is held in a secure escrow account. The artisan does NOT receive your money until you confirm you are satisfied with the completed work.\n\n💰 *Payment options (after artisan accepts):*\n• Full amount: R${finalCost.toFixed(2)}\n• Deposit (35%): R${depositAmount.toFixed(2)} now, R${balanceAmount.toFixed(2)} after job completion`,
      };
    }

    // ═══════════════════════════════════════════
    // 3) CHECK BOOKING STATUS
    // ═══════════════════════════════════════════
    case 'check_booking_status': {
      if (!firestore) return { error: 'Database unavailable' };
      const bid = args.bookingId;
      if (!bid) return { error: 'Please provide a booking ID' };

      // Try tasksManagement first, then futureBookings
      let doc = await firestore.collection('tasksManagement').doc(bid).get();
      if (!doc.exists) doc = await firestore.collection('futureBookings').doc(bid).get();
      if (!doc.exists) {
        // Try by order_no
        let snap = await firestore.collection('tasksManagement').where('order_no', '==', bid).limit(1).get();
        if (snap.empty) snap = await firestore.collection('futureBookings').where('order_no', '==', bid).limit(1).get();
        if (snap.empty) return { error: `Booking "${bid}" not found. Please check the ID.` };
        doc = snap.docs[0];
      }

      const d = doc.data();
      const paymentStatus = d.payment_status || d.paymentStatus || 'unknown';
      const totalCost = parseFloat(d.cost || d.total_cost || '0');
      const isDeposit = d.payment_type === 'deposit' || paymentStatus === 'deposit_paid';
      const depositAmount = isDeposit ? (parseFloat(d.deposit_amount || '0') || Math.round(totalCost * 0.35 * 100) / 100) : 0;
      const balanceRemaining = isDeposit ? (parseFloat(d.balance_remaining || d.balance_amount || '0') || Math.round((totalCost - depositAmount) * 100) / 100) : 0;
      const balancePaid = d.balance_paid === true;

      return {
        bookingId: doc.id,
        orderNo: d.order_no || doc.id,
        status: d.status || 'unknown',
        category: d.category_name || d.category || '',
        artisan: d.service_provider_name || d.artisanName || 'Not assigned yet',
        cost: totalCost > 0 ? `R${totalCost.toFixed(2)}` : 'Pending quote',
        paymentStatus,
        paymentType: isDeposit ? 'deposit' : 'full',
        depositPaid: isDeposit ? `R${depositAmount.toFixed(2)}` : null,
        balanceRemaining: isDeposit && !balancePaid ? `R${balanceRemaining.toFixed(2)}` : null,
        balancePaid: isDeposit ? balancePaid : null,
        scheduledDate: d.scheduled_date || 'Not scheduled',
        scheduledTime: d.scheduled_time || '',
        isRFQ: d.is_rfq === 'yes',
        rfqStatus: d.rfq_status || null,
      };
    }

    // ═══════════════════════════════════════════
    // 4) GET MY BOOKINGS
    // ═══════════════════════════════════════════
    case 'get_my_bookings': {
      if (!firestore) return { error: 'Database unavailable' };

      const bookings = [];

      // Search by linked user ID first
      if (session.linkedUserId) {
        const snap = await firestore.collection('futureBookings')
          .where('user_id', '==', session.linkedUserId)
          .orderBy('created_at', 'desc').limit(5).get();
        for (const d of snap.docs) {
          const data = d.data();
          bookings.push({
            id: d.id,
            orderNo: data.order_no || d.id,
            category: data.category_name || data.category || '',
            status: data.status || '',
            cost: data.cost ? `R${data.cost}` : 'Pending',
            paymentStatus: data.payment_status || '',
            date: data.scheduled_date || data.created_at || '',
          });
        }
      }

      // Also search by phone
      if (bookings.length === 0) {
        const snap = await firestore.collection('tasksManagement')
          .where('customerPhone', '==', session.phone)
          .orderBy('createdAt', 'desc').limit(5).get();
        for (const d of snap.docs) {
          const data = d.data();
          bookings.push({
            id: d.id,
            orderNo: data.order_no || d.id,
            category: data.category_name || data.category || '',
            status: data.status || '',
            cost: data.cost ? `R${data.cost}` : 'Pending',
            paymentStatus: data.payment_status || data.paymentStatus || '',
          });
        }
      }

      if (bookings.length === 0) return { message: 'No bookings found for your number.' };
      return { bookings, count: bookings.length };
    }

    // ═══════════════════════════════════════════
    // 5) LOOKUP PRICING
    // ═══════════════════════════════════════════
    case 'lookup_pricing': {
      if (!firestore) return { matched: false, estimate: 'Pricing service temporarily unavailable. Please try again.', note: 'Suggest the customer try again or submit an RFQ.' };
      try {
        const catSlug = (args.category || '').toLowerCase().replace(/\s+/g, '_');
        const subQuery = (args.subcategory || '').toLowerCase();

        // Fuzzy matching helpers
        const normalize = (s) => s.toLowerCase().replace(/[_\-]+/g, ' ').trim();
        const stem = (w) => w.replace(/(ing|ed|tion|ment|ness|able|ible|er|est|ly|s)$/i, '');
        // Comprehensive 14-category synonym map (matches livekit-backend)
        const SYNONYMS = {
          plumbing:    ['toilet', 'cistern', 'basin', 'bath', 'tap', 'pipe', 'drain', 'geyser', 'shower', 'sink', 'plumb', 'blocked', 'leak', 'water', 'bathroom', 'kitchen'],
          electrical:  ['light', 'switch', 'socket', 'wire', 'wiring', 'breaker', 'db board', 'plug', 'circuit', 'electric', 'power', 'volt'],
          painting:    ['paint', 'wall', 'ceiling', 'enamel', 'pva', 'varnish', 'roof', 'garage', 'door'],
          cleaning:    ['clean', 'wash', 'deep clean', 'carpet', 'window', 'scrub'],
          tiling:      ['tile', 'floor', 'grout', 'ceramic'],
          carpentry:   ['wood', 'cabinet', 'shelf', 'cupboard', 'door', 'frame', 'carpenter'],
          solar:       ['panel', 'pv', 'inverter', 'battery', 'geyser', 'energy'],
          maintenance: ['repair', 'fix', 'maintain', 'service', 'general'],
          bathroom:    ['toilet', 'cistern', 'basin', 'bath', 'shower', 'tap', 'plumb', 'blocked', 'drain'],
          kitchen:     ['tap', 'mixer', 'sink', 'faucet', 'cupboard'],
          door:        ['lock', 'handle', 'hinge', 'frame', 'door'],
          window:      ['glass', 'pane', 'frame', 'window'],
          installation:['install', 'setup', 'mount', 'fit'],
        };
        const expandWithSynonyms = (words) => {
          const expanded = new Set(words);
          for (const w of words) {
            const stemmed = stem(w);
            expanded.add(stemmed);
            // Bidirectional: if word matches a category key, add all its synonyms
            if (SYNONYMS[w]) SYNONYMS[w].forEach(s => expanded.add(s));
            if (SYNONYMS[stemmed]) SYNONYMS[stemmed].forEach(s => expanded.add(s));
            // Reverse: if word appears in a category's synonyms, add the category key + all siblings
            for (const [key, syns] of Object.entries(SYNONYMS)) {
              if (syns.includes(w) || syns.includes(stemmed)) {
                expanded.add(key);
                syns.forEach(s => expanded.add(s));
              }
            }
          }
          return [...expanded];
        };
        const fuzzyMatch = (queryNorm, svcNorm) => {
          if (svcNorm.includes(queryNorm) || queryNorm.includes(svcNorm)) return true;
          const qWords = queryNorm.split(/\s+/).filter(w => w.length >= 3);
          const sWords = svcNorm.split(/\s+/).filter(w => w.length >= 3);
          if (qWords.some(w => svcNorm.includes(w)) || sWords.some(w => queryNorm.includes(w))) return true;
          const qStems = qWords.map(stem);
          const sStems = sWords.map(stem);
          if (qStems.some(qs => sStems.some(ss => qs === ss || qs.includes(ss) || ss.includes(qs)))) return true;
          const qExpanded = expandWithSynonyms(qWords.concat(qStems));
          if (qExpanded.some(qe => sWords.some(sw => sw.includes(qe) || qe.includes(sw)))
              || qExpanded.some(qe => sStems.some(ss => ss.includes(qe) || qe.includes(ss)))) return true;
          return false;
        };
        const subNorm = normalize(subQuery);

        let matchedService = null;
        let matchedPrice = null;
        let categoryName = args.category || '';

        // ── SOLE SOURCE: tasks collection (admin-managed fixed prices) ──
        // These are the prices set by the admin via the admin app categories.
        // pricingGuidance collection is NOT used (stale default data, deleted).
        const taskResults = [];
        try {
          const taskSnap = await firestore.collection('tasks').limit(200).get();
          for (const td of taskSnap.docs) {
            const d = td.data();
            const status = (d.status || '').toLowerCase();
            if (status && status !== 'publish' && status !== 'active') continue;
            const name = (d.name || d.title || d.task_name || '').toString();
            const cost = parseFloat(d.client_rate || d.cost || d.clientRate || d.price || d.amount || 0);
            if (name && cost > 0) {
              taskResults.push({ name, cost, category_id: d.categoryId || d.category_id || '', category_name: d.category_name || d.categoryName || '' });
            }
          }
        } catch (e) { console.warn('[wa-tool] tasks lookup failed:', e.message); }

        // Score a match by specificity (higher = better)
        const matchScore = (qNorm, sNorm) => {
          if (sNorm === qNorm) return 100;
          if (sNorm.includes(qNorm)) return 90;
          if (qNorm.includes(sNorm)) return 85;
          const qW = qNorm.split(/\s+/).filter(w => w.length >= 3);
          const sW = sNorm.split(/\s+/).filter(w => w.length >= 3);
          const wordHits = qW.filter(w => sNorm.includes(w)).length + sW.filter(w => qNorm.includes(w)).length;
          if (wordHits >= 2) return 70 + wordHits;
          if (wordHits === 1) return 60;
          const qS = qW.map(stem), sS = sW.map(stem);
          const stemHits = qS.filter(qs => sS.some(ss => qs === ss || qs.includes(ss) || ss.includes(qs))).length;
          if (stemHits > 0) return 40 + stemHits;
          return 20;
        };

        // Try to match subcategory against tasks — pick BEST match
        if (subQuery) {
          let bestMatch = null;
          for (const t of taskResults) {
            const tNorm = normalize(t.name);
            if (fuzzyMatch(subNorm, tNorm)) {
              const score = matchScore(subNorm, tNorm);
              if (!bestMatch || score > bestMatch.score) {
                bestMatch = { ...t, score };
              }
            }
          }
          if (bestMatch) {
            matchedService = bestMatch.name;
            matchedPrice = bestMatch.cost;
            categoryName = bestMatch.category_name || categoryName;
          }
        }

        // Build list of all available fixed prices for context
        const allFixedPrices = [];
        for (const t of taskResults) {
          const catId = normalize(t.category_id);
          const catNameNorm = normalize(t.category_name);
          const catSlugNorm = normalize(catSlug);
          if (!catSlug || catId === catSlugNorm || catId.includes(catSlugNorm) || catSlugNorm.includes(catId)
              || catNameNorm === catSlugNorm || catNameNorm.includes(catSlugNorm) || catSlugNorm.includes(catNameNorm)) {
            allFixedPrices.push({ service: t.name, fixedPrice: `R${t.cost.toFixed(2)}` });
          }
        }

        if (matchedService && matchedPrice) {
          return {
            matched: true,
            service: matchedService,
            fixedPrice: `R${matchedPrice.toFixed(2)}`,
            category: categoryName,
            allServicesInCategory: allFixedPrices,
            note: 'This is a FIXED price. Use this exact amount when creating the booking.',
          };
        }

        if (allFixedPrices.length > 0) {
          return {
            matched: false,
            category: categoryName,
            availableServices: allFixedPrices,
            note: 'No exact match for the requested service. These are the fixed-price services available. If the customer\'s job doesn\'t match any fixed-price service, suggest submitting an RFQ instead.',
          };
        }

        return { matched: false, estimate: 'No fixed pricing found for this category.', note: 'Suggest the customer submit an RFQ for a detailed quote.' };
      } catch (e) {
        console.error('[lookup_pricing] Error:', e.message);
        return { matched: false, estimate: 'Pricing lookup failed. Please try again.', note: 'Suggest the customer submit an RFQ for a detailed quote.' };
      }
    }

    // ═══════════════════════════════════════════
    // 6) APPLY PROMO CODE
    // ═══════════════════════════════════════════
    case 'apply_promo_code': {
      if (!firestore) return { error: 'Cannot validate promo codes right now. Please try again later.' };
      const code = (args.code || '').trim().toUpperCase();
      if (!code) return { error: 'Please provide a promo code.' };

      try {
        const snap = await firestore.collection('promo_codes')
          .where('code', '==', code).limit(1).get();
        if (snap.empty) return { valid: false, message: `Promo code "${code}" not found.` };

        const promo = snap.docs[0].data();
        const promoId = snap.docs[0].id;

        // Check active
        if (promo.status !== 'active' && promo.is_active !== true) {
          return { valid: false, message: 'This promo code is no longer active.' };
        }

        // Check expiry
        if (promo.end_date) {
          const endDate = new Date(promo.end_date);
          if (endDate < new Date()) return { valid: false, message: 'This promo code has expired.' };
        }

        // Check max uses
        if (promo.max_uses && (promo.used_count || 0) >= promo.max_uses) {
          return { valid: false, message: 'This promo code has reached its maximum uses.' };
        }

        // Calculate discount
        const discountType = promo.discount_type || promo.discountType || 'percentage';
        const discountValue = promo.discount_value || promo.discountValue || 0;

        session.promoCode = code;
        session.promoId = promoId;

        session.promoDiscountType = discountType;
        session.promoDiscount = discountValue;

        if (discountType === 'percentage') {
          return { valid: true, message: `Promo "${code}" applied! ${discountValue}% discount will be applied to your booking.`, discountType: 'percentage', discountValue };
        } else {
          return { valid: true, message: `Promo "${code}" applied! R${discountValue} discount will be applied to your booking.`, discountType: 'fixed', discountValue };
        }
      } catch (e) {
        return { error: 'Could not validate promo code. Please try again.' };
      }
    }

    // ═══════════════════════════════════════════
    // 7) REQUEST PAYMENT LINK (generates real payment URL via backend)
    // ═══════════════════════════════════════════
    case 'request_payment_link': {
      if (!firestore) return { error: 'Database unavailable' };
      const bid = args.bookingId || session.lastBookingId;
      if (!bid) return { error: 'Please provide a booking ID.' };

      let doc = await firestore.collection('futureBookings').doc(bid).get();
      if (!doc.exists) doc = await firestore.collection('tasksManagement').doc(bid).get();
      if (!doc.exists) return { error: `Booking "${bid}" not found.` };

      const d = doc.data();
      const totalCost = parseFloat(d.cost || '0');
      if (totalCost <= 0) return { error: 'This booking does not have a confirmed price yet.' };

      if (d.payment_status === 'paid' || d.paymentStatus === 'paid') {
        return { message: 'This booking is already paid in full!', bookingId: bid };
      }

      // Handle balance payment for deposit bookings
      const isDepositPaid = d.payment_status === 'deposit_paid';
      const balanceDone = d.balance_paid === true;
      if (isDepositPaid && balanceDone) {
        return { message: 'This booking is fully paid (deposit + balance)!', bookingId: bid };
      }

      let cost, isDeposit, balanceAfterDeposit;
      if (isDepositPaid && !balanceDone) {
        // Deposit already paid — charge the remaining balance
        const depositAmt = parseFloat(d.deposit_amount || '0') || Math.round(totalCost * 0.35 * 100) / 100;
        cost = parseFloat(d.balance_remaining || d.balance_amount || '0') || Math.round((totalCost - depositAmt) * 100) / 100;
        isDeposit = false;
        balanceAfterDeposit = 0;
      } else {
        // Calculate amount based on payment type (full or 35% deposit)
        const paymentType = (args.paymentType || 'full').toLowerCase();
        isDeposit = paymentType === 'deposit';
        cost = isDeposit ? Math.round(totalCost * 0.35 * 100) / 100 : totalCost;
        balanceAfterDeposit = isDeposit ? Math.round((totalCost - cost) * 100) / 100 : 0;
      }

      // Check real-time acceptance status from Firestore
      let artisanAccepted = d.accept === '1' || d.accept === 1 ||
          d.artisan_confirmed === 'yes' || d.status === 'pending_payment' || d.status === 'accepted';
      // Fallback: check the OTHER collection (futureBookings ↔ tasksManagement)
      if (!artisanAccepted) {
        try {
          const altCollection = doc.ref.parent.id === 'futureBookings' ? 'tasksManagement' : 'futureBookings';
          const altDoc = await firestore.collection(altCollection).doc(bid).get();
          if (altDoc.exists) {
            const a = altDoc.data();
            artisanAccepted = a.accept === '1' || a.accept === 1 ||
                a.artisan_confirmed === 'yes' || a.status === 'pending_payment' || a.status === 'accepted';
          }
        } catch (_) {}
      }
      // Fallback: check bridge records (artisan sets accept='1' on tasksManagement/{bid}_{artisanId})
      if (!artisanAccepted) {
        try {
          const bridgeSnap = await firestore.collection('tasksManagement')
            .where('future_booking_id', '==', bid)
            .where('accept', '==', '1')
            .limit(1).get();
          artisanAccepted = !bridgeSnap.empty;
        } catch (_) {}
      }
      if (!artisanAccepted) {
        return { error: `An artisan hasn't accepted this job yet. You'll be notified when an artisan accepts, and then you can proceed to payment. Your booking ${d.order_no || bid} is in the queue.` };
      }

      // Generate real payment link via backend
      let paymentUrl = '';
      try {
        const backendUrl = process.env.LIVEKIT_BACKEND_URL || 'https://square15-livekit-backend.onrender.com';
        const resp = await fetch(`${backendUrl}/api/payment/whatsapp-initiate`, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({
            amount: cost.toFixed(2),
            booking_id: bid,
            customer_name: d.customerName || d.name || '',
            customer_phone: session.phone,
            description: d.description || d.subcategory || d.category_name || `Booking ${bid}`,
          }),
          signal: AbortSignal.timeout(15000),
        });
        const result = await resp.json();
        if (result.ok && result.payment_url) {
          paymentUrl = result.payment_url;
        }
      } catch (e) {
        console.warn('[wa-tool] payment link generation failed:', e.message);
      }

      // Update Firestore with payment type choice
      if (isDeposit) {
        // Check if deposit payment is already pending to prevent double-charge
        if (data.payment_status === 'deposit_pending') {
          return {
            message: `A deposit payment is already in progress for this booking. Please complete or cancel the existing payment before requesting a new one.`,
            bookingId: bid,
          };
        }
        try {
          await doc.ref.set({
            payment_type: 'deposit',
            deposit_amount: cost,
            balance_remaining: balanceAfterDeposit,
            payment_status: 'deposit_pending',
            updated_at: new Date().toISOString(),
          }, { merge: true });
        } catch (e) {
          console.error('[wa-tool] Failed to persist payment type:', e.message);
        }
      }

      const amountLabel = isDepositPaid
        ? `R${cost.toFixed(2)} (remaining balance after deposit)`
        : isDeposit
          ? `R${cost.toFixed(2)} (35% deposit — R${balanceAfterDeposit.toFixed(2)} balance due after job)`
          : `R${cost.toFixed(2)} (full amount)`;

      if (paymentUrl) {
        return {
          message: `Here is your secure payment link for ${amountLabel}:\n\n${paymentUrl}\n\nClick the link above to pay securely. Your payment is protected and held in escrow until you confirm satisfaction with the work.`,
          amount: `R${cost.toFixed(2)}`,
          paymentType: isDeposit ? 'deposit' : 'full',
          payment_url: paymentUrl,
          bookingId: bid,
        };
      } else {
        // Fallback: notify admin to send payment link manually
        await firestore.collection('notifications').add({
          title: 'WhatsApp Payment Request',
          body: `Customer requests ${isDeposit ? 'deposit' : 'full'} payment link for booking ${bid} (R${cost.toFixed(2)})`,
          type: 'payment_request',
          user_type: 'admin',
          booking_id: bid,
          read: false,
          created_at: admin.firestore.FieldValue.serverTimestamp(),
        });
        return {
          message: `We're preparing your payment link for ${amountLabel}. Our team will send it to you shortly. You can also pay via the Square 15 app.`,
          amount: `R${cost.toFixed(2)}`,
          paymentType: isDeposit ? 'deposit' : 'full',
          bookingId: bid,
        };
      }
    }

    // ═══════════════════════════════════════════
    // 8) CHECK WALLET BALANCE
    // ═══════════════════════════════════════════
    case 'check_wallet_balance': {
      if (!firestore) return { error: 'Database unavailable' };
      if (!session.linkedUserId) {
        const user = await findUserByPhone(session.phone);
        if (user) session.linkedUserId = user.id;
        else return { error: 'Your WhatsApp number is not linked to a Square 15 account. Please sign up in the app first.' };
      }

      const userDoc = await firestore.collection('users').doc(session.linkedUserId).get();
      if (!userDoc.exists) return { error: 'Account not found.' };
      const balance = parseFloat(userDoc.data().balance || '0');
      return { balance: `R${balance.toFixed(2)}`, userId: session.linkedUserId };
    }

    // ═══════════════════════════════════════════
    // 9) PAY WITH WALLET
    // ═══════════════════════════════════════════
    case 'pay_with_wallet': {
      if (!firestore) return { error: 'Database unavailable' };
      if (!session.linkedUserId) {
        const user = await findUserByPhone(session.phone);
        if (user) session.linkedUserId = user.id;
        else return { error: 'Your WhatsApp number is not linked to a Square 15 account. Wallet payment requires an app account.' };
      }

      const bid = args.bookingId;
      if (!bid) return { error: 'Please provide a booking ID.' };

      // Get booking (check both collections)
      let bookDoc = await firestore.collection('tasksManagement').doc(bid).get();
      if (!bookDoc.exists) bookDoc = await firestore.collection('futureBookings').doc(bid).get();
      if (!bookDoc.exists) return { error: `Booking "${bid}" not found.` };
      const bookData = bookDoc.data();

      if (bookData.payment_status === 'paid') return { message: 'This booking is already paid!' };

      // Ensure an artisan has accepted before allowing payment (match request_payment_link logic)
      let artisanAccepted = bookData.accept === '1' || bookData.accept === 1 ||
          bookData.artisan_confirmed === 'yes' || bookData.status === 'pending_payment' || bookData.status === 'accepted';
      if (!artisanAccepted) {
        try {
          const altDoc = await firestore.collection('futureBookings').doc(bid).get();
          if (altDoc.exists) {
            const a = altDoc.data();
            artisanAccepted = a.accept === '1' || a.accept === 1 ||
                a.artisan_confirmed === 'yes' || a.status === 'pending_payment' || a.status === 'accepted';
          }
        } catch (_) {}
      }
      if (!artisanAccepted) {
        try {
          const bridgeSnap = await firestore.collection('tasksManagement')
            .where('future_booking_id', '==', bid)
            .where('accept', '==', '1')
            .limit(1).get();
          artisanAccepted = !bridgeSnap.empty;
        } catch (_) {}
      }
      if (!artisanAccepted) {
        return { error: 'No artisan has accepted this booking yet. Please wait for an artisan to accept before paying.' };
      }

      const cost = parseFloat(bookData.cost || '0');
      if (cost <= 0) return { error: 'This booking does not have a confirmed price yet.' };

      // Get user balance (atomic transaction)
      try {
        await firestore.runTransaction(async (txn) => {
          const userRef = firestore.collection('users').doc(session.linkedUserId);
          const userSnap = await txn.get(userRef);
          if (!userSnap.exists) throw new Error('User not found');

          const balance = parseFloat(userSnap.data().balance || '0');
          if (balance < cost) throw new Error(`Insufficient balance. You have R${balance.toFixed(2)} but need R${cost.toFixed(2)}.`);

          const newBalance = balance - cost;
          txn.update(userRef, { balance: newBalance.toFixed(2) });
          txn.update(firestore.collection('tasksManagement').doc(bid), {
            payment_status: 'paid',
            paymentStatus: 'paid',
            payment_method: 'wallet',
            paid_at: new Date().toISOString(),
          });

          // Also update futureBookings if exists
          const fbRef = firestore.collection('futureBookings').doc(bid);
          const fbSnap = await txn.get(fbRef);
          if (fbSnap.exists) {
            txn.update(fbRef, {
              payment_status: 'paid',
              wallet_deducted: true,
              paid_at: new Date().toISOString(),
            });
          }
        });

        // Log transaction
        await firestore.collection('transactionLogs').add({
          user_id: session.linkedUserId,
          type: 'payment',
          subtype: 'wallet_deduction',
          amount: cost,
          booking_id: bid,
          source: 'whatsapp',
          status: 'success',
          created_at: admin.firestore.FieldValue.serverTimestamp(),
        });

        return { success: true, message: `Payment of R${cost.toFixed(2)} successful via wallet! Your booking ${bid} is now confirmed.`, paid: `R${cost.toFixed(2)}` };
      } catch (e) {
        return { error: e.message || 'Payment failed. Please try again.' };
      }
    }

    // ═══════════════════════════════════════════
    // 10) SUBMIT RFQ (with AI Quote Generation)
    // ═══════════════════════════════════════════
    case 'submit_rfq': {
      if (!firestore) return { error: 'Database unavailable' };

      const rfqId = `RFQ-${Date.now().toString(36).toUpperCase()}`;
      const rfqNo = `SQ15-RFQ-${rfqId}`;
      const now = new Date().toISOString();

      const rfqDoc = {
        id: rfqId,
        order_no: rfqNo,
        rfq_no: rfqNo,
        is_rfq: 'yes',
        rfq_status: 'pending_admin_review',
        user_id: session.linkedUserId || `wa_${session.phone}`,
        user_name: args.customerName || '',
        user_phone: session.phone,
        category_name: args.category || '',
        description: args.description || '',
        problem_description: args.description || '',
        address: args.address || '',
        materials_responsibility: args.materialsResponsibility || 'artisan',
        status: 'rfq_pending',
        payment_status: 'unpaid',
        cost: '',
        source: 'whatsapp',
        service_provider_id: '',
        service_provider_name: '',
        scheduled_date: '',
        scheduled_time: '',
        // Photo URLs from customer images sent during this session
        work_images: session.photoUrls.length ? session.photoUrls : [],
        image_urls: session.photoUrls.length ? session.photoUrls : [],
        imageUrls: session.photoUrls.length ? session.photoUrls : [],
        has_photos: session.photoUrls.length ? 'yes' : 'no',
        created_at: now,
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
      };

      await firestore.collection('futureBookings').doc(rfqId).set(rfqDoc);

      // Clear photo URLs after storing them in the RFQ
      session.photoUrls = [];

      // Track in session for follow-up
      session.lastRfqId = rfqId;
      session.lastRfqNo = rfqNo;

      // Notify admin
      await firestore.collection('notifications').add({
        title: 'New WhatsApp RFQ',
        body: `${args.customerName} submitted RFQ for ${args.category} via WhatsApp. RFQ: ${rfqNo}`,
        type: 'new_rfq',
        user_type: 'admin',
        booking_id: rfqId,
        read: false,
        created_at: admin.firestore.FieldValue.serverTimestamp(),
      });

      // ── AI Quote Generation ──
      // Extract any image analysis context from the conversation history
      let imageContext = '';
      for (const m of session.messages) {
        if (typeof m.content === 'string' && m.role === 'assistant' && m.content.length > 50) {
          // Capture assistant's image analysis summaries
          if (m.content.toLowerCase().includes('issue') || m.content.toLowerCase().includes('damage') ||
              m.content.toLowerCase().includes('repair') || m.content.toLowerCase().includes('install')) {
            imageContext += m.content.substring(0, 300) + ' ';
          }
        }
      }

      try {
        console.log(`[submit_rfq] Generating AI quote for ${rfqNo}...`);
        const quote = await generateAIQuote(
          args.category || '',
          args.description || '',
          args.materialsResponsibility || 'artisan',
          imageContext.trim()
        );

        if (quote) {
          // Save quote to the RFQ document
          await firestore.collection('futureBookings').doc(rfqId).update({
            ai_quote: quote,
            quoted_price: quote.grand_total.toString(),
            quote_details: quote.scope_of_work,
            rfq_status: 'pending_client_response',
            total_price: quote.grand_total.toString(),
            cost: quote.grand_total.toString(),
          });

          const quoteMsg = formatQuoteForWhatsApp(quote, rfqNo);
          console.log(`[submit_rfq] AI quote generated: R${quote.grand_total.toFixed(2)} for ${rfqNo}`);

          return {
            success: true,
            rfqId,
            rfqNo,
            hasQuote: true,
            grand_total: `R${quote.grand_total.toFixed(2)}`,
            message: `RFQ ${rfqNo} submitted with AI-generated quote!\n\n${quoteMsg}`,
          };
        }
      } catch (quoteErr) {
        console.error('[submit_rfq] AI quote generation error:', quoteErr.message);
      }

      // Fallback if quote generation fails
      return {
        success: true,
        rfqId,
        rfqNo,
        hasQuote: false,
        message: `RFQ ${rfqNo} submitted! Our team will review your request and provide a detailed quotation. You'll receive the quote here on WhatsApp.`,
      };
    }

    // ═══════════════════════════════════════════
    // 11) CANCEL BOOKING
    // ═══════════════════════════════════════════
    case 'cancel_booking': {
      if (!firestore) return { error: 'Database unavailable' };
      const bid = args.bookingId;
      if (!bid) return { error: 'Please provide a booking ID.' };

      let doc = await firestore.collection('tasksManagement').doc(bid).get();
      if (!doc.exists) return { error: `Booking "${bid}" not found.` };

      const d = doc.data();
      const status = (d.status || '').toLowerCase();

      // Can't cancel completed or already cancelled
      if (status === 'completed' || status === 'closed' || status === 'done') {
        return { error: 'This booking is already completed and cannot be cancelled.' };
      }
      if (status === 'cancelled') {
        return { message: 'This booking is already cancelled.' };
      }
      // Warn if in progress
      if (status === 'progress' || status === 'in_progress') {
        return { error: 'This booking is currently in progress. Please contact admin at support@square15.co.za to cancel an active job.' };
      }

      const now = new Date().toISOString();
      const wasPaid = d.payment_status === 'paid' || d.paymentStatus === 'paid';

      // Cancel in tasksManagement
      await firestore.collection('tasksManagement').doc(bid).update({
        status: 'cancelled',
        cancelled_at: now,
        cancelled_by: 'client_whatsapp',
        cancel_reason: args.reason || 'Cancelled via WhatsApp',
        cancellation_reason: args.reason || 'Cancelled via WhatsApp',
      });

      // Cancel in futureBookings if exists
      try {
        const fbDoc = await firestore.collection('futureBookings').doc(bid).get();
        if (fbDoc.exists) {
          await firestore.collection('futureBookings').doc(bid).update({
            status: 'cancelled',
            cancelled_at: now,
            cancelled_by: 'client_whatsapp',
            cancel_reason: args.reason || 'Cancelled via WhatsApp',
            cancellation_reason: args.reason || 'Cancelled via WhatsApp',
          });
        }
      } catch (e) { console.warn('[wa-tool] futureBookings cancel sync failed:', e.message); }

      // Clean up bridge records (artisan dispatch copies)
      try {
        const bridgeSnap = await firestore.collection('tasksManagement')
          .where('future_booking_id', '==', bid).get();
        const batch = firestore.batch();
        let bridgeCount = 0;
        bridgeSnap.forEach(doc => {
          if (doc.id !== bid) {
            batch.update(doc.ref, { status: 'cancelled', cancelled_at: now });
            bridgeCount++;
          }
        });
        if (bridgeCount > 0) {
          await batch.commit();
          console.log(`[wa-tool] Cancelled ${bridgeCount} bridge records for ${bid}`);
        }
      } catch (e) { console.warn('[wa-tool] bridge cleanup failed:', e.message); }

      // Initiate refund if paid
      let refundMsg = '';
      if (wasPaid) {
        const cost = parseFloat(d.cost || '0');
        if (cost > 0) {
          await firestore.collection('refund_requests').add({
            booking_id: bid,
            user_id: session.linkedUserId || d.user_id || '',
            phone: session.phone,
            amount: cost,
            reason: args.reason || 'Cancelled via WhatsApp',
            status: 'pending',
            source: 'whatsapp',
            created_at: admin.firestore.FieldValue.serverTimestamp(),
          });

          // If wallet payment, auto-refund
          if (d.payment_method === 'wallet' && session.linkedUserId) {
            try {
              const userRef = firestore.collection('users').doc(session.linkedUserId);
              await firestore.runTransaction(async (txn) => {
                const userSnap = await txn.get(userRef);
                if (userSnap.exists) {
                  const bal = parseFloat(userSnap.data().balance || '0');
                  txn.update(userRef, { balance: (bal + cost).toFixed(2) });
                }
              });
              await firestore.collection('transactionLogs').add({
                user_id: session.linkedUserId,
                type: 'refund',
                subtype: 'wallet_refund',
                amount: cost,
                booking_id: bid,
                source: 'whatsapp',
                status: 'success',
                created_at: admin.firestore.FieldValue.serverTimestamp(),
              });
              refundMsg = ` R${cost.toFixed(2)} has been refunded to your wallet.`;
            } catch (e) {
              console.warn('[wa-tool] wallet refund failed:', e.message);
              refundMsg = ' Your refund request has been submitted. Admin will process it shortly.';
            }
          } else {
            refundMsg = ' Your refund request has been submitted. It will be processed within 3-5 business days.';
          }
        }
      }

      // Notify admin
      await firestore.collection('notifications').add({
        title: 'Booking Cancelled (WhatsApp)',
        body: `Booking ${bid} cancelled by customer.${wasPaid ? ' Refund required.' : ''}`,
        type: 'booking_cancelled',
        user_type: 'admin',
        booking_id: bid,
        read: false,
        created_at: admin.firestore.FieldValue.serverTimestamp(),
      });

      return {
        success: true,
        message: `Booking ${bid} has been cancelled.${refundMsg}`,
        refundInitiated: wasPaid,
      };
    }

    // ═══════════════════════════════════════════
    // 12) RESCHEDULE BOOKING
    // ═══════════════════════════════════════════
    case 'reschedule_booking': {
      if (!firestore) return { error: 'Database unavailable' };
      const bid = args.bookingId;
      if (!bid || !args.newDate) return { error: 'Please provide booking ID and new date.' };

      // Validate date is in the future
      const newDt = new Date(args.newDate);
      if (isNaN(newDt.getTime()) || newDt < new Date()) {
        return { error: 'Please provide a valid future date in YYYY-MM-DD format.' };
      }

      let doc = await firestore.collection('futureBookings').doc(bid).get();
      if (!doc.exists) doc = await firestore.collection('tasksManagement').doc(bid).get();
      if (!doc.exists) return { error: `Booking "${bid}" not found.` };

      const d = doc.data();
      if (d.status === 'cancelled' || d.status === 'completed' || d.status === 'closed') {
        return { error: `Cannot reschedule a ${d.status} booking.` };
      }

      const update = {
        scheduled_date: args.newDate,
        scheduled_time: args.newTime || d.scheduled_time || '',
        rescheduled_at: new Date().toISOString(),
        rescheduled_by: 'client_whatsapp',
      };

      // Update both collections
      try { await firestore.collection('futureBookings').doc(bid).update(update); } catch (e) { console.warn('[wa-tool] reschedule futureBookings failed:', e.message); }
      try { await firestore.collection('tasksManagement').doc(bid).update(update); } catch (e) { console.warn('[wa-tool] reschedule tasksManagement failed:', e.message); }

      return {
        success: true,
        message: `Booking ${bid} rescheduled to ${args.newDate}${args.newTime ? ' at ' + args.newTime : ''}. The assigned artisan will be notified.`,
        newDate: args.newDate,
        newTime: args.newTime || '',
      };
    }

    // ═══════════════════════════════════════════
    // 13) RATE BOOKING
    // ═══════════════════════════════════════════
    case 'rate_booking': {
      if (!firestore) return { error: 'Database unavailable' };
      const bid = args.bookingId;
      const rating = Math.max(1, Math.min(5, Math.round(args.rating || 0)));
      if (!bid) return { error: 'Please provide a booking ID.' };
      if (!rating) return { error: 'Please provide a rating between 1 and 5.' };

      // Get booking from tasksManagement, futureBookings, or rfq_requests
      let doc = await firestore.collection('tasksManagement').doc(bid).get();
      if (!doc.exists) doc = await firestore.collection('futureBookings').doc(bid).get();
      if (!doc.exists) doc = await firestore.collection('rfq_requests').doc(bid).get();
      if (!doc.exists) return { error: `Booking "${bid}" not found.` };

      const d = doc.data();

      // Verify the current WhatsApp user owns this booking
      const bookingUserId = (d.user_id || d.userId || d.uid || '').toString().trim();
      const bookingPhone = (d.user_phone || d.phone || d.contact || '').toString().replace(/\D/g, '');
      const sessionUserId = (session.linkedUserId || '').toString().trim();
      const sessionPhone = (session.phone || '').toString().replace(/\D/g, '');
      const isOwner = (sessionUserId && (sessionUserId === bookingUserId)) ||
                      (sessionPhone && bookingPhone.endsWith(sessionPhone.slice(-9)));
      if (!isOwner) {
        return { error: 'You can only rate bookings that belong to your account.' };
      }

      const status = (d.status || '').toLowerCase();

      if (status !== 'completed' && status !== 'closed' && status !== 'done') {
        return { error: 'You can only rate completed jobs. This booking status is: ' + d.status };
      }

      if (d.rating) {
        return { message: `You've already rated this booking (${d.rating} stars).` };
      }

      const now = new Date().toISOString();

      // Update booking with rating
      await firestore.collection('tasksManagement').doc(bid).update({
        rating,
        user_comment: args.comment || '',
        rated_at: now,
        status: 'closed',
      });

      // Store review on artisan profile
      const artisanId = d.service_provider_id;
      if (artisanId) {
        try {
          await firestore.collection('serviceProvider').doc(artisanId)
            .collection('reviews').add({
              booking_id: bid,
              user_id: session.linkedUserId || d.user_id || '',
              rating,
              review: args.comment || '',
              source: 'whatsapp',
              created_at: admin.firestore.FieldValue.serverTimestamp(),
            });

          // Update artisan average rating
          const reviewsSnap = await firestore.collection('serviceProvider').doc(artisanId)
            .collection('reviews').get();
          const allRatings = reviewsSnap.docs.map(r => r.data().rating || 0).filter(r => r > 0);
          const avgRating = allRatings.reduce((a, b) => a + b, 0) / allRatings.length;

          await firestore.collection('serviceProvider').doc(artisanId).update({
            rating: Math.round(avgRating * 10) / 10,
            job_count: admin.firestore.FieldValue.increment(1),
          });
        } catch (e) {
          console.error('[wa-tool] artisan rating update failed:', e.message);
          // Don't silently swallow — tell the user the review part failed
          const stars = '⭐'.repeat(rating);
          session.pendingRatingBookingId = null; // clear pending
          return {
            success: true,
            message: `Thank you for your ${stars} rating! Your rating was saved but we had trouble updating the artisan's profile — our team will fix this. Your feedback is appreciated! 🙏`,
          };
        }
      }

      session.pendingRatingBookingId = null; // clear pending rating
      const stars = '⭐'.repeat(rating);
      return {
        success: true,
        message: `Thank you for your ${stars} rating!${args.comment ? ' Your review has been saved.' : ''} Your feedback helps us maintain quality service.`,
      };
    }

    // ═══════════════════════════════════════════
    // 14) REQUEST REFUND
    // ═══════════════════════════════════════════
    case 'request_refund': {
      if (!firestore) return { error: 'Database unavailable' };
      const bid = args.bookingId;
      if (!bid) return { error: 'Please provide a booking ID.' };

      let doc = await firestore.collection('tasksManagement').doc(bid).get();
      if (!doc.exists) return { error: `Booking "${bid}" not found.` };

      const d = doc.data();
      if (d.payment_status !== 'paid' && d.paymentStatus !== 'paid') {
        return { error: 'No payment found for this booking. Refunds are only available for paid bookings.' };
      }

      // Check if refund already requested
      const existingRefund = await firestore.collection('refund_requests')
        .where('booking_id', '==', bid).where('status', '==', 'pending').limit(1).get();
      if (!existingRefund.empty) {
        return { message: 'A refund request for this booking is already being processed.' };
      }

      const cost = parseFloat(d.cost || '0');
      await firestore.collection('refund_requests').add({
        booking_id: bid,
        user_id: session.linkedUserId || d.user_id || '',
        phone: session.phone,
        amount: cost,
        reason: args.reason || 'Refund requested via WhatsApp',
        status: 'pending',
        source: 'whatsapp',
        created_at: admin.firestore.FieldValue.serverTimestamp(),
      });

      // Notify admin
      await firestore.collection('notifications').add({
        title: 'Refund Request (WhatsApp)',
        body: `Refund requested for booking ${bid} (R${cost.toFixed(2)}). Reason: ${args.reason || 'Not specified'}`,
        type: 'refund_request',
        user_type: 'admin',
        booking_id: bid,
        read: false,
        created_at: admin.firestore.FieldValue.serverTimestamp(),
      });

      return {
        success: true,
        message: `Refund request submitted for booking ${bid} (R${cost.toFixed(2)}). Our admin team will review and process it within 3-5 business days.`,
        amount: `R${cost.toFixed(2)}`,
      };
    }

    // ═══════════════════════════════════════════
    // 15) LINK PARTNER CODE
    // ═══════════════════════════════════════════
    case 'link_partner_code': {
      if (!firestore) return { error: 'Database unavailable' };

      const code = (args.referralCode || '').trim().toUpperCase();
      if (!code) return { error: 'Please provide a partner/referral code.' };

      // Validate referral code
      const partnerSnap = await firestore.collection('corporate_partners')
        .where('referral_code', '==', code).where('status', '==', 'active').limit(1).get();
      if (partnerSnap.empty) {
        return { valid: false, message: `Referral code "${code}" not found or is inactive.` };
      }

      const partner = partnerSnap.docs[0];
      const partnerData = partner.data();

      // Need a linked user account
      if (!session.linkedUserId) {
        const user = await findUserByPhone(session.phone);
        if (user) session.linkedUserId = user.id;
        else return { error: 'Your WhatsApp number is not linked to a Square 15 account. Please sign up in the app first to use referral codes.' };
      }

      // Check if already linked
      const userDoc = await firestore.collection('users').doc(session.linkedUserId).get();
      if (userDoc.data()?.referred_by_partner_id) {
        return { message: 'Your account is already linked to a partner. Only one referral code can be used per account.' };
      }

      // Link user to partner
      await firestore.collection('users').doc(session.linkedUserId).update({
        referred_by_partner_id: partner.id,
        referral_code_used: code,
        referral_linked_at: new Date().toISOString(),
      });

      await firestore.collection('corporate_partners').doc(partner.id).update({
        total_referrals: admin.firestore.FieldValue.increment(1),
      });

      return {
        valid: true,
        message: `Partner code "${code}" linked to your account! You're now under ${partnerData.company_name || 'our corporate partner'}'s program.`,
        partner: partnerData.company_name || code,
      };
    }

    // ═══════════════════════════════════════════
    // 16) LINK ACCOUNT
    // ═══════════════════════════════════════════
    case 'link_account': {
      if (session.linkedUserId) {
        return { linked: true, message: 'Your WhatsApp number is already linked to your Square 15 account.' };
      }

      const user = await findUserByPhone(session.phone);
      if (user) {
        session.linkedUserId = user.id;
        return { linked: true, message: `Found your account! Welcome back, ${user.name || user.userName || 'customer'}. Your WhatsApp is now linked.` };
      }

      return {
        linked: false,
        message: 'No Square 15 account found for this phone number. Would you like me to register a new account for you right here on WhatsApp? Just provide your full name to get started.',
      };
    }

    // ═══════════════════════════════════════════
    // 16b) REGISTER ACCOUNT (WhatsApp)
    // ═══════════════════════════════════════════
    case 'register_account': {
      if (!firestore) return { error: 'Database unavailable' };

      const customerName = (args.name || '').trim();
      if (!customerName) return { error: 'Please provide your full name to register.' };

      // Check if already registered
      if (session.linkedUserId) {
        return { registered: true, message: 'You already have a Square 15 account linked to this WhatsApp number.' };
      }

      const existingUser = await findUserByPhone(session.phone);
      if (existingUser) {
        session.linkedUserId = existingUser.id;
        return { registered: true, message: `You already have an account (${existingUser.name || customerName}). I've linked it to this WhatsApp chat.` };
      }

      // Create a new user document (compatible with Flutter app UserModel)
      const userId = `wa_${session.phone}`;
      const now = new Date().toISOString();
      const userData = {
        uid: userId,
        name: customerName,
        email: (args.email || '').trim() || null,
        contact: parseInt(session.phone) || session.phone,
        phone: session.phone,
        isAdmin: false,
        isServiceProvider: false,
        isUser: true,
        isVerified: false,
        lat: '0.0',
        lng: '0.0',
        deviceToken: '',
        fcm_token: '',
        image: '',
        balance: '0',
        source: 'whatsapp',
        created_at: now,
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
      };

      if (args.address) userData.address = args.address.trim();

      await firestore.collection('users').doc(userId).set(userData);
      session.linkedUserId = userId;

      // Handle referral code if provided
      let referralMessage = '';
      const code = (args.referralCode || '').trim().toUpperCase();
      if (code) {
        try {
          const partnerSnap = await firestore.collection('corporate_partners')
            .where('referral_code', '==', code).where('status', '==', 'active').limit(1).get();
          if (!partnerSnap.empty) {
            const partner = partnerSnap.docs[0];
            const partnerData = partner.data();
            await firestore.collection('users').doc(userId).update({
              referred_by_partner_id: partner.id,
              referral_code_used: code,
              referral_linked_at: now,
            });
            await firestore.collection('corporate_partners').doc(partner.id).update({
              total_referrals: admin.firestore.FieldValue.increment(1),
            });
            referralMessage = ` Partner code "${code}" linked — you're under ${partnerData.company_name || 'our corporate partner'}'s program.`;
          } else {
            referralMessage = ` (Referral code "${code}" was not found or is inactive — you can try again later.)`;
          }
        } catch (e) {
          console.error('[register_account] Referral link error:', e.message);
          referralMessage = ' (Could not link referral code right now — you can try again later.)';
        }
      }

      return {
        registered: true,
        userId,
        message: `Welcome to Square 15, ${customerName}! 🎉 Your account has been created and linked to this WhatsApp number.${referralMessage} You can now book services, track jobs, earn wallet credits, and more — all right here on WhatsApp.`,
      };
    }

    // ═══════════════════════════════════════════
    // 17) CHECK RFQ STATUS
    // ═══════════════════════════════════════════
    case 'check_rfq_status': {
      if (!firestore) return { error: 'Database unavailable' };

      const rfqId = args.rfqId || args.bookingId || session.lastRfqId;
      if (!rfqId) {
        // List all RFQs for this phone number
        try {
          const snap = await firestore.collection('futureBookings')
            .where('user_phone', '==', session.phone)
            .where('is_rfq', '==', 'yes')
            .limit(5)
            .get();

          if (snap.empty) {
            // Also try linked user ID
            if (session.linkedUserId) {
              const snap2 = await firestore.collection('futureBookings')
                .where('user_id', '==', session.linkedUserId)
                .where('is_rfq', '==', 'yes')
                .limit(5)
                .get();
              if (!snap2.empty) {
                const rfqs = snap2.docs.map(d => {
                  const data = d.data();
                  return {
                    rfqId: d.id,
                    rfqNo: data.rfq_no || data.order_no,
                    category: data.category_name,
                    status: data.rfq_status || data.status,
                    quotedPrice: data.quoted_price || data.total_price || 'pending',
                    createdAt: data.created_at,
                  };
                });
                return { rfqs, message: `Found ${rfqs.length} RFQ(s).` };
              }
            }
            return { message: 'No RFQ requests found for your number.' };
          }

          const rfqs = snap.docs.map(d => {
            const data = d.data();
            return {
              rfqId: d.id,
              rfqNo: data.rfq_no || data.order_no,
              category: data.category_name,
              status: data.rfq_status || data.status,
              quotedPrice: data.quoted_price || data.total_price || 'pending',
              createdAt: data.created_at,
            };
          });

          return { rfqs, message: `Found ${rfqs.length} RFQ(s).` };
        } catch (e) {
          return { error: 'Could not retrieve RFQs. Please try again.' };
        }
      }

      // Specific RFQ lookup
      const doc = await firestore.collection('futureBookings').doc(rfqId).get();
      if (!doc.exists) return { error: `RFQ "${rfqId}" not found.` };

      const data = doc.data();
      const result = {
        rfqId: doc.id,
        rfqNo: data.rfq_no || data.order_no,
        category: data.category_name,
        description: data.problem_description || data.description,
        status: data.rfq_status || data.status,
        quotedPrice: data.quoted_price || data.total_price || '',
        quoteDetails: data.quote_details || '',
        createdAt: data.created_at,
      };

      if (data.ai_quote) {
        result.hasQuote = true;
        result.quote = {
          grandTotal: `R${parseFloat(data.ai_quote.grand_total || 0).toFixed(2)}`,
          labor: `R${parseFloat(data.ai_quote.laborCost || 0).toFixed(2)}`,
          materials: `R${parseFloat(data.ai_quote.materials_with_markup || 0).toFixed(2)}`,
          contingency: `R${parseFloat(data.ai_quote.contingency || 0).toFixed(2)}`,
          scopeOfWork: data.ai_quote.scope_of_work || '',
          duration: data.ai_quote.estimated_duration || '',
          materialsBOM: (data.ai_quote.materialsBOM || []).map(m => `${m.name} (${m.qty} ${m.unit})`),
        };
      }

      return result;
    }

    // ═══════════════════════════════════════════
    // 18) ACCEPT RFQ QUOTE
    // ═══════════════════════════════════════════
    case 'accept_rfq_quote': {
      if (!firestore) return { error: 'Database unavailable' };

      const rfqId = args.rfqId || args.bookingId || session.lastRfqId;
      if (!rfqId) return { error: 'Please provide the RFQ ID.' };

      const doc = await firestore.collection('futureBookings').doc(rfqId).get();
      if (!doc.exists) return { error: `RFQ "${rfqId}" not found.` };

      const data = doc.data();
      if (!data.quoted_price && !data.ai_quote) {
        return { error: 'This RFQ does not have a quote yet. Please wait for the quote to be generated.' };
      }

      const price = data.quoted_price || (data.ai_quote ? data.ai_quote.grand_total : '0');
      const priceNum = parseFloat(price);
      const depositAmount = Math.round(priceNum * 0.35 * 100) / 100;
      const balanceAmount = Math.round((priceNum - depositAmount) * 100) / 100;

      await firestore.collection('futureBookings').doc(rfqId).update({
        rfq_status: 'accepted_converted',
        status: 'pending_artisan_acceptance',
        artisan_confirmed: 'pending',
        deposit_amount: depositAmount.toFixed(2),
        balance_amount: balanceAmount.toFixed(2),
        payment_type: '',
        deposit_paid: false,
        balance_paid: false,
        accepted_at: new Date().toISOString(),
        accepted_via: 'whatsapp',
      });

      // Mirror accepted RFQ to tasksManagement so all downstream handlers
      // (cancel, reschedule, wallet payment, admin app) can find it
      await firestore.collection('tasksManagement').doc(rfqId).set({
        id: rfqId,
        order_no: data.order_no || data.rfq_no || rfqId,
        user_id: data.user_id || session.linkedUserId || '',
        user_name: data.user_name || '',
        user_phone: data.user_phone || session.phone,
        category_name: data.category_name || '',
        description: data.description || data.problem_description || '',
        problem_description: data.problem_description || data.description || '',
        address: data.address || '',
        status: 'pending_artisan_acceptance',
        artisan_confirmed: 'pending',
        accept: '',
        payment_status: 'unpaid',
        cost: priceNum.toFixed(2),
        total_cost: priceNum.toFixed(2),
        deposit_amount: depositAmount.toFixed(2),
        balance_amount: balanceAmount.toFixed(2),
        payment_type: '',
        deposit_paid: false,
        balance_paid: false,
        source: 'whatsapp_rfq',
        is_rfq: 'yes',
        rfq_status: 'accepted_converted',
        service_provider_id: data.service_provider_id || '',
        service_provider_name: data.service_provider_name || '',
        scheduled_date: data.scheduled_date || '',
        scheduled_time: data.scheduled_time || '',
        created_at: data.created_at || new Date().toISOString(),
        accepted_at: new Date().toISOString(),
        accepted_via: 'whatsapp',
      }, { merge: true });

      // Notify admin to assign an artisan
      await firestore.collection('notifications').add({
        title: 'RFQ Quote Accepted — Assign Artisan',
        body: `Customer accepted quote for RFQ ${data.rfq_no || rfqId} (R${priceNum.toFixed(2)}). Please assign an artisan.`,
        type: 'rfq_accepted',
        user_type: 'admin',
        booking_id: rfqId,
        read: false,
        created_at: admin.firestore.FieldValue.serverTimestamp(),
      });

      // ── Auto-dispatch: route directly to artisans when conditions met ──
      const materialsResp = (data.materials_responsibility || '').toString().trim().toLowerCase();
      const clientBuysMaterials = materialsResp === 'client';
      const underThreshold = priceNum > 0 && priceNum < 12000;
      let autoDispatched = false;

      if (clientBuysMaterials || underThreshold) {
        const autoReason = clientBuysMaterials ? 'client_buys_materials' : 'under_12k';
        const cat = (data.category || data.category_name || '').toLowerCase().replace(/\s+/g, '_');
        try {
          // Query without inequality filter — Firestore != excludes docs
          // where the field doesn't exist, hiding most artisans.
          const artisanSnap = await firestore.collection('serviceProvider')
            .where('status', 'in', ['publish', 'published', 'approved', 'approve'])
            .limit(50)
            .get();
          const matchedArtisans = [];
          for (const artDoc of artisanSnap.docs) {
            const ad = artDoc.data() || {};
            // Skip suspended artisans (checked in code, not query)
            if (ad.is_suspended === true) continue;
            // Check active status — only the manual toggle gates dispatch
            const activeField = ad.active;
            if (activeField != null && !isTruthyValue(activeField)) continue;
            const cats = (ad.categories || ad.category || '').toString().toLowerCase();
            if (cats && cat && !cats.includes(cat) && cat !== 'general_maintenance') continue;
            const aName = ad.name || ad.userName || ad.full_name || artDoc.id;
            matchedArtisans.push({ id: artDoc.id, name: aName, token: (ad.fcm_token || ad.deviceToken || '').toString().trim() });
            if (matchedArtisans.length >= 3) break;
          }
          if (matchedArtisans.length > 0) {
            const artisanIds = matchedArtisans.map(a => a.id);
            const artisanNames = {};
            matchedArtisans.forEach(a => { artisanNames[a.id] = a.name; });

            await firestore.collection('futureBookings').doc(rfqId).update({
              rfq_status: 'pending_artisan_acceptance',
              status: 'pending_artisan_acceptance',
              rfq_submitted_to: 'artisan',
              rfq_assigned_artisan_ids: artisanIds,
              rfq_assigned_artisan_names: artisanNames,
              rfq_auto_assigned: true,
              rfq_auto_assign_reason: autoReason,
              rfq_auto_assigned_at: new Date().toISOString(),
              rfq_artisan_rejection_count: 0,
              rfq_artisan_rejections: [],
              artisan_name: matchedArtisans[0].name,
            });

            await firestore.collection('tasksManagement').doc(rfqId).update({
              status: 'pending_artisan_acceptance',
              rfq_assigned_artisan_ids: artisanIds,
              rfq_auto_assigned: true,
              rfq_auto_assign_reason: autoReason,
            });

            for (const art of matchedArtisans) {
              if (!art.token) continue;
              try {
                await admin.messaging().send({
                  token: art.token,
                  notification: { title: '🔔 New RFQ Job Available', body: `RFQ ${data.rfq_no || rfqId} — R${priceNum.toFixed(2)}. Tap to view and accept.` },
                  data: { type: 'rfq_accepted', booking_id: rfqId },
                  android: { notification: { channelId: 'order_request_channel', sound: 'sound' } },
                });
              } catch (fcmErr) { console.warn(`[wa-tool] FCM to artisan ${art.id} failed:`, fcmErr.message); }
            }
            autoDispatched = true;
            console.log(`[wa-tool] Auto-dispatched RFQ ${rfqId} to ${artisanIds.length} artisans (${autoReason})`);
          } else {
            console.log(`[wa-tool] No artisans matched for RFQ ${rfqId} — admin will assign manually`);
          }
        } catch (e) { console.warn('[wa-tool] auto-dispatch failed, falling back to admin:', e.message); }
      }

      if (autoDispatched) {
        console.log(`[wa-tool] RFQ ${rfqId} auto-dispatched to artisans (under R12K or client buys materials)`);
      }

      // Store for quick payment follow-up
      session.lastBookingId = rfqId;
      session.lastBookingCost = priceNum;

      return {
        success: true,
        message: `Quote accepted! RFQ ${data.rfq_no || rfqId} — Total: R${priceNum.toFixed(2)}.\n\n⏳ *Next step:* An artisan needs to accept your job before payment. We'll notify you as soon as one accepts.\n\n🔒 *Your money is protected:* When it's time to pay, your payment is held in a secure escrow account. The artisan does NOT receive your money until you confirm you are satisfied with the completed work.\n\n💰 *Payment options (after artisan accepts):*\n• Full amount: R${priceNum.toFixed(2)}\n• Deposit (35%): R${depositAmount.toFixed(2)} now, R${balanceAmount.toFixed(2)} after job completion`,
        rfqId,
        price: `R${priceNum.toFixed(2)}`,
      };
    }

    // ═══════════════════════════════════════════
    // 19) REJECT / NEGOTIATE RFQ QUOTE
    // ═══════════════════════════════════════════
    case 'reject_rfq_quote': {
      if (!firestore) return { error: 'Database unavailable' };

      const rfqId = args.rfqId || args.bookingId || session.lastRfqId;
      if (!rfqId) return { error: 'Please provide the RFQ ID.' };

      const doc = await firestore.collection('futureBookings').doc(rfqId).get();
      if (!doc.exists) return { error: `RFQ "${rfqId}" not found.` };

      const reason = args.reason || 'Customer wants to negotiate via WhatsApp';

      await firestore.collection('futureBookings').doc(rfqId).update({
        rfq_status: 'under_negotiation',
        negotiation_reason: reason,
        negotiation_at: new Date().toISOString(),
        negotiation_via: 'whatsapp',
      });

      // Notify admin
      await firestore.collection('notifications').add({
        title: 'RFQ Quote Negotiation',
        body: `Customer wants to negotiate RFQ ${doc.data().rfq_no || rfqId}. Reason: ${reason}`,
        type: 'rfq_negotiation',
        user_type: 'admin',
        booking_id: rfqId,
        read: false,
        created_at: admin.firestore.FieldValue.serverTimestamp(),
      });

      return {
        success: true,
        message: `We've noted your feedback on RFQ ${doc.data().rfq_no || rfqId}. Our admin team will review and adjust the quote. You'll receive an updated quote here on WhatsApp.`,
      };
    }

    // ═══════════════════════════════════════════
    // EXPLAIN QUOTE
    // ═══════════════════════════════════════════
    case 'explain_quote': {
      if (!firestore) return { error: 'Database unavailable' };
      const bid = args.bookingId;
      if (!bid) return { error: 'Please provide a booking or RFQ ID.' };

      let doc = await firestore.collection('futureBookings').doc(bid).get();
      if (!doc.exists) doc = await firestore.collection('tasksManagement').doc(bid).get();
      if (!doc.exists) return { error: `Booking "${bid}" not found.` };

      const data = doc.data();
      const result = {
        booking_id: bid,
        status: data.status || data.rfq_status || 'unknown',
        cost: data.cost || data.total_cost || 'N/A',
      };
      if (data.quote_breakdown) result.breakdown = data.quote_breakdown;
      if (data.labour_cost) result.labour = data.labour_cost;
      if (data.materials_cost) result.materials = data.materials_cost;
      if (data.equipment_cost) result.equipment = data.equipment_cost;
      if (data.contingency) result.contingency = data.contingency;
      if (data.ai_quote) result.ai_quote = data.ai_quote;
      return result;
    }

    // ═══════════════════════════════════════════
    // CHECK PAYMENT
    // ═══════════════════════════════════════════
    case 'check_payment': {
      if (!firestore) return { error: 'Database unavailable' };
      const bid = args.bookingId;
      if (!bid) return { error: 'Please provide a booking ID.' };

      let doc = await firestore.collection('tasksManagement').doc(bid).get();
      if (!doc.exists) doc = await firestore.collection('futureBookings').doc(bid).get();
      if (!doc.exists) return { error: `Booking "${bid}" not found.` };

      const data = doc.data();
      const paymentStatus = data.payment_status || 'unpaid';
      const totalCost = parseFloat(data.cost || data.total_cost || '0');
      const isDeposit = data.payment_type === 'deposit' || paymentStatus === 'deposit_paid';
      const depositAmount = isDeposit ? (parseFloat(data.deposit_amount || '0') || Math.round(totalCost * 0.35 * 100) / 100) : 0;
      const balanceRemaining = isDeposit ? (parseFloat(data.balance_remaining || data.balance_amount || '0') || Math.round((totalCost - depositAmount) * 100) / 100) : 0;

      return {
        booking_id: bid,
        payment_status: paymentStatus,
        payment_type: isDeposit ? 'deposit' : 'full',
        payment_method: data.payment_method || 'N/A',
        total_amount: totalCost > 0 ? `R${totalCost.toFixed(2)}` : 'N/A',
        deposit_paid: isDeposit ? `R${depositAmount.toFixed(2)}` : null,
        balance_remaining: isDeposit && data.balance_paid !== true ? `R${balanceRemaining.toFixed(2)}` : null,
        balance_paid: isDeposit ? (data.balance_paid === true) : null,
        paid_at: data.paid_at || null,
      };
    }

    // ═══════════════════════════════════════════
    // GET MESSAGES
    // ═══════════════════════════════════════════
    case 'get_messages': {
      if (!firestore) return { error: 'Database unavailable' };
      const bid = args.bookingId;
      if (!bid) return { error: 'Please provide a booking ID.' };

      try {
        const snap = await firestore.collection('messages')
          .where('booking_id', '==', bid)
          .orderBy('created_at', 'desc')
          .limit(20)
          .get();
        if (snap.empty) return { messages: [], message: 'No messages found for this booking.' };
        const msgs = snap.docs.map(d => {
          const m = d.data();
          return {
            sender: m.sender_type || 'unknown',
            message: m.message || '',
            time: m.created_at?.toDate?.()?.toISOString() || '',
          };
        });
        return { messages: msgs, count: msgs.length };
      } catch (e) {
        return { error: 'Failed to fetch messages' };
      }
    }

    // ═══════════════════════════════════════════
    // SEND MESSAGE
    // ═══════════════════════════════════════════
    case 'send_message': {
      if (!firestore) return { error: 'Database unavailable' };
      const bid = args.bookingId;
      const msg = args.message;
      const recipient = args.recipient || 'admin';
      if (!bid || !msg) return { error: 'Please provide a booking ID and message.' };

      try {
        const msgRef = firestore.collection('messages').doc();
        await msgRef.set({
          id: msgRef.id,
          booking_id: bid,
          sender_id: session.linkedUserId || session.phone,
          sender_type: 'client',
          recipient_type: recipient,
          message: msg,
          source: 'whatsapp',
          read: false,
          created_at: admin.firestore.FieldValue.serverTimestamp(),
        });
        return { success: true, message: `Message sent to ${recipient}.` };
      } catch (e) {
        return { error: 'Failed to send message' };
      }
    }

    // ═══════════════════════════════════════════
    // LIST CASES
    // ═══════════════════════════════════════════
    case 'list_cases': {
      if (!firestore) return { error: 'Database unavailable' };
      const userId = session.linkedUserId;
      if (!userId) return { error: 'Please link your account first to view support cases.' };

      try {
        let query = firestore.collection('customer_support_cases').where('user_id', '==', userId);
        if (args.state) query = query.where('status', '==', args.state);
        const snap = await query.orderBy('created_at', 'desc').limit(10).get();
        if (snap.empty) return { cases: [], message: 'No support cases found.' };
        const cases = snap.docs.map(d => {
          const c = d.data();
          return {
            case_id: d.id,
            subject: c.subject || '',
            status: c.status || 'unknown',
            created: c.created_at?.toDate?.()?.toISOString() || '',
          };
        });
        return { cases, count: cases.length };
      } catch (e) {
        return { error: 'Failed to fetch cases' };
      }
    }

    // ═══════════════════════════════════════════
    // REPLY TO CASE
    // ═══════════════════════════════════════════
    case 'reply_to_case': {
      if (!firestore) return { error: 'Database unavailable' };
      const caseId = args.caseId;
      const msg = args.message;
      if (!caseId || !msg) return { error: 'Please provide a case ID and message.' };

      try {
        const caseDoc = await firestore.collection('customer_support_cases').doc(caseId).get();
        if (!caseDoc.exists) return { error: `Case "${caseId}" not found.` };

        await firestore.collection('customer_support_cases').doc(caseId).collection('replies').add({
          user_id: session.linkedUserId || session.phone,
          message: msg,
          source: 'whatsapp',
          created_at: admin.firestore.FieldValue.serverTimestamp(),
        });
        return { success: true, message: `Reply added to case ${caseId}.` };
      } catch (e) {
        return { error: 'Failed to reply to case' };
      }
    }

    // ═══════════════════════════════════════════
    // GET CASE DETAILS
    // ═══════════════════════════════════════════
    case 'get_case_details': {
      if (!firestore) return { error: 'Database unavailable' };
      const caseId = args.caseId;
      if (!caseId) return { error: 'Please provide a case ID.' };

      try {
        const caseDoc = await firestore.collection('customer_support_cases').doc(caseId).get();
        if (!caseDoc.exists) return { error: `Case "${caseId}" not found.` };
        const data = caseDoc.data();
        const repliesSnap = await firestore.collection('customer_support_cases').doc(caseId)
          .collection('replies').orderBy('created_at', 'asc').limit(20).get();
        const replies = repliesSnap.docs.map(d => {
          const r = d.data();
          return { message: r.message || '', time: r.created_at?.toDate?.()?.toISOString() || '' };
        });
        return {
          case_id: caseId,
          subject: data.subject || '',
          status: data.status || 'unknown',
          description: data.description || '',
          created: data.created_at?.toDate?.()?.toISOString() || '',
          replies,
        };
      } catch (e) {
        return { error: 'Failed to fetch case details' };
      }
    }

    // ═══════════════════════════════════════════
    // REPORT ISSUE (auto-escalation to admin)
    // ═══════════════════════════════════════════
    case 'report_issue': {
      if (!firestore) return { error: 'Database unavailable' };
      try {
        const caseId = firestore.collection('customer_support_cases').doc().id;
        await firestore.collection('customer_support_cases').doc(caseId).set({
          id: caseId,
          user_id: session.linkedUserId || '',
          phone: session.phone || '',
          subject: (args.error_type || 'technical_error').replace(/_/g, ' '),
          description: `${args.description || 'Technical issue reported'}\n\nAuto-detected by: whatsapp_bot\nPhone: ${session.phone || 'unknown'}`,
          booking_id: args.booking_id || '',
          status: 'open',
          priority: 'high',
          source: 'whatsapp_bot',
          auto_generated: true,
          error_type: args.error_type || 'technical_error',
          created_at: admin.firestore.FieldValue.serverTimestamp(),
        });
        // Also log to error_logs + notify admin
        await logErrorToAdmin(
          args.error_type || 'technical_error',
          args.description || 'Issue reported via WhatsApp',
          'whatsapp_bot',
          '',
          args.booking_id,
          'high',
        );
        return { success: true, case_id: caseId, message: `Issue logged (ref: ${caseId}). Our tech team has been notified and will look into it right away.` };
      } catch (e) {
        return { error: 'Failed to report issue' };
      }
    }

    default:
      return { error: `Unknown tool: ${name}` };
  }
}

// ─── Main message handler ───

const SYSTEM_PROMPT = `You are Lizzy, the Square 15 Facility Solutions AI assistant on WhatsApp.
You are an AI-powered assistant (not a human). When greeting a customer for the first time, introduce yourself clearly:
"Hi! I'm Lizzy, your AI assistant from Square 15 Facility Solutions. I can help you book maintenance services, get quotes, track jobs, and process payments — all right here on WhatsApp. How can I help you today?"
You help South African homeowners and tenants with property maintenance services.

YOUR FULL CAPABILITIES:
📋 BOOKINGS:
- List service categories (plumbing, electrical, painting, carpentry, roofing, tiling, locksmith, etc.)
- Create maintenance bookings with full details
- Check booking status by ID
- List customer's recent bookings
- Reschedule bookings to new dates
- Cancel bookings (with automatic refund if paid)

💰 PAYMENTS:
- Check wallet balance
- Pay for bookings using wallet balance
- Request payment link for card payment
- Apply promo/discount codes before booking

📝 RFQ (Request for Quote) — AI-POWERED QUOTING:
- Submit RFQ for complex/large jobs that need a detailed quote first
- AI automatically generates a full cost breakdown: labour, materials BOM, equipment, contingency (15%), and grand total
- Customer receives the quote instantly on WhatsApp with line-by-line materials pricing
- Customer can ACCEPT the quote (proceeds to payment) or NEGOTIATE (admin reviews and adjusts)
- Check status of existing RFQs
- Suggest RFQ when the job sounds complex (e.g. full bathroom renovation, roof replacement, geyser installation)

RFQ FLOW (CRITICAL — Follow this exactly):
1. Customer describes a complex job or sends photos of the issue
2. Collect: category, detailed description, address, name, materials responsibility (client or artisan)
3. Call submit_rfq — this creates the RFQ AND generates an AI quote instantly
4. The AI quote includes: labour hours × rate, materials BOM with markup (1.5×), equipment, and 15% contingency
5. Present the full quote breakdown to the customer (it's included in the submit_rfq response)
6. Ask if they want to ACCEPT or NEGOTIATE the quote
7. If ACCEPT → call accept_rfq_quote → proceed to payment
8. If NEGOTIATE → call reject_rfq_quote with their feedback → admin reviews
9. Customer can check RFQ status anytime with check_rfq_status

PHOTO ANALYSIS FOR RFQ:
- When a customer sends photos, analyse them with vision to identify the issue
- Use the photo analysis to build a detailed description for the RFQ
- The AI quote generator uses the conversation context including your photo analysis

⭐ RATINGS & REVIEWS:
- Rate completed jobs (1-5 stars with optional comment)
- Prompt customers to rate after asking about completed bookings

💸 REFUNDS:
- Request refunds for problematic bookings
- Wallet refunds processed instantly; card refunds take 3-5 business days

🤝 PARTNER CODES:
- Link corporate partner / referral codes for commission tracking
- Validate referral codes

🔗 ACCOUNT:
- Auto-link WhatsApp number to existing Square 15 app account
- Register new accounts directly via WhatsApp (register_account) — collect customer's full name, optionally email, address, and referral/partner code
- When link_account fails (no existing account found), offer to register a new account right here on WhatsApp
- Inform customers about app features when relevant

💬 MESSAGING:
- Get messages/chat history for a booking (get_messages)
- Send a message to the artisan or admin about a booking (send_message)

🎫 SUPPORT CASES:
- List your support cases (list_cases)
- Reply to an existing case (reply_to_case)
- View full case details (get_case_details)

📊 QUOTES & PAYMENTS:
- Explain a quote breakdown (explain_quote)
- Check payment status for a booking (check_payment)

CRITICAL PRICING RULES:
- You MUST call lookup_pricing BEFORE calling create_booking, EVERY TIME, NO EXCEPTIONS.
- When calling lookup_pricing, pass the specific service as subcategory (e.g. category="plumbing", subcategory="toilet unblocking").
- If lookup_pricing returns matched=true with a fixedPrice, use that EXACT price — do NOT estimate or use a different amount.
- If lookup_pricing returns matched=false and no fixedPrice service matches, tell the customer: "This job needs a detailed quote" and use submit_rfq instead of create_booking.
- NEVER guess or make up a price. Only use prices returned by lookup_pricing.
- If create_booking returns an estimated cost of R0.00, it means no fixed price was found — inform the customer and suggest an RFQ.

PRICE CONFIRMATION (CRITICAL — NEVER SKIP):
- After calling lookup_pricing, you MUST present the price to the customer and WAIT for their explicit confirmation BEFORE calling create_booking.
- Say something like: "The cost for [service] is R[price]. Shall I go ahead and create the booking?"
- Do NOT call create_booking in the same response as lookup_pricing. You must STOP and wait for the customer to say yes/confirm.
- Only after the customer confirms (e.g. "yes", "ok", "go ahead", "book it") should you call create_booking.
- If the customer questions the price or wants to negotiate, do NOT create the booking — explain the pricing and wait.
- This applies even if you already have all other details (category, address, name, photo). The price MUST be confirmed first.

PAYMENT FLOW (CRITICAL):
- When the customer asks to pay, says "pay", or wants to make payment, you MUST first ask: "Would you like to pay the full amount of R[X] or a 35% deposit of R[Y] (with R[Z] balance due after the job is completed)?"
- WAIT for the customer to choose "full" or "deposit" before calling request_payment_link.
- Pass the customer's choice as the paymentType parameter ("full" or "deposit").
- Do NOT call request_payment_link without first asking and getting the customer's payment type choice.
- Do NOT refuse or block payment based on conversation history alone. The function checks real-time booking status in the database.
- If an artisan hasn't accepted yet, the function itself will return an appropriate message.
- NEVER tell the customer "the artisan hasn't accepted yet" without first calling request_payment_link to verify.

DEPOSIT vs BALANCE PAYMENTS (CRITICAL):
- "deposit_paid" means ONLY the 35% deposit has been paid. There is STILL a remaining balance the customer owes.
- "paid" means the booking is fully paid. No further payment needed.
- When check_booking_status or check_payment shows paymentStatus="deposit_paid" with balanceRemaining, the customer STILL NEEDS to pay the balance.
- NEVER tell a customer "everything is paid" or "no balance to pay" when the status is "deposit_paid". They owe the remaining 65%.
- When a customer with deposit_paid asks to pay, call request_payment_link with paymentType="full" — the system will automatically calculate the correct balance amount.
- If check_booking_status returns balanceRemaining, always mention it: "You have a remaining balance of R[X] to pay."
- CRITICAL: When a customer asks about balance, remaining payment, or wants to pay — you MUST call check_booking_status or request_payment_link FIRST. NEVER answer from memory or conversation history. Always verify the real-time database status.
- If you see a [SYSTEM STATUS UPDATE] message with status "completed" or "after_photo", check if balance is due by calling check_booking_status.

PHOTO REQUIREMENT (CRITICAL):
- ALWAYS ask the customer to send a photo of the issue BEFORE creating a booking or RFQ.
- Say something like: "Could you please send me a photo of the issue? This helps our artisans understand the problem and come prepared."
- If the customer has already sent a photo during this conversation, you do NOT need to ask again.
- If the customer says they cannot send a photo (e.g. "I can't right now"), proceed without one — don't block the booking.
- Photos are automatically attached to the booking and sent to artisans when they receive the job request.
- The artisan will see the photos alongside the job description, address, and pricing.

GUIDELINES:
- Be warm, professional, and concise (WhatsApp messages should be short)
- Before creating a booking, make sure you have: category, description, service address, and customer name. If ANY of these were already mentioned in the conversation, do NOT ask for them again — use what the customer already said.
- SERVICE ADDRESS: The customer might already include the address in their first message (e.g. "I need a plumber at 15 Main Rd, Sandton"). If so, use that address — do NOT ask again. Only ask "Where does the service need to be done?" if no address was mentioned yet. Remember: the service location may differ from where the customer is right now. Do NOT ask for a location pin — just the text address is enough.
- For complex jobs (renovations, full installations), suggest submitting an RFQ instead of a regular booking
- Use South African Rands (R) for all pricing
- When a customer sends a photo, ANALYSE the image using your vision capabilities. Identify the maintenance issue (e.g. leaking pipe, broken socket, cracked wall), suggest the correct service category, call lookup_pricing to get the price, and present the price to the customer for confirmation. Do NOT create a booking until the customer confirms the price.
- For emergencies, emphasise urgency and prioritise booking creation (still ask for photo but don't delay)
- When a booking is created, always mention the estimated cost and payment options
- After job completion, encourage rating
- If payment is discussed, explain: "Payment is held securely in escrow and only released to the artisan once you confirm the job is done"
- For promo codes, apply them BEFORE creating the booking
- Keep messages under 500 characters when possible
- Always include the booking ID/order number in responses about specific bookings
- The customer's phone number is automatically captured from WhatsApp — never ask for it

🚨 ERROR DETECTION & AUTO-REPORTING (CRITICAL):
- report_issue(error_type, description, booking_id?) — auto-logs and alerts admin in real time
- When a customer reports ANY technical problem (payment failed, photos won't upload, app crashed, booking error, screen not loading, etc.), you MUST call report_issue IMMEDIATELY — do NOT just sympathise or acknowledge
- error_type values: payment_error, image_upload_error, booking_error, network_error, app_crash, loading_error
- After calling report_issue, reassure the customer: "I've logged this issue and our tech team has been notified. They'll look into it right away."
- If the customer describes symptoms that sound like a bug (e.g. "the page is blank", "I keep getting an error", "my photos won't send", "payment keeps failing"), treat it as a technical error and report it`;

async function handleMessage(session, userMessage, imageDataUrl) {
  // Build user message content — supports text-only or text+image (vision)
  if (imageDataUrl) {
    const content = [
      { type: 'image_url', image_url: { url: imageDataUrl, detail: 'auto' } },
      { type: 'text', text: userMessage },
    ];
    session.messages.push({ role: 'user', content });
  } else {
    session.messages.push({ role: 'user', content: userMessage });
  }

  // Keep context window manageable
  if (session.messages.length > 20) {
    session.messages = session.messages.slice(-16);
  }

  try {
    const response = await openai.chat.completions.create({
      model: 'gpt-4o-mini',
      temperature: 0.4,
      max_tokens: 500,
      messages: [
        { role: 'system', content: SYSTEM_PROMPT },
        ...session.messages,
      ],
      tools: waTools,
      tool_choice: 'auto',
    });

    let choice = response.choices[0];
    let assistantMessage = choice.message;

    // Handle tool calls (support multiple rounds)
    let toolRounds = 0;
    while (assistantMessage.tool_calls && assistantMessage.tool_calls.length > 0 && toolRounds < 3) {
      toolRounds++;
      session.messages.push(assistantMessage);

      for (const tc of assistantMessage.tool_calls) {
        let toolArgs = {};
        try { toolArgs = JSON.parse(tc.function.arguments); } catch (_) {}
        console.log(`[tool] ${tc.function.name}(${JSON.stringify(toolArgs).substring(0, 100)})`);

        let result;
        try {
          result = await executeWaTool(tc.function.name, toolArgs, session);
        } catch (toolErr) {
          console.error(`[tool] ${tc.function.name} THREW:`, toolErr.message, toolErr.stack);
          result = { error: `Tool ${tc.function.name} failed: ${toolErr.message}` };
        }
        session.messages.push({
          role: 'tool',
          tool_call_id: tc.id,
          content: JSON.stringify(result),
        });
      }

      // Get follow-up response
      const followUp = await openai.chat.completions.create({
        model: 'gpt-4o-mini',
        temperature: 0.4,
        max_tokens: 500,
        messages: [
          { role: 'system', content: SYSTEM_PROMPT },
          ...session.messages,
        ],
        tools: waTools,
        tool_choice: 'auto',
      });
      assistantMessage = followUp.choices[0].message;
    }

    const reply = assistantMessage.content || "I'm sorry, I couldn't process that. Please try again.";
    session.messages.push({ role: 'assistant', content: reply });

    // Persist session to Firestore (fire-and-forget)
    const firestore = db();
    if (firestore) {
      firestore.collection('wa_sessions').doc(session.phone).set({
        phone: session.phone,
        linkedUserId: session.linkedUserId || null,
        messages: session.messages.slice(-10).map(m => {
          // Truncate base64 image data to prevent exceeding Firestore 1MB doc limit
          if (typeof m.content === 'string' && m.content.length > 50000) {
            return { ...m, content: m.content.substring(0, 500) + '...[truncated]' };
          }
          if (Array.isArray(m.content)) {
            return { ...m, content: m.content.map(c => c.type === 'image_url' ? { type: 'text', text: '[image sent]' } : c) };
          }
          return m;
        }),
        photoUrls: session.photoUrls || [],
        lastBookingId: session.lastBookingId || null,
        lastBookingCost: session.lastBookingCost || null,
        lastRfqId: session.lastRfqId || null,
        pendingRatingBookingId: session.pendingRatingBookingId || null,
        sharedAddress: session.sharedAddress || null,
        sharedLatitude: session.sharedLatitude || null,
        sharedLongitude: session.sharedLongitude || null,
        promoCode: session.promoCode || null,
        promoDiscount: session.promoDiscount || 0,
        promoDiscountType: session.promoDiscountType || null,
        promoId: session.promoId || null,
        lastActivity: admin.firestore.FieldValue.serverTimestamp(),
      }).catch(() => {});
    }

    return reply;
  } catch (err) {
    console.error('[handleMessage] Error:', err.message);
    return "I'm having trouble right now. Please try again in a moment, or send 'Hi' to restart our conversation.";
  }
}

// ─── Rate limiting (per-phone, in-memory) ───

const _rateLimits = new Map();
const RATE_LIMIT_WINDOW_MS = 60 * 1000; // 1 minute
const RATE_LIMIT_MAX = 12;              // max 12 messages per minute per phone

function isRateLimited(phone) {
  const now = Date.now();
  const entry = _rateLimits.get(phone);
  if (!entry || now > entry.resetAt) {
    _rateLimits.set(phone, { count: 1, resetAt: now + RATE_LIMIT_WINDOW_MS });
    return false;
  }
  entry.count++;
  if (entry.count > RATE_LIMIT_MAX) return true;
  return false;
}

// Periodic cleanup of stale rate-limit entries (every 5 min)
setInterval(() => {
  const now = Date.now();
  for (const [phone, entry] of _rateLimits) {
    if (now > entry.resetAt) _rateLimits.delete(phone);
  }
}, 5 * 60 * 1000);

// ─── Webhook routes ───

// Meta verification handshake
app.get('/webhook', (req, res) => {
  const mode      = req.query['hub.mode'];
  const token     = req.query['hub.verify_token'];
  const challenge = req.query['hub.challenge'];

  if (mode === 'subscribe' && token === process.env.WHATSAPP_VERIFY_TOKEN) {
    console.log('[webhook] Verified');
    return res.status(200).send(challenge);
  }
  res.status(403).send('Forbidden');
});

// Incoming messages
app.post('/webhook', async (req, res) => {
  // Verify Meta webhook signature (X-Hub-Signature-256)
  const appSecret = process.env.WHATSAPP_APP_SECRET || process.env.META_APP_SECRET || '';
  if (appSecret) {
    const signature = req.headers['x-hub-signature-256'] || '';
    const rawBody = req.rawBody || Buffer.from(JSON.stringify(req.body));
    const expected = 'sha256=' + require('crypto').createHmac('sha256', appSecret).update(rawBody).digest('hex');
    if (signature !== expected) {
      console.warn('[webhook] Invalid signature — rejecting');
      return res.sendStatus(403);
    }
  } else {
    console.warn('[webhook] No WHATSAPP_APP_SECRET configured — signature verification disabled');
  }

  // Always respond 200 quickly to Meta
  res.sendStatus(200);

  try {
    const entry = req.body?.entry?.[0];
    const changes = entry?.changes?.[0];
    const value = changes?.value;

    if (!value?.messages) return; // status update, not a message

    for (const msg of value.messages) {
      const from = msg.from; // phone number
      let userText = '';

      try {

      // Rate-limit check (prevents abuse / runaway OpenAI costs)
      if (isRateLimited(from)) {
        console.warn(`[webhook] Rate limited: ${from}`);
        continue;
      }

      const session = getSession(from);

      // Restore session from Firestore if this is a fresh in-memory session
      await restoreSessionFromFirestore(session);

      // Auto-link: if no linked account yet, try to find existing app user by phone number
      if (!session.linkedUserId) {
        try {
          const appUser = await findUserByPhone(session.phone);
          if (appUser) {
            session.linkedUserId = appUser.id;
            console.log(`[auto-link] Matched WhatsApp ${session.phone} to app user ${appUser.id} (${appUser.name || 'unknown'})`);
          }
        } catch (e) {
          console.warn('[auto-link] Phone lookup failed:', e.message);
        }
      }

      switch (msg.type) {
        case 'text':
          userText = msg.text.body;
          break;
        case 'interactive':
          // Button replies and list replies
          if (msg.interactive?.button_reply) {
            userText = msg.interactive.button_reply.title;
          } else if (msg.interactive?.list_reply) {
            userText = msg.interactive.list_reply.title;
            if (msg.interactive.list_reply.description) {
              userText += ' — ' + msg.interactive.list_reply.description;
            }
          }
          break;
        case 'image': {
          const imageMedia = await downloadWhatsAppMedia(msg.image?.id);
          const caption = msg.image?.caption || '';
          if (imageMedia) {
            // Upload photo to Firebase Storage so artisans can see it
            const storageUrl = await uploadImageToStorage(imageMedia.buffer, imageMedia.mimeType);
            if (storageUrl) {
              session.photoUrls.push(storageUrl);
              console.log(`[msg] ${from}: [IMAGE uploaded to Storage, ${session.photoUrls.length} total]`);
            }
            userText = caption
              ? `[Customer sent a photo with caption: "${caption}"] Analyse this image of a maintenance/repair issue. Identify the problem and suggest the service category. Then call lookup_pricing to get the price, present it to the customer, and WAIT for their confirmation before creating any booking.`
              : '[Customer sent a photo of a maintenance issue] Analyse this image. Identify what repair or maintenance is needed and suggest the service category (plumbing, electrical, painting, etc.). Then call lookup_pricing to get the price, present it to the customer, and WAIT for their confirmation before creating any booking. Do NOT create a booking until the customer confirms the price.';
            console.log(`[msg] ${from}: [IMAGE received, ${(imageMedia.base64.length / 1024).toFixed(0)}KB]`);
            const reply = await handleMessage(session, userText, imageMedia.dataUrl);
            const chunks = reply.match(/.{1,4000}/gs) || [reply];
            for (const chunk of chunks) {
              await sendWhatsAppMessage(from, chunk);
            }
            continue; // Skip normal handleMessage below — already handled
          } else {
            await sendWhatsAppMessage(
              from,
              'I could not download your photo. Please send the photo again, or describe the issue in text.'
            );
            continue;
          }
          break;
        }
        case 'document':
          userText = '[Customer sent a document: ' + (msg.document?.filename || 'unknown') + ']';
          break;
        case 'audio': {
          // Transcribe voice note via Whisper
          const audioTranscript = await transcribeAudio(msg.audio?.id);
          if (audioTranscript && audioTranscript.trim()) {
            userText = audioTranscript.trim();
            console.log(`[msg] ${from}: [VOICE NOTE transcribed: "${userText.substring(0, 80)}"]`);
          } else {
            await sendWhatsAppMessage(
              from,
              'I could not transcribe that voice note. Please try sending it again, or type your request in text.'
            );
            continue;
          }
          break;
        }
        case 'location':
          userText = `[Customer shared location: ${msg.location.latitude}, ${msg.location.longitude}]`;
          if (msg.location.address) userText += ` Address: ${msg.location.address}`;
          // Persist GPS coordinates on the session so create_booking can store them
          session.sharedLatitude = msg.location.latitude;
          session.sharedLongitude = msg.location.longitude;
          if (msg.location.address) session.sharedAddress = msg.location.address;
          console.log(`[location] ${from}: saved lat=${session.sharedLatitude} lng=${session.sharedLongitude} addr=${session.sharedAddress || 'none'}`);
          break;
        case 'sticker':
          continue; // Ignore stickers
        default:
          userText = `[Customer sent a ${msg.type} message — ask them to describe their issue in text]`;
      }

      if (!userText.trim()) continue;

      // Truncate excessively long messages to prevent OpenAI token abuse
      if (userText.length > 10000) {
        userText = userText.substring(0, 10000) + '...[message truncated]';
      }

      console.log(`[msg] ${from}: ${userText.substring(0, 100)}`);

      const reply = await handleMessage(session, userText);
      if (!reply || !reply.trim()) {
        await sendWhatsAppMessage(
          from,
          'I could not generate a reply for that yet. Please rephrase your request, or send Hi to restart.'
        );
        continue;
      }

      // Split long replies into chunks (WhatsApp has ~4096 char limit)
      const chunks = reply.match(/.{1,4000}/gs) || [reply];
      for (const chunk of chunks) {
        await sendWhatsAppMessage(from, chunk);
      }
      } catch (msgErr) {
        console.error(`[webhook] Message processing failed for ${from}:`, msgErr);
        await notifyWebhookProcessingFailure(from, msgErr, userText);
      }
    }
  } catch (err) {
    console.error('[webhook] Error processing message:', err);
  }
});

// Health check
app.get('/health', (req, res) => res.json({ status: 'ok', service: 'square15-whatsapp-bot', version: 'cc31c07-apr13-v2' }));

// ─── Diagnostic: test Firebase read/write ───
app.get('/debug/firebase-test', async (req, res) => {
  const results = { firebase_init: false, project_id: null, read_ok: false, write_ok: false, delete_ok: false, sp_count: 0, tm_count: 0, wa_bookings: 0, errors: [] };
  try {
    const firestore = db();
    if (!firestore) { results.errors.push('db() returned null — Firebase not initialized'); return res.json(results); }
    results.firebase_init = true;

    // Report which Firebase project we're connected to
    try {
      const app = admin.app();
      results.project_id = app.options.credential?.projectId || app.options.projectId || (app.options.credential?.certificate?.projectId) || 'unknown';
      // Try to get from Firestore settings
      if (results.project_id === 'unknown') {
        results.project_id = firestore._settings?.projectId || firestore.projectId || 'unknown';
      }
    } catch (e) { results.errors.push('project_id lookup: ' + e.message); }

    // Test read
    try {
      const tmCount = await firestore.collection('tasksManagement').select().limit(1).get();
      results.read_ok = true;
      const tmAll = await firestore.collection('tasksManagement').select().get();
      results.tm_count = tmAll.docs.length;
    } catch (e) { results.errors.push('read failed: ' + e.message); }

    // Count WA bookings
    try {
      const allTm = await firestore.collection('tasksManagement').get();
      const waBookings = allTm.docs.filter(d => d.id.startsWith('WA-') || (d.data().source === 'whatsapp'));
      results.wa_bookings = waBookings.length;
      // Show latest 3 WA bookings
      results.wa_latest = waBookings.slice(-3).map(d => {
        const dd = d.data();
        return { id: d.id, order_no: dd.order_no, status: dd.status, cost: dd.cost, sp_id: dd.service_provider_id, created_at: dd.created_at, source: dd.source, category: dd.category_name };
      });
    } catch (e) { results.errors.push('wa count failed: ' + e.message); }

    // Test write + delete
    const testDocId = `_diag_test_${Date.now()}`;
    try {
      await firestore.collection('tasksManagement').doc(testDocId).set({ _test: true, created_at: new Date().toISOString() });
      results.write_ok = true;
    } catch (e) { results.errors.push('write failed: ' + e.message); }
    try {
      await firestore.collection('tasksManagement').doc(testDocId).delete();
      results.delete_ok = true;
    } catch (e) { results.errors.push('delete failed: ' + e.message); }

    // Service providers
    try {
      const spSnap = await firestore.collection('serviceProvider').get();
      results.sp_count = spSnap.docs.length;
      results.sp_sample_fields = spSnap.docs.length > 0 ? Object.keys(spSnap.docs[0].data()) : [];
      results.sp_first = spSnap.docs.length > 0 ? { id: spSnap.docs[0].id, name: spSnap.docs[0].data().name, active: spSnap.docs[0].data().active, status: spSnap.docs[0].data().status } : null;
    } catch (e) { results.errors.push('sp read failed: ' + e.message); }
  } catch (e) { results.errors.push('outer error: ' + e.message); }
  res.json(results);
});

// ─── Artisan App → WhatsApp: Notify client when artisan accepts/rejects ───
app.post('/api/artisan-accepted', async (req, res) => {
  try {
    const { bookingId, artisanName } = req.body || {};
    if (!bookingId) return res.status(400).json({ error: 'bookingId required' });

    const firestore = db();
    if (!firestore) return res.status(503).json({ error: 'Database unavailable' });

    // Look up booking to find customer phone + details
    // bookingId may be the bridge ID (WA-XXX_artisanId) or the main booking ID (WA-XXX)
    const mainBookingId = bookingId.includes('_') ? bookingId.split('_')[0] : bookingId;

    let customerPhone = '';
    let bookingCost = '';
    let bookingDescription = '';
    let orderNo = '';

    // Try futureBookings first (has the canonical data)
    const fbDoc = await firestore.collection('futureBookings').doc(mainBookingId).get();
    if (fbDoc.exists) {
      const d = fbDoc.data();
      customerPhone = d.user_phone || d.customerPhone || d.contact || '';
      bookingCost = d.cost || '';
      bookingDescription = d.description || d.subcategory || d.category_name || '';
      orderNo = d.order_no || '';
    }

    // Fallback to tasksManagement
    if (!customerPhone) {
      const tmDoc = await firestore.collection('tasksManagement').doc(mainBookingId).get();
      if (tmDoc.exists) {
        const d = tmDoc.data();
        customerPhone = d.customerPhone || d.contact || '';
        bookingCost = d.cost || '';
        bookingDescription = d.description || d.subcategory || d.category_name || '';
        orderNo = d.order_no || '';
      }
    }

    if (!customerPhone) {
      return res.status(404).json({ error: 'No customer phone found for booking' });
    }

    // Update the main tasksManagement doc to mark as accepted (so payment check passes)
    try {
      await firestore.collection('tasksManagement').doc(mainBookingId).set({
        accept: '1',
        artisan_confirmed: 'yes',
        status: 'pending_payment',
        service_provider_name: artisanName || '',
        updated_at: new Date().toISOString(),
      }, { merge: true });
    } catch (e) { console.warn('[api/artisan-accepted] main doc update failed:', e.message); }

    // Also update futureBookings to ensure consistency
    try {
      await firestore.collection('futureBookings').doc(mainBookingId).set({
        artisan_confirmed: 'yes',
        status: 'pending_payment',
        updated_at: new Date().toISOString(),
      }, { merge: true });
    } catch (e) { console.warn('[api/artisan-accepted] futureBookings update failed:', e.message); }

    // Normalise phone to international format (27...)
    let to = customerPhone.replace(/[^0-9]/g, '');
    if (to.startsWith('0')) to = '27' + to.slice(1);

    // Send artisan acceptance message (no payment link yet — customer chooses full/deposit first)
    const name = artisanName || 'Your artisan';
    const costStr = bookingCost ? `R${parseFloat(bookingCost).toFixed(2)}` : '';
    const descStr = bookingDescription || 'your maintenance request';

    let msg = `✅ *Great news!* ${name} has accepted your booking`;
    if (orderNo) msg += ` (#${orderNo})`;
    msg += `!\n\n`;
    msg += `📋 *Job:* ${descStr}\n`;
    if (costStr) msg += `💰 *Cost:* ${costStr}\n`;
    msg += `\n${name} will contact you to confirm the schedule and arrive at your location.\n`;

    // Payment section — ask customer to choose full or deposit
    const depositAmt = bookingCost ? (Math.round(parseFloat(bookingCost) * 0.35 * 100) / 100).toFixed(2) : '0.00';
    const balanceAmt = bookingCost ? (parseFloat(bookingCost) - parseFloat(depositAmt)).toFixed(2) : '0.00';
    msg += `\n💳 *Ready to pay? Choose an option:*\n`;
    msg += `1️⃣ *Full amount:* ${costStr}\n`;
    msg += `2️⃣ *Deposit (35%):* R${depositAmt} now (R${balanceAmt} due after job)\n`;
    msg += `\nReply *"pay full"* or *"pay deposit"* to get your secure payment link.\n`;
    msg += `\n🔒 Your payment is held in escrow until you confirm satisfaction with the completed work.\n`;
    msg += `\nReply anytime if you have questions! 😊`;

    await sendWhatsAppMessage(to, msg);
    console.log(`[api/artisan-accepted] Sent acceptance notification to ${to} for booking ${mainBookingId}`);

    res.json({ success: true, to, bookingId: mainBookingId });
  } catch (err) {
    console.error('[api/artisan-accepted] error:', err.message);
    res.status(500).json({ error: err.message });
  }
});

// ─── Artisan App → WhatsApp: Notify client of booking status changes ───
app.post('/api/booking-status-update', async (req, res) => {
  try {
    const { bookingId, status, message: customMsg } = req.body || {};
    if (!bookingId || !status) return res.status(400).json({ error: 'bookingId and status required' });

    const firestore = db();
    if (!firestore) return res.status(503).json({ error: 'Database unavailable' });

    const mainBookingId = bookingId.includes('_') ? bookingId.split('_')[0] : bookingId;

    let customerPhone = '';
    const fbDoc = await firestore.collection('futureBookings').doc(mainBookingId).get();
    if (fbDoc.exists) {
      const d = fbDoc.data();
      customerPhone = d.user_phone || d.customerPhone || d.contact || d.client_phone || d.phone || '';
    }
    if (!customerPhone) {
      const tmDoc = await firestore.collection('tasksManagement').doc(mainBookingId).get();
      if (tmDoc.exists) {
        const d = tmDoc.data();
        customerPhone = d.customerPhone || d.contact || d.user_phone || d.client_phone || d.phone || '';
      }
    }
    if (!customerPhone) return res.status(404).json({ error: 'No customer phone found' });

    let to = customerPhone.replace(/[^0-9]/g, '');
    if (to.startsWith('0')) to = '27' + to.slice(1);

    // Default status messages
    const statusMessages = {
      'in_progress': '🔧 Your artisan has started working on your job. We\'ll update you when they\'re done!',
      'progress': '🔧 Your artisan has started working on your job. We\'ll update you when they\'re done!',
      'completed': '✅ Your job has been completed! Please review the work and confirm satisfaction in the app.',
      'closed': '✅ Your job has been completed and closed. Thank you for using Square 15!',
      'cancelled': '❌ Your booking has been cancelled. If you need help, reply here.',
      'payment_received': '💳 Payment received! Thank you. Your booking is confirmed.',
    };

    const msg = customMsg || statusMessages[status] || `📋 Your booking status has been updated to: *${status}*`;
    await sendWhatsAppMessage(to, msg);
    console.log(`[api/booking-status-update] Status "${status}" sent to ${to} for ${mainBookingId}`);

    res.json({ success: true, to, status });
  } catch (err) {
    console.error('[api/booking-status-update] error:', err.message);
    res.status(500).json({ error: err.message });
  }
});

// ─── App → WhatsApp: Notify client that payment was received ───
app.post('/api/payment-confirmed', async (req, res) => {
  try {
    const { bookingId, paymentType, amount } = req.body || {};
    if (!bookingId) return res.status(400).json({ error: 'bookingId required' });

    const firestore = db();
    if (!firestore) return res.status(503).json({ error: 'Database unavailable' });

    const mainBookingId = bookingId.includes('_') ? bookingId.split('_')[0] : bookingId;

    // Look up customer phone + booking details
    let customerPhone = '', orderNo = '', cost = 0, balanceAmount = 0;
    const fbDoc = await firestore.collection('futureBookings').doc(mainBookingId).get();
    if (fbDoc.exists) {
      const d = fbDoc.data();
      customerPhone = d.user_phone || d.customerPhone || d.contact || d.client_phone || d.phone || '';
      orderNo = d.order_no || d.orderNumber || mainBookingId;
      cost = parseFloat(d.cost || d.total_cost || d.price || d.deposit_amount || '0') || 0;
      balanceAmount = parseFloat(d.balance_amount || '0') || 0;
    }
    if (!customerPhone) {
      const tmDoc = await firestore.collection('tasksManagement').doc(mainBookingId).get();
      if (tmDoc.exists) {
        const d = tmDoc.data();
        customerPhone = d.customerPhone || d.contact || d.user_phone || d.client_phone || d.phone || '';
        if (!orderNo) orderNo = d.order_no || d.orderNumber || mainBookingId;
        if (!cost) cost = parseFloat(d.cost || d.total_cost || d.price || d.deposit_amount || '0') || 0;
        if (!balanceAmount) balanceAmount = parseFloat(d.balance_amount || '0') || 0;
      }
    }
    if (!customerPhone) return res.status(404).json({ error: 'No customer phone found' });

    let to = customerPhone.replace(/[^0-9]/g, '');
    if (to.startsWith('0')) to = '27' + to.slice(1);

    const paidAmt = parseFloat(amount || cost || '0');
    const isDeposit = (paymentType || '').toLowerCase() === 'deposit';

    let msg = `✅ *Payment Received!* R${paidAmt.toFixed(2)} for booking ${orderNo}.\n\n`;
    if (isDeposit) {
      const balance = balanceAmount > 0 ? balanceAmount : (cost * 0.65);
      msg += `💰 Deposit secured. Remaining balance: R${balance.toFixed(2)} (due after job completion).\n\n`;
    }
    msg += `🔧 Your artisan will be in touch shortly. Thank you for using Square 15!`;

    await sendWhatsAppMessage(to, msg);
    console.log(`[api/payment-confirmed] Payment confirmation sent to ${to} for ${mainBookingId} (${paymentType || 'full'})`);

    res.json({ success: true, to, bookingId: mainBookingId });
  } catch (err) {
    console.error('[api/payment-confirmed] error:', err.message);
    res.status(500).json({ error: err.message });
  }
});

// ─── Admin → WhatsApp: Send RFQ response back to client ───
app.post('/api/send-rfq-response', async (req, res) => {
  try {
    const { phone, rfqNo, message } = req.body || {};
    if (!phone || !message) {
      return res.status(400).json({ error: 'phone and message are required' });
    }
    // Normalise to international format (27…)
    let to = phone.replace(/[^0-9]/g, '');
    if (to.startsWith('0')) to = '27' + to.slice(1);
    await sendWhatsAppMessage(to, message);
    res.json({ success: true, to, rfqNo });
  } catch (err) {
    console.error('[send-rfq-response] error:', err.message);
    res.status(500).json({ error: err.message });
  }
});

// ─── App → WhatsApp: Notify client of artisan job lifecycle events ───
app.post('/api/job-status-update', async (req, res) => {
  try {
    const { bookingId, status, artisanName, imageUrl } = req.body || {};
    if (!bookingId || !status) return res.status(400).json({ error: 'bookingId and status required' });

    const firestore = db();
    if (!firestore) return res.status(503).json({ error: 'Database unavailable' });

    const mainBookingId = bookingId.includes('_') ? bookingId.split('_')[0] : bookingId;

    // Resolve customer phone
    let customerPhone = '', orderNo = '';
    const fbDoc = await firestore.collection('futureBookings').doc(mainBookingId).get();
    if (fbDoc.exists) {
      const d = fbDoc.data();
      customerPhone = d.user_phone || d.customerPhone || d.contact || d.client_phone || d.phone || '';
      orderNo = d.order_no || d.orderNumber || mainBookingId;
    }
    if (!customerPhone) {
      const tmDoc = await firestore.collection('tasksManagement').doc(mainBookingId).get();
      if (tmDoc.exists) {
        const d = tmDoc.data();
        customerPhone = d.customerPhone || d.contact || d.user_phone || d.client_phone || d.phone || '';
        if (!orderNo) orderNo = d.order_no || d.orderNumber || mainBookingId;
      }
    }
    if (!customerPhone) return res.status(404).json({ error: 'No customer phone found' });

    let to = customerPhone.replace(/[^0-9]/g, '');
    if (to.startsWith('0')) to = '27' + to.slice(1);

    const name = artisanName || 'Your artisan';
    const ref = orderNo || mainBookingId;

    const statusMessages = {
      'progress':         `🚗 *${name} is on the way!*\n\nYour artisan is heading to your location for booking #${ref}. You can track their location in the Square 15 app.\n\nPlease ensure access to the site is available. 🏠`,
      'buying_material':  `🛒 *${name} is buying materials!*\n\nYour artisan is purchasing the materials needed for booking #${ref}. They will head to your site once ready.\n\nWe'll keep you updated on progress. 🔧`,
      'before_photo':     `📸 *${name} has arrived!*\n\nYour artisan has arrived at the site and taken a before-work photo for booking #${ref}. Work is about to begin.\n\nWe'll keep you updated on progress. 🔧`,
      'after_photo':      `📸 *Work completed!*\n\nYour artisan has finished the job and uploaded an after-work photo for booking #${ref}.\n\nPlease review the work in the Square 15 app. ✅`,
      'completed':        `✅ *Job completed!*\n\nThe work for booking #${ref} has been completed by ${name}.\n\n🙏 *Thank you for choosing Square 15!* We truly appreciate your trust in our service.\n\nPlease review the work and rate your artisan. ⭐ Your feedback helps us maintain high standards.`,
      'balance_due':      `💰 *Balance payment due!*\n\nThe work for booking #${ref} has been completed. Please pay the remaining balance to finalise your booking.\n\nReply "pay balance" to get a secure payment link. 💳`,
      'additional_work':  `🔧 *Additional work found!*\n\nYour artisan noticed an additional issue while working on booking #${ref}.\n\nYou qualify for a *15% discount* on the follow-up job. Check the Square 15 app or reply here for details.`,
    };

    const msg = statusMessages[status] || `📋 Your booking #${ref} status has been updated to: *${status}*`;
    await sendWhatsAppMessage(to, msg);

    // Send the before/after photo as an image message if provided
    if (imageUrl && (status === 'before_photo' || status === 'after_photo')) {
      const caption = status === 'before_photo'
        ? `📸 Before-work photo for booking #${ref}`
        : `📸 After-work photo for booking #${ref}`;
      await sendWhatsAppImage(to, imageUrl, caption);
    }

    // ── Inject status into AI session so it knows about job progress ──
    try {
      const phone = to.startsWith('27') ? to : to;
      const session = sessions.get(phone);
      if (session) {
        session.messages.push({
          role: 'system',
          content: `[SYSTEM STATUS UPDATE] Booking #${ref} (${mainBookingId}): status changed to "${status}". ${imageUrl ? `Photo uploaded: ${imageUrl}` : ''}`,
        });
        // Track pending rating so bot can re-prompt after restart
        if (status === 'completed') {
          session.pendingRatingBookingId = mainBookingId;
        }
      }
    } catch (e) { console.warn('[job-status-update] session inject failed:', e.message); }

    // ── Auto-send balance payment prompt after job completion for deposit bookings ──
    if (status === 'completed' || status === 'after_photo') {
      try {
        let bookDoc = await firestore.collection('tasksManagement').doc(mainBookingId).get();
        if (!bookDoc.exists) bookDoc = await firestore.collection('futureBookings').doc(mainBookingId).get();
        if (bookDoc.exists) {
          const bd = bookDoc.data();
          const isDepositPaid = bd.payment_status === 'deposit_paid';
          const balanceDone = bd.balance_paid === true;
          const totalCost = parseFloat(bd.cost || bd.total_cost || '0');
          const depositAmt = parseFloat(bd.deposit_amount || '0') || Math.round(totalCost * 0.35 * 100) / 100;
          const balanceAmt = parseFloat(bd.balance_remaining || bd.balance_amount || '0') || Math.round((totalCost - depositAmt) * 100) / 100;

          if (isDepositPaid && !balanceDone && balanceAmt > 0 && status === 'completed') {
            const balanceMsg = `💰 *Balance payment due: R${balanceAmt.toFixed(2)}*\n\nYour artisan has completed the work for booking #${ref}. You still owe a balance of R${balanceAmt.toFixed(2)} (total R${totalCost.toFixed(2)} minus deposit of R${depositAmt.toFixed(2)}).\n\nWould you like to pay the balance now? Reply "pay balance" to get a payment link.`;
            await sendWhatsAppMessage(to, balanceMsg);
          }
        }
      } catch (e) { console.warn('[job-status-update] balance check failed:', e.message); }
    }

    console.log(`[api/job-status-update] Status "${status}" sent to ${to} for ${mainBookingId}${imageUrl ? ' (with image)' : ''}`);

    res.json({ success: true, to, status });
  } catch (err) {
    console.error('[api/job-status-update] error:', err.message);
    res.status(500).json({ error: err.message });
  }
});

// Privacy policy (required for Meta app Live mode)
app.get('/privacy', (req, res) => {
  res.type('html').send(`<!DOCTYPE html><html><head><title>Privacy Policy – Square 15 Facility Solutions</title></head><body style="font-family:sans-serif;max-width:700px;margin:40px auto;padding:0 20px">
<h1>Privacy Policy</h1><p><strong>Square 15 Facility Solutions</strong></p><p>Last updated: 2026-03-26</p>
<h2>Information We Collect</h2><p>When you interact with our WhatsApp assistant, we collect your phone number and message content solely to provide maintenance booking, RFQ, and support services.</p>
<h2>How We Use Your Information</h2><p>Your data is used to: process service bookings, respond to enquiries, send booking confirmations and updates, and improve our services.</p>
<h2>Data Storage</h2><p>Your data is stored securely in Google Firebase and is not sold or shared with third parties except as required to fulfil your service requests.</p>
<h2>Data Retention</h2><p>We retain your data for the duration of your service relationship. You may request deletion at any time.</p>
<h2>Contact</h2><p>For privacy enquiries, contact us at: support@square15.co.za</p>
</body></html>`);
});

// Terms of service
app.get('/terms', (req, res) => {
  res.type('html').send(`<!DOCTYPE html><html><head><title>Terms of Service – Square 15 Facility Solutions</title></head><body style="font-family:sans-serif;max-width:700px;margin:40px auto;padding:0 20px">
<h1>Terms of Service</h1><p><strong>Square 15 Facility Solutions</strong></p><p>Last updated: 2026-03-26</p>
<h2>Service</h2><p>Square 15 provides facility maintenance services including plumbing, electrical, cleaning, and general repairs in South Africa.</p>
<h2>WhatsApp Bot</h2><p>Our WhatsApp assistant ("Lizzy") helps you book services, request quotes, check booking status, and manage your account. Service availability depends on artisan capacity in your area.</p>
<h2>Liability</h2><p>We strive to deliver quality service but are not liable for delays beyond our control. All bookings are subject to artisan availability.</p>
<h2>Contact</h2><p>support@square15.co.za</p>
</body></html>`);
});

// ─── Start ───

app.listen(PORT, () => {
  console.log(`[whatsapp-bot] listening on :${PORT}`);
  initFirebase();

  // One-time cleanup: remove stale service_prices from pricingGuidance documents.
  // Keep labor_cost_per_hour, material_multiplier, outsourced_labor_rate (used by RFQ).
  // Fixed pricing now comes solely from the tasks collection (admin-managed categories).
  try {
    const firestore = db();
    if (firestore) {
      const FieldValue = admin.firestore.FieldValue;
      firestore.collection('pricingGuidance').get().then(snap => {
        if (snap.empty) { console.log('[cleanup] pricingGuidance empty, nothing to clean'); return; }
        const batch = firestore.batch();
        let cleaned = 0;
        snap.docs.forEach(doc => {
          const d = doc.data();
          if (d.service_prices || d.servicePrices) {
            batch.update(doc.ref, {
              service_prices: FieldValue.delete(),
              servicePrices: FieldValue.delete(),
            });
            cleaned++;
          }
        });
        if (cleaned === 0) { console.log('[cleanup] pricingGuidance service_prices already removed'); return; }
        return batch.commit().then(() => {
          console.log(`[cleanup] Removed service_prices from ${cleaned} pricingGuidance docs (labor rates preserved for RFQ)`);
        });
      }).catch(e => console.warn('[cleanup] pricingGuidance cleanup failed:', e.message));
    }
  } catch (e) { console.warn('[cleanup] error:', e.message); }
});
