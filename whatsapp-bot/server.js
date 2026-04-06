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
app.use(express.json());

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
    admin.initializeApp({ credential: admin.credential.cert(sa) });
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
  });
  if (!res.ok) console.error('[wa] send failed:', await res.text());
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
    });
    if (!metaRes.ok) { console.error('[wa-media] metadata fetch failed:', metaRes.status); return null; }
    const meta = await metaRes.json();
    const mediaUrl = meta.url;
    if (!mediaUrl) return null;

    // Step 2: Download the media binary
    const dlRes = await fetch(mediaUrl, {
      headers: { 'Authorization': `Bearer ${token}` },
    });
    if (!dlRes.ok) { console.error('[wa-media] download failed:', dlRes.status); return null; }
    const buffer = Buffer.from(await dlRes.arrayBuffer());
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
      lastActivity: Date.now(),
    };
    sessions.set(phone, s);
  }
  s.lastActivity = Date.now();
  return s;
}

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
    console.log(`[session] Restored ${session.phone} from Firestore (${session.messages.length} msgs)`);
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

  for (const v of variants) {
    for (const field of ['contact', 'phone', 'mobile', 'phoneNumber', 'phone_number']) {
      const snap = await firestore.collection('users').where(field, '==', v).limit(1).get();
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
          address:      { type: 'string', description: 'Service address' },
          urgency:      { type: 'string', enum: ['normal', 'urgent', 'emergency'] },
          customerName: { type: 'string', description: 'Customer full name' },
          scheduledDate:{ type: 'string', description: 'Preferred date (YYYY-MM-DD) if customer specifies' },
          scheduledTime:{ type: 'string', description: 'Preferred time (HH:MM) if customer specifies' },
        },
        required: ['category', 'description', 'customerName'],
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
      description: 'MUST be called BEFORE create_booking. Looks up fixed pricing for a service and real-time material prices from Builders.co.za. Returns the exact fixed price if available, or suggests RFQ if not.',
      parameters: {
        type: 'object',
        properties: {
          category:    { type: 'string', description: 'Service category (e.g. plumbing, electrical, painting)' },
          subcategory: { type: 'string', description: 'Specific service needed (e.g. toilet unblocking, leak repair, light installation)' },
          material:    { type: 'string', description: 'Specific material or product to look up on Builders.co.za (e.g. geyser 150L, 20mm copper pipe, circuit breaker)' },
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
      name: 'check_auto_discounts',
      description: 'Check if the customer qualifies for any automatic discounts (first-job discount, off-peak discount, loyalty points). Call this BEFORE creating a booking to inform the customer of available savings.',
      parameters: { type: 'object', properties: {}, required: [] },
    },
  },
  {
    type: 'function',
    function: {
      name: 'get_upsell_addons',
      description: 'Get recommended add-on services for a booking category. These are discounted extra services the customer might want to add. Call this after the customer picks a category and BEFORE creating the booking.',
      parameters: {
        type: 'object',
        properties: {
          categoryId: { type: 'string', description: 'The service category slug (e.g. plumbing, electrical, painting)' },
        },
        required: ['categoryId'],
      },
    },
  },
  {
    type: 'function',
    function: {
      name: 'request_payment_link',
      description: 'Generate a payment link for an unpaid booking so the customer can pay via card. Customer must choose deposit (35%) or full payment. Artisan must have accepted the job first.',
      parameters: {
        type: 'object',
        properties: {
          bookingId: { type: 'string', description: 'The booking ID to generate payment for' },
          payment_type: { type: 'string', enum: ['deposit', 'full'], description: 'Whether to pay the deposit (35%) or the full amount. Ask the customer to choose.' },
        },
        required: ['bookingId', 'payment_type'],
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
      description: 'Pay for a booking using wallet balance. Customer must choose deposit (35%) or full payment. Artisan must have accepted the job first.',
      parameters: {
        type: 'object',
        properties: {
          bookingId: { type: 'string', description: 'The booking ID to pay for (optional, uses last booking if not provided)' },
          payment_type: { type: 'string', enum: ['deposit', 'full'], description: 'Whether to pay the deposit (35%) or the full amount. Ask the customer to choose.' },
        },
        required: ['payment_type'],
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
      name: 'lookup_builders_product',
      description: 'Search Builders Warehouse (builders.co.za) for real products with live pricing. Use when a customer wants to see specific materials, compare brands, or choose items for their job. Returns product names, prices, and links.',
      parameters: {
        type: 'object',
        properties: {
          query: { type: 'string', description: 'Product search query (e.g. "150L geyser", "PVC pipe 110mm", "Kwikot geyser")' },
        },
        required: ['query'],
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

// ─── Fixed-price lookup helper (shared by generateAIQuote & submit_rfq) ───

async function lookupFixedPrice(category, description) {
  const firestore = db();
  if (!firestore) return null;
  try {
    const catSlug = (category || '').toLowerCase().replace(/\s+/g, '_');
    const searchQ = [category || '', description || ''].join(' ').toLowerCase().trim();

    const _matchScore = (a, b) => {
      const al = a.toLowerCase(), bl = b.toLowerCase();
      if (al === bl) return 1000;
      if (al.includes(bl) || bl.includes(al)) return 100;
      const aw = al.split(/\s+/).filter(w => w.length >= 3);
      const bw = bl.split(/\s+/).filter(w => w.length >= 3);
      let score = 0;
      for (const w of aw) { if (bl.includes(w)) score++; }
      for (const w of bw) { if (al.includes(w)) score++; }
      return score;
    };

    const taskSnap = await firestore.collection('tasks').limit(200).get();
    let bestScore = 0, matchedService = null, matchedPrice = null;
    for (const td of taskSnap.docs) {
      const d = td.data();
      const name = (d.name || d.title || d.task_name || '').toString();
      const cost = parseFloat(d.cost || d.price || d.amount || 0);
      if (name && cost > 0) {
        const score = _matchScore(name, searchQ);
        if (score > bestScore) {
          bestScore = score;
          matchedService = name;
          matchedPrice = cost;
        }
      }
    }
    if (matchedService && matchedPrice && bestScore >= 2) {
      console.log(`[fixed-price] Matched "${matchedService}" @ R${matchedPrice} (score ${bestScore}) for "${searchQ}"`);
      return { service: matchedService, price: matchedPrice, score: bestScore };
    }
    return null;
  } catch (e) {
    console.error('[fixed-price] lookup error:', e.message);
    return null;
  }
}

// ─── AI Quote Generation for RFQ (with Builders.co.za real-time pricing) ───

async function generateAIQuote(category, description, materialsResponsibility, additionalContext) {
  // Sanitize user-provided inputs before injecting into AI prompts
  category = sanitizeForPrompt(category, 100);
  description = sanitizeForPrompt(description, 1000);
  materialsResponsibility = sanitizeForPrompt(materialsResponsibility, 50);
  additionalContext = sanitizeForPrompt(additionalContext, 500);

  const firestore = db();

  // 0. Check tasks collection for a fixed price FIRST — if found, return it directly
  try {
    const fixedMatch = await lookupFixedPrice(category, description);
    if (fixedMatch) {
      console.log(`[ai-quote] Using fixed price R${fixedMatch.price} for "${fixedMatch.service}" instead of AI generation`);
      const r2 = (v) => Math.round(v * 100) / 100;
      return {
        laborHours: 0,
        laborCostPerHour: 0,
        laborCost: 0,
        complexity: 2,
        materialsBOM: [],
        materialsMultiplier: 1,
        materials_subtotal: 0,
        materials_with_markup: 0,
        materials_responsibility: materialsResponsibility || 'artisan',
        equipmentCost: 0,
        subtotal: r2(fixedMatch.price),
        contingency: 0,
        grand_total: r2(fixedMatch.price),
        scope_of_work: description || fixedMatch.service,
        estimated_duration: 'To be determined on-site',
        learning_factor: 1,
        pricing_sources: { fixed_price: 1, builders: 0, catalog: 0, ai_estimate: 0 },
        breakdown: [
          { description: `Fixed price: ${fixedMatch.service}`, cost: fixedMatch.price.toFixed(2) },
        ],
        disclaimer: 'This is a fixed price set by admin for this service.',
        generated_at: new Date().toISOString(),
        source: 'tasks_fixed_price',
        fixed_price_match: fixedMatch.service,
      };
    }
  } catch (e) {
    console.warn('[ai-quote] fixed price check failed, continuing with AI:', e.message);
  }

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
      let line = `${i + 1}. ${src} ${m.name} \u2014 ${m.qty} ${m.unit} @ R${m.unit_price.toFixed(2)} = R${m.line_base.toFixed(2)}`;
      if (m.builders_url) {
        line += `\n   \u{1F517} ${m.builders_url}`;
      }
      lines.push(line);
    });
    lines.push('');
    lines.push('\u2705 = Builders.co.za price | \u{1F4D7} = Catalog | \u{1F4CA} = Estimated');
    lines.push('');
    lines.push('\u{1F6D2} _Want a different brand or product? Tell me what you prefer and I\'ll look it up on Builders for you!_');
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

      // Look up pricing estimate from pricingGuidance service_prices map and tasks collection
      let estimatedCost = '0';
      let pricingSource = 'none';
      try {
        const catSlug = (args.category || '').toLowerCase().replace(/\s+/g, '_');
        const subQuery = (args.subcategory || args.description || '').toLowerCase();

        // 1) Check pricingGuidance doc's service_prices map
        const guidanceDoc = await firestore.collection('pricingGuidance').doc(catSlug).get();
        if (guidanceDoc.exists) {
          const gd = guidanceDoc.data();
          const servicePrices = gd.service_prices || gd.servicePrices || {};
          // Try to match subcategory/description against service_prices keys
          for (const [svcName, price] of Object.entries(servicePrices)) {
            const svcLower = svcName.toLowerCase();
            if (subQuery.includes(svcLower) || svcLower.includes(subQuery) ||
                subQuery.split(/\s+/).some(w => w.length >= 3 && svcLower.includes(w))) {
              estimatedCost = (typeof price === 'number' ? price : parseFloat(price)).toString();
              pricingSource = 'fixed';
              break;
            }
          }
          // If no service match, use labor_cost_per_hour as rough baseline (not fallback R500)
          if (pricingSource === 'none') {
            const laborRate = gd.labor_cost_per_hour || gd.laborCostPerHour;
            if (laborRate) {
              estimatedCost = (parseFloat(laborRate) * 2).toString(); // 2-hour minimum estimate
              pricingSource = 'labor_estimate';
            }
          }
        }

        // 2) Also check tasks collection for exact service pricing
        if (pricingSource !== 'fixed' && subQuery) {
          const taskSnap = await firestore.collection('tasks').limit(200).get();
          for (const td of taskSnap.docs) {
            const d = td.data();
            const name = (d.name || d.title || d.task_name || '').toString().toLowerCase();
            const cost = parseFloat(d.cost || d.price || d.amount || 0);
            if (name && cost > 0 && (subQuery.includes(name) || name.includes(subQuery) ||
                subQuery.split(/\s+/).some(w => w.length >= 3 && name.includes(w)))) {
              estimatedCost = cost.toString();
              pricingSource = 'fixed';
              break;
            }
          }
        }
      } catch (e) {
        console.error('[create_booking] Pricing lookup error:', e.message);
      }

      // If no pricing found at all, don't default to R500 — flag it
      if (estimatedCost === '0' || pricingSource === 'none') {
        estimatedCost = '0';
      }

      // Auto-check for first-job / off-peak discounts if no promo applied yet
      if (!session.promoCode) {
        try {
          const uid = session.linkedUserId;
          // First-job check
          let isFirstJob = false;
          if (uid) {
            const co = await firestore.collection('tasksManagement')
              .where('user_id', '==', uid).where('status', 'in', ['completed', 'closed']).limit(1).get();
            isFirstJob = co.empty;
          }
          if (!isFirstJob) {
            const wao = await firestore.collection('tasksManagement')
              .where('customerPhone', '==', session.phone).where('status', 'in', ['completed', 'closed']).limit(1).get();
            isFirstJob = wao.empty;
          }
          if (isFirstJob) {
            const fjSnap = await firestore.collection('promo_codes')
              .where('promo_type', '==', 'first_job').where('status', '==', 'active').limit(1).get();
            if (!fjSnap.empty) {
              const fj = fjSnap.docs[0].data();
              session.promoCode = fj.code || 'FIRSTJOB';
              session.promoId = fjSnap.docs[0].id;
              session.promoDiscountType = fj.discount_type || fj.discountType || 'percentage';
              session.promoDiscount = fj.discount_value || fj.discountValue || 0;
              session.autoDiscount = 'first_job';
            }
          }
          // Off-peak check (only if no first-job)
          if (!session.promoCode) {
            const sast = new Date(new Date().toLocaleString('en-US', { timeZone: 'Africa/Johannesburg' }));
            const day = sast.getDay();
            const hour = sast.getHours();
            if (day >= 1 && day <= 5 && hour < 10) {
              const opSnap = await firestore.collection('promo_codes')
                .where('promo_type', '==', 'off_peak').where('status', '==', 'active').limit(1).get();
              if (!opSnap.empty) {
                const op = opSnap.docs[0].data();
                session.promoCode = op.code || 'OFFPEAK';
                session.promoId = opSnap.docs[0].id;
                session.promoDiscountType = op.discount_type || op.discountType || 'percentage';
                session.promoDiscount = op.discount_value || op.discountValue || 0;
                session.autoDiscount = 'off_peak';
              }
            }
          }
        } catch (e) { console.warn('[create_booking] auto-discount check error:', e.message); }
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
        promoApplied = { code: session.promoCode, discount, type: session.promoDiscountType || 'fixed', autoApplied: session.autoDiscount || null };
      }

      // Calculate deposit amount (35% of total, matching app's deposit_service.dart)
      const depositAmount = Math.round(finalCost * 0.35 * 100) / 100;
      const balanceAmount = Math.round((finalCost - depositAmount) * 100) / 100;

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
        urgency: args.urgency || 'normal',
        name: args.customerName || '',
        customerName: args.customerName || '',
        customerPhone: session.phone,
        contact: session.phone,
        user_id: session.linkedUserId || '',
        source: 'whatsapp',
        status: 'pending_artisan_acceptance',
        accept: '',
        artisan_confirmed: 'pending',
        cost: finalCost.toFixed(2),
        deposit_amount: depositAmount.toFixed(2),
        balance_amount: balanceAmount.toFixed(2),
        payment_type: '',
        deposit_paid: false,
        balance_paid: false,
        payment_status: 'unpaid',
        paymentStatus: 'pending',
        promo_code: promoApplied ? promoApplied.code : null,
        promo_discount: promoApplied ? promoApplied.discount : 0,
        created_at: now,
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
        updated_at: now,
      };

      await firestore.collection('tasksManagement').doc(bookingId).set(booking);

      // Also create futureBookings entry (modern flow)
      const futureBooking = {
        id: bookingId,
        order_no: orderNo,
        user_id: session.linkedUserId || '',
        user_name: args.customerName || '',
        user_phone: session.phone,
        category_name: args.category || '',
        subcategory: args.subcategory || '',
        description: args.description || '',
        address: args.address || '',
        urgency: args.urgency || 'normal',
        cost: finalCost.toFixed(2),
        deposit_amount: depositAmount.toFixed(2),
        balance_amount: balanceAmount.toFixed(2),
        payment_type: '',
        deposit_paid: false,
        balance_paid: false,
        status: 'pending_artisan_acceptance',
        artisan_confirmed: 'pending',
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
        created_at: now,
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
      };

      await firestore.collection('futureBookings').doc(bookingId).set(futureBooking);

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

      // ── Notify available artisans via FCM push ──
      try {
        const catSlug = (args.category || '').toLowerCase().replace(/\s+/g, '_');
        const artisanSnap = await firestore.collection('serviceProvider')
          .where('status', '==', 'approved')
          .where('is_suspended', '!=', true)
          .limit(20)
          .get();
        for (const artDoc of artisanSnap.docs) {
          const ad = artDoc.data() || {};
          // Check if artisan serves this category
          const cats = (ad.categories || ad.category || '').toString().toLowerCase();
          if (cats && !cats.includes(catSlug) && catSlug !== 'general_maintenance') continue;
          const token = (ad.fcm_token || ad.deviceToken || '').toString().trim();
          if (!token) continue;
          try {
            await admin.messaging().send({
              token,
              notification: {
                title: '🔔 New Booking Request',
                body: `New ${args.category || 'maintenance'} job available. Tap to view and accept.`,
              },
              data: {
                type: 'new_booking',
                booking_id: bookingId,
                order_no: orderNo,
              },
              android: { notification: { channelId: 'order_request_channel', sound: 'sound' } },
            });
          } catch (fcmErr) {
            console.warn(`[wa-tool] FCM to artisan ${artDoc.id} failed:`, fcmErr.message);
          }
        }
      } catch (e) { console.warn('[wa-tool] artisan dispatch notification failed:', e.message); }

      // Store last booking ID for quick payment follow-up
      session.lastBookingId = bookingId;
      session.lastBookingCost = finalCost;

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
      return {
        bookingId: doc.id,
        orderNo: d.order_no || doc.id,
        status: d.status || 'unknown',
        category: d.category_name || d.category || '',
        artisan: d.service_provider_name || d.artisanName || 'Not assigned yet',
        cost: d.cost ? `R${d.cost}` : 'Pending quote',
        paymentStatus: d.payment_status || d.paymentStatus || 'unknown',
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
      if (!firestore) return { estimate: 'R350 – R1,200 (typical range for most services)' };
      try {
        const catSlug = (args.category || '').toLowerCase().replace(/\s+/g, '_');
        const subQuery = (args.subcategory || '').toLowerCase();

        // Scoring helper: exact > substring > word overlap count
        const _matchScore = (a, b) => {
          const al = a.toLowerCase(), bl = b.toLowerCase();
          if (al === bl) return 1000;
          if (al.includes(bl) || bl.includes(al)) return 100;
          const aw = al.split(/\s+/).filter(w => w.length >= 3);
          const bw = bl.split(/\s+/).filter(w => w.length >= 3);
          let score = 0;
          for (const w of aw) { if (bl.includes(w)) score++; }
          for (const w of bw) { if (al.includes(w)) score++; }
          return score;
        };

        const combinedQuery = [args.category || '', args.subcategory || ''].join(' ').toLowerCase().trim();
        const searchQ = subQuery || combinedQuery;

        // 1) AUTHORITATIVE SOURCE: tasks collection (admin-managed fixed prices)
        let matchedService = null;
        let matchedPrice = null;
        let bestScore = 0;
        const taskResults = [];
        try {
          const taskSnap = await firestore.collection('tasks').limit(200).get();
          for (const td of taskSnap.docs) {
            const d = td.data();
            const name = (d.name || d.title || d.task_name || '').toString();
            const cost = parseFloat(d.cost || d.price || d.amount || 0);
            if (name && cost > 0) {
              taskResults.push({ name, cost, category_id: d.categoryId || d.category_id || '' });
              if (searchQ) {
                const score = _matchScore(name, searchQ);
                if (score > bestScore) {
                  bestScore = score;
                  matchedService = name;
                  matchedPrice = cost;
                }
              }
            }
          }
        } catch (e) { console.warn('[wa-tool] tasks lookup failed:', e.message); }

        // 2) pricingGuidance — for AI context only (labor rates, material multipliers)
        //    Does NOT override task-matched price.
        let categoryName = args.category || '';
        let laborCostPerHour = null;
        let outsourcedLaborRate = null;
        let materialMultiplier = null;
        let guidanceServicePrices = {};
        try {
          const guidanceDoc = await firestore.collection('pricingGuidance').doc(catSlug).get();
          if (guidanceDoc.exists) {
            const gd = guidanceDoc.data();
            guidanceServicePrices = gd.service_prices || gd.servicePrices || {};
            categoryName = gd.category_name || gd.categoryName || categoryName;
            laborCostPerHour = parseFloat(gd.labor_cost_per_hour || gd.laborCostPerHour || 0) || null;
            outsourcedLaborRate = parseFloat(gd.outsourced_labor_rate || 0) || null;
            materialMultiplier = parseFloat(gd.material_multiplier || 0) || null;
          }
        } catch (e) { /* ignore guidance errors */ }

        // Build the available fixed prices list from tasks
        const allFixedPrices = [];
        const addedNames = new Set();
        for (const t of taskResults) {
          const catId = (t.category_id || '').toLowerCase();
          const catScore = _matchScore(catId, catSlug);
          const nameScore = _matchScore(t.name, combinedQuery);
          if (catScore > 0 || nameScore > 0) {
            if (!addedNames.has(t.name.toLowerCase())) {
              allFixedPrices.push({ service: t.name, fixedPrice: `R${t.cost.toFixed(2)}` });
              addedNames.add(t.name.toLowerCase());
            }
          }
        }

        // 4) Look up real-time Builders.co.za prices for materials
        let buildersPrice = null;
        const materialQuery = args.material || args.subcategory || args.item || '';
        if (materialQuery) {
          try {
            const bp = await lookupBuildersPriceOne(materialQuery);
            if (bp && !bp.blocked && bp.priceZar > 0) {
              buildersPrice = {
                title: bp.title,
                priceZar: `R${bp.priceZar.toFixed(2)}`,
                url: bp.url,
                source: 'builders.co.za',
              };
            }
          } catch (e) { console.warn('[lookup_pricing] Builders lookup failed:', e.message); }
        }

        if (matchedService && matchedPrice) {
          return {
            matched: true,
            service: matchedService,
            fixedPrice: `R${matchedPrice.toFixed(2)}`,
            category: categoryName,
            ...(laborCostPerHour ? { laborCostPerHour: `R${laborCostPerHour}/hr` } : {}),
            ...(materialMultiplier ? { materialMultiplier } : {}),
            allServicesInCategory: allFixedPrices,
            ...(buildersPrice ? { buildersRetailPrice: buildersPrice } : {}),
            note: 'This is a FIXED price from the current pricing guide. Use this exact amount when creating the booking.',
          };
        }

        if (buildersPrice) {
          return {
            matched: false,
            category: categoryName,
            buildersRetailPrice: buildersPrice,
            availableServices: allFixedPrices,
            note: `Found a retail price on Builders.co.za for "${buildersPrice.title}": ${buildersPrice.priceZar}. This is a retail/material price, not a service price. For a full quote including labor, suggest submitting an RFQ.`,
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
        return { estimate: 'R350 – R1,200 (typical range)' };
      }
    }

    // ═══════════════════════════════════════════
    // 5b) LOOKUP BUILDERS PRODUCT (browse items/brands on builders.co.za)
    // ═══════════════════════════════════════════
    case 'lookup_builders_product': {
      const query = (args.query || '').trim();
      if (!query) return { error: 'Please provide a product search query.' };
      try {
        const cfg = await getBuildersBffConfig();
        if (!cfg) return { error: 'Builders.co.za is temporarily unavailable. Try again later.' };

        const uri = `https://www.builders.co.za/wmapi/bff/graphql/${cfg.searchKey}/${cfg.searchHash}`;
        let decoded;
        try {
          const r = await buildersFetch(uri, {
            method: 'POST',
            headers: buildersBffHeaders({ operationName: cfg.searchKey, operationHash: cfg.searchHash }),
            body: JSON.stringify({ variables: { keyword: query, offset: 0, pageSize: 10, dynamicPriceRange: true, site: cfg.site } }),
            timeoutMs: 12000,
          });
          if (!r.ok) return { error: 'Builders search unavailable right now.' };
          decoded = await r.json();
        } catch { return { error: 'Could not reach Builders.co.za.' }; }

        const items = decoded?.data?.search?.data?.results?.items;
        if (!Array.isArray(items) || !items.length) return { products: [], message: `No products found on Builders.co.za for "${query}".` };

        const products = [];
        for (const it of items.slice(0, 8)) {
          if (!it) continue;
          const title = _str(it.name || it.title || it.productName);
          if (!title) continue;
          let urlPath = _str(it.url || it.productUrl || it.seoUrl || it.link);
          if (!urlPath) { const code = _str(it.code || it.id || it.productCode); if (code) urlPath = `/p/${code}`; }
          const url = urlPath ? (urlPath.startsWith('http') ? urlPath : `https://www.builders.co.za${urlPath.startsWith('/') ? '' : '/'}${urlPath}`) : '';
          const price = extractPriceFromBffItem(it);
          const brand = _str(it.brand || it.brandName || '');
          products.push({
            title,
            brand: brand || undefined,
            price: price > 0 ? `R${price.toFixed(2)}` : 'Price in-store',
            priceZar: price > 0 ? price : null,
            url: url || undefined,
          });
        }

        return {
          products,
          searchQuery: query,
          source: 'builders.co.za',
          message: products.length > 0
            ? `Found ${products.length} product(s) on Builders.co.za for "${query}". Present these to the customer so they can choose their preferred brand or item.`
            : `No products found for "${query}".`,
          instruction: 'Show these products to the customer with prices and ask which one they prefer. Include the Builders link so they can view it.',
        };
      } catch (e) {
        console.error('[lookup_builders_product] Error:', e.message);
        return { error: 'Product search failed. Try again.' };
      }
    }

    // ═══════════════════════════════════════════
    // 6) APPLY PROMO CODE
    // ═══════════════════════════════════════════
    // ═══════════════════════════════════════════
    // 6a) CHECK AUTO-DISCOUNTS
    // ═══════════════════════════════════════════
    case 'check_auto_discounts': {
      if (!firestore) return { error: 'Database unavailable' };
      const discounts = [];
      const userId = session.linkedUserId;

      // 1) First-job discount — check if user has zero completed orders
      if (userId) {
        try {
          const completedOrders = await firestore.collection('tasksManagement')
            .where('user_id', '==', userId)
            .where('status', 'in', ['completed', 'closed'])
            .limit(1).get();
          if (completedOrders.empty) {
            // Also check WhatsApp bookings by phone
            const waOrders = await firestore.collection('tasksManagement')
              .where('customerPhone', '==', session.phone)
              .where('status', 'in', ['completed', 'closed'])
              .limit(1).get();
            if (waOrders.empty) {
              const fjSnap = await firestore.collection('promo_codes')
                .where('promo_type', '==', 'first_job')
                .where('status', '==', 'active').limit(1).get();
              if (!fjSnap.empty) {
                const fj = fjSnap.docs[0].data();
                const discType = fj.discount_type || fj.discountType || 'percentage';
                const discVal = fj.discount_value || fj.discountValue || 0;
                discounts.push({
                  type: 'first_job',
                  label: 'First Job Discount',
                  discountType: discType,
                  discountValue: discVal,
                  description: discType === 'percentage' ? `${discVal}% off your first booking!` : `R${discVal} off your first booking!`,
                  promoId: fjSnap.docs[0].id,
                  code: fj.code || 'FIRSTJOB',
                });
              }
            }
          }
        } catch (e) { console.warn('[auto-discount] first-job check error:', e.message); }
      } else {
        // No linked account — check by phone only
        try {
          const waOrders = await firestore.collection('tasksManagement')
            .where('customerPhone', '==', session.phone)
            .where('status', 'in', ['completed', 'closed'])
            .limit(1).get();
          if (waOrders.empty) {
            const fjSnap = await firestore.collection('promo_codes')
              .where('promo_type', '==', 'first_job')
              .where('status', '==', 'active').limit(1).get();
            if (!fjSnap.empty) {
              const fj = fjSnap.docs[0].data();
              const discType = fj.discount_type || fj.discountType || 'percentage';
              const discVal = fj.discount_value || fj.discountValue || 0;
              discounts.push({
                type: 'first_job',
                label: 'First Job Discount',
                discountType: discType,
                discountValue: discVal,
                description: discType === 'percentage' ? `${discVal}% off your first booking!` : `R${discVal} off your first booking!`,
                promoId: fjSnap.docs[0].id,
                code: fj.code || 'FIRSTJOB',
              });
            }
          }
        } catch (e) { console.warn('[auto-discount] first-job phone check error:', e.message); }
      }

      // 2) Off-peak discount — weekdays before 10am SAST
      try {
        const sast = new Date(new Date().toLocaleString('en-US', { timeZone: 'Africa/Johannesburg' }));
        const day = sast.getDay(); // 0=Sun, 6=Sat
        const hour = sast.getHours();
        if (day >= 1 && day <= 5 && hour < 10) {
          const opSnap = await firestore.collection('promo_codes')
            .where('promo_type', '==', 'off_peak')
            .where('status', '==', 'active').limit(1).get();
          if (!opSnap.empty) {
            const op = opSnap.docs[0].data();
            const discType = op.discount_type || op.discountType || 'percentage';
            const discVal = op.discount_value || op.discountValue || 0;
            discounts.push({
              type: 'off_peak',
              label: 'Off-Peak Discount',
              discountType: discType,
              discountValue: discVal,
              description: discType === 'percentage' ? `${discVal}% off for booking during off-peak hours!` : `R${discVal} off for booking during off-peak hours!`,
              promoId: opSnap.docs[0].id,
              code: op.code || 'OFFPEAK',
            });
          }
        }
      } catch (e) { console.warn('[auto-discount] off-peak check error:', e.message); }

      // 3) Loyalty points balance
      if (userId) {
        try {
          const lpDoc = await firestore.collection('loyalty_points').doc(userId).get();
          if (lpDoc.exists) {
            const pts = lpDoc.data().totalPoints || 0;
            if (pts >= 100) {
              const randValue = Math.floor(pts / 10); // 100pts = R10
              discounts.push({
                type: 'loyalty_points',
                label: 'Loyalty Points',
                points: pts,
                randValue,
                description: `You have ${pts} loyalty points (worth R${randValue})! You can redeem up to 10% of your booking total.`,
              });
            }
          }
        } catch (e) { console.warn('[auto-discount] loyalty check error:', e.message); }
      }

      // Auto-apply the best promo if no manual promo is active
      if (!session.promoCode && discounts.length > 0) {
        const bestPromo = discounts.find(d => d.type === 'first_job') || discounts.find(d => d.type === 'off_peak');
        if (bestPromo && bestPromo.promoId) {
          session.promoCode = bestPromo.code;
          session.promoId = bestPromo.promoId;
          session.promoDiscountType = bestPromo.discountType;
          session.promoDiscount = bestPromo.discountValue;
          session.autoDiscount = bestPromo.type;
        }
      }

      if (discounts.length === 0) {
        return { discounts: [], message: 'No automatic discounts available right now, but you can still enter a promo code if you have one!' };
      }

      return {
        discounts,
        autoApplied: session.autoDiscount || null,
        message: `Great news! You qualify for: ${discounts.map(d => d.description).join(' | ')}`,
      };
    }

    // ═══════════════════════════════════════════
    // 6b) GET UPSELL ADD-ONS
    // ═══════════════════════════════════════════
    case 'get_upsell_addons': {
      if (!firestore) return { error: 'Database unavailable' };
      const catId = (args.categoryId || '').toLowerCase().replace(/\s+/g, '_');
      if (!catId) return { addons: [], message: 'No category provided.' };

      try {
        let addonDocs;
        try {
          const snap = await firestore.collection('upsell_addons')
            .where('trigger_category_id', '==', catId)
            .where('status', '==', 'active')
            .orderBy('sort_order').get();
          addonDocs = snap.docs;
        } catch (indexErr) {
          // Fallback without orderBy if composite index doesn't exist
          const snap = await firestore.collection('upsell_addons')
            .where('trigger_category_id', '==', catId)
            .where('status', '==', 'active').get();
          addonDocs = snap.docs;
        }

        if (addonDocs.length === 0) {
          return { addons: [], message: 'No add-on services available for this category.' };
        }

        const addons = addonDocs.map(d => {
          const a = d.data();
          const base = parseFloat(a.base_price || a.basePrice || 0);
          const disc = parseFloat(a.discount_percent || a.discountPercent || 0);
          const discounted = Math.round(base * (1 - disc / 100));
          return {
            id: d.id,
            name: a.name || a.title || '',
            description: a.description || '',
            originalPrice: base,
            discountPercent: disc,
            discountedPrice: discounted,
            savings: Math.round(base - discounted),
          };
        });

        // Log that upsells were shown
        for (const addon of addons) {
          firestore.collection('upsell_logs').add({
            user_id: session.linkedUserId || session.phone,
            addon_id: addon.id,
            event_type: 'shown',
            addon_name: addon.name,
            addon_price: addon.discountedPrice,
            source: 'whatsapp',
            created_at: new Date().toISOString(),
          }).catch(() => {});
        }

        return {
          addons,
          message: `Recommended add-ons for your ${args.categoryId} booking (special bundle prices when added to your booking):\n${addons.map((a, i) => `${i+1}. ${a.name} — R${a.discountedPrice}${a.discountPercent > 0 ? ` (was R${a.originalPrice}, save ${a.discountPercent}%)` : ''}`).join('\n')}\n\nWould you like to add any of these to your booking?`,
        };
      } catch (e) {
        console.error('[get_upsell_addons] Error:', e.message);
        return { addons: [], message: 'Could not load add-ons right now.' };
      }
    }

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
    // 7) REQUEST PAYMENT LINK (Ozow)
    // ═══════════════════════════════════════════
    case 'request_payment_link': {
      if (!firestore) return { error: 'Database unavailable' };
      const bid = args.bookingId || session.lastBookingId;
      if (!bid) return { error: 'Please provide a booking ID.' };

      let doc = await firestore.collection('tasksManagement').doc(bid).get();
      if (!doc.exists) doc = await firestore.collection('futureBookings').doc(bid).get();
      if (!doc.exists) return { error: `Booking "${bid}" not found.` };

      const d = doc.data();

      // Enforce artisan acceptance before payment
      const artisanAccepted = d.accept === '1' || d.accept === 1 || d.artisan_confirmed === 'yes';
      if (!artisanAccepted) {
        return { error: `An artisan hasn't accepted this job yet. You'll be notified when an artisan accepts, and then you can proceed to payment. Your booking ${d.order_no || bid} is in the queue.` };
      }

      const cost = parseFloat(d.cost || d.total_cost || d.quoted_price || '0');
      if (cost <= 0) return { error: 'This booking does not have a confirmed price yet.' };

      if (d.payment_status === 'paid' || d.paymentStatus === 'paid') {
        return { message: 'This booking is already paid!', bookingId: bid };
      }

      // If deposit already paid, only balance remains
      if (d.deposit_paid === true && d.balance_paid !== true) {
        const bal = parseFloat(d.balance_amount || '0');
        if (bal <= 0) return { message: 'Deposit already paid. No balance due yet.', bookingId: bid };
        args.payment_type = 'full';
      }

      // Determine payment amount based on deposit vs full
      const paymentType = args.payment_type || 'full';
      let payAmount;
      let itemSuffix;
      if (paymentType === 'deposit') {
        payAmount = Math.round(cost * 0.35 * 100) / 100;
        itemSuffix = '(35% Deposit)';
      } else {
        payAmount = d.deposit_paid === true ? parseFloat(d.balance_amount || cost) : cost;
        itemSuffix = d.deposit_paid === true ? '(Balance Payment)' : '(Full Payment)';
      }

      // Try to generate an Ozow payment URL via the backend
      try {
        const backendUrl = process.env.BACKEND_URL || 'https://square15-livekit-backend.onrender.com';
        const fetch = (await import('node-fetch')).default;
        const ozowResp = await fetch(`${backendUrl}/api/payment/initiate`, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({
            amount: payAmount.toFixed(2),
            item_name: `Square 15 Booking ${d.order_no || d.rfq_no || bid} ${itemSuffix}`,
            custom_str1: bid,
          }),
        });
        const ozowBody = await ozowResp.json();

        if (ozowBody.ok && ozowBody.payment_url) {
          // Update booking with payment_type
          try {
            await firestore.collection('tasksManagement').doc(bid).update({ payment_type: paymentType }).catch(() => {});
            await firestore.collection('futureBookings').doc(bid).update({ payment_type: paymentType }).catch(() => {});
          } catch (e) { /* ignore */ }

          const escrowMsg = paymentType === 'deposit'
            ? `\n\n🔒 Your deposit of R${payAmount.toFixed(2)} is held securely in escrow. The remaining R${(cost - payAmount).toFixed(2)} is due after job completion. The artisan does NOT receive your money until you confirm satisfaction.`
            : `\n\n🔒 Your payment is held securely in escrow. The artisan does NOT receive your money until you confirm you are satisfied with the completed work.`;

          return {
            success: true,
            message: `Here's your ${itemSuffix} link for R${payAmount.toFixed(2)}:\n\n${ozowBody.payment_url}\n\nClick to pay securely via Ozow (instant EFT).${escrowMsg}\n\n✅ 100% Money-Back Guarantee — not satisfied? Full refund, no questions asked within 24 hours.\n🚫 Free cancellation before artisan dispatch.`,
            amount: `R${payAmount.toFixed(2)}`,
            paymentUrl: ozowBody.payment_url,
            reference: ozowBody.transaction_ref || '',
            bookingId: bid,
          };
        }
      } catch (e) {
        console.warn('[request_payment_link] Ozow API call failed:', e.message);
      }

      // Fallback: store request and notify admin
      const payRef = `PAY-${bid}-${Date.now().toString(36)}`;
      await firestore.collection('payment_links').doc(payRef).set({
        booking_id: bid,
        amount: payAmount,
        payment_type: paymentType,
        phone: session.phone,
        user_id: session.linkedUserId || '',
        status: 'pending',
        source: 'whatsapp',
        created_at: admin.firestore.FieldValue.serverTimestamp(),
      });

      await firestore.collection('notifications').add({
        title: 'WhatsApp Payment Request',
        body: `Customer requests ${itemSuffix} for booking ${bid} (R${payAmount.toFixed(2)})`,
        type: 'payment_request',
        user_type: 'admin',
        booking_id: bid,
        read: false,
        created_at: admin.firestore.FieldValue.serverTimestamp(),
      });

      return {
        message: `${itemSuffix} request for R${payAmount.toFixed(2)} submitted for booking ${d.order_no || d.rfq_no || bid}. You can also pay via the Square 15 app.\n\nAlternatively, reply "pay with wallet" if you have sufficient balance.\n\n🔒 Your money is protected in escrow until you confirm satisfaction.`,
        amount: `R${payAmount.toFixed(2)}`,
        reference: payRef,
        bookingId: bid,
      };
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

      const bid = args.bookingId || session.lastBookingId;
      if (!bid) return { error: 'Please provide a booking ID.' };

      // Get booking — check both collections (RFQs live in futureBookings only)
      let bookDoc = await firestore.collection('tasksManagement').doc(bid).get();
      let bookingCollection = 'tasksManagement';
      if (!bookDoc.exists) {
        bookDoc = await firestore.collection('futureBookings').doc(bid).get();
        bookingCollection = 'futureBookings';
      }
      if (!bookDoc.exists) return { error: `Booking "${bid}" not found.` };
      const bookData = bookDoc.data();

      if (bookData.payment_status === 'paid') return { message: 'This booking is already paid!' };

      // Enforce artisan acceptance before payment
      const artisanAccepted = bookData.accept === '1' || bookData.accept === 1 || bookData.artisan_confirmed === 'yes';
      if (!artisanAccepted) {
        return { error: `An artisan hasn't accepted this job yet. You'll be notified when an artisan accepts, and then you can proceed to payment.` };
      }

      const cost = parseFloat(bookData.cost || '0');
      if (cost <= 0) return { error: 'This booking does not have a confirmed price yet.' };

      // Determine payment amount based on deposit vs full
      const paymentType = args.payment_type || 'full';
      let payAmount;
      if (bookData.deposit_paid === true && bookData.balance_paid !== true) {
        // Deposit already paid, only balance remains
        payAmount = parseFloat(bookData.balance_amount || cost);
      } else if (paymentType === 'deposit') {
        payAmount = Math.round(cost * 0.35 * 100) / 100;
      } else {
        payAmount = cost;
      }

      // Get user balance (atomic transaction)
      try {
        await firestore.runTransaction(async (txn) => {
          const userRef = firestore.collection('users').doc(session.linkedUserId);
          const userSnap = await txn.get(userRef);
          if (!userSnap.exists) throw new Error('User not found');

          const balance = parseFloat(userSnap.data().balance || '0');
          if (balance < payAmount) throw new Error(`Insufficient balance. You have R${balance.toFixed(2)} but need R${payAmount.toFixed(2)}.`);

          const newBalance = balance - payAmount;
          txn.update(userRef, { balance: newBalance.toFixed(2) });

          // Determine payment status fields
          const isDeposit = paymentType === 'deposit' && bookData.deposit_paid !== true;
          const paymentFields = isDeposit
            ? {
                payment_status: 'deposit_paid',
                paymentStatus: 'deposit_paid',
                deposit_paid: true,
                payment_type: 'deposit',
                payment_method: 'wallet',
                paid_at: new Date().toISOString(),
              }
            : {
                payment_status: 'paid',
                paymentStatus: 'paid',
                balance_paid: bookData.deposit_paid === true ? true : false,
                deposit_paid: bookData.deposit_paid === true ? true : true,
                payment_type: bookData.deposit_paid === true ? 'deposit' : 'full',
                payment_method: 'wallet',
                paid_at: new Date().toISOString(),
              };

          // Update the primary collection where the booking was found
          txn.update(firestore.collection(bookingCollection).doc(bid), paymentFields);

          // Also update the OTHER collection if it exists there too
          const otherCollection = bookingCollection === 'tasksManagement' ? 'futureBookings' : 'tasksManagement';
          const otherRef = firestore.collection(otherCollection).doc(bid);
          const otherSnap = await txn.get(otherRef);
          if (otherSnap.exists) {
            txn.update(otherRef, { ...paymentFields, wallet_deducted: true });
          }
        });

        // Log transaction
        await firestore.collection('transactionLogs').add({
          user_id: session.linkedUserId,
          type: 'payment',
          subtype: paymentType === 'deposit' ? 'wallet_deposit_payment' : 'wallet_deduction',
          amount: payAmount,
          booking_id: bid,
          payment_type: paymentType,
          source: 'whatsapp',
          status: 'success',
          created_at: admin.firestore.FieldValue.serverTimestamp(),
        });

        const isDeposit = paymentType === 'deposit' && bookData.deposit_paid !== true;
        const balanceRemaining = Math.round((cost - payAmount) * 100) / 100;

        if (isDeposit) {
          return {
            success: true,
            message: `Deposit payment of R${payAmount.toFixed(2)} successful via wallet! 🔒 Your deposit is held securely in escrow.\n\nRemaining balance: R${balanceRemaining.toFixed(2)} (due after job completion).\nThe artisan does NOT receive your money until you confirm satisfaction.\n\n✅ 100% Money-Back Guarantee`,
            paid: `R${payAmount.toFixed(2)}`,
            paymentType: 'deposit',
          };
        }
        return {
          success: true,
          message: `Payment of R${payAmount.toFixed(2)} successful via wallet! 🔒 Your payment is held securely in escrow. The artisan does NOT receive your money until you confirm you are satisfied with the completed work.\n\n✅ 100% Money-Back Guarantee — not satisfied? Full refund, no questions asked within 24 hours.`,
          paid: `R${payAmount.toFixed(2)}`,
          paymentType: 'full',
        };
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
        user_id: session.linkedUserId || '',
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
        created_at: now,
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
      };

      await firestore.collection('futureBookings').doc(rfqId).set(rfqDoc);

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
            admin_quote_total: quote.grand_total,
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
        // Notify admin that AI quote failed so they can manually create one
        try {
          await firestore.collection('notifications').add({
            title: '⚠️ AI Quote Generation Failed',
            body: `AI quote failed for RFQ ${rfqNo} (${args.category || 'unknown category'}). Error: ${quoteErr.message}. Please create a manual quote.`,
            type: 'rfq_quote_failed',
            user_type: 'admin',
            booking_id: rfqId,
            read: false,
            created_at: admin.firestore.FieldValue.serverTimestamp(),
          });
        } catch (nErr) { console.warn('[submit_rfq] Failed to notify admin of quote failure:', nErr.message); }
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
      if (!doc.exists) doc = await firestore.collection('futureBookings').doc(bid).get();
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

      const cancelUpdate = {
        status: 'cancelled',
        cancelled_at: now,
        cancelled_by: 'client_whatsapp',
        cancel_reason: args.reason || 'Cancelled via WhatsApp',
        cancellation_reason: args.reason || 'Cancelled via WhatsApp',
      };

      // Cancel in both collections (safe — only updates if doc exists)
      try { await firestore.collection('tasksManagement').doc(bid).update(cancelUpdate); } catch (e) { /* doc may not exist */ }
      try { await firestore.collection('futureBookings').doc(bid).update(cancelUpdate); } catch (e) { /* doc may not exist */ }

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

      // Get booking
      let doc = await firestore.collection('tasksManagement').doc(bid).get();
      if (!doc.exists) doc = await firestore.collection('futureBookings').doc(bid).get();
      if (!doc.exists) return { error: `Booking "${bid}" not found.` };

      const d = doc.data();
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
        } catch (e) { console.warn('[wa-tool] artisan rating update failed:', e.message); }
      }

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
      if (!doc.exists) doc = await firestore.collection('futureBookings').doc(bid).get();
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
        else return { error: 'You don\'t have a Square 15 account yet. Please register first by telling me your name, and I\'ll set you up — then we can link the referral code.' };
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
        message: 'No Square 15 account found for this phone number. I can register you right here on WhatsApp — just tell me your full name and I\'ll create your account. Or if you already have the app, make sure you registered with this same phone number.',
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
        return { registered: true, message: `You already have an account (${existingUser.name || customerName}). I\'ve linked it to this WhatsApp chat.` };
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

      // ── Notify available artisans via FCM push ──
      try {
        const cat = (data.category || data.category_name || '').toLowerCase().replace(/\s+/g, '_');
        const artisanSnap = await firestore.collection('serviceProvider')
          .where('status', '==', 'approved')
          .where('is_suspended', '!=', true)
          .limit(20)
          .get();
        for (const artDoc of artisanSnap.docs) {
          const ad = artDoc.data() || {};
          const cats = (ad.categories || ad.category || '').toString().toLowerCase();
          if (cats && cat && !cats.includes(cat) && cat !== 'general_maintenance') continue;
          const token = (ad.fcm_token || ad.deviceToken || '').toString().trim();
          if (!token) continue;
          try {
            await admin.messaging().send({
              token,
              notification: {
                title: '🔔 New RFQ Job Available',
                body: `RFQ ${data.rfq_no || rfqId} — R${priceNum.toFixed(2)}. Tap to view and accept.`,
              },
              data: { type: 'rfq_accepted', booking_id: rfqId },
              android: { notification: { channelId: 'order_request_channel', sound: 'sound' } },
            });
          } catch (fcmErr) {
            console.warn(`[wa-tool] FCM to artisan ${artDoc.id} failed:`, fcmErr.message);
          }
        }
      } catch (e) { console.warn('[wa-tool] artisan RFQ dispatch failed:', e.message); }

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
      return {
        booking_id: bid,
        payment_status: data.payment_status || 'unpaid',
        payment_method: data.payment_method || 'N/A',
        amount: data.cost || data.total_cost || 'N/A',
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
- Generate secure Ozow payment links for instant EFT payment
- Apply promo/discount codes before booking

PAYMENT FLOW (CRITICAL — Artisan must accept BEFORE payment):
1. After creating a booking or accepting an RFQ quote, DO NOT offer payment immediately.
2. Tell the customer: "An artisan needs to accept your job first. You'll be notified when one accepts, and then you can pay."
3. ONLY offer payment AFTER the booking status shows an artisan has accepted (accept='1' or artisan_confirmed='yes').
4. When an artisan has accepted and customer wants to pay, ALWAYS ask: "Would you like to pay the full amount (R{total}) or a 35% deposit (R{deposit}) with the balance due after job completion?"
5. If customer says "pay deposit" or "35%" → call request_payment_link or pay_with_wallet with payment_type='deposit'
6. If customer says "pay full" or "pay everything" → call request_payment_link or pay_with_wallet with payment_type='full'
7. NEVER skip the deposit/full question — ALWAYS let the customer choose
8. After payment, explain the escrow protection and guarantee

🔒 FINANCIAL SECURITY (ALWAYS mention these when discussing payment):
- "Your payment is held in a secure escrow account. The artisan does NOT receive your money until you confirm you are satisfied with the completed work. You are always in control."
- "100% Money-Back Guarantee — not satisfied? Full refund, no questions asked within 24 hours."
- "Free cancellation before artisan dispatch. Full refund within 2 hours of payment."
- When a customer asks "is my money safe?" or expresses concern, explain all three protections
- If deposit is chosen: "Your deposit of R{amount} is protected in escrow. The remaining R{balance} is only due after the job is completed to your satisfaction."

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

🎁 AUTO-DISCOUNTS (IMPORTANT — check and mention these proactively):
- FIRST-JOB DISCOUNT: New customers who have never completed a booking get an automatic discount. Call check_auto_discounts to verify eligibility and tell them about their savings BEFORE creating the booking.
- OFF-PEAK DISCOUNT: Bookings made on weekdays before 10am SAST qualify for an automatic off-peak discount.
- LOYALTY POINTS: Returning customers earn loyalty points (10 pts per R100 spent). 100+ points can be redeemed for up to 10% off (100pts = R10).
- Auto-discounts are applied automatically at booking time even if you don't call check_auto_discounts — but ALWAYS mention the discount to make the customer feel valued.
- If a customer already has a manual promo code applied, auto-discounts won't override it.

🛒 UPSELL ADD-ONS (use these to offer more value):
- After the customer picks a service category, call get_upsell_addons(categoryId) to check for recommended add-on services.
- Add-ons come with special bundle discounts (e.g. "Add a geyser inspection to your plumbing booking — 30% off!").
- Present add-ons BEFORE creating the booking. Let the customer choose which (if any) they want.
- Example flow: Customer wants plumbing → you call get_upsell_addons('plumbing') → present options → customer picks → include them in the booking description and add their costs.
- NEVER pressure the customer — frame it as "Here are some recommended services that pair well with your booking".

DISCOUNT & UPSELL FLOW (follow this for every booking):
1. Customer describes their need → you identify the category
2. Call check_auto_discounts — mention any available discounts enthusiastically
3. Call get_upsell_addons(categoryId) — present relevant add-ons with bundle pricing
4. Call lookup_pricing → get the service price
5. Let customer confirm what they want
6. Call create_booking — discounts are auto-applied to the final price

⭐ RATINGS & REVIEWS:
- Rate completed jobs (1-5 stars with optional comment)
- Prompt customers to rate after asking about completed bookings

💸 REFUNDS:
- Request refunds for problematic bookings
- Wallet refunds processed instantly; card refunds take 3-5 business days

🤝 PARTNER CODES:
- Link corporate partner / referral codes for commission tracking
- Validate referral codes
- Referral codes can be provided during registration or linked afterwards

📝 REGISTRATION & ACCOUNT:
- Register new customers directly on WhatsApp (register_account) — NO app download needed
- During registration, ALWAYS ask: "Do you have a referral or partner code?" (but make it clear it's optional)
- Collect: full name (required), email (optional but recommended), address (optional), referral code (optional)
- Auto-link WhatsApp number to existing Square 15 app account (link_account) for customers who already have the app
- If a new user tries to book or use a referral code without an account, suggest registering first

FIRST-TIME USER FLOW (IMPORTANT):
1. When you detect a new/unregistered user (no linked account), warmly welcome them and offer to register them
2. Ask for their full name
3. Ask "Do you have a referral or partner code? (No worries if you don't!)"
4. Call register_account with the collected info
5. Then proceed with whatever they originally wanted (booking, RFQ, etc.)
6. For returning users who already have the app, use link_account to sync their WhatsApp

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

🔍 BUILDERS PRODUCT BROWSING:
- Search for products, materials, and brands on Builders Warehouse (lookup_builders_product)
- Help customers compare brands and prices for materials they need
- Show product names, brands, prices, and direct links to Builders website

CRITICAL PRICING RULES:
- You MUST call lookup_pricing BEFORE calling create_booking, EVERY TIME, NO EXCEPTIONS.
- When calling lookup_pricing, pass the specific service as subcategory (e.g. category="plumbing", subcategory="toilet unblocking").
- lookup_pricing now returns laborCostPerHour, outsourcedLaborRate, and materialMultiplier from admin pricing guidance — use these for accurate quotes.
- If lookup_pricing returns matched=true with a fixedPrice, use that EXACT price — do NOT estimate or use a different amount.
- If lookup_pricing returns matched=false and no fixedPrice service matches, tell the customer: "This job needs a detailed quote" and use submit_rfq instead of create_booking.
- NEVER guess or make up a price. Only use prices returned by lookup_pricing.
- If create_booking returns an estimated cost of R0.00, it means no fixed price was found — inform the customer and suggest an RFQ.

BUILDERS PRODUCT BROWSING RULES:
- When presenting RFQ quotes that include materials, mention that you can look up specific products on Builders if they want different brands or options.
- When a customer asks about specific products, materials, or brands, use lookup_builders_product to search Builders Warehouse.
- Present results with product name, brand, price, and a direct link to the Builders website.
- Let the customer choose which product/brand they prefer — then factor that into the quote.
- If a customer wants to compare brands (e.g. "show me geyser options"), search Builders and present the top options with prices.
- Always show the Builders link so the customer can view the product details themselves.

GUIDELINES:
- Be warm, professional, and concise (WhatsApp messages should be short)
- Always collect: category, description, address, customer name BEFORE creating a booking
- For complex jobs (renovations, full installations), suggest submitting an RFQ instead of a regular booking
- Use South African Rands (R) for all pricing
- When a customer sends a photo, ANALYSE the image using your vision capabilities. Identify the maintenance issue (e.g. leaking pipe, broken socket, cracked wall), suggest the correct service category, and offer to create a booking or RFQ
- For emergencies, emphasise urgency and prioritise booking creation
- When a booking is created, mention the estimated cost and explain that an artisan needs to accept first before payment
- NEVER offer payment immediately after booking creation — artisan must accept first
- After an artisan accepts, ask the customer to choose between FULL PAYMENT or 35% DEPOSIT before generating a payment link
- After accepting an RFQ quote, tell the customer an artisan needs to accept the job — do NOT offer payment immediately
- If customer asks to pay but artisan hasn't accepted, explain: "An artisan needs to accept your job first. You'll be notified when one accepts."
- NEVER say "admin will send a link" or "you'll receive a link soon" — when artisan has accepted, generate the link yourself using request_payment_link
- After payment, explain: "Your payment is held securely in escrow. The artisan does NOT receive your money until you confirm you are satisfied. 100% money-back guarantee."
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

        const result = await executeWaTool(tc.function.name, toolArgs, session);
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
        messages: session.messages.slice(-10),
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
  // Always respond 200 quickly to Meta
  res.sendStatus(200);

  try {
    const entry = req.body?.entry?.[0];
    const changes = entry?.changes?.[0];
    const value = changes?.value;

    if (!value?.messages) return; // status update, not a message

    for (const msg of value.messages) {
      const from = msg.from; // phone number

      // Rate-limit check (prevents abuse / runaway OpenAI costs)
      if (isRateLimited(from)) {
        console.warn(`[webhook] Rate limited: ${from}`);
        continue;
      }

      const session = getSession(from);

      // Restore session from Firestore if this is a fresh in-memory session
      await restoreSessionFromFirestore(session);

      let userText = '';

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
            userText = caption
              ? `[Customer sent a photo with caption: "${caption}"] Analyse this image of a maintenance/repair issue. Identify the problem, suggest the service category, and offer to create a booking or RFQ.`
              : '[Customer sent a photo of a maintenance issue] Analyse this image. Identify what repair or maintenance is needed, suggest the service category (plumbing, electrical, painting, etc.), estimate the scope, and offer to create a booking or submit an RFQ.';
            console.log(`[msg] ${from}: [IMAGE received, ${(imageMedia.base64.length / 1024).toFixed(0)}KB]`);
            const reply = await handleMessage(session, userText, imageMedia.dataUrl);
            const chunks = reply.match(/.{1,4000}/gs) || [reply];
            for (const chunk of chunks) {
              await sendWhatsAppMessage(from, chunk);
            }
            continue; // Skip normal handleMessage below — already handled
          } else {
            userText = '[Customer sent a photo but it could not be downloaded] ' + (caption || 'Please describe the maintenance issue you need help with.');
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
            userText = '[Customer sent a voice note but it could not be transcribed] Please ask them to type their question instead, or try sending the voice note again.';
          }
          break;
        }
        case 'location':
          userText = `[Customer shared location: ${msg.location.latitude}, ${msg.location.longitude}]`;
          if (msg.location.address) userText += ` Address: ${msg.location.address}`;
          break;
        case 'sticker':
          continue; // Ignore stickers
        default:
          userText = `[Customer sent a ${msg.type} message — ask them to describe their issue in text]`;
      }

      if (!userText.trim()) continue;

      console.log(`[msg] ${from}: ${userText.substring(0, 100)}`);

      const reply = await handleMessage(session, userText);

      // Split long replies into chunks (WhatsApp has ~4096 char limit)
      const chunks = reply.match(/.{1,4000}/gs) || [reply];
      for (const chunk of chunks) {
        await sendWhatsAppMessage(from, chunk);
      }
    }
  } catch (err) {
    console.error('[webhook] Error processing message:', err);
  }
});

// Health check
app.get('/health', (req, res) => res.json({ status: 'ok', service: 'square15-whatsapp-bot' }));

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

// ─── Webhook: Artisan accepted a booking → notify client via WhatsApp ───
app.post('/api/artisan-accepted', async (req, res) => {
  try {
    const { bookingId, artisanName } = req.body || {};
    if (!bookingId) return res.status(400).json({ error: 'bookingId required' });

    const firestore = admin.firestore();

    // Find booking in tasksManagement
    const tmDoc = await firestore.collection('tasksManagement').doc(bookingId).get();
    if (!tmDoc.exists) return res.status(404).json({ error: 'Booking not found' });
    const tm = tmDoc.data();

    // Find customer phone
    let phone = (tm.phone || tm.customer_phone || '').toString().trim();
    if (!phone && tm.user_id) {
      try {
        const userDoc = await firestore.collection('users').doc(tm.user_id).get();
        phone = (userDoc.data()?.phone || userDoc.data()?.phoneNumber || '').toString().trim();
      } catch (_) {}
    }

    if (!phone) return res.status(404).json({ error: 'Customer phone not found' });

    // Normalise phone
    phone = phone.replace(/[^0-9]/g, '');
    if (phone.startsWith('0')) phone = '27' + phone.slice(1);

    const cost = parseFloat(tm.cost || tm.total_cost || '0');
    const deposit = (cost * 0.35).toFixed(2);
    const name = artisanName || tm.service_provider_name || 'An artisan';
    const orderNo = tm.order_no || tm.booking_id || bookingId;

    await sendWhatsAppMessage(phone,
      `✅ *Great news!* ${name} has accepted your booking ${orderNo}.\n\n` +
      `You can now proceed with payment:\n` +
      `💰 Full amount: R${cost.toFixed(2)}\n` +
      `💰 Deposit (35%): R${deposit} now, R${(cost - parseFloat(deposit)).toFixed(2)} after completion\n\n` +
      `🔒 Your payment is held in secure escrow — the artisan only gets paid when you're satisfied.\n\n` +
      `Reply "pay" or "payment" to get your payment link.`
    );

    res.json({ success: true, phone });
  } catch (err) {
    console.error('[artisan-accepted] error:', err.message);
    res.status(500).json({ error: err.message });
  }
});

// ─── Webhook: Payment confirmed → update booking + notify client ───
app.post('/api/payment-confirmed', async (req, res) => {
  try {
    const { bookingId, paymentType, amount } = req.body || {};
    if (!bookingId) return res.status(400).json({ error: 'bookingId required' });

    const firestore = admin.firestore();
    const tmRef = firestore.collection('tasksManagement').doc(bookingId);
    const tmDoc = await tmRef.get();
    if (!tmDoc.exists) return res.status(404).json({ error: 'Booking not found' });
    const tm = tmDoc.data();

    // Update payment status
    const isDeposit = paymentType === 'deposit';
    const updateData = isDeposit
      ? { deposit_paid: true, deposit_paid_at: new Date().toISOString(), payment_status: 'deposit_paid' }
      : { deposit_paid: true, balance_paid: true, balance_paid_at: new Date().toISOString(), payment_status: 'paid' };
    await tmRef.update(updateData);

    // Also update futureBookings if exists
    const fbId = (tm.future_booking_id || '').toString().trim();
    if (fbId) {
      try {
        await firestore.collection('futureBookings').doc(fbId).update(updateData);
      } catch (_) {}
    }

    // Find customer phone and send WhatsApp confirmation
    let phone = (tm.phone || tm.customer_phone || '').toString().trim();
    if (!phone && tm.user_id) {
      try {
        const userDoc = await firestore.collection('users').doc(tm.user_id).get();
        phone = (userDoc.data()?.phone || userDoc.data()?.phoneNumber || '').toString().trim();
      } catch (_) {}
    }

    if (phone) {
      phone = phone.replace(/[^0-9]/g, '');
      if (phone.startsWith('0')) phone = '27' + phone.slice(1);

      const paidAmt = amount || (isDeposit ? tm.deposit_amount : tm.cost);
      const orderNo = tm.order_no || tm.booking_id || bookingId;

      let msg = `✅ *Payment Received!* R${parseFloat(paidAmt).toFixed(2)} for booking ${orderNo}.\n\n`;
      if (isDeposit) {
        const balance = parseFloat(tm.balance_amount || (parseFloat(tm.cost) * 0.65));
        msg += `💰 Deposit secured. Remaining balance: R${balance.toFixed(2)} (due after job completion).\n\n`;
      }
      msg += `🔧 Your artisan will be dispatched according to the scheduled date/time. We'll keep you updated!\n\n`;
      msg += `🔒 Remember: Your money is in escrow — the artisan only gets paid when you confirm you're satisfied.`;

      await sendWhatsAppMessage(phone, msg);
    }

    res.json({ success: true, bookingId, paymentStatus: updateData.payment_status });
  } catch (err) {
    console.error('[payment-confirmed] error:', err.message);
    res.status(500).json({ error: err.message });
  }
});

// ─── Webhook: Job status update → notify client via WhatsApp ───
app.post('/api/job-status-update', async (req, res) => {
  try {
    const { bookingId, status, artisanName } = req.body || {};
    if (!bookingId || !status) return res.status(400).json({ error: 'bookingId and status required' });

    const firestore = admin.firestore();
    const tmDoc = await firestore.collection('tasksManagement').doc(bookingId).get();
    if (!tmDoc.exists) return res.status(404).json({ error: 'Booking not found' });
    const tm = tmDoc.data();

    let phone = (tm.phone || tm.customer_phone || '').toString().trim();
    if (!phone && tm.user_id) {
      try {
        const userDoc = await firestore.collection('users').doc(tm.user_id).get();
        phone = (userDoc.data()?.phone || userDoc.data()?.phoneNumber || '').toString().trim();
      } catch (_) {}
    }

    if (!phone) return res.status(404).json({ error: 'Customer phone not found' });
    phone = phone.replace(/[^0-9]/g, '');
    if (phone.startsWith('0')) phone = '27' + phone.slice(1);

    const name = artisanName || tm.service_provider_name || 'Your artisan';
    const orderNo = tm.order_no || tm.booking_id || bookingId;

    const statusMessages = {
      'progress': `🚗 *${name} is on the way!* Booking ${orderNo}.\n\nYour artisan has started the job. Sit tight!`,
      'in_progress': `🚗 *${name} is on the way!* Booking ${orderNo}.\n\nYour artisan has started the job. Sit tight!`,
      'completed': `✅ *Job completed!* Booking ${orderNo}.\n\n${name} has marked the job as done.\n\n⭐ Please rate the service in your Square 15 app to help us maintain quality standards.\n\n${tm.payment_type === 'deposit' && !tm.balance_paid ? '💰 Reminder: Your remaining balance of R' + parseFloat(tm.balance_amount || 0).toFixed(2) + ' is now due.' : ''}`,
    };

    const msg = statusMessages[status];
    if (!msg) return res.status(400).json({ error: `Unknown status: ${status}` });

    await sendWhatsAppMessage(phone, msg);
    res.json({ success: true, status, orderNo });
  } catch (err) {
    console.error('[job-status-update] error:', err.message);
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
});
