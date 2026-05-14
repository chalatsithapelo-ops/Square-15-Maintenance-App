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

// ─── PII helper: mask phone numbers in logs ───
// Format: keep country code (first 2-3 digits) + last 4, redact middle.
// Example: '27821234567' -> '27***4567'
function maskPhone(p) {
  if (!p) return '';
  const s = String(p).replace(/\D/g, '');
  if (s.length <= 6) return s.slice(0, 2) + '***';
  return s.slice(0, 2) + '***' + s.slice(-4);
}

// ─── Internal API secret middleware (for Flutter app → WA bot calls) ───
function requireInternalSecret(req, res, next) {
  const internalSecret = (process.env.INTERNAL_API_SECRET || '').trim();
  if (!internalSecret) {
    console.error('FATAL: INTERNAL_API_SECRET not set — rejecting request');
    return res.status(503).json({ error: 'Server misconfigured' });
  }
  const provided = (req.headers['x-internal-secret'] || '').trim();
  if (!provided || provided !== internalSecret) {
    return res.status(403).json({ error: 'Unauthorized' });
  }
  next();
}

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

// ─── Push notification helper for linked app customers ───
// Looks up the customer's app account by phone number or user_id,
// finds their FCM token, and sends a push notification + in-app notification.
async function notifyLinkedCustomer(firestore, { phone, userId, title, body, data }) {
  try {
    let custUserId = (userId || '').toString().trim();
    let custDoc = null;

    // If we have a userId that's a real app user (not wa_ prefix), use it directly
    if (custUserId && !custUserId.startsWith('wa_')) {
      const doc = await firestore.collection('users').doc(custUserId).get();
      if (doc.exists) custDoc = doc;
    }

    // Fallback: look up user by phone number
    if (!custDoc && phone) {
      const cleanPhone = phone.replace(/[^0-9]/g, '');
      const variants = [cleanPhone];
      if (cleanPhone.startsWith('27')) variants.push('0' + cleanPhone.slice(2));
      if (cleanPhone.startsWith('0')) variants.push('27' + cleanPhone.slice(1));
      variants.push('+' + (cleanPhone.startsWith('27') ? cleanPhone : '27' + cleanPhone.replace(/^0/, '')));

      for (const v of variants) {
        const snap = await firestore.collection('users')
          .where('phone', '==', v).limit(1).get();
        if (!snap.empty) {
          custDoc = snap.docs[0];
          custUserId = custDoc.id;
          break;
        }
        // Also check phoneNumber field
        const snap2 = await firestore.collection('users')
          .where('phoneNumber', '==', v).limit(1).get();
        if (!snap2.empty) {
          custDoc = snap2.docs[0];
          custUserId = custDoc.id;
          break;
        }
      }
    }

    if (!custDoc) return; // No linked app account

    const cu = custDoc.data() || {};
    const tokenCandidates = [cu.deviceToken, cu.device_token, cu.fcm_token, cu.fcmToken, cu.token, cu.push_token];
    const seen = new Set();
    const tokens = [];
    for (const c of tokenCandidates) {
      const t = String(c || '').trim();
      if (t && !seen.has(t)) { seen.add(t); tokens.push(t); }
    }

    // Send FCM push (HIGH-9: track total failure so admin sees it)
    let fcmOk = 0;
    let fcmFail = 0;
    let lastFcmErr = '';
    for (const tok of tokens) {
      try {
        await admin.messaging().send({
          token: tok,
          notification: { title, body },
          data: { ...data, user_type: 'customer' },
          android: { priority: 'high', notification: { channelId: 'order_request_channel', sound: 'sound' } },
        });
        fcmOk += 1;
        console.log(`[push] Customer ${custUserId} notified via ${tok.substring(0, 15)}...`);
      } catch (fcmErr) {
        fcmFail += 1;
        lastFcmErr = fcmErr.message || String(fcmErr);
        console.warn(`[push] Customer FCM failed: ${lastFcmErr}`);
      }
    }
    const allFcmFailed = tokens.length > 0 && fcmOk === 0;
    if (allFcmFailed) {
      try {
        await logErrorToAdmin(
          'fcm_total_failure',
          `Customer push failed on ALL ${tokens.length} tokens for user ${custUserId}: ${lastFcmErr}`,
          'whatsapp_bot.notifyLinkedCustomer',
          lastFcmErr,
          (data && data.booking_id) || '',
          'high'
        );
      } catch (_) {}
    }

    // Write in-app notification
    await firestore.collection('notifications').add({
      user_id: custUserId,
      user_type: 'customer',
      title,
      message: body,
      type: data.type || 'status_update',
      booking_id: data.booking_id || '',
      read: false,
      view: false,
      push_delivery: tokens.length === 0 ? 'no_token' : (allFcmFailed ? 'failed' : (fcmFail > 0 ? 'partial' : 'sent')),
      push_tokens_total: tokens.length,
      push_tokens_ok: fcmOk,
      push_tokens_fail: fcmFail,
      created_at: new Date().toISOString(),
    });
  } catch (err) {
    console.warn(`[push] notifyLinkedCustomer failed: ${err.message}`);
  }
}

// ─── OpenAI ───

const OpenAI = require('openai');
const openai = new OpenAI({ apiKey: process.env.OPENAI_API_KEY });

// ─── WhatsApp Cloud API helper ───

const WA_API = 'https://graph.facebook.com/v19.0';

async function sendWhatsAppMessage(to, text) {
  const phoneId = process.env.WHATSAPP_PHONE_NUMBER_ID;
  const token   = process.env.WHATSAPP_ACCESS_TOKEN;
  if (!phoneId || !token) { console.error('[wa] Missing credentials'); return { ok: false, error: 'no_credentials' }; }

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
    if (!res.ok) {
      const errText = await res.text();
      console.error('[wa] send failed:', errText);
      return { ok: false, status: res.status, error: errText.slice(0, 500) };
    }
    return { ok: true };
  } catch (e) {
    console.error('[wa] sendWhatsAppMessage error:', e.message);
    return { ok: false, error: String(e.message) };
  }
}

async function sendWhatsAppImage(to, imageUrl, caption) {
  const phoneId = process.env.WHATSAPP_PHONE_NUMBER_ID;
  const token   = process.env.WHATSAPP_ACCESS_TOKEN;
  if (!phoneId || !token) { console.error('[wa-image] Missing credentials'); return { ok: false, error: 'no_credentials' }; }
  if (!imageUrl || !/^https?:\/\//i.test(imageUrl)) {
    console.warn('[wa-image] skipping, invalid url:', imageUrl);
    return { ok: false, error: 'invalid_url' };
  }

  // Pre-flight: make sure the URL resolves and returns an image content-type.
  // LOW-20: retry HEAD once on 5xx so a transient upstream blip doesn't
  // drop the product image entirely. 4xx is fatal (no retry).
  let headOkOrFatal = false;
  let lastHeadErr = '';
  for (let attempt = 0; attempt < 2 && !headOkOrFatal; attempt++) {
    try {
      const head = await fetch(imageUrl, { method: 'HEAD', signal: AbortSignal.timeout(6000), redirect: 'follow' });
      if (head.ok) {
        const ct = String(head.headers.get('content-type') || '').toLowerCase();
        if (!ct.startsWith('image/')) {
          console.warn('[wa-image] wrong content-type:', ct, imageUrl);
          return { ok: false, error: `bad_ct_${ct}` };
        }
        headOkOrFatal = true;
        break;
      }
      lastHeadErr = `head_${head.status}`;
      if (head.status < 500) {
        console.warn('[wa-image] HEAD failed', head.status, imageUrl);
        return { ok: false, error: lastHeadErr };
      }
      console.warn(`[wa-image] HEAD ${head.status} (attempt ${attempt + 1}/2), retrying:`, imageUrl);
    } catch (e) {
      lastHeadErr = 'head_error';
      console.warn(`[wa-image] HEAD error (attempt ${attempt + 1}/2):`, e.message, imageUrl);
    }
    if (!headOkOrFatal && attempt === 0) await new Promise(r => setTimeout(r, 500));
  }
  if (!headOkOrFatal) return { ok: false, error: lastHeadErr || 'head_error' };

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
    if (!res.ok) {
      const errBody = await res.text().catch(() => '');
      console.error('[wa-image] send failed:', res.status, errBody);
      return { ok: false, error: `send_${res.status}`, detail: errBody.slice(0, 300) };
    }
    return { ok: true };
  } catch (e) {
    console.error('[wa-image] error:', e.message);
    return { ok: false, error: e.message };
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

// ─── Chat logging (Firestore wa_chat_logs) ───

async function logChatMessage(phone, direction, text, opts = {}) {
  const firestore = db();
  if (!firestore) return;
  try {
    const chatRef = firestore.collection('wa_chat_logs').doc(phone);
    const msgData = {
      direction,             // 'incoming' or 'outgoing'
      text: (text || '').substring(0, 5000),
      messageType: opts.messageType || 'text',
      timestamp: admin.firestore.FieldValue.serverTimestamp(),
      linkedUserId: opts.linkedUserId || null,
      toolsCalled: opts.toolsCalled || [],
      bookingRef: opts.bookingRef || null,
    };
    // HIGH-8: log write failures so admin sees chat-history loss instead of
    // the prior silent .catch(()=>{}).
    chatRef.collection('messages').add(msgData).catch(err => {
      console.warn('[chatLog] message add failed:', err.message);
      logErrorToAdmin('chat_log_write_failure', `wa_chat_logs message add failed for ${phone}: ${err.message}`, 'whatsapp_bot.logChatMessage', err.message, opts.bookingRef || '', 'medium').catch(() => {});
    });
    // Update conversation summary
    chatRef.set({
      phone,
      lastMessage: (text || '').substring(0, 200),
      lastDirection: direction,
      lastActivity: admin.firestore.FieldValue.serverTimestamp(),
      linkedUserId: opts.linkedUserId || null,
      displayName: opts.displayName || null,
    }, { merge: true }).catch(err => {
      console.warn('[chatLog] summary set failed:', err.message);
      logErrorToAdmin('chat_log_write_failure', `wa_chat_logs summary set failed for ${phone}: ${err.message}`, 'whatsapp_bot.logChatMessage', err.message, opts.bookingRef || '', 'medium').catch(() => {});
    });
  } catch (e) {
    console.error('[chatLog] Error:', e.message);
  }
}

// ─── Download media from WhatsApp Cloud API ───

async function downloadWhatsAppMedia(mediaId, opts = {}) {
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
    // LOW-21: tell the customer why their file was dropped instead of
    // failing silently. Caller passes { phone } when known.
    if (buffer.length > 10 * 1024 * 1024) {
      const sizeMb = (buffer.length / 1024 / 1024).toFixed(1);
      console.warn(`[wa-media] Buffer too large (${sizeMb}MB), skipping`);
      if (opts.phone) {
        try {
          await sendWhatsAppMessage(opts.phone,
            `⚠️ That file is too large (${sizeMb}MB). Please send a smaller image or short video (under 10MB).`);
        } catch (_) {}
      }
      return null;
    }
    const mimeType = meta.mime_type || 'image/jpeg';
    // Validate MIME type and magic bytes BEFORE we hand the buffer off to
    // Storage. Without this, an attacker could upload arbitrary binaries
    // (e.g. malware, scripts) by labelling them as `image/jpeg`. We accept
    // only the formats Meta WhatsApp itself emits for image/voice/document
    // capture: jpeg, png, webp, ogg/opus (voice notes), mp4 (video).
    const isImage = mimeType.startsWith('image/');
    if (isImage) {
      const allowedImage = new Set(['image/jpeg', 'image/jpg', 'image/png', 'image/webp']);
      if (!allowedImage.has(mimeType.toLowerCase())) {
        console.warn(`[wa-media] rejected disallowed image mime: ${mimeType}`);
        return null;
      }
      // Magic-byte sniffing — first few bytes must match the claimed type
      const b = buffer;
      const looksJpeg = b.length >= 3 && b[0] === 0xFF && b[1] === 0xD8 && b[2] === 0xFF;
      const looksPng  = b.length >= 8 && b[0] === 0x89 && b[1] === 0x50 && b[2] === 0x4E && b[3] === 0x47;
      const looksWebp = b.length >= 12 && b.slice(0, 4).toString('ascii') === 'RIFF' && b.slice(8, 12).toString('ascii') === 'WEBP';
      if (!(looksJpeg || looksPng || looksWebp)) {
        console.warn(`[wa-media] image magic-bytes mismatch (mime=${mimeType}, first=${b.slice(0,4).toString('hex')})`);
        return null;
      }
    }
    const base64 = buffer.toString('base64');
    return { base64, mimeType, dataUrl: `data:${mimeType};base64,${base64}`, buffer };
  } catch (e) {
    console.error('[wa-media] error:', e.message);
    // Log media download failure to admin
    logErrorToAdmin('media_download_error', 'WhatsApp media download failed', 'whatsapp_bot', e.message).catch(() => {});
    return null;
  }
}

// ─── BHV-15: delete photos from Firebase Storage by public download URL ───
// Used when a booking/RFQ is cancelled so abandoned photos don't accumulate.
// Best-effort: never throws; logs counts. Accepts an array of URLs (any shape).
async function deleteStoragePhotos(urls, context) {
  try {
    if (!Array.isArray(urls) || urls.length === 0) return { deleted: 0, skipped: 0 };
    const bucketName = 'promaintapp-b618a.firebasestorage.app';
    const bucket = admin.storage().bucket(bucketName);
    let deleted = 0, skipped = 0;
    // Dedup
    const seen = new Set();
    for (const raw of urls) {
      const u = String(raw || '').trim();
      if (!u || seen.has(u)) { skipped++; continue; }
      seen.add(u);
      // Match: https://storage.googleapis.com/<bucket>/<path>
      // Tolerate alternative bucket alias forms (firebasestorage.googleapis.com etc.).
      let path = null;
      const m1 = u.match(/^https?:\/\/storage\.googleapis\.com\/[^/]+\/(.+?)(?:\?.*)?$/i);
      if (m1) path = decodeURIComponent(m1[1]);
      else {
        const m2 = u.match(/^https?:\/\/firebasestorage\.googleapis\.com\/v0\/b\/[^/]+\/o\/([^?]+)/i);
        if (m2) path = decodeURIComponent(m2[1]);
      }
      if (!path || !path.startsWith('booking_images/')) { skipped++; continue; }
      try {
        await bucket.file(path).delete({ ignoreNotFound: true });
        deleted++;
      } catch (e) {
        skipped++;
        console.warn(`[storage-cleanup] delete failed ${path}:`, e.message);
      }
    }
    if (deleted || skipped) {
      console.log(`[storage-cleanup] ${context || 'cleanup'}: deleted=${deleted} skipped=${skipped} of ${urls.length}`);
    }
    return { deleted, skipped };
  } catch (e) {
    console.warn('[storage-cleanup] fatal:', e.message);
    return { deleted: 0, skipped: 0, error: e.message };
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
      whatsapp_bot_error: 'WhatsApp Bot Error',
      whatsapp_vision_error: 'WhatsApp Photo Analysis Failed',
    };
    const label = labels[errorType] || `System Error: ${errorType}`;
    const title = `${icons[sev] || '🔵'} ${label}`;

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

    const basePayload = {
      title,
      message: description, // admin popup service reads 'message'
      body: description,
      type: 'error_report',
      error_type: errorType,
      error_id: errorId,
      booking_id: bookingId || '',
      severity: sev,
      target: 'admin',
      user_type: 'admin',
      read: false,
      timestamp: admin.firestore.FieldValue.serverTimestamp(),
      created_at: admin.firestore.FieldValue.serverTimestamp(),
    };

    // Generic admin notification
    await firestore.collection('notifications').add({
      ...basePayload,
      user_id: 'admin',
    });

    // Per-admin docs + FCM push so OS tray lights up when app is closed
    try {
      const adminSnap = await firestore.collection('users')
        .where('isAdmin', '==', true)
        .limit(25)
        .get();

      const TOKEN_FIELDS_SINGLE = ['deviceToken', 'device_token', 'fcm_token', 'fcmToken', 'token', 'push_token', 'pushToken'];
      const TOKEN_FIELDS_LIST = ['tokens', 'fcm_tokens', 'deviceTokens'];
      const tokens = [];
      const tokenSet = new Set();
      const perAdminWrites = [];

      for (const doc of adminSnap.docs) {
        const data = doc.data() || {};
        perAdminWrites.push(firestore.collection('notifications').add({
          ...basePayload,
          user_id: doc.id,
        }));
        for (const f of TOKEN_FIELDS_SINGLE) {
          const t = String(data[f] || '').trim();
          if (t && !tokenSet.has(t)) { tokenSet.add(t); tokens.push(t); }
        }
        for (const f of TOKEN_FIELDS_LIST) {
          const list = data[f];
          if (!Array.isArray(list)) continue;
          for (const item of list) {
            const t = String(item || '').trim();
            if (t && !tokenSet.has(t)) { tokenSet.add(t); tokens.push(t); }
          }
        }
      }
      await Promise.all(perAdminWrites).catch(() => {});

      if (tokens.length > 0) {
        try {
          const resp = await admin.messaging().sendEachForMulticast({
            tokens,
            notification: { title, body: String(description || '').slice(0, 240) },
            data: {
              type: 'error_report',
              error_type: String(errorType || ''),
              error_id: String(errorId || ''),
              severity: String(sev || ''),
              booking_id: String(bookingId || ''),
            },
            android: {
              priority: 'high',
              notification: { channelId: 'high_importance_channel' },
            },
            apns: { payload: { aps: { sound: 'default', badge: 1 } } },
          });
          console.log(`[errorReport] FCM push: ${resp.successCount}/${tokens.length} delivered for error=${errorId}`);
        } catch (fcmErr) {
          console.warn('[errorReport] FCM multicast failed:', fcmErr && fcmErr.message);
        }
      } else {
        console.warn('[errorReport] No admin FCM tokens found — push not sent.');
      }
    } catch (fanoutErr) {
      console.warn('[errorReport] admin fanout failed:', fanoutErr && fanoutErr.message);
    }

    return errorId;
  } catch (err) {
    console.error('[errorReport] Failed to log error:', err.message);
    return null;
  }
}

// ─── Admin push helper: creates a notification doc AND fires FCM to every admin device ───
// Use this for non-error events (new RFQ, quote accepted, escalation etc) where we want
// the admin phone to light up even when the app is closed.
async function pushAdminNotification({ title, body, type, bookingId = '', extraData = {} }) {
  if (!firestore) return;
  try {
    const notifPayload = {
      title: String(title || 'Square 15'),
      body: String(body || '').slice(0, 500),
      type: String(type || 'admin_event'),
      user_type: 'admin',
      booking_id: String(bookingId || ''),
      read: false,
      source: 'whatsapp_bot',
      timestamp: admin.firestore.FieldValue.serverTimestamp(),
      created_at: admin.firestore.FieldValue.serverTimestamp(),
    };
    await firestore.collection('notifications').add({ ...notifPayload, user_id: 'admin' });

    const adminSnap = await firestore.collection('users').where('isAdmin', '==', true).limit(25).get();
    const TOKEN_FIELDS_SINGLE = ['deviceToken', 'device_token', 'fcm_token', 'fcmToken', 'token', 'push_token', 'pushToken'];
    const TOKEN_FIELDS_LIST = ['tokens', 'fcm_tokens', 'deviceTokens'];
    const tokens = [];
    const tokenSet = new Set();
    const perAdminWrites = [];
    for (const doc of adminSnap.docs) {
      const data = doc.data() || {};
      perAdminWrites.push(firestore.collection('notifications').add({ ...notifPayload, user_id: doc.id }));
      for (const f of TOKEN_FIELDS_SINGLE) {
        const t = String(data[f] || '').trim();
        if (t && !tokenSet.has(t)) { tokenSet.add(t); tokens.push(t); }
      }
      for (const f of TOKEN_FIELDS_LIST) {
        const list = data[f];
        if (!Array.isArray(list)) continue;
        for (const item of list) {
          const t = String(item || '').trim();
          if (t && !tokenSet.has(t)) { tokenSet.add(t); tokens.push(t); }
        }
      }
    }
    await Promise.all(perAdminWrites).catch(() => {});
    if (!tokens.length) {
      console.warn(`[adminPush:${type}] no admin tokens found (admins=${adminSnap.size})`);
      try {
        await firestore.collection('errorLogs').add({
          type: 'fcm_no_admin_tokens',
          severity: 'high',
          source: 'whatsapp_bot',
          message: `No FCM tokens found on any admin user — push for "${notifPayload.title}" was not delivered. Admins must sign in to the admin app at least once so their device token is saved.`,
          context: `admins_found=${adminSnap.size}; type=${type}; booking_id=${notifPayload.body}`,
          created_at: admin.firestore.FieldValue.serverTimestamp(),
        });
      } catch (_) {}
      return;
    }
    try {
      const data = { type: notifPayload.type, booking_id: notifPayload.booking_id };
      for (const [k, v] of Object.entries(extraData || {})) data[k] = String(v == null ? '' : v).slice(0, 500);
      const resp = await admin.messaging().sendEachForMulticast({
        tokens,
        notification: { title: notifPayload.title, body: notifPayload.body },
        data,
        android: { priority: 'high', notification: { channelId: 'high_importance_channel' } },
        apns: { payload: { aps: { sound: 'default', badge: 1 } } },
      });
      console.log(`[adminPush:${type}] FCM ${resp.successCount}/${tokens.length} delivered`);
    } catch (fcmErr) {
      console.warn(`[adminPush:${type}] FCM multicast failed:`, fcmErr && fcmErr.message);
    }
  } catch (e) {
    console.warn('[adminPush] failed:', e && e.message);
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

// ─── Natural-language schedule parser ───
// Returns { date: 'YYYY-MM-DD', time: 'HH:MM' | '' } or null.
// Handles: today, tomorrow, weekday names ("Friday", "next Monday"),
// time-of-day hints ("morning"=08:00, "afternoon"=13:00, "evening"=17:00),
// numeric times ("at 2pm", "14:00"), and DD/MM[/YYYY] dates.
function parseScheduleFromText(input) {
  if (!input || typeof input !== 'string') return null;
  const txt = input.trim().toLowerCase();
  if (!txt) return null;

  const now = new Date();
  const pad = (n) => String(n).padStart(2, '0');
  const fmt = (d) => `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
  const weekdayMap = { sun: 0, sunday: 0, mon: 1, monday: 1, tue: 2, tues: 2, tuesday: 2, wed: 3, weds: 3, wednesday: 3, thu: 4, thur: 4, thurs: 4, thursday: 4, fri: 5, friday: 5, sat: 6, saturday: 6 };
  const monthMap = { jan: 0, january: 0, feb: 1, february: 1, mar: 2, march: 2, apr: 3, april: 3, may: 4, jun: 5, june: 5, jul: 6, july: 6, aug: 7, august: 7, sep: 8, sept: 8, september: 8, oct: 9, october: 9, nov: 10, november: 10, dec: 11, december: 11 };

  let date = null;

  // 1) "today" / "tomorrow"
  if (/\btoday\b/.test(txt)) {
    date = new Date(now);
  } else if (/\btomorrow\b/.test(txt)) {
    date = new Date(now); date.setDate(date.getDate() + 1);
  }

  // 2) Weekday names (with optional "next")
  if (!date) {
    const wkMatch = txt.match(/\b(next\s+)?(sun|mon|tue|tues|wed|weds|thu|thur|thurs|fri|sat|sunday|monday|tuesday|wednesday|thursday|friday|saturday)\b/);
    if (wkMatch) {
      const target = weekdayMap[wkMatch[2]];
      const cur = now.getDay();
      let delta = (target - cur + 7) % 7;
      if (delta === 0) delta = 7; // "Friday" said on Friday → next Friday
      if (wkMatch[1] && delta < 7) delta += 7; // "next" → following week if same week
      date = new Date(now); date.setDate(date.getDate() + delta);
    }
  }

  // 3) "27 Apr" / "Apr 27" / "27 April 2026"
  if (!date) {
    let m = txt.match(/\b(\d{1,2})\s+(jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec|january|february|march|april|june|july|august|september|october|november|december)(?:\s+(\d{2,4}))?\b/);
    if (!m) m = txt.match(/\b(jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec|january|february|march|april|june|july|august|september|october|november|december)\s+(\d{1,2})(?:[, ]+(\d{2,4}))?\b/);
    if (m) {
      let day, mon, yr;
      if (/^\d/.test(m[1])) { day = parseInt(m[1], 10); mon = monthMap[m[2]]; yr = m[3] ? parseInt(m[3], 10) : now.getFullYear(); }
      else { mon = monthMap[m[1]]; day = parseInt(m[2], 10); yr = m[3] ? parseInt(m[3], 10) : now.getFullYear(); }
      if (yr < 100) yr += 2000;
      const candidate = new Date(yr, mon, day);
      if (!isNaN(candidate.getTime())) {
        // If date is already in the past, bump to next year.
        const today0 = new Date(now); today0.setHours(0, 0, 0, 0);
        if (candidate < today0) candidate.setFullYear(candidate.getFullYear() + 1);
        date = candidate;
      }
    }
  }

  // 4) DD/MM or DD/MM/YYYY
  if (!date) {
    const m = txt.match(/\b(\d{1,2})[\/\-](\d{1,2})(?:[\/\-](\d{2,4}))?\b/);
    if (m) {
      const day = parseInt(m[1], 10), mon = parseInt(m[2], 10) - 1;
      let yr = m[3] ? parseInt(m[3], 10) : now.getFullYear();
      if (yr < 100) yr += 2000;
      const candidate = new Date(yr, mon, day);
      if (!isNaN(candidate.getTime())) {
        const today0 = new Date(now); today0.setHours(0, 0, 0, 0);
        if (candidate < today0) candidate.setFullYear(candidate.getFullYear() + 1);
        date = candidate;
      }
    }
  }

  // 5) Time parsing
  let time = '';
  // HH:MM with optional am/pm suffix (e.g. "10:00am", "2:30 pm", "14:00").
  // The original regex used \b after \d{2}, which fails for "10:00am" because
  // there is no word boundary between '0' and 'a' (both are word chars).
  let timeMatch = txt.match(/\b(\d{1,2}):(\d{2})\s*(am|pm)?\b/);
  if (timeMatch) {
    let hh = parseInt(timeMatch[1], 10);
    const mm = parseInt(timeMatch[2], 10);
    const ampm = timeMatch[3];
    if (ampm === 'pm' && hh < 12) hh += 12;
    if (ampm === 'am' && hh === 12) hh = 0;
    if (hh >= 0 && hh < 24 && mm >= 0 && mm < 60) time = `${pad(hh)}:${pad(mm)}`;
  }
  if (!time) {
    timeMatch = txt.match(/\b(\d{1,2})\s*(am|pm)\b/);
    if (timeMatch) {
      let hh = parseInt(timeMatch[1], 10);
      if (timeMatch[2] === 'pm' && hh < 12) hh += 12;
      if (timeMatch[2] === 'am' && hh === 12) hh = 0;
      time = `${pad(hh)}:00`;
    }
  }
  if (!time) {
    if (/\b(morning)\b/.test(txt)) time = '08:00';
    else if (/\b(noon|midday)\b/.test(txt)) time = '12:00';
    else if (/\b(afternoon)\b/.test(txt)) time = '13:00';
    else if (/\b(evening|tonight)\b/.test(txt)) time = '17:00';
  }

  if (!date) return null;
  // Don't accept past dates
  const today0 = new Date(now); today0.setHours(0, 0, 0, 0);
  if (date < today0) return null;
  return { date: fmt(date), time };
}

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

// ─── Per-phone async mutex ─────────────────────────────────────────────────
// Prevents two webhook requests for the same phone from interleaving session
// reads/writes (e.g. clobbering lastRfqId or messages[] history).
const _phoneLocks = new Map(); // phone → Promise tail
function withPhoneLock(phone, fn) {
  const prev = _phoneLocks.get(phone) || Promise.resolve();
  const next = prev.catch(() => {}).then(fn);
  _phoneLocks.set(phone, next);
  // Clean up when done so the Map doesn't grow unbounded.
  next.finally(() => {
    if (_phoneLocks.get(phone) === next) _phoneLocks.delete(phone);
  });
  return next;
}

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

      // HIGH-7: race-guard the escalation against manual admin assignment
      // happening at the same moment. Only flip to admin_review if the doc
      // is STILL in pending_artisan_acceptance.
      let escalated = false;
      try {
        await firestore.runTransaction(async (txn) => {
          const fresh = await txn.get(doc.ref);
          if (!fresh.exists) return;
          const fd = fresh.data() || {};
          const curStatus = String(fd.status || '').toLowerCase();
          if (curStatus !== 'pending_artisan_acceptance') {
            console.log(`[timeout] Booking ${doc.id} no longer pending_artisan_acceptance (now=${curStatus}) — skipping escalation`);
            return;
          }
          txn.update(doc.ref, {
            status: 'pending_admin_review',
            rfq_status: 'timeout_escalated',
            rfq_timeout_at: new Date().toISOString(),
            rfq_timeout_reason: `No artisan accepted within 30 minutes (${rejCount} rejections)`,
            updated_at: new Date().toISOString(),
          });
          escalated = true;
        });
      } catch (txErr) {
        console.warn(`[timeout] transaction failed for ${doc.id}:`, txErr.message);
        continue;
      }
      if (!escalated) continue;
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
    const PHOTO_TTL_MS = 10 * 60 * 1000;
    const RFQ_PTR_TTL_MS = 20 * 60 * 1000;
    const ageMs = Date.now() - lastTs;
    if (Array.isArray(data.messages) && data.messages.length > 0) {
      let restored = data.messages;
      // BHV-7: prune stale photo-analysis context. If photoUrls have aged
      // out (>10 min), the assistant's earlier vision read of those photos
      // ("I see a frameless shower door…") is misleading — the customer's
      // next photo batch is likely a different product. Drop the
      // image-bearing user message AND the assistant reply immediately
      // following it, so the matcher runs fresh against the new photos.
      if (ageMs > PHOTO_TTL_MS) {
        const isImageMsg = (m) => m && m.role === 'user' && Array.isArray(m.content)
          && m.content.some(c => c && c.type === 'text' && typeof c.text === 'string' && c.text.includes('[image sent]'));
        const filtered = [];
        let droppedAny = false;
        for (let i = 0; i < restored.length; i++) {
          const m = restored[i];
          if (isImageMsg(m)) {
            droppedAny = true;
            // Also skip the next assistant message (the vision analysis reply).
            if (restored[i + 1] && restored[i + 1].role === 'assistant') i += 1;
            continue;
          }
          filtered.push(m);
        }
        if (droppedAny) {
          console.log(`[session] BHV-7: pruned stale photo-analysis context (age ${Math.round(ageMs/1000)}s > ${PHOTO_TTL_MS/1000}s); ${restored.length - filtered.length} msg(s) dropped`);
        }
        restored = filtered;
      }
      session.messages = restored;
      // Drop orphaned tool messages at the start
      while (session.messages.length > 0 && session.messages[0].role === 'tool') {
        session.messages.shift();
      }
    }
    // Restore linked account
    if (data.linkedUserId) session.linkedUserId = data.linkedUserId;
    // HIGH-4: per-field TTL on volatile context (photos, RFQ pointer).
    // Without this we restore 29-min-old photo URLs (likely deleted from
    // Storage already) and stale lastRfqId pointers from cancelled RFQs.
    if (ageMs <= PHOTO_TTL_MS && Array.isArray(data.photoUrls) && data.photoUrls.length > 0) {
      session.photoUrls = data.photoUrls;
    }
    if (data.lastBookingId) session.lastBookingId = data.lastBookingId;
    if (data.lastBookingCost) session.lastBookingCost = data.lastBookingCost;
    if (ageMs <= RFQ_PTR_TTL_MS && data.lastRfqId) session.lastRfqId = data.lastRfqId;
    if (data.pendingRatingBookingId) session.pendingRatingBookingId = data.pendingRatingBookingId;
    if (data.sharedAddress) session.sharedAddress = data.sharedAddress;
    if (data.sharedLatitude) session.sharedLatitude = data.sharedLatitude;
    if (data.sharedLongitude) session.sharedLongitude = data.sharedLongitude;
    // BHV-10: TTL on promo restore. Promos can be disabled by admin between
    // sessions; if a session is older than 30 min, force the customer to
    // re-apply so we re-validate against the live promo_codes collection.
    const PROMO_TTL_MS = 30 * 60 * 1000;
    if (ageMs <= PROMO_TTL_MS && data.promoCode) {
      session.promoCode = data.promoCode;
      session.promoDiscount = data.promoDiscount || 0;
      session.promoDiscountType = data.promoDiscountType || 'fixed';
      if (data.promoId) session.promoId = data.promoId;
    } else if (data.promoCode) {
      console.log(`[session] Promo ${data.promoCode} not restored (age ${Math.round(ageMs/1000)}s > ${PROMO_TTL_MS/1000}s TTL) — customer must re-apply`);
    }
    console.log(`[session] Restored ${maskPhone(session.phone)} from Firestore (${session.messages.length} msgs, ${session.photoUrls.length} photos)`);
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
    const digitsOnly = String(v).replace(/\D/g, '');
    if (!digitsOnly) continue;
    const n = parseInt(digitsOnly, 10);
    if (Number.isFinite(n)) numericVariants.add(n);
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

// ─────────────────────────────────────────────────────────────────────────
// SHARED FIXED-PRICE MATCHER (BHV-2 — May 3 2026)
// Single source of truth for matching a customer's job description against
// the admin-managed `tasks` collection. Previously duplicated in BOTH
// `case 'lookup_pricing'` AND `case 'create_booking'` with subtly different
// helper names and a third copy in livekit-backend. The R480 "shower door
// installation" bug took TWO commits to fix because the second copy was
// missed. From now on, every call site uses this function.
//
// Inputs:
//   subcategory  — the customer's specific job phrase ("shower door installation")
//   description  — fallback if subcategory empty
//   category     — slug or name (used for synonym expansion only)
//   taskResults  — pre-fetched array of {name, cost, category_id, category_name}
//
// Output: { matched: bool, name?, cost?, score?, action?, sharedCount?,
//           category_name?, rejected: [...debug info] }
//
// Guards (DO NOT WEAKEN — every guard exists because of a real customer incident):
//  1. Stopword filter: generic words ("repair","door","shower" alone) don't count.
//  2. Action verb compatibility: install ≠ replace ≠ repair ≠ paint.
//  3. "Labour only" tasks require explicit ask.
//  4. Score floor: 70 normal, 85 for install/replace.
//  5. Hardware-install guard (May 3 2026): install/replace requires substring
//     containment OR ≥2 distinctive shared words.
//  6. Suspicious-low-cost gate (May 3 2026): install/replace match < R800 → discard.
// ─────────────────────────────────────────────────────────────────────────
const _MATCHER_STOPWORDS = new Set([
  'repair','repairs','repairing','fix','fixing','fixes',
  'install','installation','installing','installs',
  'replace','replacement','replacing','replaces','swap','swapping','change',
  'service','services','servicing','maintain','maintenance',
  'general','standard','basic','simple',
  'work','works','job','jobs','task','tasks',
  'problem','problems','issue','issues',
  'need','needs','want','wants',
  'please','help','quote','price','pricing','cost',
  'home','house','room','door','window','wall','floor','frame',
]);
const _MATCHER_SYNONYMS = {
  plumbing:    ['toilet','cistern','basin','bath','tap','pipe','drain','geyser','shower','sink','plumb','blocked','leak','water','bathroom','kitchen'],
  electrical:  ['light','switch','socket','wire','wiring','breaker','db board','plug','circuit','electric','power','volt'],
  painting:    ['paint','wall','ceiling','enamel','pva','varnish','roof','garage','door'],
  cleaning:    ['clean','wash','deep clean','carpet','window','scrub'],
  tiling:      ['tile','floor','grout','ceramic'],
  carpentry:   ['wood','cabinet','shelf','cupboard','door','frame','carpenter'],
  solar:       ['panel','pv','inverter','battery','geyser','energy'],
  maintenance: ['repair','fix','maintain','service','general'],
  bathroom:    ['toilet','cistern','basin','bath','shower','tap','plumb','blocked','drain'],
  kitchen:     ['tap','mixer','sink','faucet','cupboard'],
  door:        ['lock','handle','hinge','frame','door'],
  window:      ['glass','pane','frame','window'],
  installation:['install','setup','mount','fit'],
};
const _MATCHER_ACTIONS = {
  install:  ['install','installation','installing','installs','fit','fitting','mount','mounting','setup','set'],
  replace:  ['replace','replacement','replacing','replaces','swap','swapping','change'],
  repair:   ['repair','repairs','repairing','fix','fixing','fixes','mend','mending'],
  inspect:  ['inspect','inspection','inspecting','check','checking','assess','assessment','report'],
  clean:    ['clean','cleaning','wash','washing','scrub','scrubbing'],
  unblock:  ['unblock','unblocking','clear','clearing'],
  service:  ['service','servicing','maintain','maintenance'],
  paint:    ['paint','painting','varnish','varnishing','enamel'],
};

function _matcherNormalize(s) { return String(s || '').toLowerCase().replace(/[_\-]+/g, ' ').trim(); }
function _matcherStem(w) { return w.replace(/(ing|ed|tion|ment|ness|able|ible|er|est|ly|s)$/i, ''); }
function _matcherDistinctive(words) { return words.filter(w => !_MATCHER_STOPWORDS.has(w) && !_MATCHER_STOPWORDS.has(_matcherStem(w))); }
function _matcherActionOf(text) {
  const tokens = String(text || '').toLowerCase().split(/[^a-z]+/).filter(Boolean);
  for (const tk of tokens) {
    for (const [grp, verbs] of Object.entries(_MATCHER_ACTIONS)) {
      if (verbs.includes(tk)) return grp;
    }
  }
  return null;
}
function _matcherFuzzy(qNorm, sNorm) {
  if (sNorm === qNorm) return true;
  const containHas = (phrase) => _matcherDistinctive(phrase.split(/\s+/).filter(w => w.length >= 3)).length >= 1;
  if (sNorm.includes(qNorm) && qNorm.length >= 4 && containHas(qNorm)) return true;
  if (qNorm.includes(sNorm) && sNorm.length >= 4 && containHas(sNorm)) return true;
  const qW = qNorm.split(/\s+/).filter(w => w.length >= 4);
  const sW = sNorm.split(/\s+/).filter(w => w.length >= 4);
  const qD = _matcherDistinctive(qW);
  const sD = _matcherDistinctive(sW);
  if (qD.some(w => sD.includes(w))) return true;
  const qS = qD.map(_matcherStem).filter(s => s.length >= 4);
  const sS = sD.map(_matcherStem).filter(s => s.length >= 4);
  if (qS.some(qs => sS.includes(qs))) return true;
  return false;
}
function _matcherScore(qNorm, sNorm) {
  if (sNorm === qNorm) return 100;
  if (sNorm.includes(qNorm)) return 90;
  if (qNorm.includes(sNorm)) return 85;
  const qW = qNorm.split(/\s+/).filter(w => w.length >= 3);
  const sW = sNorm.split(/\s+/).filter(w => w.length >= 3);
  const wordHits = qW.filter(w => sNorm.includes(w)).length + sW.filter(w => qNorm.includes(w)).length;
  if (wordHits >= 2) return 70 + wordHits;
  if (wordHits === 1) return 60;
  const qS = qW.map(_matcherStem), sS = sW.map(_matcherStem);
  const stemHits = qS.filter(qs => sS.some(ss => qs === ss || qs.includes(ss) || ss.includes(qs))).length;
  if (stemHits > 0) return 40 + stemHits;
  return 20;
}

/**
 * Find a fixed-price task matching the customer's request.
 * Returns { matched, name, cost, ... } or { matched: false, rejected: [...] }.
 */
function findFixedPriceMatch({ subcategory, description, taskResults }) {
  const subQuery = String(subcategory || description || '').toLowerCase();
  if (!subQuery) return { matched: false, rejected: [] };
  const subNorm = _matcherNormalize(subQuery);
  const qAction = _matcherActionOf(subQuery);
  const askedLabourOnly = /\b(lab[ou]r)\s*only\b/i.test(subQuery);
  const qWordsAll = subNorm.split(/\s+/).filter(w => w.length >= 3);
  const qDistinctive = _matcherDistinctive(qWordsAll);
  const isHardwareInstall = qAction === 'install' || qAction === 'replace';

  let bestMatch = null;
  const rejected = [];
  for (const t of taskResults || []) {
    if (!t || !t.name || !(t.cost > 0)) continue;
    const tNorm = _matcherNormalize(t.name);

    if (!_matcherFuzzy(subNorm, tNorm)) continue;

    const sAction = _matcherActionOf(t.name);
    if (qAction && sAction && qAction !== sAction) {
      rejected.push({ name: t.name, reason: `action-mismatch q=${qAction} s=${sAction}` });
      continue;
    }

    const isLabourOnly = /\b(lab[ou]r)\s*only\b/i.test(t.name);
    if (isLabourOnly && !askedLabourOnly) {
      rejected.push({ name: t.name, reason: 'labour-only-not-asked' });
      continue;
    }

    const tWordsAll = tNorm.split(/\s+/).filter(w => w.length >= 3);
    const tDistinctive = _matcherDistinctive(tWordsAll);
    const sharedDistinctive = qDistinctive.filter(w => tDistinctive.includes(w) || tWordsAll.includes(w));

    if (qDistinctive.length > 0 && sharedDistinctive.length === 0) {
      rejected.push({ name: t.name, reason: 'no-distinctive-overlap' });
      continue;
    }

    if (isHardwareInstall) {
      const containment = tNorm.includes(subNorm) || subNorm.includes(tNorm);
      if (!containment && sharedDistinctive.length < 2) {
        rejected.push({ name: t.name, reason: `hw-install-needs-2-distinctive-or-containment (had ${sharedDistinctive.length})` });
        continue;
      }
    }

    const score = _matcherScore(subNorm, tNorm);
    const minScore = isHardwareInstall ? 85 : 70;
    if (score < minScore) {
      rejected.push({ name: t.name, reason: `score-${score}-min-${minScore}` });
      continue;
    }

    if (!bestMatch || score > bestMatch.score) {
      bestMatch = {
        name: t.name,
        cost: t.cost,
        score,
        action: qAction,
        sharedCount: sharedDistinctive.length,
        category_id: t.category_id || '',
        category_name: t.category_name || '',
      };
    }
  }

  // Suspicious-low-cost gate for install/replace.
  if (bestMatch && (bestMatch.action === 'install' || bestMatch.action === 'replace') && bestMatch.cost < 800) {
    rejected.push({ name: bestMatch.name, reason: `suspicious-low-cost-R${bestMatch.cost}-for-${bestMatch.action}` });
    bestMatch = null;
  }

  if (bestMatch) {
    return { matched: true, ...bestMatch, rejected };
  }
  return { matched: false, rejected };
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
          clientBudget: { type: 'number', description: 'Client stated budget in ZAR (ask them before calling submit_rfq). Pass 0 if the client explicitly said they have no budget in mind.' },
          materialChoice: { type: 'string', description: 'If materialsResponsibility=artisan and you already called show_material_options and the client picked one, pass the chosen option label (e.g. "Mid-range shower mixer").' },
          noPhotoReason: { type: 'string', description: 'Only set this if the customer explicitly says they cannot send a photo right now. Pass their stated reason (e.g. "client cannot take photo, away from site"). Otherwise leave blank — the bot will refuse the RFQ until at least one photo is received.' },
        },
        required: ['category', 'description', 'customerName', 'materialsResponsibility', 'clientBudget'],
      },
    },
  },
  {
    type: 'function',
    function: {
      name: 'show_material_options',
      description: 'Record what material/fixture the client wants the artisan to source, with whatever specs the client has shared so far. Use this when materialsResponsibility=artisan and the job needs a specific part/fixture. Call it ONCE PER DISTINCT MATERIAL (e.g. once for the geyser, once for the geyser blanket, once for the mounting kit). Our admin will then hand-pick the actual product on Builders Warehouse and send the photo + price to the client with the final quote. Capture: capacity/size, type/variant, brand preference (if any) and any other detail the client mentioned. NEVER attempt to send images or product links to the client yourself.',
      parameters: {
        type: 'object',
        properties: {
          category:        { type: 'string', description: 'Service category (e.g. plumbing, electrical, tiling, painting)' },
          itemType:        { type: 'string', description: 'Specific item, e.g. "solar geyser", "shower mixer", "toilet cistern", "ceiling light", "wall tile". Keep ALL qualifying words ("solar geyser", not "geyser").' },
          specSummary:     { type: 'string', description: 'One-line summary of the client-stated specs and intended use. Examples: "200L, roof-mount, family of 4", "chrome thermostatic, single-handle", "matte black, single-lever basin mixer".' },
          brandPreference: { type: 'string', description: 'Brand the client asked for (e.g. "Kwikot", "Apollo", "Cobra"). Use "any" or empty if no preference.' },
          qty:             { type: 'number', description: 'Quantity (default 1).' },
          unit:            { type: 'string', description: 'Unit of measure (default "ea"). Examples: "ea", "m", "m2", "kg", "set".' },
        },
        required: ['category', 'itemType', 'specSummary'],
      },
    },
  },
  {
    type: 'function',
    function: {
      name: 'request_quote_amendment',
      description: 'Use this when the client has already received a quote (status rfq_sent) and asks to change something (e.g. "swap the Apollo geyser for a Kwikot", "remove the geyser blanket", "use a cheaper mixer"). Logs the amendment for admin to action. NEVER use this before the client has received the quote.',
      parameters: {
        type: 'object',
        properties: {
          rfqId:         { type: 'string', description: 'The RFQ ID to amend. If omitted, uses the most recent RFQ in this conversation.' },
          amendmentText: { type: 'string', description: 'The client\'s exact words describing what they want changed.' },
        },
        required: ['amendmentText'],
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
      name: 'set_preferred_schedule',
      description: 'Capture the client\'s preferred date/time for a NEWLY ACCEPTED RFQ (after accept_rfq_quote). Use this — NOT reschedule_booking — the very first time the client tells you when they want the work done. This stores the preferred slot on the RFQ and notifies admin + the assigned artisan. Reschedule_booking is only for changing an already-scheduled booking.',
      parameters: {
        type: 'object',
        properties: {
          bookingId:     { type: 'string', description: 'The RFQ / booking ID (from session.lastRfqId or accept_rfq_quote response)' },
          preferredDate: { type: 'string', description: 'Preferred date in YYYY-MM-DD format. Convert vague phrases (e.g. "Friday morning") into the next matching calendar date in 2026.' },
          preferredTime: { type: 'string', description: 'Preferred time in HH:MM (24h). Use sensible defaults: morning=08:00, afternoon=13:00, evening=17:00.' },
          notes:         { type: 'string', description: 'Optional free text from the client (e.g. "after 4pm only", "weekends only").' },
        },
        required: ['bookingId', 'preferredDate'],
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

// Extract the OpenGraph / Twitter product image URL from a Builders product page HTML.
function extractOgImageFromHtml(html) {
  if (!html) return '';
  const tryMatch = (re) => { const m = html.match(re); return m && m[1] ? m[1].trim() : ''; };
  let u = tryMatch(/<meta[^>]+property=["']og:image["'][^>]+content=["']([^"']+)["']/i)
       || tryMatch(/<meta[^>]+content=["']([^"']+)["'][^>]+property=["']og:image["']/i)
       || tryMatch(/<meta[^>]+name=["']twitter:image["'][^>]+content=["']([^"']+)["']/i)
       || tryMatch(/<meta[^>]+content=["']([^"']+)["'][^>]+name=["']twitter:image["']/i);
  if (!u) {
    // JSON-LD image field
    const ld = html.match(/"image"\s*:\s*"([^"]+\.(?:jpg|jpeg|png|webp))"/i);
    if (ld && ld[1]) u = ld[1];
  }
  if (!u) return '';
  u = u.trim();
  if (u.startsWith('//')) u = 'https:' + u;
  if (u.startsWith('/')) u = 'https://www.builders.co.za' + u;
  if (!/^https?:\/\//i.test(u)) return '';
  return u;
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

// Extract a product image URL from a Builders BFF item (field names vary).
function extractImageFromBffItem(item) {
  if (!item || typeof item !== 'object') return '';
  const tryField = (v) => {
    if (!v) return '';
    if (typeof v === 'string') return v;
    if (Array.isArray(v) && v.length) {
      const f = v[0];
      if (typeof f === 'string') return f;
      if (f && typeof f === 'object') return _str(f.url || f.src || f.imageUrl || f.image || f.href || '');
    }
    if (typeof v === 'object') return _str(v.url || v.src || v.imageUrl || v.image || v.href || v.large || v.medium || v.default || '');
    return '';
  };
  const fields = ['image', 'images', 'imageUrl', 'imageURL', 'thumbnail', 'thumbnails', 'picture', 'pictures', 'primaryImage', 'mainImage', 'media'];
  for (const k of fields) {
    const u = tryField(item[k]);
    if (u && /^https?:\/\//i.test(u)) return u;
  }
  // Builders sometimes stores a code we can map to images.builders.co.za
  const code = _str(item.code || item.id || item.productCode);
  if (code && /^\d{4,8}$/.test(code)) return `https://images.builders.co.za/product/360/360/${code}.jpg`;
  return '';
}

// Live search against Builders BFF returning top N options with real image URLs.
// Used by browse_builders_materials tool and as a live source for show_material_options.
async function buildersSearchOptions(keyword, limit = 3) {
  try {
    const q = normalizeBuildersQuery(keyword);
    if (!q) return [];
    const cfg = await getBuildersBffConfig();
    if (!cfg) return [];
    const uri = `https://www.builders.co.za/wmapi/bff/graphql/${cfg.searchKey}/${cfg.searchHash}`;
    const r = await buildersFetch(uri, {
      method: 'POST',
      headers: buildersBffHeaders({ operationName: cfg.searchKey, operationHash: cfg.searchHash }),
      body: JSON.stringify({ variables: { keyword: q, offset: 0, pageSize: 24, dynamicPriceRange: true, site: cfg.site } }),
      timeoutMs: 12000,
    });
    if (!r.ok) return [];
    const decoded = await r.json().catch(() => null);
    const items = decoded?.data?.search?.data?.results?.items;
    if (!Array.isArray(items)) return [];
    const qt = new Set(buildersTokens(q));
    const scored = [];
    for (const it of items) {
      if (!it) continue;
      const title = _str(it.name || it.title || it.productName); if (!title) continue;
      let urlPath = _str(it.url || it.productUrl || it.seoUrl || it.link);
      if (!urlPath) { const code = _str(it.code || it.id || it.productCode); if (code) urlPath = `/p/${code}`; }
      if (!urlPath) continue;
      const url = urlPath.startsWith('http') ? urlPath : `https://www.builders.co.za${urlPath.startsWith('/') ? '' : '/'}${urlPath}`;
      const price = extractPriceFromBffItem(it) || 0;
      const image_url = extractImageFromBffItem(it);
      const tt = new Set(buildersTokens(title));
      let score = 0;
      for (const t of qt) if (tt.has(t)) score++;
      if (price > 0) score += 2;
      if (image_url) score += 1;
      scored.push({ score, option: { label: title.slice(0, 60), price, image_url, product_url: url } });
    }
    if (!scored.length) return [];
    scored.sort((a, b) => b.score - a.score);
    // Spread across low/mid/high price if we have enough distinct prices
    const withPrice = scored.filter(s => s.option.price > 0);
    let picks;
    if (withPrice.length >= limit) {
      const sorted = [...withPrice].sort((a, b) => a.option.price - b.option.price);
      picks = [];
      const idxs = [0, Math.floor(sorted.length / 2), sorted.length - 1];
      for (const i of idxs.slice(0, limit)) if (sorted[i] && !picks.includes(sorted[i])) picks.push(sorted[i]);
    } else {
      picks = scored.slice(0, limit);
    }
    const baseOptions = picks.map(p => p.option);
    // HYDRATE: fetch each product page to grab og:image (real product photo) and
    // (if missing) a price. This is what makes WhatsApp display actual images.
    const hydrated = await Promise.all(baseOptions.map(async (opt) => {
      try {
        const referer = `https://www.builders.co.za/search?text=${encodeURIComponent(q)}`;
        const res = await buildersFetch(opt.product_url, { headers: buildersHeaders({ referer }), timeoutMs: 15000 });
        if (!res.ok) return opt;
        const html = await res.text();
        if (!html) return opt;
        const og = extractOgImageFromHtml(html);
        if (og) opt.image_url = og;
        if (!(opt.price > 0)) {
          const p = extractRetailPriceFromHtml(html);
          if (p > 0) opt.price = p;
        }
        // Canonical URL from <link rel="canonical">
        const canon = html.match(/<link[^>]+rel=["']canonical["'][^>]+href=["']([^"']+)["']/i);
        if (canon && canon[1]) {
          let c = canon[1].trim();
          if (c.startsWith('//')) c = 'https:' + c;
          if (c.startsWith('/')) c = 'https://www.builders.co.za' + c;
          if (/^https?:\/\//i.test(c)) opt.product_url = c;
        }
      } catch (e) { /* keep baseline option */ }
      return opt;
    }));
    return hydrated;
  } catch (e) {
    console.error('[builders-search] error:', e.message);
    return [];
  }
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
  let contingencyPct = 0.15; // default 15%
  let materialMultiplierFromGuide = 1.5; // default markup on materials
  try {
    if (firestore) {
      const catSlug = (category || '').toLowerCase().replace(/\s+/g, '_');
      const guidanceDoc = await firestore.collection('pricingGuidance').doc(catSlug).get();
      if (guidanceDoc.exists) {
        const gd = guidanceDoc.data();
        laborRate = parseFloat(gd.labor_cost_per_hour || gd.laborCostPerHour || 150);
        const servicePrices = gd.service_prices || gd.servicePrices || {};
        if (gd.contingency_percentage != null) {
          contingencyPct = parseFloat(gd.contingency_percentage) / 100;
          if (isNaN(contingencyPct) || contingencyPct < 0) contingencyPct = 0.15;
        }
        const mm = parseFloat(gd.material_multiplier || gd.materialMultiplier);
        // Sanity floor: a multiplier < 1.0 means we'd CHARGE LESS than cost
        // (a "discount") — which has caused customer totals to omit markup
        // entirely (May 2026 incident: pricingGuidance/plumbing had 0.35).
        // Log + ignore bogus values so we always at least pass cost through.
        if (!isNaN(mm) && mm >= 1.0) {
          materialMultiplierFromGuide = mm;
        } else if (!isNaN(mm) && mm > 0) {
          console.warn(`[ai-quote] pricingGuidance/${catSlug}.material_multiplier=${mm} is < 1.0 (would discount materials below cost). Ignoring; using default ${materialMultiplierFromGuide}x.`);
        }
        pricingContext = `Labor rate for ${category}: R${laborRate}/hr. Known service prices: ${JSON.stringify(servicePrices)}. Contingency: ${(contingencyPct * 100).toFixed(0)}%. Material multiplier: ${materialMultiplierFromGuide}x`;
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

CRITICAL — MATERIALS COMPLETENESS:
- The materialsBOM MUST list EVERY consumable, fitting, fixing and installation accessory needed to complete the job from start to finish — not just the main item.
- Think like a plumber/electrician/installer doing the job: what would they put in their van besides the main product? Brackets, valves, pipes, fittings, fasteners, sealants, tapes, insulation, electrical cable, isolators, conduit, plaster, paint, grout, silicone, screws, anchors, etc. — include ALL of them.
- For SOLAR GEYSER INSTALLATION (200 L example): main collector + tank, mounting frame/brackets, vacuum tubes (if not integrated), high-pressure valve / pressure relief valve, vacuum breaker, expansion vessel, drip tray, electrical isolator + 2.5 mm² flex cable, 22 mm copper pipe + 22 mm fittings (elbows, tees, nuts), 22 mm pipe insulation lagging, mixing/tempering valve, gate valves, non-return valve, Teflon/PTFE tape, plumbing sealant, roof flashing, lag bolts/anchors, silicone, drain pipe + fittings.
- For GEYSER REPLACEMENT: vacuum breaker, drip tray, isolators, drain valve, flexi connectors, copper pipe + fittings, lagging, PTFE tape, silicone, brackets.
- For PLUMBING: pipe + fittings, valves, traps, brackets, PTFE tape, sealant, silicone.
- For ELECTRICAL: cable, conduit, isolators, glands, lugs, breakers, terminals, cable ties, insulation tape.
- Aim for 8–15 line items for any complex installation. Missing items make the quote inaccurate.
- Every material in materialsBOM MUST be a real product available on builders.co.za (Builders Warehouse). Do NOT include specialty items or proprietary accessories that Builders does not stock.
- Use realistic South African 2026 retail pricing (ZAR). Use specific brand names where relevant (Cobra, Plumbsure, Apollo, Kwikot, Cedar, Major Tech, ACDC, Abro, Sika, Den Braven). Return ONLY the JSON object.`;

  try {
    console.log(`[ai-quote] step=openai_request category=${category} matResp=${materialsResponsibility}`);
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
    console.log(`[ai-quote] step=openai_done`);

    const raw = completion.choices[0]?.message?.content || '{}';
    const draft = JSON.parse(raw);
    console.log(`[ai-quote] step=parsed bom_count=${(draft.materialsBOM || []).length} laborHours=${draft.laborHours}`);

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
    const materialsMultiplier = materialMultiplierFromGuide;
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
    const contingency = subtotal * contingencyPct;
    const grandTotal = subtotal + contingency;

    const buildersCount = materialsBOM.filter(b => b.matched_by && b.matched_by.startsWith('builders')).length;
    const catalogCount = materialsBOM.filter(b => b.matched_by && b.matched_by.startsWith('catalog')).length;
    const aiCount = materialsBOM.filter(b => b.matched_by === 'ai_estimate').length;

    const r2 = (v) => Math.round(v * 100) / 100;
    // Admin's Amend Quote dialog reads materialsPriced_reference / materialsUnpriced_reference.
    // Provide them as simple {name, unit, qty, unit_price} rows for direct editing.
    //
    // BUG-FIX (May 2026): unit_price written here is the SELL price
    // (base × materialsMultiplier × learningFactor). The admin amend
    // dialog computes `total = labour + sum(qty × unit_price)` and the
    // artisan RFQ review shows the per-unit/line value to the artisan,
    // so both must reflect what the client actually pays. Writing base
    // costs here previously caused the customer total to omit the
    // material markup entirely.
    const sellMultiplier = materialsMultiplier * learningFactor;
    const materialsPriced_reference = materialsBOM
      .filter(b => Number(b.unit_price) > 0)
      .map(b => ({ name: b.name, unit: b.unit || 'each', qty: b.qty, unit_price: r2(b.unit_price * sellMultiplier), unit_cost_base: r2(b.unit_price), product_url: b.builders_url || '' }));
    const materialsUnpriced_reference = materialsBOM
      .filter(b => !(Number(b.unit_price) > 0))
      .map(b => ({ name: b.name, unit: b.unit || 'each', qty: b.qty, unit_price: 0 }));
    return {
      laborHours,
      laborCostPerHour,
      labor_hours: laborHours,
      labor_cost_per_hour: laborCostPerHour,
      laborCost: r2(laborCost),
      complexity: draft.complexity || 3,
      materialsBOM,
      materialsPriced_reference,
      materialsUnpriced_reference,
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
  lines.push('Reply *YES* to accept or *NO* to negotiate / discuss changes. (You can also say "accept", "approve", "proceed" — or tell me what you\'d like to change.)');

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

  // ── Sanitize obvious GPT placeholder strings in args (e.g. "[Customer's
  // Name]", "{address}", "<your phone>"). Replace with empty string so
  // downstream code falls back to session-derived values.
  try {
    const PLACEHOLDER_RE = /^[\s]*[\[\{<].*[\]\}>][\s]*$/;
    for (const [k, v] of Object.entries(args || {})) {
      if (typeof v === 'string' && PLACEHOLDER_RE.test(v)) {
        console.warn(`[tool:${name}] stripping placeholder arg ${k}="${v}"`);
        args[k] = '';
      }
    }
    // Also reject obviously templated names like "Customer's Name", "Your Name".
    if (typeof args.customerName === 'string') {
      const lc = args.customerName.toLowerCase().trim();
      if (lc === "customer's name" || lc === 'customer name' || lc === 'your name'
          || lc === 'client name' || lc === "client's name" || lc === 'name' || lc === 'full name') {
        console.warn(`[tool:${name}] stripping templated customerName="${args.customerName}"`);
        args.customerName = '';
      }
    }
  } catch (_) {}

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

      // ── ADDRESS GATE (2026-04-14): never let a booking be created without a
      // service address. The OpenAI tool schema marks address required, but the
      // model occasionally calls the tool with an empty string. Enforce here.
      // International-aware: Square 15 serves SA + Lesotho/Botswana/Namibia etc.,
      // so we require an explicit address rather than guessing from phone country.
      {
        let addressArg = String(args.address || '').trim();
        const sessionAddr = String(session.sharedAddress || '').trim();
        if (!addressArg && sessionAddr) {
          args.address = sessionAddr;
          addressArg = sessionAddr;
        }
        if (!addressArg) {
          console.log(`[create_booking] ADDRESS GATE: refusing booking for ${maskPhone(session.phone)} — no service address`);
          return {
            success: false,
            error: 'address_required',
            required_next_action: 'ask_for_address',
            instruction: "Before creating this booking, you MUST ask the customer for the FULL service address — street, suburb/area, city, AND country if the customer is outside South Africa (Square 15 also serves Lesotho, Botswana, Namibia, Zimbabwe, Eswatini and beyond). Example: 'Could you please share the full address where the work needs to be done? (street, area, city — and country if outside South Africa). You can also drop a WhatsApp location pin if that's easier.' Do NOT call create_booking again until they reply with an address.",
          };
        }
      }

      const bookingId = `WA-${Date.now().toString(36).toUpperCase()}`;
      const orderNo = `SQ15-${bookingId}`;
      const now = new Date().toISOString();

      // Look up pricing estimate — tasks collection is AUTHORITATIVE (admin-managed)
      let estimatedCost = '0';
      let pricingSource = 'none';
      try {
        const catSlug = (args.category || '').toLowerCase().replace(/\s+/g, '_');
        const subQuery = (args.subcategory || args.description || '').toLowerCase();

        if (subQuery) {
          // BHV-2: shared matcher (defined at module top) — same code path as
          // lookup_pricing. All hardware-install / labour-only / suspicious
          // -low-cost guards live in findFixedPriceMatch.
          const taskSnap = await firestore.collection('tasks').limit(200).get();
          const taskResults = [];
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
          const result = findFixedPriceMatch({ subcategory: subQuery, taskResults });
          if (result.matched) {
            estimatedCost = result.cost.toString();
            pricingSource = 'fixed';
            console.log(`[create_booking] Best price match: "${result.name}" R${result.cost} (score=${result.score})`);
          } else {
            if (result.rejected && result.rejected.length) {
              console.log(`[create_booking] No match for "${subQuery}"; rejected ${result.rejected.length}:`, result.rejected.slice(0, 5).map(r => `${r.name}[${r.reason}]`).join(', '));
            } else {
              console.log(`[create_booking] No fixed-price task matched "${subQuery}" — will RFQ`);
            }
          }
        }
      } catch (e) {
        console.error('[create_booking] Pricing lookup error:', e.message);
      }

      // If no pricing found at all, convert to RFQ instead of creating R0 booking.
      // Write to futureBookings with rfq_status='pending_admin_review' so the
      // Admin → RFQ Requests screen (which streams futureBookings filtered by
      // rfq_status) actually sees and can action the request.
      if (estimatedCost === '0' || pricingSource === 'none') {
        console.log(`[create_booking] ⚠️ No pricing found for category="${args.category}" sub="${args.subcategory}" — converting to RFQ (admin review)`);
        const rfqBookingId = bookingId; // already WA-XXXXX
        const rfqShortNo = `RFQ-${Date.now().toString(36).toUpperCase()}`;
        const customerName = args.customerName || args.client_name || '';
        const customerPhone = session.phone || args.customerPhone || '';
        const photoUrls = (session.photoUrls && session.photoUrls.length) ? session.photoUrls : [];

        const rfqDoc = {
          // Identity
          id: rfqBookingId,
          bookingId: rfqBookingId,
          order_no: orderNo,
          rfq_no: rfqShortNo,

          // RFQ flags read by admin_rfq_list_screen.dart / admin_rfq_review_screen.dart
          is_rfq: 'yes',
          rfq_status: 'pending_admin_review',
          rfq_submitted_to: 'admin',
          rfq_total: 0,
          rfq_artisan_rejections: [],
          rfq_artisan_rejection_count: 0,
          rfq_client_rejections: [],

          // Category / description (both naming styles for cross-app compat)
          category: args.category || '',
          category_name: args.category || '',
          categoryName: args.category || '',
          subcategory: args.subcategory || '',
          sub_category_name: args.subcategory || '',
          description: args.description || args.subcategory || '',
          problem_description: args.description || '',

          // Client identity (admin list reads client_name / client_phone first)
          client_name: customerName,
          client_phone: customerPhone,
          client_contact: customerPhone,
          customerName: customerName,
          customerPhone: customerPhone,
          user_name: customerName,
          user_phone: customerPhone,
          user_id: session.linkedUserId || `wa_${customerPhone}`,

          // Address / scheduling
          address: args.address || '',
          location: args.address || '',
          scheduled_date: args.scheduled_date || '',
          scheduled_time: args.scheduled_time || '',
          materials_responsibility: args.materials_responsibility || '',

          // Pricing — explicitly zero so admin sees draft state, not random fallback
          cost: '0',
          total: '0',
          total_price: '0',
          totalPrice: '0',
          admin_quote_total: 0,

          // Photos (multiple key styles for cross-screen compat)
          image_urls: photoUrls,
          work_images: photoUrls,
          imageUrls: photoUrls,
          images: photoUrls,
          photos: photoUrls,

          // Routing / source
          source: 'whatsapp',
          status: 'pending_admin_review',
          payment_status: 'unpaid',

          // Timestamps
          created_at: now,
          created_at_ts: admin.firestore.FieldValue.serverTimestamp(),
          updated_at: now,
        };

        // Generate AI draft quote (materials BOM, labour, contingency, grand total)
        // so the admin RFQ Review screen shows a real draft instead of R0.00.
        try {
          console.log(`[create_booking] Generating AI draft quote for RFQ ${rfqBookingId}...`);
          const aiQuote = await generateAIQuote(
            args.category || '',
            args.description || args.subcategory || '',
            args.materials_responsibility || 'artisan',
            ''
          );
          if (aiQuote && aiQuote.grand_total > 0) {
            const gt = aiQuote.grand_total;
            rfqDoc.ai_quote = aiQuote;
            rfqDoc.quoted_price = gt.toString();
            rfqDoc.quote_details = aiQuote.scope_of_work || '';
            rfqDoc.rfq_total = gt;
            rfqDoc.admin_quote_total = gt;
            rfqDoc.cost = gt.toFixed(2);
            rfqDoc.total = gt.toFixed(2);
            rfqDoc.total_price = gt.toFixed(2);
            rfqDoc.totalPrice = gt.toFixed(2);
            console.log(`[create_booking] ✅ AI draft quote generated: R${gt.toFixed(2)} (${(aiQuote.materialsBOM || []).length} BOM items)`);
          } else {
            console.warn('[create_booking] AI quote generation returned null/zero — admin will price manually.');
          }
        } catch (e) {
          console.error('[create_booking] AI quote generation error (non-fatal):', e.message);
        }

        try {
          // Primary collection used by admin RFQ list/review streams.
          await firestore.collection('futureBookings').doc(rfqBookingId).set(rfqDoc, { merge: true });
        } catch (e) {
          console.error('[create_booking] futureBookings RFQ write failed:', e.message);
        }

        // Keep a parallel record in rfq_requests for any existing reporting/legacy paths.
        try {
          await firestore.collection('rfq_requests').doc(rfqBookingId).set({
            ...rfqDoc,
            futureBookingId: rfqBookingId,
          }, { merge: true });
        } catch (e) {
          console.warn('[create_booking] rfq_requests mirror write failed:', e.message);
        }

        // Notify admin (link to the futureBookings doc so tap-through works).
        try {
          await firestore.collection('notifications').add({
            title: 'New RFQ from WhatsApp',
            body: `${customerName || 'Customer'} needs pricing for ${args.category || 'service'}${args.subcategory ? ' > ' + args.subcategory : ''}.`,
            type: 'rfq_request',
            user_type: 'admin',
            booking_id: rfqBookingId,
            rfq_id: rfqBookingId,
            rfq_no: rfqShortNo,
            source: 'whatsapp',
            read: false,
            view: false,
            created_at: admin.firestore.FieldValue.serverTimestamp(),
          });
        } catch (e) {
          console.warn('[create_booking] admin RFQ notification failed:', e.message);
        }

        // Track on session so follow-up messages can reference it.
        session.lastRfqId = rfqBookingId;
        session.lastRfqNo = rfqShortNo;

        return {
          success: true,
          rfq: true,
          rfqId: rfqBookingId,
          rfq_no: rfqShortNo,
          message: `We don't have a fixed price for "${args.subcategory || args.category}" yet. Your request has been sent to our team as a quote request (${rfqShortNo}). An admin will review and provide a custom quote shortly. You'll be notified once pricing is ready.`,
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
        user_id: session.linkedUserId || `wa_${maskPhone(session.phone)}`,
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
        user_id: session.linkedUserId || `wa_${maskPhone(session.phone)}`,
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

      // Record promo redemption if used (atomic max_uses enforcement)
      if (promoApplied && session.promoId) {
        try {
          const promoRef = firestore.collection('promo_codes').doc(session.promoId);
          await firestore.runTransaction(async (txn) => {
            const snap = await txn.get(promoRef);
            if (!snap.exists) return; // promo deleted between apply and use
            const data = snap.data() || {};
            const used = Number(data.used_count || 0);
            const max = data.max_uses ? Number(data.max_uses) : 0;
            if (max > 0 && used >= max) {
              throw new Error('PROMO_MAX_USES_EXCEEDED');
            }
            txn.update(promoRef, { used_count: admin.firestore.FieldValue.increment(1) });
          });
          await firestore.collection('promo_redemptions').add({
            promo_id: session.promoId,
            user_id: session.linkedUserId || session.phone,
            task_management_id: bookingId,
            job_amount: parseFloat(estimatedCost),
            discount_amount: promoApplied.discount,
            source: 'whatsapp',
            created_at: now,
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

      // Push notification to linked customer app (booking confirmation)
      if (session.linkedUserId) {
        await notifyLinkedCustomer(firestore, {
          userId: session.linkedUserId,
          phone: session.phone,
          title: 'Booking Created',
          body: `Your ${args.category || 'maintenance'} booking #${orderNo} has been created. We're finding available artisans.`,
          data: { type: 'booking_created', booking_id: bookingId },
        });
      }

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
        message: `Booking ${orderNo} created! Estimated cost: R${finalCost.toFixed(2)}.\n\n⏳ *Next step:* An artisan needs to accept your job before payment. We're dispatching the nearest available artisan now — you'll be notified as soon as one accepts.\n\n🔒 *Your money is 100% protected (Escrow):* When it's time to pay, your payment is held in a secure escrow account. The artisan does NOT receive your money until you confirm you are satisfied with the completed work.\n\n🛡️ *Your safety matters:* Every Square 15 artisan is registered, ID-verified and rated by past customers. When the artisan is on the way, we'll send you their profile photo so you can confirm it's the same person who arrives at your door. If anything ever feels unsafe, reply *"help"* and we'll alert support immediately.\n\n💸 *Refund policy:* Cancel before the artisan starts work for a *full refund*. If you're not satisfied with the completed work, do *not* release payment — reply *"refund"* or *"complaint"* and our team will investigate before any money leaves escrow. Wallet refunds are instant; card refunds take 3–5 business days.\n\n💰 *Payment options (after artisan accepts):*\n• Full amount: R${finalCost.toFixed(2)}\n• Deposit (35%): R${depositAmount.toFixed(2)} now, R${balanceAmount.toFixed(2)} after job completion`,
      };
    }

    // ═══════════════════════════════════════════
    // 3) CHECK BOOKING STATUS
    // ═══════════════════════════════════════════
    case 'check_booking_status': {
      if (!firestore) return { error: 'Database unavailable' };
      const bid = String(args.bookingId || '').trim();
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
        const normalize = _matcherNormalize; // local alias for the price-list builder below
        let matchedService = null;
        let matchedPrice = null;
        let categoryName = args.category || '';

        // ── SOLE SOURCE: tasks collection (admin-managed fixed prices) ──
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

        // BHV-2: delegate matching to the SHARED helper (defined at module
        // top). All matching guards (stopwords, action-verb compat,
        // hardware-install containment/distinctive rules, R800 sanity gate)
        // live there. Any future tweak applies to BOTH lookup_pricing and
        // create_booking automatically.
        if (subQuery) {
          const result = findFixedPriceMatch({ subcategory: subQuery, taskResults });
          if (result.matched) {
            matchedService = result.name;
            matchedPrice = result.cost;
            categoryName = result.category_name || categoryName;
          } else if (result.rejected && result.rejected.length) {
            console.log(`[lookup_pricing] rejected ${result.rejected.length} candidate(s) for "${subQuery}":`, result.rejected.map(r => `${r.name}[${r.reason || r.sAction || ''}]`).join(', '));
          }
        }

        // Build list of all available fixed prices for context.
        // Filter out labour-only tasks (they confuse GPT into quoting a
        // labour-only price as if it were the all-in price). Also cap the
        // list size so GPT can't cherry-pick a price for an unrelated job.
        const allFixedPrices = [];
        const askedLabourOnlyForList = /\b(lab[ou]r)\s*only\b/i.test(subQuery);
        for (const t of taskResults) {
          const catId = normalize(t.category_id);
          const catNameNorm = normalize(t.category_name);
          const catSlugNorm = normalize(catSlug);
          const catMatch = !catSlug || catId === catSlugNorm || catId.includes(catSlugNorm) || catSlugNorm.includes(catId)
              || catNameNorm === catSlugNorm || catNameNorm.includes(catSlugNorm) || catSlugNorm.includes(catNameNorm);
          if (!catMatch) continue;
          const isLabourOnlyT = /\b(lab[ou]r)\s*only\b/i.test(t.name);
          if (isLabourOnlyT && !askedLabourOnlyForList) continue;
          allFixedPrices.push({ service: t.name, fixedPrice: `R${t.cost.toFixed(2)}` });
        }

        if (matchedService && matchedPrice) {
          return {
            matched: true,
            service: matchedService,
            fixedPrice: `R${matchedPrice.toFixed(2)}`,
            category: categoryName,
            note: 'This is a FIXED price for the matched service. Use this exact amount when creating the booking. Do NOT pick any other price.',
          };
        }

        // No match → DO NOT hand GPT a price list to pick from.
        // The bot must call submit_rfq instead. Returning availableServices
        // here causes hallucinated quotes (e.g. "shower door = R480" picked
        // from "varnish door frame Labour only").
        return {
          matched: false,
          category: categoryName,
          note: 'NO FIXED PRICE EXISTS for this exact service. You MUST NOT quote any price to the customer. You MUST call submit_rfq so admin can produce a curated quote. Do NOT invent a price, do NOT pick a price from any other service in this category, do NOT use prior conversation memory.',
        };
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
      let bid = String(args.bookingId || session.lastBookingId || '').trim();
      if (!bid) return { error: 'Please provide a booking ID.' };

      // HIGH-3: validate session.linkedUserId before letting it influence
      // the payment context. A stale linkedUserId could otherwise credit
      // the wrong app account.
      if (session.linkedUserId && !String(session.linkedUserId).startsWith('wa_')) {
        try {
          const linkedDoc = await firestore.collection('users').doc(session.linkedUserId).get();
          if (!linkedDoc.exists) {
            console.warn(`[request_payment_link] stale linkedUserId ${session.linkedUserId} (no user doc) — clearing`);
            session.linkedUserId = null;
          } else {
            const u = linkedDoc.data() || {};
            const phoneFields = [u.phone, u.phoneNumber, u.phone_number, u.contact, u.mobile];
            const sessDigits = String(session.phone || '').replace(/\D/g, '');
            const matches = phoneFields.some(p => {
              const pd = String(p == null ? '' : p).replace(/\D/g, '');
              if (!pd || !sessDigits) return false;
              const tail = (s) => s.length >= 9 ? s.slice(-9) : s;
              return tail(pd) === tail(sessDigits);
            });
            if (!matches) {
              console.warn(`[request_payment_link] linkedUserId ${session.linkedUserId} phone mismatch with session phone ${maskPhone(session.phone)} — clearing`);
              try {
                await logErrorToAdmin(
                  'linked_user_phone_mismatch',
                  `Session linkedUserId ${session.linkedUserId} does not match WA phone ${maskPhone(session.phone)}`,
                  'whatsapp_bot.request_payment_link',
                  '',
                  bid,
                  'high'
                );
              } catch (_) {}
              session.linkedUserId = null;
            }
          }
        } catch (e) {
          // CRITICAL: do NOT keep an unverified linkedUserId on transient
          // Firestore errors. Leaving it set could route a payment to the
          // wrong account if the validation fetch happened to fail. Clear
          // it and force re-link on the next interaction.
          console.warn('[request_payment_link] linkedUserId validation failed (clearing):', e.message);
          session.linkedUserId = null;
          try {
            await logErrorToAdmin(
              'linked_user_validation_error',
              `linkedUserId validation threw for ${maskPhone(session.phone)}: ${e.message}`,
              'whatsapp_bot.request_payment_link',
              e.message,
              bid || '',
              'medium'
            );
          } catch (_) {}
        }
      }

      let doc = await firestore.collection('futureBookings').doc(bid).get();
      if (!doc.exists) doc = await firestore.collection('tasksManagement').doc(bid).get();
      if (!doc.exists) return { error: `Booking "${bid}" not found.` };

      // FINANCIAL-SAFETY: If the resolved booking is already paid but the
      // customer has another booking with an OUTSTANDING balance for the
      // same phone, switch to that one. Otherwise the bot incorrectly says
      // "already paid" while a real balance is sitting unpaid — losing
      // revenue and damaging trust. (May 2026 incident.)
      const isFullyPaid = (rec) => {
        if (!rec) return false;
        const ps = String(rec.payment_status || rec.paymentStatus || '').toLowerCase();
        if (ps === 'paid' || ps === 'fully_paid') return true;
        if (ps === 'deposit_paid' && rec.balance_paid === true) return true;
        return false;
      };
      const hasOutstandingBalance = (rec) => {
        if (!rec) return false;
        const ps = String(rec.payment_status || rec.paymentStatus || '').toLowerCase();
        if (ps === 'deposit_paid' && rec.balance_paid !== true) return true;
        // Unpaid bookings with a confirmed cost
        const cost = parseFloat(rec.cost || rec.total_cost || '0');
        if (cost > 0 && (ps === '' || ps === 'pending' || ps === 'pending_payment' || ps === 'unpaid')) return true;
        return false;
      };
      if (isFullyPaid(doc.data())) {
        try {
          const sessPhone = String(session.phone || '').replace(/\D/g, '');
          if (sessPhone) {
            const phoneVariants = Array.from(new Set([
              sessPhone,
              sessPhone.replace(/^27/, '0'),
              '+' + sessPhone,
              sessPhone.startsWith('0') ? '27' + sessPhone.slice(1) : sessPhone,
            ]));
            const candidates = [];
            for (const ph of phoneVariants) {
              for (const col of ['futureBookings', 'tasksManagement']) {
                for (const field of ['user_phone', 'customerPhone', 'phone', 'contact', 'client_phone']) {
                  try {
                    const q = await firestore.collection(col)
                      .where(field, '==', ph)
                      .orderBy('updated_at', 'desc')
                      .limit(10)
                      .get().catch(() => ({ empty: true, docs: [] }));
                    for (const d2 of q.docs) {
                      const data2 = d2.data() || {};
                      if (hasOutstandingBalance(data2) && !isFullyPaid(data2)) {
                        candidates.push({ id: d2.id, data: data2, ref: d2.ref });
                      }
                    }
                  } catch (_) {}
                }
              }
            }
            if (candidates.length > 0) {
              // Pick most recent by updated_at
              candidates.sort((a, b) => {
                const ta = new Date(a.data.updated_at || 0).getTime();
                const tb = new Date(b.data.updated_at || 0).getTime();
                return tb - ta;
              });
              const pick = candidates[0];
              console.log(`[request_payment_link] Booking ${bid} is paid; switching to outstanding ${pick.id} for ${maskPhone(session.phone)}`);
              try {
                await logErrorToAdmin(
                  'payment_link_rerouted_to_unpaid',
                  `Customer ${maskPhone(session.phone)} requested link for paid booking ${bid}; rerouted to outstanding ${pick.id}`,
                  'whatsapp_bot.request_payment_link',
                  '',
                  pick.id,
                  'medium'
                );
              } catch (_) {}
              bid = pick.id;
              doc = await pick.ref.get();
              // Update session so future intercepts use the right id
              session.lastBookingId = pick.id;
              try {
                await firestore.collection('wa_sessions').doc(session.phone).set({
                  phone: session.phone,
                  lastBookingId: pick.id,
                  lastActivity: admin.firestore.FieldValue.serverTimestamp(),
                }, { merge: true });
              } catch (_) {}
            }
          }
        } catch (e) {
          console.warn('[request_payment_link] outstanding-balance recovery failed:', e.message);
        }
      }

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

      // ── Pre-flight double-submit guards ──
      // HIGH-10: deposit_pending without a TTL leaves the booking stuck if
      // the previous link generation crashed. Allow retry after 5 minutes.
      // NOTE: deposit_pending_at is normally an ISO string, but legacy docs
      // or other writers can store it as a Firestore Timestamp object. Wrap
      // the parse so a NaN result (which is falsy) doesn't silently let
      // duplicate payment links through.
      const parsePendingAt = (v) => {
        if (!v) return 0;
        if (typeof v === 'string') {
          const t = Date.parse(v);
          return Number.isFinite(t) ? t : 0;
        }
        if (typeof v.toMillis === 'function') return v.toMillis();
        if (v instanceof Date) return v.getTime();
        if (typeof v === 'number') return v;
        return 0;
      };
      if (isDeposit && d.payment_status === 'deposit_pending') {
        const depPendingAt = parsePendingAt(d.deposit_pending_at);
        if (depPendingAt && (Date.now() - depPendingAt) < 300000) {
          return {
            message: `A deposit payment is already in progress for this booking. Please complete the existing payment or wait a few minutes before requesting a new one.`,
            bookingId: bid,
          };
        }
      }
      // Block full-payment retry while one was generated in the last 2 minutes
      // (uses full_pending_at timestamp; if older than 2 min, allow re-issue).
      if (!isDeposit && !isDepositPaid) {
        const fullPendingAt = parsePendingAt(d.full_pending_at);
        if (fullPendingAt && (Date.now() - fullPendingAt) < 120000) {
          return {
            message: `A full payment link was just sent for this booking. Please use the existing link, or wait 2 minutes to request a new one.`,
            bookingId: bid,
          };
        }
      }

      // Generate real payment link via backend (with one retry + admin alert on failure).
      let paymentUrl = '';
      let paymentLinkErr = '';
      try {
        const backendUrl = process.env.LIVEKIT_BACKEND_URL || 'https://square15-livekit-backend.onrender.com';
        // Resolve customer name from canonical fields, then session, then a sensible default.
        const resolvedCustomerName = (
          d.user_name || d.userName || d.customer_name || d.customerName || d.name ||
          session.linkedUserName || session.customerName || ''
        ).toString().trim();
        const reqBody = JSON.stringify({
          amount: cost.toFixed(2),
          booking_id: bid,
          customer_name: resolvedCustomerName,
          customer_phone: session.phone,
          description: d.description || d.subcategory || d.category_name || `Booking ${bid}`,
        });
        const reqHeaders = { 'Content-Type': 'application/json', 'x-internal-secret': process.env.INTERNAL_API_SECRET || '' };
        // Helper: one fetch attempt, returning {ok, paymentUrl, status, errMsg}.
        async function _attempt(timeoutMs) {
          try {
            const resp = await fetch(`${backendUrl}/api/payment/whatsapp-initiate`, {
              method: 'POST', headers: reqHeaders, body: reqBody,
              signal: AbortSignal.timeout(timeoutMs),
            });
            let json = null;
            try { json = await resp.json(); } catch (_) {}
            if (resp.ok && json && json.ok && json.payment_url) {
              return { ok: true, paymentUrl: json.payment_url };
            }
            return { ok: false, status: resp.status, errMsg: (json && (json.error || json.message)) || `HTTP ${resp.status}` };
          } catch (e) {
            return { ok: false, errMsg: (e && e.message) || 'fetch failed' };
          }
        }
        let r = await _attempt(15000);
        if (!r.ok) {
          // Retry once after 1.5s — covers cold-start / transient blip on Render.
          await new Promise(s => setTimeout(s, 1500));
          const r2 = await _attempt(20000);
          if (r2.ok) r = r2;
          else r = { ok: false, errMsg: `${r.errMsg}; retry: ${r2.errMsg}` };
        }
        if (r.ok) {
          paymentUrl = r.paymentUrl;
        } else {
          paymentLinkErr = r.errMsg || 'unknown';
          console.warn('[wa-tool] payment link generation failed (after retry):', paymentLinkErr);
          // Surface to admin so a customer waiting for a link doesn't get
          // silently stuck on the fallback message.
          try {
            await logErrorToAdmin(
              'payment_link_backend_unavailable',
              `Payment link generation failed after retry for booking ${bid} (${cost.toFixed(2)}). Error: ${paymentLinkErr}`,
              'whatsapp_bot.request_payment_link',
              paymentLinkErr,
              bid,
              'high'
            );
          } catch (_) {}
        }
      } catch (e) {
        paymentLinkErr = e && e.message;
        console.warn('[wa-tool] payment link generation threw:', paymentLinkErr);
        try {
          await logErrorToAdmin(
            'payment_link_backend_threw',
            `Payment link generation threw for booking ${bid}: ${paymentLinkErr}`,
            'whatsapp_bot.request_payment_link',
            paymentLinkErr,
            bid,
            'high'
          );
        } catch (_) {}
      }

      // ── Persist payment-type choice to Firestore (mirror to both collections) ──
      // Skip persistence if we couldn't generate the link (admin-fallback path).
      if (paymentUrl) {
        const nowIso = new Date().toISOString();
        let pendingFields;
        if (isDeposit) {
          pendingFields = {
            payment_type: 'deposit',
            deposit_amount: cost,
            balance_amount: balanceAfterDeposit,
            balance_remaining: balanceAfterDeposit,
            payment_status: 'deposit_pending',
            deposit_pending_at: nowIso,
            // Clear any stale full-payment marker
            full_pending_at: admin.firestore.FieldValue.delete(),
            updated_at: nowIso,
          };
        } else if (isDepositPaid) {
          // Balance-after-deposit payment
          pendingFields = {
            payment_status: 'balance_pending',
            balance_pending_at: nowIso,
            updated_at: nowIso,
          };
        } else {
          // Full payment (clear any stale deposit-pending fields if user changed mind)
          pendingFields = {
            payment_type: 'full',
            full_pending_at: nowIso,
            updated_at: nowIso,
          };
          // If a previous deposit_pending was set, clear it so the ITN/result handler
          // doesn't mislabel this full payment as a deposit.
          if (d.payment_status === 'deposit_pending') {
            pendingFields.payment_status = 'unpaid';
            pendingFields.deposit_amount = admin.firestore.FieldValue.delete();
            pendingFields.balance_amount = admin.firestore.FieldValue.delete();
            pendingFields.balance_remaining = admin.firestore.FieldValue.delete();
          }
        }
        try {
          await doc.ref.set(pendingFields, { merge: true });
          const otherCollection = doc.ref.parent.id === 'futureBookings' ? 'tasksManagement' : 'futureBookings';
          const otherDoc = await firestore.collection(otherCollection).doc(bid).get();
          if (otherDoc.exists) {
            await otherDoc.ref.set(pendingFields, { merge: true });
          }
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

      const bid = String(args.bookingId || '').trim();
      if (!bid) return { error: 'Please provide a booking ID.' };

      // Get booking (check both collections)
      let bookDoc = await firestore.collection('tasksManagement').doc(bid).get();
      if (!bookDoc.exists) bookDoc = await firestore.collection('futureBookings').doc(bid).get();
      if (!bookDoc.exists) return { error: `Booking "${bid}" not found.` };
      const bookData = bookDoc.data();

      if (bookData.payment_status === 'paid') return { message: 'This booking is already paid!' };
      if (bookData.payment_status === 'deposit_paid' && bookData.balance_paid === true) {
        return { message: 'This booking is fully paid (deposit + balance)!' };
      }

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

      const totalCost = parseFloat(bookData.cost || '0');
      if (totalCost <= 0) return { error: 'This booking does not have a confirmed price yet.' };

      // Handle deposit/balance split: if deposit already paid, only charge the remaining balance
      const isDepositPaid = bookData.payment_status === 'deposit_paid';
      const balanceDone = bookData.balance_paid === true;
      let chargeAmount, paymentLabel, newPaymentStatus, balanceFields;

      if (isDepositPaid && !balanceDone) {
        // Only charge the remaining balance (65%)
        const depositAmt = parseFloat(bookData.deposit_amount || '0') || Math.round(totalCost * 0.35 * 100) / 100;
        chargeAmount = parseFloat(bookData.balance_remaining || bookData.balance_amount || '0') || Math.round((totalCost - depositAmt) * 100) / 100;
        paymentLabel = `balance payment of R${chargeAmount.toFixed(2)}`;
        newPaymentStatus = 'paid';
        balanceFields = { balance_paid: true, balance_paid_at: new Date().toISOString(), balance_payment_method: 'wallet' };
      } else {
        // Full payment
        chargeAmount = totalCost;
        paymentLabel = `payment of R${chargeAmount.toFixed(2)}`;
        newPaymentStatus = 'paid';
        balanceFields = {};
      }

      // Get user balance (atomic transaction)
      try {
        await firestore.runTransaction(async (txn) => {
          // Re-read booking inside the transaction so a rapid double-tap
          // (two `pay_with_wallet` calls within the same second) cannot
          // both pass the outer `payment_status` check and double-debit.
          const tmRef = firestore.collection('tasksManagement').doc(bid);
          const fbRef = firestore.collection('futureBookings').doc(bid);
          const freshTm = await txn.get(tmRef);
          const freshFb = await txn.get(fbRef);
          const freshBook = freshTm.exists ? freshTm.data() : (freshFb.exists ? freshFb.data() : null);
          if (freshBook) {
            if (freshBook.payment_status === 'paid') {
              throw new Error('ALREADY_PAID');
            }
            if (freshBook.payment_status === 'deposit_paid' && freshBook.balance_paid === true) {
              throw new Error('ALREADY_PAID');
            }
          }

          const userRef = firestore.collection('users').doc(session.linkedUserId);
          const userSnap = await txn.get(userRef);
          if (!userSnap.exists) throw new Error('User not found');

          const balance = parseFloat(userSnap.data().balance || '0');
          if (balance < chargeAmount) throw new Error(`INSUFFICIENT_BALANCE:${balance.toFixed(2)}:${chargeAmount.toFixed(2)}`);

          const newBalance = balance - chargeAmount;
          txn.update(userRef, { balance: newBalance.toFixed(2) });
          txn.update(tmRef, {
            payment_status: newPaymentStatus,
            paymentStatus: newPaymentStatus,
            payment_method: 'wallet',
            paid_at: new Date().toISOString(),
            ...balanceFields,
          });

          // Also update futureBookings if exists
          if (freshFb.exists) {
            txn.update(fbRef, {
              payment_status: newPaymentStatus,
              wallet_deducted: true,
              paid_at: new Date().toISOString(),
              ...balanceFields,
            });
          }
        });

        // Log transaction
        await firestore.collection('transactionLogs').add({
          user_id: session.linkedUserId,
          type: 'payment',
          subtype: isDepositPaid ? 'wallet_balance_payment' : 'wallet_deduction',
          amount: chargeAmount,
          booking_id: bid,
          source: 'whatsapp',
          status: 'success',
          created_at: admin.firestore.FieldValue.serverTimestamp(),
        });

        return { success: true, message: `${isDepositPaid ? 'Balance' : 'Full'} ${paymentLabel} successful via wallet! Your booking ${bid} is now fully paid.`, paid: `R${chargeAmount.toFixed(2)}` };
      } catch (e) {
        if (e && e.message === 'ALREADY_PAID') {
          return { message: 'This booking is already paid.' };
        }
        if (e && typeof e.message === 'string' && e.message.startsWith('INSUFFICIENT_BALANCE:')) {
          const parts = e.message.split(':');
          const have = parts[1] || '0.00';
          const need = parts[2] || chargeAmount.toFixed(2);
          const short = (parseFloat(need) - parseFloat(have)).toFixed(2);
          return {
            error: `Insufficient wallet balance. You have R${have} but need R${need} (short by R${short}). Reply "top up" to add funds, or choose another payment method.`,
          };
        }
        return { error: e.message || 'Payment failed. Please try again.' };
      }
    }

    // ═══════════════════════════════════════════
    // 10) SUBMIT RFQ (with AI Quote Generation)
    // ═══════════════════════════════════════════
    case 'submit_rfq': {
      if (!firestore) return { error: 'Database unavailable' };

     try {
      // ── PHOTO GATE: refuse to file an RFQ without at least one photo or
      // an explicit "no_photo_reason" arg. The system prompt instructs the LLM
      // to ALWAYS ask for a photo first, but this server-side check enforces
      // the rule even when the model skips it.
      const hasSessionPhotos = Array.isArray(session.photoUrls) && session.photoUrls.length > 0;
      const noPhotoReason = String(args.noPhotoReason || args.no_photo_reason || '').trim();
      if (!hasSessionPhotos && !noPhotoReason && !session.photoGateAcknowledged) {
        session.photoGateAcknowledged = false;
        console.log(`[submit_rfq] PHOTO GATE: refusing RFQ for ${maskPhone(session.phone)} — no photo received yet`);
        return {
          success: false,
          error: 'photo_required',
          required_next_action: 'ask_for_photo',
          instruction: "Before filing this RFQ, ask the customer to send a photo of the issue. Say something warm like: 'Could you please send me a quick photo of the spot where the work is needed? It helps our team scope the job and price it accurately.' If the customer explicitly says they cannot send a photo, call submit_rfq again with noPhotoReason set to their reason (e.g. 'client unable to take photo right now').",
        };
      }
      // Mark gate as cleared so retries within the same session aren't re-blocked.
      session.photoGateAcknowledged = true;

      // ── ADDRESS GATE (2026-04-14): never let an RFQ be filed without a service
      // address. The system prompt instructs the LLM to ALWAYS ask, but the AI
      // sometimes skips when the customer is brief — so enforce server-side too.
      // Square 15 operates internationally (SA, Lesotho, Botswana, Namibia, etc.)
      // so we require an explicit address rather than guessing from the phone country.
      {
        let addressArg = String(args.address || '').trim();
        const sessionAddr = String(session.sharedAddress || '').trim();
        if (!addressArg && sessionAddr) {
          // AI omitted but customer shared a location pin/address earlier — fold it in.
          args.address = sessionAddr;
          addressArg = sessionAddr;
        }
        if (!addressArg) {
          console.log(`[submit_rfq] ADDRESS GATE: refusing RFQ for ${maskPhone(session.phone)} — no service address`);
          return {
            success: false,
            error: 'address_required',
            required_next_action: 'ask_for_address',
            instruction: "Before filing this RFQ, you MUST ask the customer for the FULL service address — street, suburb/area, city, AND country if the customer is outside South Africa (Square 15 also serves Lesotho, Botswana, Namibia, Zimbabwe, Eswatini and beyond). Example: 'Could you please share the full address where the work needs to be done? (street, area, city — and country if outside South Africa). You can also drop a WhatsApp location pin if that's easier.' Do NOT call submit_rfq again until they reply with an address.",
          };
        }
      }

      // ── GATE (v27): when the artisan supplies materials AND the job needs
      // parts, the AI must have recorded at LEAST ONE material spec via
      // show_material_options before submit_rfq. The admin app then uses these
      // specs as the picking list (admin selects the actual Builders product
      // per line via WebView).
      const materialsResp = String(args.materialsResponsibility || 'artisan').toLowerCase();
      const recordedSpecs = Array.isArray(session.materialSpecs) ? session.materialSpecs : [];
      const hasSpecs = recordedSpecs.length > 0;
      const hasChoice = !!String(args.materialChoice || '').trim();
      const hasAttempted = !!session.materialOptionsAttempted;
      const cat = String(args.category || '').toLowerCase();
      const NEEDS_PARTS = ['plumb', 'electric', 'tile', 'tiling', 'carpent', 'lock', 'paint', 'roof', 'appliance'];
      const needsParts = NEEDS_PARTS.some(k => cat.includes(k));
      if (materialsResp === 'artisan' && needsParts && !hasSpecs && !hasChoice && !hasAttempted) {
        const desc = String(args.description || '').toLowerCase();
        const ITEM_HINTS = ['solar geyser', 'heat pump', 'shower mixer', 'mixer', 'toilet cistern', 'cistern', 'tap', 'door lock', 'lock', 'ceiling light', 'light', 'geyser', 'tile', 'paint', 'basin', 'sink', 'plug point', 'plug', 'socket', 'breaker', 'earth leakage'];
        const guess = ITEM_HINTS.find(h => desc.includes(h)) || (cat.includes('plumb') ? 'tap' : cat.includes('electric') ? 'ceiling light' : cat.includes('lock') ? 'door lock' : 'fixture');
        console.log(`[submit_rfq] GATE: artisan materials but no spec recorded. Asking for one spec capture (guess: ${guess})`);
        return {
          success: false,
          error: 'Capture at least one material spec before filing this RFQ.',
          required_next_action: 'call_show_material_options',
          suggested_itemType: guess,
          instruction: `Call show_material_options with itemType="${guess}" plus the specSummary you have collected from the client (e.g. capacity, finish, brand preference). Then call submit_rfq again. Repeat show_material_options for additional line items if the job needs them (brackets, blanket, fittings, etc.).`,
        };
      }

      // ── IDEMPOTENCY GUARD ──
      // If this session already created an RFQ in the last 10 minutes, treat a
      // repeat call as an UPDATE (e.g. client just supplied budget or material choice
      // after the first attempt). This prevents duplicate RFQs from being created
      // when the LLM calls submit_rfq twice in the same conversation.
      const REUSE_WINDOW_MS = 10 * 60 * 1000;
      if (session.lastRfqId && session.lastRfqAt && (Date.now() - session.lastRfqAt) < REUSE_WINDOW_MS) {
        const existingId = session.lastRfqId;
        const existingNo = session.lastRfqNo || existingId;
        console.log(`[submit_rfq] Idempotency: reusing existing ${existingNo} (${Math.round((Date.now()-session.lastRfqAt)/1000)}s ago)`);
        try {
          const updatePatch = {
            description: args.description || '',
            problem_description: args.description || '',
            materials_responsibility: args.materialsResponsibility || 'artisan',
            user_budget: Number(args.clientBudget) > 0 ? Number(args.clientBudget) : 0,
            material_choice: String(args.materialChoice || '').trim(),
            updated_at: new Date().toISOString(),
            updatedAt: admin.firestore.FieldValue.serverTimestamp(),
          };
          await firestore.collection('futureBookings').doc(existingId).update(updatePatch);
        } catch (e) { console.error('[submit_rfq] idempotent update failed:', e.message); }
        return {
          success: true,
          rfqId: existingId,
          rfqNo: existingNo,
          hasQuote: false,
          duplicate_prevented: true,
          message: `RFQ ${existingNo} already received — I've updated it with your latest info. Our admin is reviewing the quote and we'll send it through here shortly.`,
        };
      }

      const rfqId = `RFQ-${Date.now().toString(36).toUpperCase()}`;
      const rfqNo = `SQ15-RFQ-${rfqId}`;
      const now = new Date().toISOString();

      const rfqDoc = {
        id: rfqId,
        order_no: rfqNo,
        rfq_no: rfqNo,
        is_rfq: 'yes',
        rfq_status: 'pending_admin_review',
        user_id: session.linkedUserId || `wa_${maskPhone(session.phone)}`,
        user_name: args.customerName || '',
        user_phone: session.phone,
        category_name: args.category || '',
        description: args.description || '',
        problem_description: args.description || '',
        address: args.address || '',
        materials_responsibility: args.materialsResponsibility || 'artisan',
        // User-stated budget — drives sales-conversion tactics and admin review UI
        user_budget: Number(args.clientBudget) > 0 ? Number(args.clientBudget) : 0,
        // If the client expressed a brand/option preference verbally, captured here.
        material_choice: String(args.materialChoice || '').trim(),
        // Full list of material specs the bot captured from the client. Admin
        // uses these as the picking list (one Builders product per spec) when
        // building the final quote in the admin app.
        material_specs: recordedSpecs.map(s => ({
          itemType: String(s.itemType || ''),
          category: String(s.category || ''),
          // Keep both naming styles for admin-app compatibility.
          specSummary: String(s.spec_summary || ''),
          spec_summary: String(s.spec_summary || ''),
          brandPreference: String(s.brand_preference || 'any'),
          brand_preference: String(s.brand_preference || 'any'),
          qty: Number(s.qty) > 0 ? Number(s.qty) : 1,
          unit: String(s.unit || 'ea'),
          recorded_at: String(s.recorded_at || ''),
        })),
        material_item_type: recordedSpecs[0] ? String(recordedSpecs[0].itemType || '') : '',
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
      session.lastRfqAt = Date.now();

      // Notify admin (Firestore doc + FCM push so OS tray lights up)
      // Wrapped in try/catch so a notification failure does NOT skip AI quote generation.
      try {
        const budgetNote = Number(args.clientBudget) > 0 ? ` (budget R${Number(args.clientBudget).toFixed(0)})` : '';
        const matNote = args.materialsResponsibility === 'client' ? ' — client supplies materials (labour-only)' : '';
        await pushAdminNotification({
          title: 'New WhatsApp RFQ',
          body: `${args.customerName || 'Client'}: ${args.category || 'service'}${matNote}${budgetNote}. RFQ ${rfqNo}`,
          type: 'new_rfq',
          bookingId: rfqId,
          extraData: {
            customer_name: args.customerName || '',
            category: args.category || '',
            materials_responsibility: args.materialsResponsibility || 'artisan',
            user_budget: String(Number(args.clientBudget) || 0),
          },
        });
      } catch (notifyErr) {
        console.error('[submit_rfq] admin notification failed (continuing):', notifyErr.message);
      }

      // ── AI Quote Generation ──
      // RULE (v27, 2026-04-25): when the artisan supplies materials, the AI
      // quote is SKIPPED entirely — the admin will pick each material on
      // Builders via the WebView picker in the admin app, and that picker
      // sets the real prices. Running AI pricing here would just be discarded.
      // For client-supplies-materials, we still run the AI quote (labour-only
      // path that auto-dispatches under R12K).
      const materialsRespLc = String(args.materialsResponsibility || '').toLowerCase();
      const clientSuppliesMaterials = materialsRespLc === 'client';

      // Extract any image analysis context from the conversation history.
      // Declared early so both the artisan-materials draft path and the legacy
      // labour-only path can use it.
      let imageContext = '';
      for (const m of session.messages) {
        if (typeof m.content === 'string' && m.role === 'assistant' && m.content.length > 50) {
          if (m.content.toLowerCase().includes('issue') || m.content.toLowerCase().includes('damage') ||
              m.content.toLowerCase().includes('repair') || m.content.toLowerCase().includes('install')) {
            imageContext += m.content.substring(0, 300) + ' ';
          }
        }
      }

      if (!clientSuppliesMaterials) {
        // ── ARTISAN-MATERIALS PATH: file RFQ with material_specs[] AND a real AI
        // draft quote so the admin RFQ Review screen shows a draft total +
        // materials BOM the admin can amend (instead of a hard-coded R0
        // placeholder). Admin still has to review/amend & send to client.
        try {
          // Build an enriched description that includes captured spec details so
          // the AI prompt can produce a meaningful BOM even when the customer's
          // raw description was short.
          const specBlurb = recordedSpecs
            .map(s => {
              const brand = s.brand_preference && s.brand_preference !== 'any' ? ` (${s.brand_preference})` : '';
              const qty = Number(s.qty) > 0 ? `${s.qty} ` : '';
              return `${qty}${s.itemType || 'item'}${brand}: ${s.spec_summary || ''}`.trim();
            })
            .filter(Boolean)
            .join('; ');
          const enrichedDescription = [
            args.description || '',
            specBlurb ? `Materials needed: ${specBlurb}` : '',
          ].filter(Boolean).join(' — ');

          let aiDraft = null;
          try {
            console.log(`[submit_rfq] Generating AI DRAFT quote for ${rfqNo} (artisan materials, ${recordedSpecs.length} specs)...`);
            aiDraft = await generateAIQuote(
              args.category || '',
              enrichedDescription,
              'artisan',
              imageContext ? imageContext.trim() : ''
            );
          } catch (genErr) {
            console.error('[submit_rfq] AI draft generation threw:', genErr.message);
          }

          // Seed materialsBOM placeholders from material_specs as fallback when
          // AI draft is unavailable or empty.
          const materialsBOMPlaceholder = recordedSpecs.map(s => ({
            name: s.itemType || 'item',
            description: [s.spec_summary, s.brand_preference && s.brand_preference !== 'any' ? `brand: ${s.brand_preference}` : ''].filter(Boolean).join(' — '),
            qty: Number(s.qty) > 0 ? Number(s.qty) : 1,
            unit: s.unit || 'ea',
            unit_price: 0,
            line_total: 0,
            source: 'pending_admin_pick',
          }));

          // Decide which quote to persist: real AI draft (preferred) or placeholder.
          const aiGrandTotal = aiDraft && Number.isFinite(Number(aiDraft.grand_total)) ? Number(aiDraft.grand_total) : 0;
          let quoteToPersist;
          if (aiDraft && aiGrandTotal > 0) {
            // Tag as a draft so admin app can show "Draft — pending admin review".
            quoteToPersist = {
              ...aiDraft,
              is_admin_draft: true,
              draft_reason: 'artisan_supplies_materials',
              source: (aiDraft.source || 'whatsapp_ai_builders') + '_draft',
            };
          } else {
            quoteToPersist = {
              laborHours: 0,
              laborCost: 0,
              materialsBOM: materialsBOMPlaceholder,
              materials_subtotal: 0,
              materials_with_markup: 0,
              materials_responsibility: 'artisan',
              equipmentCost: 0,
              subtotal: 0,
              contingency: 0,
              grand_total: 0,
              total: 0,
              estimatedCost: 0,
              breakdown: [
                ...materialsBOMPlaceholder.map(m => ({
                  description: `Material: ${m.name || 'item'}`,
                  cost: 0,
                  source: 'pending_admin_pick',
                })),
                { description: 'Labor (to be finalised by admin)', cost: 0, source: 'pending_admin_review' },
              ],
              scope_of_work: args.description || '',
              estimated_duration: 'To be confirmed by admin',
              disclaimer: 'Awaiting admin to pick each material on Builders Warehouse and finalise pricing.',
              generated_at: new Date().toISOString(),
              source: 'whatsapp_spec_capture_v27',
              is_admin_draft: true,
              draft_reason: 'ai_generation_unavailable',
            };
          }

          // Persist draft + mirror totals onto the booking doc so admin RFQ list
          // card shows the draft amount instead of R0.00. Admin still reviews
          // before sending to client (rfq_status remains pending_admin_review).
          const persistGt = aiGrandTotal > 0 ? aiGrandTotal : 0;
          const updatePatch = {
            ai_quote: quoteToPersist,
            quote_details: quoteToPersist.scope_of_work || args.description || '',
            rfq_status: 'pending_admin_review',
            rfq_awaiting_admin_review_reason: 'artisan_supplies_materials',
            updated_at: new Date().toISOString(),
          };
          if (persistGt > 0) {
            updatePatch.quoted_price = persistGt.toFixed(2);
            updatePatch.cost = persistGt.toFixed(2);
            updatePatch.total = persistGt.toFixed(2);
            updatePatch.total_price = persistGt.toFixed(2);
            updatePatch.totalPrice = persistGt.toFixed(2);
            updatePatch.rfq_total = persistGt;
            updatePatch.admin_quote_total = persistGt;
          }
          await firestore.collection('futureBookings').doc(rfqId).update(updatePatch);
          console.log(`[submit_rfq] ARTISAN-MATERIALS path: ${rfqNo} filed with ${recordedSpecs.length} spec(s), draft total=R${persistGt.toFixed(2)}`);

          try {
            await pushAdminNotification({
              title: 'New RFQ — Pick Materials & Quote',
              body: `${args.customerName || 'Client'} • ${args.category || 'service'} • ${recordedSpecs.length} material spec(s). Pick on Builders & send quote.`,
              type: 'rfq_quote_needs_review',
              bookingId: rfqId,
              extraData: {
                materials_responsibility: 'artisan',
                user_budget: String(Number(args.clientBudget) || 0),
                spec_count: String(recordedSpecs.length),
              },
            });
          } catch (_) {}

          // Clear session spec list now that they're persisted on the RFQ.
          session.materialSpecs = [];
          session.pendingMaterialChoice = null;

          return {
            success: true,
            rfqId,
            rfqNo,
            hasQuote: false,
            adminReviewRequired: true,
            message: `Thanks! RFQ ${rfqNo} is in. Our admin will hand-pick the right product for each item you mentioned, send you photos and the final quote here on WhatsApp shortly (usually within a couple of hours during business hours). I'll ping you the moment it's ready.`,
          };
        } catch (artisanPathErr) {
          console.error('[submit_rfq] artisan-path update failed:', artisanPathErr.message);
          // Fall through to legacy AI quote path on failure as a safety net.
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

        // RULE (2026-04-23): when the artisan supplies materials, the AI quote must be
        // reviewed by admin BEFORE it's shown to the client (so admin can check the
        // material selection and amend if needed). When the client supplies materials,
        // the quote goes directly to the client for acceptance (fast labour-only path).
        // (materialsRespLc + clientSuppliesMaterials already declared above for v27 path.)

        if (quote) {
          const gt = Number(quote.grand_total);
          const gtStr = (Number.isFinite(gt) ? gt : 0).toFixed(2);
          if (!Number.isFinite(gt) || gt <= 0) {
            console.warn(`[submit_rfq] AI quote returned but grand_total invalid (${quote.grand_total}) — will fall through to fallback`);
          }
          if (clientSuppliesMaterials) {
            // ── FAST PATH: client buys materials → present quote now, auto-dispatch on accept ──
            await firestore.collection('futureBookings').doc(rfqId).update({
              ai_quote: quote,
              quoted_price: gtStr,
              quote_details: quote.scope_of_work || args.description || '',
              rfq_status: 'pending_client_response',
              total_price: gtStr,
              cost: gtStr,
            });

            const quoteMsg = formatQuoteForWhatsApp(quote, rfqNo);
            console.log(`[submit_rfq] AI quote (client-materials) R${gtStr} for ${rfqNo} — going straight to client`);

            return {
              success: true,
              rfqId,
              rfqNo,
              hasQuote: true,
              grand_total: `R${gtStr}`,
              message: `RFQ ${rfqNo} submitted with AI-generated quote!\n\n${quoteMsg}`,
            };
          } else {
            // ── REVIEW PATH: artisan buys materials → hold for admin, DO NOT show client yet ──
            await firestore.collection('futureBookings').doc(rfqId).update({
              ai_quote: quote,
              quoted_price: gtStr,
              quote_details: quote.scope_of_work || args.description || '',
              rfq_status: 'pending_admin_review',
              rfq_awaiting_admin_review_reason: 'artisan_supplies_materials',
              total_price: gtStr,
              cost: gtStr,
            });
            console.log(`[submit_rfq] AI quote (artisan-materials) R${gtStr} for ${rfqNo} — HELD for admin review`);

            // Push admins: quote needs review (include material list for context)
            try {
              const matCount = Array.isArray(session.pendingMaterialChoice?.options) ? session.pendingMaterialChoice.options.length : 0;
              await pushAdminNotification({
                title: 'RFQ Quote Ready — Needs Admin Review',
                body: `${args.customerName || 'Client'} • ${args.category || 'service'} • R${gtStr} • ${matCount} material option(s) shown. Review & send to client.`,
                type: 'rfq_quote_needs_review',
                bookingId: rfqId,
                extraData: {
                  price: gtStr,
                  material_choice: String(args.materialChoice || ''),
                  materials_responsibility: 'artisan',
                  user_budget: String(Number(args.clientBudget) || 0),
                },
              });
            } catch (_) {}

            // Clear pending options now that they're persisted on the RFQ
            session.pendingMaterialChoice = null;

            return {
              success: true,
              rfqId,
              rfqNo,
              hasQuote: true,
              adminReviewRequired: true,
              grand_total: `R${gtStr}`,
              // Message the bot should relay to the client — do NOT include the quote breakdown.
              message: `Thanks! RFQ ${rfqNo} is in. Because our artisan will source the materials, our admin is reviewing the quote to make sure everything's right — we'll send it through here shortly (usually within a couple of hours during business hours). I'll ping you the moment it's ready.`,
            };
          }
        }
      } catch (quoteErr) {
        console.error('[submit_rfq] AI quote generation error:', quoteErr.message, quoteErr.stack);
      }

      // Fallback if quote generation fails — DO NOT leave the RFQ at R0.
      // Build a minimal labour-only quote so admin sees breakdown + flag for manual review.
      const fallbackBudget = Number(args.clientBudget) > 0 ? Number(args.clientBudget) : 0;
      let fallbackLaborRate = 250;
      let fallbackContingency = 0.15;
      try {
        const catSlug = String(args.category || '').toLowerCase().replace(/\s+/g, '_');
        const gd = await firestore.collection('pricingGuidance').doc(catSlug).get();
        if (gd.exists) {
          const d = gd.data() || {};
          const lr = parseFloat(d.labor_cost_per_hour || d.laborCostPerHour);
          if (lr > 0) fallbackLaborRate = lr;
          const cp = parseFloat(d.contingency_percentage);
          if (!isNaN(cp) && cp > 0) fallbackContingency = cp / 100;
        }
      } catch (_) {}
      const fallbackHours = 4;
      const fallbackLabor = Math.round(fallbackHours * fallbackLaborRate * 100) / 100;
      const fallbackContTotal = Math.round(fallbackLabor * fallbackContingency * 100) / 100;
      const fallbackTotal = fallbackBudget > 0 ? fallbackBudget : Math.round((fallbackLabor + fallbackContTotal) * 100) / 100;
      const fallbackQuote = {
        laborHours: fallbackHours,
        laborCostPerHour: fallbackLaborRate,
        laborCost: fallbackLabor,
        complexity: 3,
        materialsBOM: [],
        materials_subtotal: 0,
        materials_with_markup: 0,
        materials_responsibility: String(args.materialsResponsibility || 'artisan'),
        equipmentCost: 0,
        subtotal: fallbackLabor,
        contingency: fallbackContTotal,
        grand_total: fallbackTotal,
        scope_of_work: args.description || '',
        estimated_duration: 'To be confirmed by admin',
        learning_factor: 1,
        pricing_sources: { builders: 0, catalog: 0, ai_estimate: 0 },
        breakdown: [
          { description: `Labour estimate (${fallbackHours}hrs @ R${fallbackLaborRate}/hr) — ADMIN PLEASE REVISE`, cost: fallbackLabor.toFixed(2) },
          { description: `Contingency (${(fallbackContingency * 100).toFixed(0)}%)`, cost: fallbackContTotal.toFixed(2) },
        ],
        disclaimer: 'AI quote generation failed — this is a labour-only placeholder. Admin must price materials and finalise.',
        generated_at: new Date().toISOString(),
        source: 'whatsapp_fallback',
      };
      try {
        await firestore.collection('futureBookings').doc(rfqId).update({
          ai_quote: fallbackQuote,
          cost: fallbackTotal.toString(),
          total_price: fallbackTotal.toString(),
          quoted_price: fallbackTotal.toString(),
          quote_details: args.description || '',
          quote_generation_failed: true,
          rfq_status: 'pending_admin_review',
          rfq_awaiting_admin_review_reason: 'quote_generation_failed',
        });
      } catch (e) { console.error('[submit_rfq] fallback update failed:', e.message); }
      try {
        await pushAdminNotification({
          title: 'RFQ Needs Manual Quote',
          body: `${args.customerName || 'Client'} • ${args.category || 'service'} • AI quote failed, please price manually. RFQ ${rfqNo}`,
          type: 'rfq_quote_needs_review',
          bookingId: rfqId,
          extraData: { reason: 'quote_generation_failed' },
        });
      } catch (_) {}
      return {
        success: true,
        rfqId,
        rfqNo,
        hasQuote: false,
        message: `Thanks! RFQ ${rfqNo} is in. Our admin is reviewing your request and will send the quote here on WhatsApp shortly (usually within a couple of hours during business hours).`,
      };
     } catch (outerErr) {
        // Catch-all so we NEVER dead-end the conversation with a raw tool error.
        console.error('[submit_rfq] OUTER error:', outerErr.message, outerErr.stack);
        const fallbackRfqNo = session.lastRfqNo || 'pending';
        const fallbackRfqId = session.lastRfqId || '';
        // Even on outer error, guarantee the admin sees *some* draft pricing so
        // the RFQ isn't blank in the Review screen.
        if (fallbackRfqId && firestore) {
          try {
            const budget = Number(args.clientBudget) > 0 ? Number(args.clientBudget) : 0;
            const emergencyLabor = Math.round(4 * 250 * 100) / 100;
            const emergencyCont = Math.round(emergencyLabor * 0.15 * 100) / 100;
            const emergencyTotal = budget > 0 ? budget : Math.round((emergencyLabor + emergencyCont) * 100) / 100;
            const emergencyQuote = {
              laborHours: 4,
              laborCostPerHour: 250,
              laborCost: emergencyLabor,
              complexity: 3,
              materialsBOM: [],
              materialsPriced_reference: [],
              materialsUnpriced_reference: [],
              materials_subtotal: 0,
              materials_with_markup: 0,
              materials_responsibility: String(args.materialsResponsibility || 'artisan'),
              equipmentCost: 0,
              subtotal: emergencyLabor,
              contingency: emergencyCont,
              grand_total: emergencyTotal,
              scope_of_work: args.description || '',
              estimated_duration: 'To be confirmed by admin',
              learning_factor: 1,
              pricing_sources: { builders: 0, catalog: 0, ai_estimate: 0 },
              breakdown: [
                { description: `Labour estimate (4hrs @ R250/hr) — ADMIN PLEASE REVISE`, cost: emergencyLabor.toFixed(2) },
                { description: 'Contingency (15%)', cost: emergencyCont.toFixed(2) },
              ],
              disclaimer: 'Bot hit an unexpected error generating the quote. Admin must review and price manually.',
              generated_at: new Date().toISOString(),
              source: 'whatsapp_emergency_fallback',
              emergency_error: String(outerErr.message || 'unknown').slice(0, 300),
            };
            await firestore.collection('futureBookings').doc(fallbackRfqId).set({
              ai_quote: emergencyQuote,
              cost: emergencyTotal.toString(),
              total_price: emergencyTotal.toString(),
              quoted_price: emergencyTotal.toString(),
              quote_details: args.description || '',
              quote_generation_failed: true,
              rfq_status: 'pending_admin_review',
              rfq_awaiting_admin_review_reason: 'outer_exception',
            }, { merge: true });
            try {
              await pushAdminNotification({
                title: 'RFQ Needs Manual Quote (bot error)',
                body: `${args.customerName || 'Client'} • ${args.category || 'service'} • RFQ ${fallbackRfqNo}. Bot crashed — please price manually.`,
                type: 'rfq_quote_needs_review',
                bookingId: fallbackRfqId,
                extraData: { reason: 'outer_exception', error: String(outerErr.message || '').slice(0, 200) },
              });
            } catch (_) {}
          } catch (emergencyErr) {
            console.error('[submit_rfq] emergency fallback write failed:', emergencyErr.message);
          }
        }
        return {
          success: true,
          rfqId: fallbackRfqId,
          rfqNo: fallbackRfqNo,
          hasQuote: false,
          message: `Thanks — I've logged your request${fallbackRfqNo !== 'pending' ? ` as ${fallbackRfqNo}` : ''}. Our admin will review it and get back to you here on WhatsApp shortly.`,
        };
     }
    }

    // ═══════════════════════════════════════════
    // 10b) RECORD MATERIAL SPEC (text-only — admin will pick the actual product)
    // ═══════════════════════════════════════════
    case 'show_material_options': {
      try {
        const itemType        = String(args.itemType || '').toLowerCase().trim();
        const cat             = String(args.category || '').toLowerCase().trim();
        const specSummary     = String(args.specSummary || '').trim();
        const brandPreference = String(args.brandPreference || '').trim();
        const qty             = Number(args.qty) > 0 ? Number(args.qty) : 1;
        const unit            = String(args.unit || 'ea').trim() || 'ea';

        if (!itemType)    return { success: false, error: 'itemType required' };
        if (!specSummary) return { success: false, error: 'specSummary required — capture what the client told you (capacity, finish, mounting etc.) before calling this.' };

        // Append to session-level material spec list. submit_rfq will copy this
        // onto the RFQ doc so admin sees every line item the client cares about.
        if (!Array.isArray(session.materialSpecs)) session.materialSpecs = [];

        // De-dupe: if the AI calls the same itemType twice, replace the previous
        // entry (treat the latest call as the truth).
        const existingIdx = session.materialSpecs.findIndex(s => s && String(s.itemType || '').toLowerCase() === itemType);
        const entry = {
          itemType,
          category: cat,
          spec_summary: specSummary,
          brand_preference: brandPreference || 'any',
          qty,
          unit,
          recorded_at: new Date().toISOString(),
        };
        if (existingIdx >= 0) session.materialSpecs[existingIdx] = entry;
        else                  session.materialSpecs.push(entry);

        // Mark the materialOptionsAttempted flag so the legacy submit_rfq gate
        // is satisfied — keeps backward compatibility with in-flight conversations.
        session.materialOptionsAttempted = true;

        return {
          success: true,
          recorded_count: session.materialSpecs.length,
          last_recorded: { itemType, spec_summary: specSummary, brand_preference: brandPreference || 'any', qty, unit },
          note: 'Material spec recorded. If the job needs more line items (e.g. brackets, blanket, fittings), call show_material_options again for each. Otherwise continue with the budget question and then submit_rfq. Do NOT promise images, prices or product links yet — admin curates those after you submit. Keep your reply to ONE short sentence acknowledging what you noted (e.g. "Got it — 200L solar geyser, roof mount."), then ask the next question.',
        };
      } catch (e) {
        console.error('[show_material_options] error:', e.message);
        return { success: false, error: e.message };
      }
    }

    // ═══════════════════════════════════════════
    // 10c) REQUEST QUOTE AMENDMENT (after client has received a quote)
    // ═══════════════════════════════════════════
    case 'request_quote_amendment': {
      if (!firestore) return { error: 'Database unavailable' };
      try {
        const rfqId = String(args.rfqId || session.lastRfqId || '').trim();
        const amendmentText = String(args.amendmentText || '').trim();
        if (!rfqId)         return { success: false, error: 'No RFQ in scope. Ask the client which RFQ they want to amend.' };
        if (!amendmentText) return { success: false, error: 'amendmentText required.' };

        const docRef = firestore.collection('futureBookings').doc(rfqId);
        const snap = await docRef.get();
        if (!snap.exists) return { success: false, error: `RFQ "${rfqId}" not found.` };
        const data = snap.data() || {};

        // Use AI to parse the amendment into a structured hint for admin.
        let parsed = null;
        try {
          const r = await openai.chat.completions.create({
            model: 'gpt-4o-mini',
            temperature: 0,
            response_format: { type: 'json_object' },
            messages: [
              { role: 'system', content: 'You parse short maintenance-quote change requests into structured JSON. Output ONLY JSON with shape: {"action":"swap"|"remove"|"add"|"adjust_qty"|"other","item":"...","detail":"..."}. Be terse.' },
              { role: 'user', content: amendmentText.slice(0, 500) },
            ],
          });
          const txt = r?.choices?.[0]?.message?.content || '';
          parsed = JSON.parse(txt);
        } catch (_) { parsed = null; }

        const change = {
          id: `chg_${Date.now().toString(36)}`,
          raw_text: amendmentText.slice(0, 800),
          parsed: parsed || null,
          requested_by: 'client',
          requested_at: new Date().toISOString(),
          status: 'pending',
          source: 'whatsapp',
        };

        await docRef.update({
          change_requests: admin.firestore.FieldValue.arrayUnion(change),
          rfq_status: 'pending_admin_review',
          rfq_awaiting_admin_review_reason: 'client_amendment',
          // Allow the relay listener to fire again once admin re-issues the quote.
          whatsapp_quote_relayed: false,
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        });

        try {
          await pushAdminNotification({
            title: 'Client requested quote change',
            body: `${data.user_name || 'Client'} on ${data.rfq_no || rfqId}: "${amendmentText.slice(0, 120)}"`,
            type: 'rfq_quote_amendment',
            bookingId: rfqId,
            extraData: { amendment: amendmentText.slice(0, 200) },
          });
        } catch (_) {}

        return {
          success: true,
          rfqId,
          message: `Got it — I've sent your change request to our admin (${parsed?.action ? `to ${parsed.action} the ${parsed.item || 'item'}` : 'noted'}). They'll update the quote and I'll send the revised version through here shortly.`,
        };
      } catch (e) {
        console.error('[request_quote_amendment] error:', e.message);
        return { success: false, error: e.message };
      }
    }

    // ═══════════════════════════════════════════
    // 11) CANCEL BOOKING
    // ═══════════════════════════════════════════
    case 'cancel_booking': {
      if (!firestore) return { error: 'Database unavailable' };
      const bid = String(args.bookingId || '').trim();
      if (!bid) return { error: 'Please provide a booking ID.' };

      // Search tasksManagement first, then fall back to futureBookings so
      // pending RFQs (not yet dispatched) can also be cancelled.
      let doc = await firestore.collection('tasksManagement').doc(bid).get();
      let collectionName = 'tasksManagement';
      if (!doc.exists) {
        doc = await firestore.collection('futureBookings').doc(bid).get();
        collectionName = 'futureBookings';
      }
      if (!doc.exists) return { error: `Booking "${bid}" not found.` };

      const d = doc.data();
      const docRef = doc.ref;
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

      // Cancel the primary doc (whichever collection it came from)
      await docRef.update({
        status: 'cancelled',
        cancelled_at: now,
        cancelled_by: 'client_whatsapp',
        cancel_reason: args.reason || 'Cancelled via WhatsApp',
        cancellation_reason: args.reason || 'Cancelled via WhatsApp',
      });

      // Mirror cancellation to the other collection if it also has this ID
      try {
        const otherCollection = collectionName === 'tasksManagement' ? 'futureBookings' : 'tasksManagement';
        const mirrorDoc = await firestore.collection(otherCollection).doc(bid).get();
        if (mirrorDoc.exists) {
          await firestore.collection(otherCollection).doc(bid).update({
            status: 'cancelled',
            cancelled_at: now,
            cancelled_by: 'client_whatsapp',
            cancel_reason: args.reason || 'Cancelled via WhatsApp',
            cancellation_reason: args.reason || 'Cancelled via WhatsApp',
          });
        }
      } catch (e) { console.warn('[wa-tool] mirror cancel sync failed:', e.message); }

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
          // If wallet payment, auto-refund and mark as processed (not pending)
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
              // Mark booking as refunded
              await docRef.update({
                wallet_refunded: 'yes',
                refund_status: 'refunded',
                refund_method: 'wallet',
                wallet_refund_amount: cost,
                updated_at: new Date().toISOString(),
              });
              // Create refund_request already marked as processed (so admin sees it in history)
              await firestore.collection('refund_requests').add({
                booking_id: bid,
                source_doc_id: bid,
                source_doc_type: collectionName,
                user_id: session.linkedUserId || d.user_id || '',
                phone: session.phone,
                amount: cost,
                payment_method: 'wallet',
                reason: args.reason || 'Cancelled via WhatsApp',
                status: 'processed',
                refund_method: 'wallet',
                source: 'whatsapp',
                created_at: admin.firestore.FieldValue.serverTimestamp(),
                updated_at: admin.firestore.FieldValue.serverTimestamp(),
              });
              refundMsg = ` R${cost.toFixed(2)} has been refunded to your wallet.`;
            } catch (e) {
              console.warn('[wa-tool] wallet refund failed:', e.message);
              refundMsg = ' Your refund request has been submitted. Admin will process it shortly.';
              // Fallback: create pending refund request for admin
              await firestore.collection('refund_requests').add({
                booking_id: bid,
                source_doc_id: bid,
                source_doc_type: collectionName,
                user_id: session.linkedUserId || d.user_id || '',
                phone: session.phone,
                amount: cost,
                payment_method: 'wallet',
                reason: args.reason || 'Cancelled via WhatsApp',
                status: 'pending',
                source: 'whatsapp',
                created_at: admin.firestore.FieldValue.serverTimestamp(),
                updated_at: admin.firestore.FieldValue.serverTimestamp(),
              });
            }
          } else {
            // Non-wallet payment — create pending refund request for admin
            await firestore.collection('refund_requests').add({
              booking_id: bid,
              source_doc_id: bid,
              source_doc_type: collectionName,
              user_id: session.linkedUserId || d.user_id || '',
              phone: session.phone,
              amount: cost,
              payment_method: d.payment_method || 'card',
              reason: args.reason || 'Cancelled via WhatsApp',
              status: 'pending',
              source: 'whatsapp',
              created_at: admin.firestore.FieldValue.serverTimestamp(),
              updated_at: admin.firestore.FieldValue.serverTimestamp(),
            });
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

      // BHV-15: drop the customer photos from Firebase Storage now that the
      // booking is dead — the artisan won't see them and admin doesn't need
      // them after cancellation. Best-effort, never blocks the response.
      try {
        const photoFields = [d.image_urls, d.work_images, d.imageUrls, d.images, d.photos, d.photoUrls];
        const allUrls = [];
        for (const f of photoFields) {
          if (Array.isArray(f)) allUrls.push(...f);
        }
        if (allUrls.length > 0) {
          deleteStoragePhotos(allUrls, `cancel_booking ${bid}`).catch(() => {});
        }
      } catch (e) { console.warn('[wa-tool] cancel photo-cleanup setup failed:', e.message); }

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
      const bid = String(args.bookingId || '').trim();
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
    // 12b) SET PREFERRED SCHEDULE (after accept_rfq_quote)
    // ═══════════════════════════════════════════
    case 'set_preferred_schedule': {
      if (!firestore) return { error: 'Database unavailable' };
      const bid = String(args.bookingId || session.lastRfqId || session.lastBookingId || '').trim();
      if (!bid) return { error: 'Please provide a booking/RFQ ID.' };
      const dateStr = String(args.preferredDate || '').trim();
      const timeStr = String(args.preferredTime || '').trim();
      const notes = String(args.notes || '').trim();
      if (!dateStr) return { error: 'Please provide a preferred date (YYYY-MM-DD).' };

      // Validate date format and that it's not in the past
      const parsed = new Date(dateStr);
      if (isNaN(parsed.getTime())) return { error: 'Invalid date format — use YYYY-MM-DD.' };
      const today = new Date(); today.setHours(0, 0, 0, 0);
      if (parsed < today) return { error: 'Preferred date must be today or later.' };

      let doc = await firestore.collection('futureBookings').doc(bid).get();
      if (!doc.exists) doc = await firestore.collection('tasksManagement').doc(bid).get();
      if (!doc.exists) return { error: `Booking "${bid}" not found.` };

      const data = doc.data() || {};
      let assignedIds = Array.isArray(data.rfq_assigned_artisan_ids) ? data.rfq_assigned_artisan_ids : [];
      let hasAssignedArtisan = assignedIds.length > 0;
      // Defensive: if accept_rfq_quote left the RFQ in 'accepted_converted'
      // because auto-dispatch matched zero artisans (or its fallback write
      // failed silently), the admin's "Waiting Assignment" filter never
      // surfaces it. Promote the status here so the admin sees the job in
      // the right bucket and can assign manually.
      const stuckAcceptedConverted =
        (data.rfq_status || '') === 'accepted_converted' && !hasAssignedArtisan;

      // ── RETRY DISPATCH (May 2026) ──────────────────────────────────────
      // If accept_rfq_quote couldn't match any artisan (e.g. the artisan
      // pool had no mainCategory / categories / userTasks populated for
      // this category, OR the deploy at the time predated the no-cat
      // fallback), the RFQ is stuck in `rfq_approved_waiting_assignment`
      // with `rfq_no_artisans_matched=true`. The client just told us when
      // they want the job done — last chance to actually get an artisan
      // before they get frustrated. Run a relaxed dispatch now: active
      // artisans with an FCM token, no category gate.
      const stuckNoArtisans = !hasAssignedArtisan
        && (data.rfq_no_artisans_matched === true || data.requires_admin_assignment === true);
      const retryPrice = Number(data.admin_quote_total || data.rfq_total || data.quoted_price || 0);
      const retryEligible = stuckNoArtisans && retryPrice > 0 && retryPrice < 12000;
      let retryDispatchAttempted = false;
      let retryDispatched = [];
      if (retryEligible) {
        retryDispatchAttempted = true;
        try {
          const artSnap = await firestore.collection('serviceProvider').limit(200).get();
          const pool = [];
          const REJECT = new Set(['pending','rejected','reject','suspended','inactive','disabled']);
          for (const d of artSnap.docs) {
            const ad = d.data() || {};
            if (ad.is_suspended === true) continue;
            if (ad.active != null && !isTruthyValue(ad.active)) continue;
            const st = ad.status == null ? '' : String(ad.status).toLowerCase();
            if (st && REJECT.has(st)) continue;
            const token = String(ad.fcm_token || ad.deviceToken || '').trim();
            if (!token) continue;
            pool.push({
              id: d.id,
              name: ad.name || ad.userName || ad.full_name || d.id,
              email: String(ad.email || ad.userEmail || '').trim().toLowerCase(),
              authUid: String(ad.uid || ad.userId || '').trim(),
              token,
            });
          }
          const chosen = pool.slice(0, 3);
          if (chosen.length > 0) {
            const artisanIds = chosen.map(a => a.id);
            const artisanNames = {};
            chosen.forEach(a => { artisanNames[a.id] = a.name; });
            const emails = chosen.map(a => a.email).filter(Boolean);
            const uids = chosen.map(a => a.authUid).filter(Boolean);
            const reDispatchUpdate = {
              rfq_status: 'pending_artisan_acceptance',
              status: 'pending_artisan_acceptance',
              rfq_submitted_to: 'artisan',
              rfq_assigned_artisan_ids: artisanIds,
              rfq_assigned_artisan_names: artisanNames,
              dispatched_artisan_emails: emails,
              dispatched_artisan_uids: uids,
              rfq_auto_assigned: true,
              rfq_auto_assign_reason: 'set_preferred_schedule_retry',
              rfq_auto_assigned_at: new Date().toISOString(),
              rfq_no_artisans_matched: false,
              requires_admin_assignment: false,
              rfq_artisan_rejection_count: 0,
              rfq_artisan_rejections: [],
              artisan_name: chosen[0].name,
              updated_at: new Date().toISOString(),
            };
            const reBatch = firestore.batch();
            reBatch.set(firestore.collection('futureBookings').doc(bid), reDispatchUpdate, { merge: true });
            reBatch.set(firestore.collection('tasksManagement').doc(bid), {
              ...reDispatchUpdate,
              is_rfq: 'yes',
              booking_id: bid,
              // Both camelCase and snake_case for cross-client compatibility.
              // The Flutter client reads `future_booking_id` (snake) — without
              // this the "Review Quote & Earnings" / profit-analysis button
              // never renders for an RFQ candidate.
              futureBookingId: bid,
              future_booking_id: bid,
              source: 'whatsapp_rfq',
              order_type: 'rfq',
            }, { merge: true });
            await reBatch.commit();
            for (const a of chosen) {
              try {
                await firestore.collection('notifications').add({
                  title: '🔔 New RFQ Job Available',
                  body: `RFQ ${data.rfq_no || bid} — R${retryPrice.toFixed(2)}. Tap to view and accept.`,
                  type: 'rfq_accepted',
                  user_type: 'artisan',
                  user_id: a.authUid || a.id,
                  sp_doc_id: a.id,
                  booking_id: bid,
                  priority: 'high',
                  read: false,
                  created_at: admin.firestore.FieldValue.serverTimestamp(),
                });
              } catch (_) {}
              try {
                await admin.messaging().send({
                  token: a.token,
                  notification: { title: '🔔 New RFQ Job Available', body: `RFQ ${data.rfq_no || bid} — R${retryPrice.toFixed(2)}. Tap to view and accept.` },
                  data: { type: 'rfq_accepted', booking_id: bid },
                  android: { notification: { channelId: 'order_request_channel', sound: 'sound' } },
                });
              } catch (fcmErr) { console.warn(`[wa-tool] retry FCM to ${a.name} failed:`, fcmErr.message); }
            }
            assignedIds = artisanIds;
            hasAssignedArtisan = true;
            retryDispatched = chosen;
            console.log(`[wa-tool] set_preferred_schedule retry dispatched RFQ ${bid} to ${chosen.length} artisan(s)`);
            try {
              await logErrorToAdmin(
                'dispatch_retry_succeeded',
                `RFQ ${bid} stuck in waiting_assignment was re-dispatched on schedule capture to ${chosen.length} active artisan(s). Backfill mainCategory/categories on serviceProvider docs to enable strict matching.`,
                'whatsapp_bot.set_preferred_schedule',
                '',
                bid,
                'medium'
              );
            } catch (_) {}
          } else {
            console.log(`[wa-tool] set_preferred_schedule retry: no eligible artisans for ${bid}`);
          }
        } catch (e) {
          console.warn('[wa-tool] set_preferred_schedule retry dispatch failed:', e.message);
        }
      }
      const update = {
        scheduled_date: dateStr,
        scheduled_time: timeStr,
        client_preferred_date: dateStr,
        client_preferred_time: timeStr,
        client_schedule_notes: notes,
        client_schedule_set_at: new Date().toISOString(),
        client_schedule_via: 'whatsapp',
        ...(stuckAcceptedConverted
          ? {
              rfq_status: 'rfq_approved_waiting_assignment',
              status: 'rfq_approved_waiting_assignment',
              requires_admin_assignment: true,
              rfq_no_artisans_matched: true,
            }
          : {}),
      };

      let _fbOk = false, _tmOk = false;
      try { await firestore.collection('futureBookings').doc(bid).set(update, { merge: true }); _fbOk = true; } catch (e) { console.warn('[wa-tool] set_preferred_schedule futureBookings failed:', e.message); }
      try { await firestore.collection('tasksManagement').doc(bid).set(update, { merge: true }); _tmOk = true; } catch (e) { console.warn('[wa-tool] set_preferred_schedule tasksManagement failed:', e.message); }
      if (!_fbOk && !_tmOk) {
        return { error: 'Could not save your preferred schedule right now. Please try again in a moment.' };
      }

      // Notify admin (Firestore + FCM tray push so admin sees it offline)
      const isWaitingAssignment = stuckAcceptedConverted
        || (data.rfq_status || '') === 'rfq_approved_waiting_assignment'
        || (data.requires_admin_assignment === true);
      try {
        await firestore.collection('notifications').add({
          title: isWaitingAssignment
            ? '📅 Client picked schedule — assign artisan'
            : 'Client preferred schedule set',
          body: `Client picked ${dateStr}${timeStr ? ' ' + timeStr : ''} for RFQ ${data.rfq_no || bid}.${notes ? ' Note: ' + notes : ''}${isWaitingAssignment ? ' Open RFQ Requests → Waiting Assignment to assign.' : ''}`,
          type: 'rfq_schedule_set',
          user_type: 'admin',
          booking_id: bid,
          priority: isWaitingAssignment ? 'high' : 'normal',
          read: false,
          created_at: admin.firestore.FieldValue.serverTimestamp(),
        });
      } catch (e) { console.warn('[wa-tool] set_preferred_schedule admin notify failed:', e.message); }
      try {
        await pushAdminNotification({
          title: isWaitingAssignment
            ? '📅 Client picked schedule (>R12K) — assign artisan'
            : '📅 Client picked a date',
          body: `RFQ ${data.rfq_no || bid}: ${dateStr}${timeStr ? ' ' + timeStr : ''}${notes ? ' — ' + notes : ''}`,
          type: 'rfq_schedule_set',
          bookingId: bid,
          extraData: { scheduled_date: dateStr, scheduled_time: timeStr, rfq_status: (data.rfq_status || '') },
        });
      } catch (e) { console.warn('[wa-tool] set_preferred_schedule FCM admin failed:', e.message); }

      // Notify assigned artisan(s) via FCM if any
      try {
        const ids = assignedIds;
        for (const aid of ids) {
          try {
            const aDoc = await firestore.collection('serviceProvider').doc(String(aid)).get();
            const ad = aDoc.exists ? (aDoc.data() || {}) : {};
            const token = ad.fcm_token || ad.deviceToken || '';
            if (!token) continue;
            await admin.messaging().send({
              token,
              notification: {
                title: '📅 Client picked a date',
                body: `RFQ ${data.rfq_no || bid}: ${dateStr}${timeStr ? ' ' + timeStr : ''}${notes ? ' — ' + notes : ''}`,
              },
              data: { type: 'rfq_schedule_set', booking_id: bid },
              android: { notification: { channelId: 'order_request_channel', sound: 'sound' } },
            });
          } catch (fcmErr) { console.warn('[wa-tool] set_preferred_schedule FCM artisan failed:', fcmErr.message); }
        }
      } catch (e) { console.warn('[wa-tool] set_preferred_schedule artisan loop failed:', e.message); }

      const cost = parseFloat(data.admin_quote_total || data.rfq_total || data.quoted_price || 0) || 0;
      const deposit = cost > 0 ? Math.round(cost * 0.35 * 100) / 100 : 0;
      const balance = cost > 0 ? Math.round((cost - deposit) * 100) / 100 : 0;
      const payHint = cost > 0
        ? `\n\n💰 *Payment options* (after artisan accepts):\n• Full: R${cost.toFixed(2)}\n• Deposit (35%): R${deposit.toFixed(2)} now, R${balance.toFixed(2)} after job completion\n\nReply "pay deposit" or "pay full" when an artisan accepts and you're ready, and I'll send a secure payment link.`
        : '';

      const artisanNotice = hasAssignedArtisan
        ? "⏳ I've notified the artisan. They'll confirm shortly."
        : "⏳ Our team is matching you with the right artisan and will confirm shortly.";

      return {
        success: true,
        message: `Got it — preferred schedule for RFQ ${data.rfq_no || bid}: *${dateStr}*${timeStr ? ' at *' + timeStr + '*' : ''}.${notes ? '\nNote: ' + notes : ''}\n\n${artisanNotice}${payHint}`,
        bookingId: bid,
        scheduledDate: dateStr,
        scheduledTime: timeStr,
      };
    }

    // ═══════════════════════════════════════════
    // 13) RATE BOOKING
    // ═══════════════════════════════════════════
    case 'rate_booking': {
      if (!firestore) return { error: 'Database unavailable' };
      const bid = String(args.bookingId || '').trim();
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
      // Pin session.lastBookingId so subsequent customer messages
      // ("refund", "send me a link") resolve to the just-rated booking.
      try {
        session.lastBookingId = bid;
        await firestore.collection('wa_sessions').doc(session.phone).set({
          phone: session.phone,
          lastBookingId: bid,
          lastBookingAt: Date.now(),
          lastActivity: admin.firestore.FieldValue.serverTimestamp(),
        }, { merge: true });
      } catch (_) {}
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
      const bid = String(args.bookingId || '').trim();
      if (!bid) return { error: 'Please provide a booking ID.' };

      let doc = await firestore.collection('tasksManagement').doc(bid).get();
      let docType = 'tasksManagement';
      if (!doc.exists) {
        doc = await firestore.collection('futureBookings').doc(bid).get();
        docType = 'futureBookings';
      }
      if (!doc.exists) return { error: `Booking "${bid}" not found.` };

      const d = doc.data();
      if (d.payment_status !== 'paid' && d.paymentStatus !== 'paid') {
        return { error: 'No payment found for this booking. Refunds are only available for paid bookings.' };
      }

      // Check if refund already requested
      const existingRefund = await firestore.collection('refund_requests')
        .where('source_doc_id', '==', bid).where('status', 'in', ['pending', 'processing']).limit(1).get();
      if (!existingRefund.empty) {
        return { message: 'A refund request for this booking is already being processed.' };
      }
      // Also check legacy booking_id field
      const existingLegacy = await firestore.collection('refund_requests')
        .where('booking_id', '==', bid).where('status', '==', 'pending').limit(1).get();
      if (!existingLegacy.empty) {
        return { message: 'A refund request for this booking is already being processed.' };
      }

      const cost = parseFloat(d.cost || '0');
      await firestore.collection('refund_requests').add({
        booking_id: bid,
        source_doc_id: bid,
        source_doc_type: docType,
        user_id: session.linkedUserId || d.user_id || '',
        phone: session.phone,
        amount: cost,
        payment_method: d.payment_method || 'unknown',
        reason: args.reason || 'Refund requested via WhatsApp',
        status: 'pending',
        source: 'whatsapp',
        created_at: admin.firestore.FieldValue.serverTimestamp(),
        updated_at: admin.firestore.FieldValue.serverTimestamp(),
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

      // Pin session.lastBookingId so a follow-up "status"/"link" request
      // resolves to the same booking the customer just disputed.
      try {
        session.lastBookingId = bid;
        await firestore.collection('wa_sessions').doc(session.phone).set({
          phone: session.phone,
          lastBookingId: bid,
          lastBookingAt: Date.now(),
          lastActivity: admin.firestore.FieldValue.serverTimestamp(),
        }, { merge: true });
      } catch (_) {}
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
      const userId = `wa_${maskPhone(session.phone)}`;
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

      const rfqId = String(args.rfqId || args.bookingId || session.lastRfqId || '').trim();
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

      const rfqId = String(args.rfqId || args.bookingId || session.lastRfqId || '').trim();
      if (!rfqId) return { error: 'Please provide the RFQ ID.' };

      const doc = await firestore.collection('futureBookings').doc(rfqId).get();
      if (!doc.exists) return { error: `RFQ "${rfqId}" not found.` };

      const data = doc.data();
      if (!data.quoted_price && !data.ai_quote && !data.admin_quote_total && !data.rfq_total) {
        return { error: 'This RFQ does not have a quote yet. Please wait for the quote to be generated.' };
      }

      // LOW-19: idempotency — don't re-run auto-dispatch on duplicate accept.
      const ALREADY_ACCEPTED = new Set([
        'accepted_converted', 'pending_artisan_acceptance', 'rfq_approved_waiting_assignment',
        'rfq_approved', 'pending_payment', 'paid', 'deposit_paid', 'in_progress', 'completed',
      ]);
      const existingRfqStatus = String(data.rfq_status || '').toLowerCase();
      const existingStatus = String(data.status || '').toLowerCase();
      if (ALREADY_ACCEPTED.has(existingRfqStatus) || ALREADY_ACCEPTED.has(existingStatus)) {
        const priceAlready = parseFloat(data.admin_quote_total || data.rfq_total || data.quoted_price || data.cost || '0');
        session.lastBookingId = rfqId;
        session.lastBookingCost = priceAlready;
        return {
          success: true,
          message: `Quote for RFQ ${data.rfq_no || rfqId} is already accepted. We'll let you know as soon as an artisan accepts.`,
          rfqId,
          deduped: true,
        };
      }
      const TERMINAL_BAD_RFQ = new Set(['rejected', 'cancelled', 'canceled', 'closed', 'expired']);
      if (TERMINAL_BAD_RFQ.has(existingRfqStatus) || TERMINAL_BAD_RFQ.has(existingStatus)) {
        return { error: `This quote can no longer be accepted (status: ${existingStatus || existingRfqStatus}).` };
      }

      // Prefer admin-amended totals (set when admin reviews/amends the quote)
      // over the raw AI quoted_price so the client is charged the correct amount.
      const price = data.admin_quote_total
        || data.rfq_total
        || data.quoted_price
        || (data.ai_quote ? data.ai_quote.grand_total : '0');
      const baseCost = parseFloat(price);

      // BHV-1: apply customer's promo code if present. The previous flow
      // silently dropped session.promoCode on the RFQ path — only
      // create_booking honoured it. Now mirror that logic here so RFQ
      // customers get their discount too. After applying, re-derive
      // deposit/balance from the discounted total.
      let priceNum = baseCost;
      let promoApplied = null;
      if (session.promoCode && session.promoDiscount > 0) {
        let discount;
        if (session.promoDiscountType === 'percentage') {
          discount = Math.round(baseCost * session.promoDiscount / 100 * 100) / 100;
        } else {
          discount = Number(session.promoDiscount);
        }
        discount = Math.min(discount, baseCost);
        if (discount > 0) {
          priceNum = Math.round(Math.max(0, baseCost - discount) * 100) / 100;
          promoApplied = { code: session.promoCode, discount, type: session.promoDiscountType || 'fixed' };
          console.log(`[wa-tool] accept_rfq_quote: applied promo ${session.promoCode} -R${discount} (base R${baseCost} -> R${priceNum})`);
        }
      }
      const depositAmount = Math.round(priceNum * 0.35 * 100) / 100;
      const balanceAmount = Math.round((priceNum - depositAmount) * 100) / 100;

      // HIGH-6: sanity-check admin-amended totals against the AI baseline.
      // We don't block — admin may legitimately re-quote — but we surface
      // any 0.5×–2.0× deviations to error_logs so suspicious typos get caught.
      try {
        const aiBase = parseFloat((data.ai_quote && data.ai_quote.grand_total) || data.quoted_price || '0');
        const adminTotal = parseFloat(data.admin_quote_total || '0');
        if (aiBase > 0 && adminTotal > 0) {
          const ratio = adminTotal / aiBase;
          if (ratio < 0.5 || ratio > 2.0) {
            await logErrorToAdmin(
              'admin_quote_outlier',
              `RFQ ${rfqId}: admin_quote_total R${adminTotal.toFixed(2)} is ${ratio.toFixed(2)}× the AI baseline R${aiBase.toFixed(2)}. Customer accepted at R${priceNum.toFixed(2)}.`,
              'whatsapp_bot.accept_rfq_quote',
              '',
              rfqId,
              'medium'
            );
          }
        }
        if (priceNum <= 0 || priceNum > 1000000) {
          await logErrorToAdmin(
            'accepted_price_out_of_range',
            `RFQ ${rfqId} accepted with implausible price R${priceNum}. Review before payment.`,
            'whatsapp_bot.accept_rfq_quote',
            '',
            rfqId,
            'high'
          );
        }
      } catch (_) {}

      // R12K cap: bookings >= R12000 must NOT auto-dispatch. Admin assigns
      // manually (internal team or external artisan). Use the dedicated
      // 'rfq_approved_waiting_assignment' status so the admin RFQ list's
      // "Waiting Assignment" filter surfaces the booking immediately.
      //
      // CRITICAL-2 (state-race fix): start ALL accepted RFQs in
      // 'rfq_approved_waiting_assignment'. The auto-dispatch block below
      // promotes under-R12K bookings to 'pending_artisan_acceptance' ONLY
      // AFTER it has confirmed at least one matched artisan and written
      // their IDs. If the auto-dispatch update fails or matches zero
      // artisans, the RFQ stays in waiting_assignment — admin can always
      // see and reassign it. Previously the initial write was
      // pending_artisan_acceptance, so a failure of the second update left
      // the RFQ stuck in a "pending artisan" terminal state with no
      // artisans actually assigned (and no admin-list visibility).
      const overR12K = priceNum >= 12000;
      const rfqStatusOnAccept = overR12K
        ? 'rfq_approved_waiting_assignment'
        : 'accepted_converted';
      const statusOnAccept = 'rfq_approved_waiting_assignment';

      // CRITICAL (audit Apr-2026): wrap the dual-collection write in a
      // batch so futureBookings + tasksManagement update atomically.
      // Previously two sequential awaits could leave the booking in an
      // inconsistent state if the second write failed (admin sees the
      // RFQ as "accepted" in one list but downstream wallet/cancel
      // tools that key off tasksManagement would silently 404).
      const _acceptBatch = firestore.batch();
      _acceptBatch.update(firestore.collection('futureBookings').doc(rfqId), {
        rfq_status: rfqStatusOnAccept,
        status: statusOnAccept,
        artisan_confirmed: 'pending',
        requires_admin_assignment: overR12K,
        // Sync the canonical cost fields with the (possibly admin-amended) price
        // so /api/artisan-accepted, the admin app, and the artisan app all
        // surface the same total to the client.
        cost: priceNum.toFixed(2),
        total_price: priceNum.toFixed(2),
        quoted_price: priceNum.toFixed(2),
        deposit_amount: depositAmount.toFixed(2),
        balance_amount: balanceAmount.toFixed(2),
        // BHV-1: persist promo so admin app + artisan app + reconciliation
        // can all see what discount was honoured.
        base_cost: baseCost.toFixed(2),
        promo_code: promoApplied ? promoApplied.code : null,
        promo_discount: promoApplied ? promoApplied.discount : 0,
        payment_type: '',
        deposit_paid: false,
        balance_paid: false,
        accepted_at: new Date().toISOString(),
        accepted_via: 'whatsapp',
      });

      // Mirror accepted RFQ to tasksManagement so all downstream handlers
      // (cancel, reschedule, wallet payment, admin app) can find it
      _acceptBatch.set(firestore.collection('tasksManagement').doc(rfqId), {
        id: rfqId,
        order_no: data.order_no || data.rfq_no || rfqId,
        user_id: data.user_id || session.linkedUserId || '',
        user_name: data.user_name || '',
        user_phone: data.user_phone || session.phone,
        category_name: data.category_name || '',
        description: data.description || data.problem_description || '',
        problem_description: data.problem_description || data.description || '',
        address: data.address || '',
        status: statusOnAccept,
        artisan_confirmed: 'pending',
        accept: '',
        payment_status: 'unpaid',
        cost: priceNum.toFixed(2),
        total_cost: priceNum.toFixed(2),
        deposit_amount: depositAmount.toFixed(2),
        balance_amount: balanceAmount.toFixed(2),
        // BHV-1: mirror promo to tasksManagement.
        base_cost: baseCost.toFixed(2),
        promo_code: promoApplied ? promoApplied.code : null,
        promo_discount: promoApplied ? promoApplied.discount : 0,
        payment_type: '',
        deposit_paid: false,
        balance_paid: false,
        source: 'whatsapp_rfq',
        is_rfq: 'yes',
        rfq_status: rfqStatusOnAccept,
        requires_admin_assignment: overR12K,
        service_provider_id: data.service_provider_id || '',
        service_provider_name: data.service_provider_name || '',
        scheduled_date: data.scheduled_date || '',
        scheduled_time: data.scheduled_time || '',
        created_at: data.created_at || new Date().toISOString(),
        accepted_at: new Date().toISOString(),
        accepted_via: 'whatsapp',
      }, { merge: true });
      await _acceptBatch.commit();

      // Notify admin to assign an artisan
      await firestore.collection('notifications').add({
        title: overR12K
          ? '⚠️ RFQ Accepted (>R12K) — Assign Artisan Manually'
          : 'RFQ Quote Accepted — Assign Artisan',
        body: overR12K
          ? `Customer accepted quote for RFQ ${data.rfq_no || rfqId} (R${priceNum.toFixed(2)}) — over R12K cap. Please assign internally or externally from RFQ Requests → Waiting Assignment.`
          : `Customer accepted quote for RFQ ${data.rfq_no || rfqId} (R${priceNum.toFixed(2)}). Please assign an artisan.`,
        type: overR12K ? 'rfq_accepted_admin_review' : 'rfq_accepted',
        user_type: 'admin',
        booking_id: rfqId,
        rfq_status: rfqStatusOnAccept,
        priority: overR12K ? 'high' : 'normal',
        read: false,
        created_at: admin.firestore.FieldValue.serverTimestamp(),
      });
      // FCM push so admin phones tray lights up even when app is closed
      const materialsRespForPush = (data.materials_responsibility || '').toString().trim().toLowerCase();
      const overCap = overR12K;
      await pushAdminNotification({
        title: overCap ? '⚠️ RFQ Accepted — Needs Admin Assignment (> R12K)' : 'RFQ Quote Accepted',
        body: `R${priceNum.toFixed(2)} — ${data.user_name || 'Client'} accepted RFQ ${data.rfq_no || rfqId}. ${overCap ? 'Over R12K cap — open Admin > RFQ Requests > Waiting Assignment to assign internally or externally.' : 'Will auto-dispatch to artisans.'}`,
        type: overCap ? 'rfq_accepted_admin_review' : 'rfq_accepted',
        bookingId: rfqId,
        extraData: { price: String(priceNum), materials_responsibility: materialsRespForPush, over_12k: overCap ? '1' : '0', rfq_status: rfqStatusOnAccept },
      });

      // ── Auto-dispatch: route directly to artisans when conditions met ──
      // RULE (2026-04-23): R12K is an ABSOLUTE cap. Even if the client buys
      // materials (labour-only), any quote >= R12K must be reviewed by admin
      // and dispatched manually. Under R12K, auto-dispatch happens whether
      // the client or the artisan supplies materials.
      const materialsResp = (data.materials_responsibility || '').toString().trim().toLowerCase();
      const clientBuysMaterials = materialsResp === 'client';
      const underThreshold = priceNum > 0 && priceNum < 12000;
      let autoDispatched = false;

      if (underThreshold) {
        const autoReason = clientBuysMaterials ? 'client_buys_materials_under_12k' : 'under_12k';
        const cat = (data.category || data.category_name || '').toLowerCase().replace(/\s+/g, '_');
        // ── International dispatch (2026-04-14): prefer artisans in the same
        // country/region as the customer. Country derived from (1) explicit
        // customer_country field, (2) phone E.164 prefix.
        const customerCountry = (function deriveCountry() {
          const explicit = String(data.customer_country || data.country || '').trim().toUpperCase();
          if (explicit) return explicit;
          const phoneDigits = String(data.user_phone || data.client_phone || data.customerPhone || '').replace(/[^0-9]/g, '');
          // Order matters — longer prefixes first
          const PREFIXES = [
            { p: '266', c: 'LS' }, { p: '267', c: 'BW' }, { p: '264', c: 'NA' },
            { p: '263', c: 'ZW' }, { p: '268', c: 'SZ' }, { p: '258', c: 'MZ' },
            { p: '260', c: 'ZM' }, { p: '265', c: 'MW' }, { p: '255', c: 'TZ' },
            { p: '254', c: 'KE' }, { p: '27',  c: 'ZA' }, { p: '1',   c: 'US' },
            { p: '44',  c: 'GB' },
          ];
          for (const { p, c } of PREFIXES) {
            if (phoneDigits.startsWith(p)) return c;
          }
          return '';
        })();
        const addressLower = String(data.address || data.provided_address || '').toLowerCase();
        const COUNTRY_KEYWORDS = {
          LS: ['lesotho', 'maseru', 'maputsoe', 'leribe', 'mafeteng'],
          BW: ['botswana', 'gaborone', 'francistown', 'maun'],
          NA: ['namibia', 'windhoek', 'swakopmund', 'walvis bay'],
          ZW: ['zimbabwe', 'harare', 'bulawayo'],
          SZ: ['eswatini', 'swaziland', 'mbabane', 'manzini'],
          ZA: ['south africa', 'johannesburg', 'cape town', 'durban', 'pretoria', 'sandton', 'soweto', 'gauteng', 'limpopo', 'mpumalanga', 'free state'],
        };
        let inferredCountry = customerCountry;
        if (!inferredCountry) {
          for (const [code, kws] of Object.entries(COUNTRY_KEYWORDS)) {
            if (kws.some(k => addressLower.includes(k))) { inferredCountry = code; break; }
          }
        }
        try {
          // CL-MATCH (May 2026): production artisans don't populate
          // serviceProvider.categories — they register individual TASKS via
          // userTasks instead. Build a fallback set of artisan IDs that have
          // userTasks linking them to ANY task in this RFQ's category (or
          // its sub-categories). We use this in the loop below: an artisan
          // with empty `categories` but a matching userTasks record IS
          // eligible.
          const userTasksArtisanIds = new Set();
          if (cat) {
            try {
              // Resolve category doc(s) matching this name (top-level + subs).
              const catSnap = await firestore.collection('categories').get();
              const catNameMatches = new Set();
              for (const d of catSnap.docs) {
                const dd = d.data() || {};
                const nm = String(dd.name || '').toLowerCase().replace(/\s+/g, '_');
                if (nm === cat) catNameMatches.add(d.id);
              }
              const subCatIds = new Set();
              for (const d of catSnap.docs) {
                const dd = d.data() || {};
                const parent = String(dd.parent_id || '');
                if (catNameMatches.has(parent)) subCatIds.add(d.id);
              }
              const allCatIds = new Set([...catNameMatches, ...subCatIds]);
              if (allCatIds.size > 0) {
                const taskSnap2 = await firestore.collection('tasks').get();
                const matchingTaskIds = new Set();
                for (const td of taskSnap2.docs) {
                  const tdd = td.data() || {};
                  const cid = String(tdd.categoryId || tdd.category_id || '');
                  if (allCatIds.has(cid)) {
                    matchingTaskIds.add(td.id);
                    const legacyId = String(tdd.id || '');
                    if (legacyId) matchingTaskIds.add(legacyId);
                  }
                }
                if (matchingTaskIds.size > 0) {
                  const utSnap = await firestore.collection('userTasks').get();
                  for (const ud of utSnap.docs) {
                    const udd = ud.data() || {};
                    const tid = String(udd.task_id || udd.taskId || '');
                    if (matchingTaskIds.has(tid)) {
                      const aid = String(udd.user_id || udd.userId || '');
                      if (aid) userTasksArtisanIds.add(aid);
                    }
                  }
                  console.log(`[wa-tool] auto-dispatch: userTasks fallback resolved ${userTasksArtisanIds.size} artisan(s) for cat="${cat}"`);
                }
              }
            } catch (utErr) {
              console.warn('[wa-tool] auto-dispatch userTasks fallback failed:', utErr.message);
            }
          }
          // Fetch ALL artisans and gate in code — many artisan docs have no
          // `status` field at all, which an inequality/in filter would hide.
          // We only refuse explicit non-eligible statuses.
          const artisanSnap = await firestore.collection('serviceProvider')
            .limit(200)
            .get();
          const REJECT_STATUSES = new Set(['pending', 'rejected', 'reject', 'suspended', 'inactive', 'disabled']);
          const sameCountryArtisans = [];
          const otherArtisans = [];
          // BUG-FIX (May 2026): track artisans that pass status/active/country
          // but FAIL only the category gate. When the primary match returns
          // zero (e.g. because no artisan in production has populated
          // mainCategory/categories/userTasks), we'll fall back to this pool
          // rather than dead-ending the RFQ in admin "Waiting Assignment".
          // Without this, every WA RFQ stalls until a human notices.
          const sameCountryNoCatMatch = [];
          let categoryRejected = 0;
          let countryRejected = 0;
          let suspendedRejected = 0;
          let inactiveRejected = 0;
          let zaCountryFallbackUsed = 0;
          for (const artDoc of artisanSnap.docs) {
            const ad = artDoc.data() || {};
            // Skip suspended artisans (checked in code, not query)
            if (ad.is_suspended === true) { suspendedRejected += 1; continue; }
            // Reject only explicitly bad statuses; missing/undefined status is OK
            const st = (ad.status == null) ? '' : String(ad.status).toLowerCase();
            if (st && REJECT_STATUSES.has(st)) { suspendedRejected += 1; continue; }
            // Check active status — only the manual toggle gates dispatch
            const activeField = ad.active;
            if (activeField != null && !isTruthyValue(activeField)) { inactiveRejected += 1; continue; }
            const cats = (ad.categories || ad.category || '').toString().toLowerCase().trim();
            // CL-MATCH (May 2026 follow-up): the canonical artisan model
            // (services_provider_model.dart) stores specialty in
            // `mainCategory` / `subCategory`, NOT in `categories`. So a
            // plumber registered as mainCategory='Plumbing' but with no
            // `categories` field was being silently rejected here, leaving
            // RFQs stuck in admin "Waiting Assignment" with zero artisans
            // matched. Treat mainCategory/subCategory as additional
            // sources for the category match.
            const mainCat = String(ad.mainCategory || ad.main_category || '').toLowerCase().replace(/\s+/g, '_').trim();
            const subCat = String(ad.subCategory || ad.sub_category || '').toLowerCase().replace(/\s+/g, '_').trim();
            // MED-13: stop letting `general_maintenance` RFQs blast every
            // artisan regardless of specialisation. Require an explicit
            // category match (or that the artisan declares
            // general_maintenance themselves).
            // BHV-3: empty/missing categories means the artisan hasn't
            // declared a specialty — reject for any specific category job.
            // Previously `if (cats && cat)` skipped the check entirely when
            // cats=='', so a plumber-with-empty-categories matched every job.
            // Compute the artisan record + country eligibility up-front so we
            // can ALSO record artisans that pass everything except category
            // — used as a last-resort fallback further down when 0 artisans
            // match the strict gates.
            const aName = ad.name || ad.userName || ad.full_name || artDoc.id;
            const aEmail = (ad.email || ad.userEmail || ad.contact_email || '').toString().trim().toLowerCase();
            // BUG-FIX (May 12 2026): the artisan's Firebase Auth UID lives
            // in `ad.uid` (see ServiceProviderModelFields.uid). The SP
            // *document id* (artDoc.id) is auto-generated and is NOT the
            // auth UID. Without this we can't address the artisan via
            // notifications (user_id == auth.uid) or via the rule path
            // `request.auth.uid in dispatched_artisan_uids`, which is
            // exactly why repeated WA dispatches "don't reach the
            // artisan" even though the dispatch loop ran successfully.
            const aAuthUid = (ad.uid || ad.userId || '').toString().trim();
            const aRecord = { id: artDoc.id, authUid: aAuthUid, name: aName, email: aEmail, token: (ad.fcm_token || ad.deviceToken || '').toString().trim() };
            // Country fields: country (code or name), countries_served (array or comma string), region, city
            const artCountry = String(ad.country || ad.country_code || '').trim().toUpperCase();
            const served = (function () {
              const v = ad.countries_served || ad.serviceCountries || ad.regions || '';
              if (Array.isArray(v)) return v.map(s => String(s).trim().toUpperCase());
              return String(v).split(/[,;]/).map(s => s.trim().toUpperCase()).filter(Boolean);
            })();
            const COUNTRY_NAME_TO_CODE = { 'SOUTH AFRICA': 'ZA', 'LESOTHO': 'LS', 'BOTSWANA': 'BW', 'NAMIBIA': 'NA', 'ZIMBABWE': 'ZW', 'ESWATINI': 'SZ', 'SWAZILAND': 'SZ' };
            const artCountryCode = COUNTRY_NAME_TO_CODE[artCountry] || artCountry;
            const servedCodes = served.map(s => COUNTRY_NAME_TO_CODE[s] || s);
            const artisanHasNoCountry = !artCountryCode && servedCodes.length === 0;
            const effectiveArtCountry = artisanHasNoCountry ? 'ZA' : artCountryCode;
            const effectiveServed = artisanHasNoCountry ? ['ZA'] : servedCodes;
            if (artisanHasNoCountry) zaCountryFallbackUsed += 1;
            const matchesCustomerCountry = inferredCountry && (
              effectiveArtCountry === inferredCountry || effectiveServed.includes(inferredCountry)
            );

            if (cat) {
              const utFallbackMatch = userTasksArtisanIds.has(artDoc.id);
              const mainSubMatch = (mainCat && (mainCat.includes(cat) || cat.includes(mainCat))) ||
                (subCat && (subCat.includes(cat) || cat.includes(subCat))) ||
                mainCat === 'general_maintenance';
              let catOk;
              if (!cats) {
                // CL-MATCH: artisan didn't fill `categories` — accept iff
                // they registered a userTask under this category OR their
                // mainCategory/subCategory matches.
                catOk = utFallbackMatch || mainSubMatch;
              } else {
                const explicitMatch = cats.includes(cat) || cats.includes('general_maintenance');
                catOk = explicitMatch || utFallbackMatch || mainSubMatch;
              }
              if (!catOk) {
                categoryRejected += 1;
                // Record into the no-cat-match pool ONLY if they would have
                // otherwise been a same-country candidate. This pool is the
                // last-resort fallback when zero artisans match strictly.
                if (matchesCustomerCountry) sameCountryNoCatMatch.push(aRecord);
                continue;
              }
            }

            if (matchesCustomerCountry) sameCountryArtisans.push(aRecord);
            else { countryRejected += 1; otherArtisans.push(aRecord); }
          }
          // Prefer same-country; only fall back to others if zero same-country matches.
          // For SA (ZA) — the largest pool — keep historical behaviour: if customer
          // is ZA or unknown, treat all matched artisans as eligible.
          let matchedArtisans;
          if (inferredCountry && inferredCountry !== 'ZA' && sameCountryArtisans.length > 0) {
            matchedArtisans = sameCountryArtisans.slice(0, 3);
          } else if (inferredCountry && inferredCountry !== 'ZA') {
            // No same-country artisan — escalate to admin instead of blasting SA artisans.
            matchedArtisans = [];
            console.log(`[wa-tool] auto-dispatch RFQ ${rfqId} country=${inferredCountry} — no in-country artisan; escalating to admin`);
            // HIGH-5: surface this to error_logs so admin sees the gap.
            try {
              await logErrorToAdmin(
                'no_in_country_artisan',
                `RFQ ${rfqId} customer in ${inferredCountry}: 0 artisans declared this country. Escalated to admin.`,
                'whatsapp_bot.accept_rfq_quote',
                '',
                rfqId,
                'high'
              );
            } catch (_) {}
          } else {
            // ZA or unknown — historical broad dispatch (cap 3)
            matchedArtisans = sameCountryArtisans.concat(otherArtisans).slice(0, 3);
          }

          // BUG-FIX (May 2026): LAST-RESORT FALLBACK. If the strict pipeline
          // returned zero candidates but we DO have artisans who passed
          // status/active/country checks (and only failed the category gate
          // because production artisans haven't populated mainCategory /
          // categories / userTasks), dispatch to them anyway. Without this,
          // every WA RFQ silently dead-ends in admin "Waiting Assignment"
          // and the artisan never sees the request — exactly the bug
          // reported on 2026-05-08. We log a high-severity admin alert so
          // ops can backfill artisan profile data.
          let usedNoCatFallback = false;
          if (matchedArtisans.length === 0 && sameCountryNoCatMatch.length > 0
              && (!inferredCountry || inferredCountry === 'ZA')) {
            matchedArtisans = sameCountryNoCatMatch.slice(0, 3);
            usedNoCatFallback = true;
            console.warn(`[wa-tool] RFQ ${rfqId} NO-CAT-FALLBACK: dispatching to ${matchedArtisans.length} artisan(s) ignoring category match (no artisans had mainCategory/categories/userTasks for cat="${cat}")`);
            try {
              await logErrorToAdmin(
                'dispatch_no_category_match',
                `RFQ ${rfqId} cat="${cat}": 0 artisans had matching category data. Dispatched to ${matchedArtisans.length} active artisan(s) as fallback. Backfill mainCategory/categories on serviceProvider docs to restore strict matching.`,
                'whatsapp_bot.accept_rfq_quote',
                '',
                rfqId,
                'high'
              );
            } catch (_) {}
          }
          // MED-18: surface dispatch funnel so admin can tune eligibility.
          console.log(`[wa-tool] auto-dispatch RFQ ${rfqId} cat="${cat}" country="${inferredCountry || 'unknown'}" — scanned=${artisanSnap.size}, in-country=${sameCountryArtisans.length}, other-country=${otherArtisans.length}, no-cat-fallback-pool=${sameCountryNoCatMatch.length}, dispatched=${matchedArtisans.length}${usedNoCatFallback ? ' (no-cat fallback)' : ''}, filtered{cat=${categoryRejected}, suspended=${suspendedRejected}, inactive=${inactiveRejected}, country=${countryRejected}}, za-country-fallback=${zaCountryFallbackUsed}`);
          if (matchedArtisans.length > 0) {
            const artisanIds = matchedArtisans.map(a => a.id);
            const artisanNames = {};
            matchedArtisans.forEach(a => { artisanNames[a.id] = a.name; });
            // Lower-cased email array used by firestore rules' `isRfqCandidate`
            // helper to authorize the dispatched artisan to read the parent
            // futureBookings doc (their auth.uid != serviceProvider doc id).
            const dispatchedEmails = matchedArtisans
              .map(a => (a.email || '').toString().trim().toLowerCase())
              .filter(e => e.length > 0);
            // BUG-FIX (May 12 2026): also expose the artisan's Firebase
            // Auth UID so the rule has a path that doesn't depend on a
            // correctly-populated email field on the serviceProvider doc.
            // The artisan dashboard's stream (and the notifications
            // stream) can then key off this array.
            const dispatchedAuthUids = matchedArtisans
              .map(a => (a.authUid || '').toString().trim())
              .filter(u => u.length > 0);

            // MED-14: batch the futureBookings + tasksManagement updates so
            // the dispatch state can never be half-written.
            let dispatchBatchOk = false;
            try {
              // BUG-FIX (May 2026): Use set+merge instead of update so the
              // batch does not abort when the tasksManagement doc has not
              // been written yet (RFQs created via WA only write to
              // futureBookings at create-time). Previously the batch failed
              // atomically, leaving rfq_assigned_artisan_ids unset on BOTH
              // collections — so the artisan app's stream (which keys off
              // that array) never showed the dispatched RFQ.
              const dispatchBatch = firestore.batch();
              dispatchBatch.set(
                firestore.collection('futureBookings').doc(rfqId),
                {
                  rfq_status: 'pending_artisan_acceptance',
                  status: 'pending_artisan_acceptance',
                  rfq_submitted_to: 'artisan',
                  rfq_assigned_artisan_ids: artisanIds,
                  rfq_assigned_artisan_names: artisanNames,
                  dispatched_artisan_emails: dispatchedEmails,
                  dispatched_artisan_uids: dispatchedAuthUids,
                  rfq_auto_assigned: true,
                  rfq_auto_assign_reason: autoReason,
                  rfq_auto_assigned_at: new Date().toISOString(),
                  rfq_artisan_rejection_count: 0,
                  rfq_artisan_rejections: [],
                  artisan_name: matchedArtisans[0].name,
                  updated_at: new Date().toISOString(),
                },
                { merge: true }
              );
              dispatchBatch.set(
                firestore.collection('tasksManagement').doc(rfqId),
                {
                  status: 'pending_artisan_acceptance',
                  rfq_status: 'pending_artisan_acceptance',
                  rfq_assigned_artisan_ids: artisanIds,
                  dispatched_artisan_emails: dispatchedEmails,
                  dispatched_artisan_uids: dispatchedAuthUids,
                  rfq_auto_assigned: true,
                  rfq_auto_assign_reason: autoReason,
                  // Mirror identity fields so the artisan stream has the
                  // basics even when the doc is being created here.
                  is_rfq: 'yes',
                  booking_id: rfqId,
                  // Both camelCase + snake_case so all clients can resolve
                  // the linked futureBookings doc (Flutter reads snake_case).
                  futureBookingId: rfqId,
                  future_booking_id: rfqId,
                  source: 'whatsapp_rfq',
                  order_type: 'rfq',
                  updated_at: new Date().toISOString(),
                },
                { merge: true }
              );
              await dispatchBatch.commit();
              dispatchBatchOk = true;
            } catch (batchErr) {
              console.warn('[wa-tool] dispatch batch commit failed:', batchErr.message);
              try {
                await logErrorToAdmin(
                  'dispatch_batch_failure',
                  `RFQ ${rfqId} auto-dispatch batch commit failed: ${batchErr.message}. RFQ left in waiting_assignment.`,
                  'whatsapp_bot.accept_rfq_quote',
                  batchErr.message,
                  rfqId,
                  'high'
                );
              } catch (_) {}
            }

            if (dispatchBatchOk) {
              for (const art of matchedArtisans) {
                // BUG-FIX (May 12 2026): write the notification doc keyed
                // by the artisan's Firebase Auth UID (`art.authUid`) so
                // their notifications stream — which queries
                // `user_id == auth.uid` — actually picks it up. The SP
                // doc id (`art.id`) is NOT the auth UID. Falling back to
                // the doc id is a no-op for the artisan (the rules
                // refuse the read) but keeps the doc around for admin
                // visibility.
                const notifUserId = art.authUid || art.id;
                try {
                  await firestore.collection('notifications').add({
                    title: '🔔 New RFQ Job Available',
                    body: `RFQ ${data.rfq_no || rfqId} — R${priceNum.toFixed(2)}. Tap to view and accept.`,
                    type: 'rfq_accepted',
                    user_type: 'artisan',
                    user_id: notifUserId,
                    sp_doc_id: art.id,
                    booking_id: rfqId,
                    priority: 'high',
                    read: false,
                    created_at: admin.firestore.FieldValue.serverTimestamp(),
                  });
                } catch (notifErr) { console.warn(`[wa-tool] artisan notif doc failed for ${art.id}:`, notifErr.message); }
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
              console.log(`[wa-tool] Auto-dispatched RFQ ${rfqId} to ${artisanIds.length} artisans (${autoReason}) emails=${dispatchedEmails.length} uids=${dispatchedAuthUids.length}`);
            }
          } else {
            console.log(`[wa-tool] No artisans matched for RFQ ${rfqId} — admin will assign manually`);
          }
        } catch (e) { console.warn('[wa-tool] auto-dispatch failed, falling back to admin:', e.message); }
      }

      if (autoDispatched) {
        console.log(`[wa-tool] RFQ ${rfqId} auto-dispatched to artisans (under R12K or client buys materials)`);
      } else {
        // No auto-dispatch happened — either over R12K (already flagged) or
        // under R12K with zero matching artisans. Either way, force the RFQ
        // into admin "Waiting Assignment" so it doesn't dead-end.
        try {
          await firestore.collection('futureBookings').doc(rfqId).update({
            rfq_status: 'rfq_approved_waiting_assignment',
            status: 'rfq_approved_waiting_assignment',
            requires_admin_assignment: true,
            rfq_no_artisans_matched: !overR12K, // distinguish "over cap" vs "no eligible artisans"
            updated_at: new Date().toISOString(),
          });
          await firestore.collection('tasksManagement').doc(rfqId).set({
            rfq_status: 'rfq_approved_waiting_assignment',
            status: 'rfq_approved_waiting_assignment',
            requires_admin_assignment: true,
            updated_at: new Date().toISOString(),
          }, { merge: true });
          await pushAdminNotification({
            title: overR12K
              ? '⚠️ RFQ Accepted (>R12K) — Assign Artisan Manually'
              : '⚠️ RFQ Accepted — No Artisans Matched, Assign Manually',
            body: `R${priceNum.toFixed(2)} — ${data.user_name || 'Client'} accepted RFQ ${data.rfq_no || rfqId}. Open Admin > RFQ Requests > Waiting Assignment.`,
            type: 'rfq_accepted_admin_review',
            bookingId: rfqId,
            extraData: { price: String(priceNum), rfq_status: 'rfq_approved_waiting_assignment', over_12k: overR12K ? '1' : '0', no_artisans: overR12K ? '0' : '1' },
          });
          console.log(`[wa-tool] RFQ ${rfqId} flagged for admin manual assignment (overR12K=${overR12K})`);
        } catch (e) {
          console.warn(`[wa-tool] failed to flag RFQ ${rfqId} for admin assignment:`, e.message);
        }
      }

      // BHV-1: record promo redemption + clear from session.
      if (promoApplied) {
        try {
          await firestore.collection('promo_redemptions').add({
            promo_id: session.promoId || null,
            promo_code: promoApplied.code,
            user_id: session.linkedUserId || session.phone,
            task_management_id: rfqId,
            booking_id: rfqId,
            job_amount: baseCost,
            discount_amount: promoApplied.discount,
            source: 'whatsapp_rfq',
            created_at: new Date().toISOString(),
          });
          if (session.promoId) {
            await firestore.collection('promo_codes').doc(session.promoId).update({
              used_count: admin.firestore.FieldValue.increment(1),
            });
          }
          session.promoCode = null;
          session.promoDiscount = 0;
          session.promoDiscountType = null;
          session.promoId = null;
        } catch (e) { console.warn('[wa-tool] accept_rfq promo redemption tracking failed:', e.message); }
      }

      // Store for quick payment follow-up
      session.lastBookingId = rfqId;
      session.lastBookingCost = priceNum;

      return {
        success: true,
        message: `Quote accepted! RFQ ${data.rfq_no || rfqId} — Total: R${priceNum.toFixed(2)}${promoApplied ? ` (promo ${promoApplied.code} -R${promoApplied.discount.toFixed(2)} applied)` : ''}.\n\n📅 *When would you like the work done?* Please reply with your preferred date and time (e.g. "Friday morning" or "27 Apr 14:00"). I'll pass it to the artisan.\n\n⏳ *Next step:* An artisan needs to accept your job before payment. We'll notify you as soon as one accepts.\n\n🔒 *Your money is protected:* When it's time to pay, your payment is held in a secure escrow account. The artisan does NOT receive your money until you confirm you are satisfied with the completed work.\n\n💰 *Payment options (after artisan accepts):*\n• Full amount: R${priceNum.toFixed(2)}\n• Deposit (35%): R${depositAmount.toFixed(2)} now, R${balanceAmount.toFixed(2)} after job completion`,
        rfqId,
        price: `R${priceNum.toFixed(2)}`,
        next_step: 'awaiting_preferred_schedule',
      };
    }

    // ═══════════════════════════════════════════
    // 19) REJECT / NEGOTIATE RFQ QUOTE
    // ═══════════════════════════════════════════
    case 'reject_rfq_quote': {
      if (!firestore) return { error: 'Database unavailable' };

      const rfqId = String(args.rfqId || args.bookingId || session.lastRfqId || '').trim();
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
      const bid = String(args.bookingId || '').trim();
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
      const bid = String(args.bookingId || '').trim();
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
      const bid = String(args.bookingId || '').trim();
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
      const bid = String(args.bookingId || '').trim();
      const msg = String(args.message || '').trim();
      const recipient = String(args.recipient || 'artisan').trim().toLowerCase();
      if (!bid || !msg) return { error: 'Please provide a booking ID and message.' };

      const senderUserId = session.linkedUserId || '';

      try {
        // Resolve the booking to find tasksManagement doc + recipient ids.
        // Customers may pass either a futureBookings id or a tasksManagement id.
        let tmId = '';
        let tmData = null;
        // Try tasksManagement direct first
        try {
          const tmSnap = await firestore.collection('tasksManagement').doc(bid).get();
          if (tmSnap.exists) { tmId = tmSnap.id; tmData = tmSnap.data() || {}; }
        } catch (_) {}
        // Fallback: lookup by future_booking_id
        if (!tmId) {
          try {
            const q = await firestore.collection('tasksManagement')
              .where('future_booking_id', '==', bid).limit(1).get();
            if (!q.empty) { tmId = q.docs[0].id; tmData = q.docs[0].data() || {}; }
          } catch (_) {}
        }
        // Fallback: futureBookings doc → its tasks_management_id
        if (!tmId) {
          try {
            const fbSnap = await firestore.collection('futureBookings').doc(bid).get();
            if (fbSnap.exists) {
              const fbd = fbSnap.data() || {};
              const linkedTm = String(fbd.tasks_management_id || '').trim();
              if (linkedTm) {
                const tmSnap2 = await firestore.collection('tasksManagement').doc(linkedTm).get();
                if (tmSnap2.exists) { tmId = tmSnap2.id; tmData = tmSnap2.data() || {}; }
              }
            }
          } catch (_) {}
        }

        if (!tmId || !tmData) {
          return { error: `Could not find an active booking record for ${bid}. The artisan can only be messaged once a booking is in progress.` };
        }

        const artisanId = String(tmData.service_provider_id || '').trim();
        const customerId = String(tmData.user_id || tmData.userId || tmData.uid || '').trim();
        if (!artisanId || artisanId === 'admin') {
          return { error: 'No artisan is currently assigned to this booking, so I can\'t pass a message to them yet.' };
        }

        // Determine actual receiver based on requested recipient.
        const receiverId = recipient === 'admin' ? 'admin' : artisanId;
        const senderId = senderUserId || customerId || session.phone || 'whatsapp';

        // 1) Write the message into the chat subcollection that the
        //    artisan/client apps actually subscribe to.
        await firestore.collection('tasksManagement').doc(tmId).collection('chat').add({
          sender_id: senderId,
          receiver_id: receiverId,
          message: msg,
          type: 'text',
          isRead: false,
          source: 'whatsapp',
          timestamp: admin.firestore.FieldValue.serverTimestamp(),
        });

        // 2) FCM push the artisan (or admin) so the message is actually seen.
        let pushed = false;
        let pushFailReason = '';
        if (recipient !== 'admin') {
          try {
            const spSnap = await firestore.collection('serviceProvider').doc(artisanId).get();
            const ad = spSnap.exists ? (spSnap.data() || {}) : {};
            const tokenCandidates = [
              ad.deviceToken, ad.device_token, ad.fcm_token, ad.fcmToken,
              ad.token, ad.push_token, ad.pushToken,
            ];
            const seenTokens = new Set();
            const tokens = [];
            for (const c of tokenCandidates) {
              const t = String(c || '').trim();
              if (t && !seenTokens.has(t)) { seenTokens.add(t); tokens.push(t); }
            }
            if (tokens.length === 0) {
              pushFailReason = 'no_fcm_token_on_artisan_profile';
            } else {
              const senderName = (tmData.user_name || tmData.userName || 'Customer').toString();
              for (const tok of tokens) {
                try {
                  await admin.messaging().send({
                    token: tok,
                    notification: { title: senderName, body: msg.slice(0, 240) },
                    data: {
                      type: 'chat_message',
                      task_management_id: tmId,
                      booking_id: tmId,
                      sender_id: senderId,
                    },
                    android: {
                      priority: 'high',
                      notification: { channelId: 'order_request_channel', sound: 'sound' },
                    },
                  });
                  pushed = true;
                } catch (fcmErr) {
                  pushFailReason = (fcmErr && fcmErr.message) || String(fcmErr);
                }
              }
            }
          } catch (e) {
            pushFailReason = (e && e.message) || String(e);
          }
        }

        // 3) Honest response back to the customer — don't claim we
        //    notified the artisan if the push couldn't go through.
        if (recipient === 'admin') {
          return { success: true, message: 'Message sent to admin.' };
        }
        if (pushed) {
          return { success: true, message: 'Message delivered to the artisan.' };
        }
        // Saved to chat thread but no push got through — be transparent.
        try {
          await logErrorToAdmin(
            'whatsapp_bot_chat_no_push',
            `WA customer message saved to chat for ${tmId} but artisan did not receive a push (${pushFailReason || 'unknown'}). Backfill artisan FCM token recommended.`,
            'whatsapp_bot.send_message',
            `tmId=${tmId} artisan=${artisanId} reason=${pushFailReason}`,
            tmId,
            'medium'
          );
        } catch (_) {}
        return {
          success: true,
          message: 'I saved the message to the booking chat, but the artisan\'s phone is not reachable for an instant alert right now (no notification token on file). They will see it when they next open the app. I\'ve also flagged the admin to follow up.',
        };
      } catch (e) {
        console.warn('[wa-tool] send_message failed:', e && e.message);
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

🛡️ TRUST & SAFETY FACTS (USE THESE EXACT TERMS — NEVER INVENT OR EMBELLISH):
When the customer asks about safety, refunds, escrow, guarantees, vetting, ratings, or "is this safe?", reply ONLY with the facts below. Do NOT invent warranty periods, money-back-guarantee percentages, insurance terms, certification names, or licence claims that are not in this list.
- ESCROW: All payments are held in a secure escrow account managed by Square 15. The artisan does NOT receive funds until the customer confirms the work is satisfactory.
- ARTISAN VETTING: Every active Square 15 artisan is registered with Square 15, has submitted a valid government-issued ID, and is rated by past customers. (Do NOT claim formal background checks, criminal-record clearance, trade-licence verification, or insurance unless the customer's booking record explicitly says so.)
- IDENTITY CHECK: When the artisan is on the way, the bot sends the artisan's profile photo to the customer's WhatsApp so they can match the face at the door before letting anyone in.
- REFUND POLICY:
  • Cancel BEFORE the artisan starts work → full refund.
  • Cancel AFTER work has started but before completion → refund of unused portion, minus any materials already purchased on the customer's behalf and any call-out time worked.
  • Work completed but customer not satisfied → do NOT release escrow. Reply "refund" or "complaint" and Square 15 admin will investigate before any money leaves escrow.
  • Wallet refunds are processed instantly. Card refunds take 3–5 business days to reflect.
- PERSONAL SAFETY: If the customer ever feels unsafe, tell them to reply "help" or "emergency" — this alerts the Square 15 support team immediately. (For life-threatening emergencies always remind them to call 10111 / 10177 first.)
- WHAT YOU MUST NOT PROMISE: workmanship warranty length, free reworks, insurance cover, criminal-background-check results, trade-licence numbers, "money-back guarantee" beyond the escrow + refund policy above. If the customer asks about these, say: "Our standard protection is the escrow + refund policy I just described. For anything beyond that, I'll connect you with our admin team — would you like me to do that?" then offer to use send_message_to_admin / report_issue.
- PROACTIVE REASSURANCE: When you successfully create_booking, accept_rfq_quote, or confirm payment, briefly remind the customer of the escrow protection and the artisan-photo-on-the-way safety check. Keep it short — one or two sentences.
You help homeowners, tenants and businesses across Southern Africa (South Africa, Lesotho, Botswana, Namibia, Zimbabwe, Eswatini) and beyond — wherever Square 15 has artisans available. Square 15 dispatches the nearest qualified artisan based on the SERVICE address, not the customer's phone country. So treat every booking as potentially cross-border and ALWAYS confirm the full service address (with country if outside South Africa) before submitting an RFQ or creating a booking.

⛔ ABSOLUTE ADDRESS RULE (NEVER SKIP):
- BEFORE calling create_booking or submit_rfq you MUST have a real service address (street + suburb/area + city — AND country if outside South Africa).
- If the customer hasn't given an address yet, ASK FIRST in a warm conversational way: "Could you please share the full address where the work needs to be done? (street, area, city — and country if outside South Africa). You can also drop a WhatsApp location pin if that's easier."
- NEVER assume the customer is in South Africa. NEVER fill the address with placeholders like "TBD", "same as account", "client home", "Johannesburg", or guesses. NEVER reuse a stale address from a different booking unless the customer confirms it.
- If the server returns error="address_required", ask for the address and wait — do NOT retry the tool call without one.

⛔ AMBIGUOUS ADDRESS DISAMBIGUATION (BHV-4 — NEVER SKIP):
- Several suburb / town names exist in MULTIPLE countries and dispatching to the wrong one wastes a callout. Treat these as ambiguous unless the customer also names an unmistakable South African city or province, OR explicitly says "South Africa" / "ZA" / "RSA":
  Hatfield (ZA Pretoria / UK / US), Newlands (ZA Cape Town / Ireland / NZ), Richmond (ZA / UK / US / Canada), Wellington (ZA Cape Winelands / NZ capital), Cambridge (ZA East London / UK / US / NZ), Kensington (ZA / UK / Australia), Greenwich, Chelsea, Brighton, Manchester, Bedford, Windsor, Oxford, Auckland, Hamilton, Dover, Sandton-Park (Sandton itself is unique to ZA — NOT ambiguous).
- If the customer's address contains an ambiguous name without a clearly ZA city/province (Johannesburg, Pretoria, Cape Town, Durban, Gauteng, Western Cape, KZN, Eastern Cape, Limpopo, Mpumalanga, North West, Free State, Northern Cape) AND no explicit country, you MUST ask once: "Just to confirm — is this address in South Africa, or in another country? (We dispatch the nearest artisan based on the service location.)" Wait for the answer before calling create_booking or submit_rfq.
- If the customer says it IS South Africa (or names a ZA city), proceed normally. If they say another country, capture that country in the address string when you call the tool.
- Do NOT ask this question if the address already includes a ZA city, province, postal code (4-digit ZA codes start 0001-9999 with specific ranges), or "South Africa".

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

⛔ ABSOLUTE RULE — NEVER WRITE A QUOTE YOURSELF:
- You are FORBIDDEN from typing out any quote, price breakdown, total cost, labour cost, materials cost, or contingency figures in a free-text reply. EVER.
- The ONLY way a quote may be shown to the customer is as the formatted output returned by the submit_rfq, accept_rfq_quote, or check_rfq_status tools (it starts with "📋 *AI Quote — RFQ-...*").
- If the customer asks for a quote / quotation / pricing for a job that's not in lookup_pricing, you MUST call submit_rfq. Do NOT summarise, repeat, or recreate a previous quote from memory — even if you "remember" the numbers.
- If you have already submitted an RFQ for this customer in this session (session.lastRfqId is set) and they ask about it again, call check_rfq_status with that rfqId — do NOT regenerate the quote text yourself.
- A reply that contains "*Total Cost*", "*Quote Breakdown*", "Labour:", "Materials:", or "Contingency" without coming from a tool result is a BUG. Always use the tool.

1. Customer describes a complex job or sends photos of the issue
2. Collect what's missing: category, detailed description, address, name, materials responsibility (client or artisan). If the customer's request already contains category + description + address (e.g. "quotation for installation of a 200L solar geyser at 270 Marshall Street"), do NOT keep asking — fill in their full name from session/account if known and proceed.
3. Call submit_rfq — this creates the RFQ AND generates an AI quote instantly
4. The AI quote includes: labour hours × rate, materials BOM with markup (1.5×), equipment, and 15% contingency
5. Present the full quote breakdown to the customer (it's included in the submit_rfq response)
6. Ask if they want to ACCEPT or NEGOTIATE the quote
7. If ACCEPT (the customer says "yes", "accept", "approve", "proceed", "sounds good", "let's do it", "go ahead", "ok", or any clear affirmation right after you presented a quote) → call accept_rfq_quote IMMEDIATELY → after success, ASK the client when they want the work done (date + optional time) and IMMEDIATELY call set_preferred_schedule with their answer (convert "Friday morning" / "tomorrow at 2pm" / "next Monday" into a real YYYY-MM-DD + HH:MM in 2026). NEVER call reschedule_booking for this — that tool is only for changing an already-set schedule. NEVER reply with "how can I assist you further" after a quote was just shown — a bare "yes" in that context ALWAYS means accept the quote.
8. If NEGOTIATE (the customer says "no", "reject", "negotiate", "too expensive", "change", "lower", or any clear push-back) → call reject_rfq_quote with their feedback → admin reviews
9. Customer can check RFQ status anytime with check_rfq_status

⚠️ IMPORTANT — REVISED QUOTES FROM ADMIN:
If the client receives a "quote request has been reviewed" message from us (admin amended the quote) and replies YES / accept / approve / proceed, call accept_rfq_quote with their RFQ ID — the bot will use the admin-amended total (NOT the original AI quote).
If they reply NO / reject / negotiate / not happy, call reject_rfq_quote and capture WHY (price too high? scope wrong? timing?) so admin can re-quote.

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
- If lookup_pricing returns matched=false, you are FORBIDDEN from quoting any price. You MUST call submit_rfq instead so admin can produce a curated quote.
- ⛔ NEVER invent a price. NEVER cherry-pick a price from another service in the category list. NEVER recall a price from session memory. NEVER guess.
- ⛔ "Labour only" / "Labor only" priced services in the catalog are NOT all-in prices. Never present a "Labour only" price as the cost of a job that includes materials.
- ⛔ A reply that contains a "R{number}" amount that did NOT come from a tool result on this turn is a BUG. The only way you may state a Rand amount is if (a) lookup_pricing returned matched=true on this turn, or (b) submit_rfq / accept_rfq_quote / check_rfq_status returned a quote on this turn.
- If create_booking returns an estimated cost of R0.00, it means no fixed price was found — DO NOT quote a price; tell the customer the job needs an RFQ and call submit_rfq.

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
- Customers often send multiple photos in one go. Treat them as ONE set and respond ONCE — do NOT send the same reply multiple times.

🏗️ CUSTOM JOB / AI RFQ FLOW (CRITICAL — use whenever the service is NOT in the fixed price list):
- If lookup_pricing returns matched=false (or the customer's job doesn't match any fixed service price), this is a CUSTOM job that needs an admin-curated quote via submit_rfq.
- NEVER invent a price. NEVER reuse an unrelated fixed price. If no fixed price matches, the ONLY correct path is submit_rfq.
- Before calling submit_rfq you MUST complete ALL of these steps IN ORDER:
  1. SCOPE CONFIRMATION — understand the issue. If photos were sent, analyse them and state your understanding in one short sentence (e.g. "Got it — the shower mixer is leaking at the wall connection, correct?"). Wait for the customer to confirm or correct you.
  2. MATERIALS-RESPONSIBILITY — ask exactly: "Will you be buying the materials yourself, or should our artisan source them for you?" Wait for the answer.
  3. MATERIAL SPEC CAPTURE (REQUIRED when artisan sources materials AND category is plumbing / electrical / tiling / carpentry / locksmith / painting / roofing / appliance):
     ➤ Conversationally collect the spec for EACH material the job needs. Ask about: capacity / size / variant (e.g. solar vs electric vs heat-pump geyser, single-lever vs thermostatic mixer), finish (chrome / black / brushed steel), brand preference (Kwikot, Apollo, Cobra etc., or "any"), and quantity if more than one. Ask one question at a time — keep it warm and conversational.
     ➤ Examples of what to ask:
        • "Roughly what capacity do you need? 150L is fine for 1–2 people, 200L for a family of 4, 300L for larger households."
        • "Any brand preference, or should I just note 'any reliable brand' and let our admin pick the best value?"
        • "Roof-mounted or ground-level for the solar geyser?"
     ➤ As soon as you have a clear spec for an item, call show_material_options ONCE for that item with: itemType (most specific — "solar geyser" not "geyser"), specSummary (one-line description capturing capacity / type / mounting / etc.), brandPreference, qty, unit. Repeat for additional line items the job needs (e.g. geyser blanket, mounting brackets, valves).
     ➤ The tool ONLY records the spec — it does NOT send images or product links to the client. Our admin will pick the actual Builders Warehouse product after you submit_rfq, and send the photos + final quote to the client themselves on WhatsApp.
     ➤ NEVER promise images, prices, brand names or product links yourself. NEVER type imaginary product lists or prices in chat. NEVER write markdown image links or invent URLs.
     ➤ After each show_material_options call, reply with ONE short sentence acknowledging what you noted (e.g. "Got it — 200L solar geyser, roof mount."), then ask the next question.
  4. BUDGET — once all material specs are captured, ask exactly: "What's your budget for this job? A rough number is fine — it helps us keep the quote realistic." Wait for the answer. If the client says "no budget" or "whatever it costs", pass clientBudget=0. Otherwise pass the number (strip the "R").
  5. Only AFTER scope + materials answer + (if applicable) ALL material specs captured + BUDGET ANSWER, call submit_rfq EXACTLY ONCE with: category, description (include the materials list summary inside the description), address, customerName, materialsResponsibility, clientBudget. NEVER call submit_rfq twice for the same request.
- TWO OUTCOMES after submit_rfq:
  • materialsResponsibility="client" (client supplies materials) → an instant labour-only quote is generated. Present it clearly and ask if they'd like to proceed. Auto-dispatches under R12K on accept.
  • materialsResponsibility="artisan" (artisan sources materials) → submit_rfq returns adminReviewRequired=true with a client-facing message you should relay verbatim. The admin will pick each material on Builders, then the bot will automatically send the photos + final quote to the client. DO NOT show any prices or product details yourself.
- AMENDMENTS AFTER QUOTE: if the client receives a quote (you'll see them respond to images/price the bot relayed) and asks to change something — different brand, swap an item, remove an item, etc. — call request_quote_amendment with the client's exact wording. Tell them admin will update the quote shortly. NEVER edit the quote yourself or quote a new price.
- DISPATCH RULES (inform the customer when relevant):
  • Labour-only jobs (client supplies materials) under R12,000 → auto-dispatched to artisans the moment the client accepts.
  • Any job where artisan supplies materials → admin picks materials and sends the curated quote first; auto-dispatch on acceptance under R12K.
  • Any job R12,000 or more → reviewed and dispatched by admin manually after acceptance.

💰 SALES CONVERSION (CRITICAL — always try to close the deal, especially when price pushback or drop-off):
- You are a sales-focused assistant. Every conversation should end in a confirmed booking, RFQ, or follow-up appointment — never a silent drop-off.
- If the client hesitates on price or says "too expensive" / "I'll think about it" / "let me check" / goes silent mid-flow:
  1. Acknowledge warmly: "Totally understand — let me see what I can do."
  2. Offer a LABOUR-ONLY variant: "If you source the materials yourself, we can drop the labour portion to R[X]. Want me to send you a shopping list?" (this also unlocks auto-dispatch under R12K, faster turnaround).
  3. Offer PHASING: "We can split this into two visits — fix the critical part now for R[Y], then the cosmetic part next month."
  4. Offer a CHEAPER material choice via show_material_options (e.g. standard vs premium mixer).
  5. Ask for their target price: "What price would work for you? I'll see if we can make it fit."
  6. If they still decline, keep it open: "No problem. I'll keep the quote on file for 30 days — just message me 'yes' when you're ready."
- If the client has booked before, look for UPSELL angles: "While we're there, would you like us to check your geyser / service the aircon / replace the bathroom silicon? We can add it for R[X] and save you a separate call-out fee."
- If the client declines the quote (calls reject_rfq_quote), ALWAYS capture the reason ("may I ask what feels off — the price, timing, or scope?"). Save it in reason — admin uses this to re-quote.
- Never be pushy, but never let a silent drop end the chat. If they go quiet after a quote, one gentle nudge after a pause: "Still thinking it over? Happy to adjust scope or materials to fit your budget."

GUIDELINES:
- Be warm, professional, and concise (WhatsApp messages should be short)
- Before creating a booking, make sure you have: category, description, service address, and customer name. If ANY of these were already mentioned in the conversation, do NOT ask for them again — use what the customer already said.
- SERVICE ADDRESS: The customer might already include the address in their first message (e.g. "I need a plumber at 15 Main Rd, Sandton"). If so, use that address — do NOT ask again. Only ask "Where does the service need to be done?" if no address was mentioned yet. Remember: the service location may differ from where the customer is right now. Do NOT ask for a location pin — just the text address is enough.
- For complex jobs (renovations, full installations), suggest submitting an RFQ instead of a regular booking
- Use South African Rands (R) for all pricing
- MULTI-ISSUE HANDLING (BHV-5): If the customer mentions MORE THAN ONE distinct problem in a single message (e.g. "my tap is leaking AND my light is broken", "I need painting and tiling"), do NOT collapse them into one booking. Each problem usually needs a different artisan trade and a different price. Reply: "I see two issues — (1) [issue A] and (2) [issue B]. Each needs a separate booking so the right artisan attends. Which one would you like to handle first?" Then create_booking ONE issue at a time. After the first is confirmed, ask: "Would you like me to book the second one ([issue B]) now too?"
- When a customer sends a photo, ANALYSE the image using your vision capabilities. Identify the maintenance issue (e.g. leaking pipe, broken socket, cracked wall), suggest the correct service category, call lookup_pricing to get the price, and present the price to the customer for confirmation. Do NOT create a booking until the customer confirms the price.
- VISION CONFIDENCE GUARD (BHV-8): If the photo is blurry, dark, partial, ambiguous, or you are NOT highly confident what product/issue it shows, DO NOT call lookup_pricing or create_booking. Instead reply: "I can see something in the photo but I'm not 100% sure what — could you describe it in a sentence (e.g. 'frameless shower door', 'kitchen mixer tap'), or send a clearer photo?" Hardware-install jobs (shower door, geyser, ceiling fan, gate, light fitting) have prices that vary 10-40× by product spec — never guess. When in doubt, route to submit_rfq so admin can confirm the actual product before quoting.
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
  // Track tools called this turn (for chat logging)
  session._lastToolsCalled = [];

  // Build user message content — supports text-only or text+image (vision)
  if (imageDataUrl) {
    // Accept either a single data URL (string) or an array of data URLs (multi-photo).
    const urls = Array.isArray(imageDataUrl)
      ? imageDataUrl.filter(u => typeof u === 'string' && u.length > 0)
      : [imageDataUrl];
    const imageParts = urls.map(u => ({ type: 'image_url', image_url: { url: u, detail: 'auto' } }));
    const content = [
      ...imageParts,
      { type: 'text', text: userMessage },
    ];
    session.messages.push({ role: 'user', content });
  } else {
    session.messages.push({ role: 'user', content: userMessage });
  }

  // Keep context window manageable
  if (session.messages.length > 20) {
    session.messages = session.messages.slice(-16);
    // Drop orphaned tool messages at the start (tool must follow assistant with tool_calls)
    while (session.messages.length > 0 && session.messages[0].role === 'tool') {
      session.messages.shift();
    }
  }

  try {
    // ── HARD INTERCEPT: numeric rating reply (1-5) when a rating is pending ──
    // The customer was asked to rate their artisan. They reply with just "5"
    // (or "★★★★★" / "5 stars" / "5/5"). GPT sometimes ignores its own
    // pendingRating system hint and treats this as a brand-new conversation,
    // greeting them again. Bypass GPT entirely and submit the rating directly.
    try {
      const rawText = (typeof userMessage === 'string' ? userMessage : '').trim();
      // Bugfix (live test May 2026): validate session.pendingRatingBookingId
      // points to a recent rating request before honouring it. Otherwise an
      // old un-rated booking from weeks ago will hijack every "5" reply.
      const RATING_TTL_MS = 48 * 60 * 60 * 1000;
      const _now = Date.now();
      const _toMs = (ts) => {
        if (!ts) return 0;
        if (typeof ts === 'object' && typeof ts.toMillis === 'function') return ts.toMillis();
        if (typeof ts === 'object' && ts._seconds) return ts._seconds * 1000;
        if (typeof ts === 'string') return Date.parse(ts) || 0;
        if (typeof ts === 'number') return ts;
        return 0;
      };
      const _fresh = (ts) => { const ms = _toMs(ts); return ms > 0 && (_now - ms) < RATING_TTL_MS; };
      if (session.pendingRatingBookingId) {
        try {
          const firestore = db();
          if (firestore) {
            const tmDoc = await firestore.collection('tasksManagement').doc(session.pendingRatingBookingId).get();
            const td = tmDoc.exists ? (tmDoc.data() || {}) : null;
            if (!td || td.rating || !_fresh(td.wa_rating_request_sent_at)) {
              console.log(`[rating-intercept] clearing stale pendingRatingBookingId=${session.pendingRatingBookingId} (rated=${!!(td && td.rating)}, fresh=${!!(td && _fresh(td.wa_rating_request_sent_at))})`);
              session.pendingRatingBookingId = null;
            }
          }
        } catch { /* ignore — fall through */ }
      }
      // Restore pendingRatingBookingId from Firestore if listener seeded it after
      // the in-memory session was last persisted (common after Render cold start).
      if (!session.pendingRatingBookingId) {
        try {
          const firestore = db();
          if (firestore) {
            const phoneNorm = String(session.phone || '').replace(/[^0-9]/g, '');
            const last9 = phoneNorm.slice(-9);
            // Query TM docs for this user_phone, then filter for unrated + rating prompt sent
            const q = await firestore.collection('tasksManagement')
              .where('user_phone', '==', phoneNorm)
              .limit(50).get();
            for (const d of q.docs) {
              const td = d.data() || {};
              if (td.rating) continue;
              if (!td.wa_rating_request_sent_at) continue;
              if (!_fresh(td.wa_rating_request_sent_at)) continue;
              session.pendingRatingBookingId = d.id;
              console.log(`[rating-intercept] restored pendingRatingBookingId=${d.id} for ${maskPhone(session.phone)} from Firestore`);
              break;
            }
            // Fallback: also check tail-match in case stored phone differs
            if (!session.pendingRatingBookingId && last9) {
              const q2 = await firestore.collection('tasksManagement')
                .orderBy('wa_rating_request_sent_at', 'desc').limit(20).get();
              for (const d of q2.docs) {
                const td = d.data() || {};
                if (td.rating) continue;
                if (!_fresh(td.wa_rating_request_sent_at)) continue;
                const tmPhone = String(td.user_phone || td.customerPhone || td.phone || '').replace(/[^0-9]/g, '');
                if (tmPhone && tmPhone.endsWith(last9)) {
                  session.pendingRatingBookingId = d.id;
                  console.log(`[rating-intercept] restored pendingRatingBookingId=${d.id} (tail-match) for ${maskPhone(session.phone)}`);
                  break;
                }
              }
            }
          }
        } catch (e) { /* ignore */ }
      }
      const ratingMatch = rawText.match(/^\s*([1-5])\s*(?:star|stars|\/5|out of 5|⭐+)?\s*$/i)
        || rawText.match(/^(⭐{1,5})$/);
      if (ratingMatch && session.pendingRatingBookingId) {
        let stars = 0;
        if (ratingMatch[1] && /^\d$/.test(ratingMatch[1])) stars = parseInt(ratingMatch[1], 10);
        else if (ratingMatch[1] && /⭐/.test(ratingMatch[1])) stars = (ratingMatch[1].match(/⭐/g) || []).length;
        if (stars >= 1 && stars <= 5) {
          console.log(`[rating-intercept] direct submit: ${stars} stars for ${session.pendingRatingBookingId}`);
          // Fake a tool call so the existing rate_booking handler runs with proper auth/dedup
          const toolResult = await executeWaTool('rate_booking',
            { bookingId: session.pendingRatingBookingId, rating: stars },
            session
          );
          if (toolResult && toolResult.message) {
            session.messages.push({ role: 'assistant', content: toolResult.message });
            return toolResult.message;
          }
          if (toolResult && toolResult.error) {
            // Fall through to AI on error so customer gets a meaningful reply
            console.warn(`[rating-intercept] tool returned error: ${toolResult.error}`);
          }
        }
      }
    } catch (e) {
      console.warn('[rating-intercept] failed:', e.message);
    }

    // Inject pending-rating hint so the AI knows to prompt the customer
    const sysMessages = [{ role: 'system', content: SYSTEM_PROMPT }];
    if (session.pendingRatingBookingId) {
      sysMessages.push({
        role: 'system',
        content: `[PENDING RATING] Booking #${session.pendingRatingBookingId} has been completed and is awaiting a 1-5 star rating from the customer. Proactively ask if they'd like to rate the artisan.`,
      });
    }

    // ── HARD INTERCEPT: quote acceptance / rejection ──
    // If the LAST assistant message we sent was a quote ("📋 *Quote Total*"
    // or "has been reviewed" or "AI Quote — RFQ-…") and the customer's
    // current reply is a clear yes/accept or no/reject, GPT has historically
    // ignored its own system rules and replied "How can I assist you
    // further?" — dead-ending the flow. We bypass GPT in this exact case
    // and call accept_rfq_quote / submit_rfq_amendment directly.
    try {
      // Find the most recent assistant *text* message (skip tool calls).
      let lastAssistantText = '';
      for (let i = session.messages.length - 1; i >= 0; i--) {
        const m = session.messages[i];
        if (m && m.role === 'assistant' && typeof m.content === 'string' && m.content.trim()) {
          lastAssistantText = m.content;
          break;
        }
      }
      const looksLikeQuote =
        /\*Quote Total\*/i.test(lastAssistantText) ||
        /has been reviewed/i.test(lastAssistantText) ||
        /AI Quote\s*[—-]\s*RFQ/i.test(lastAssistantText);
      const userTextRaw = (typeof userMessage === 'string' ? userMessage : '').trim();
      const userTextLower = userTextRaw.toLowerCase();
      const isAffirmative = /^(yes|y|yeah|yep|yup|sure|ok|okay|accept|approve|approved|confirm|confirmed|proceed|go ahead|sounds good|let'?s do it|👍|✅)\b/i
        .test(userTextLower);
      const isRejection = /^(no|nope|nah|reject|cancel|❌)\b/i.test(userTextLower);

      // Fallback: if session.lastRfqId missing but the user said yes/no,
      // fetch the most recent rfq_sent for this phone from Firestore. This
      // handles the case where the quote-relay listener bridged data to
      // firestore but the in-memory session pre-existed and never picked
      // it up, OR the bridge ran in a different worker process.
      let recoveredFromFirestore = false;
      if (!session.lastRfqId && (isAffirmative || isRejection)) {
        try {
          const firestore = db();
          if (firestore) {
            // Try wa_sessions first (cheaper)
            const sessDoc = await firestore.collection('wa_sessions').doc(session.phone).get();
            if (sessDoc.exists && sessDoc.data().lastRfqId) {
              session.lastRfqId = sessDoc.data().lastRfqId;
              session.lastBookingId = session.lastBookingId || sessDoc.data().lastBookingId || sessDoc.data().lastRfqId;
              recoveredFromFirestore = true;
              console.log(`[quote-intercept] recovered lastRfqId=${session.lastRfqId} from wa_sessions`);
              // Also pull recent assistant messages so looksLikeQuote regex matches
              if (Array.isArray(sessDoc.data().messages) && sessDoc.data().messages.length) {
                const lastFew = sessDoc.data().messages.slice(-5);
                for (const m of lastFew) {
                  if (m && m.role === 'assistant' && typeof m.content === 'string' &&
                      /\*Quote Total\*|has been reviewed|AI Quote/i.test(m.content)) {
                    lastAssistantText = m.content;
                    break;
                  }
                }
              }
            } else {
              // Find most recent rfq_sent for this phone (try several formats).
              const phoneVariants = Array.from(new Set([
                session.phone,
                session.phone.replace(/^27/, '0'),
                '+' + session.phone,
                session.phone.replace(/^0/, '27'),
              ]));
              let foundRfq = null;
              for (const ph of phoneVariants) {
                const snap = await firestore.collection('futureBookings')
                  .where('source', '==', 'whatsapp')
                  .where('user_phone', '==', ph)
                  .where('status', '==', 'rfq_sent')
                  .orderBy('updated_at', 'desc')
                  .limit(1).get().catch(() => ({ empty: true, docs: [] }));
                if (!snap.empty && snap.docs.length) { foundRfq = snap.docs[0].id; break; }
              }
              if (foundRfq) {
                session.lastRfqId = foundRfq;
                session.lastBookingId = foundRfq;
                recoveredFromFirestore = true;
                console.log(`[quote-intercept] recovered lastRfqId=${foundRfq} from futureBookings query`);
              }
            }
          }
        } catch (e) {
          console.warn('[quote-intercept] lastRfqId recovery failed:', e.message);
        }
      }

      // Re-evaluate looksLikeQuote in case we just pulled the quote text from firestore
      const looksLikeQuoteNow =
        /\*Quote Total\*/i.test(lastAssistantText) ||
        /has been reviewed/i.test(lastAssistantText) ||
        /AI Quote\s*[—-]\s*RFQ/i.test(lastAssistantText);

      // Trigger condition:
      //   - We have an RFQ id (either from session or just recovered) AND
      //   - User said yes/no AND
      //   - EITHER the prior assistant message looked like a quote, OR we
      //     just recovered from Firestore (which proves an RFQ awaits)
      const shouldInterceptQuote = (isAffirmative || isRejection) &&
        session.lastRfqId &&
        (looksLikeQuoteNow || recoveredFromFirestore);

      console.log(`[quote-intercept] phone=${maskPhone(session.phone)} userText="${userTextRaw.slice(0,40)}" affirm=${isAffirmative} reject=${isRejection} lastRfqId=${session.lastRfqId || '(none)'} looksLikeQuote=${looksLikeQuoteNow} recovered=${recoveredFromFirestore} → ${shouldInterceptQuote ? 'INTERCEPT' : 'skip'}`);

      if (shouldInterceptQuote) {
        const rfqId = session.lastRfqId;
        if (isAffirmative) {
          console.log(`[quote-intercept] ${maskPhone(session.phone)}: YES on quote → accept_rfq_quote(${rfqId})`);
          session._lastToolsCalled.push('accept_rfq_quote');
          let reply = '';
          try {
            const toolResult = await executeWaTool('accept_rfq_quote', { rfqId }, session);
            reply = typeof toolResult === 'string'
              ? toolResult
              : (toolResult && (toolResult.message || toolResult.reply || toolResult.error)) || '';
          } catch (toolErr) {
            console.error(`[quote-intercept] accept_rfq_quote threw:`, toolErr && toolErr.stack || toolErr);
            reply = '';
          }
          if (!reply) {
            reply = `Thanks — I've recorded your acceptance of RFQ ${rfqId}. When would you like the work scheduled? (e.g. "Friday morning" or "tomorrow at 2pm")`;
          } else if (!/when would you like|preferred|schedule/i.test(reply)) {
            reply = `${reply}\n\nWhen would you like the work scheduled? (e.g. "Friday morning" or "tomorrow at 2pm")`;
          }
          session.messages.push({ role: 'assistant', content: reply });
          return reply;
        }
        if (isRejection) {
          console.log(`[quote-intercept] ${maskPhone(session.phone)}: NO on quote → noting rejection`);
          const reply = 'No problem — what would you like to change? You can ask to swap a brand, remove an item, or adjust quantities, and I\'ll log it for our admin to update the quote.';
          session.messages.push({ role: 'assistant', content: reply });
          return reply;
        }
      }
    } catch (e) {
      console.warn('[quote-intercept] failed:', e && e.message, e && e.stack);
    }

    // ── HARD INTERCEPT: schedule reply after quote acceptance ──
    // Right after accept_rfq_quote, our bot asked "When would you like the
    // work scheduled?". The customer's next reply is almost always a date
    // phrase ("Friday morning", "tomorrow at 2pm", "27 Apr"). GPT
    // sometimes fails to call set_preferred_schedule and the flow stalls.
    // We parse common phrases ourselves and call the tool directly.
    try {
      let lastAssistantText = '';
      for (let i = session.messages.length - 1; i >= 0; i--) {
        const m = session.messages[i];
        if (m && m.role === 'assistant' && typeof m.content === 'string' && m.content.trim()) {
          lastAssistantText = m.content;
          break;
        }
      }
      const askedSchedule =
        /when would you like|preferred date|preferred schedule|when would you like the work/i.test(lastAssistantText);
      if (askedSchedule && session.lastRfqId) {
        const userTextRaw = (typeof userMessage === 'string' ? userMessage : '').trim();
        const parsed = parseScheduleFromText(userTextRaw);
        if (parsed && parsed.date) {
          const rfqId = session.lastRfqId;
          console.log(`[schedule-intercept] ${maskPhone(session.phone)}: "${userTextRaw}" → ${parsed.date} ${parsed.time || ''} for ${rfqId}`);
          const argsObj = { bookingId: rfqId, preferredDate: parsed.date, preferredTime: parsed.time || '', notes: '' };
          session._lastToolsCalled.push('set_preferred_schedule');
          let reply = '';
          try {
            const toolResult = await executeWaTool('set_preferred_schedule', argsObj, session);
            reply = (toolResult && (toolResult.message || toolResult.error)) || '';
          } catch (toolErr) {
            console.error(`[schedule-intercept] set_preferred_schedule threw:`, toolErr && toolErr.stack || toolErr);
          }
          if (!reply) {
            reply = `Got it — I've noted your preferred schedule: ${parsed.date}${parsed.time ? ' at ' + parsed.time : ''}. We'll pass it to the artisan once they accept your job.`;
          }
          session.messages.push({ role: 'assistant', content: reply });
          return reply;
        }
      }
    } catch (e) {
      console.warn('[schedule-intercept] failed:', e && e.message);
    }

    // ── HARD INTERCEPT: payment choice ("pay deposit" / "pay full" / "deposit" / "full") ──
    // After artisan acceptance, the bot prompts the customer to choose
    // deposit or full. GPT sometimes drops the tool call and replies
    // generically. Detect explicit payment phrases and call
    // request_payment_link directly.
    try {
      const userTextRaw = (typeof userMessage === 'string' ? userMessage : '').trim();
      const userTextLower = userTextRaw.toLowerCase();
      // Explicit payment phrases only — do NOT trigger on bare "yes/no".
      const wantsDeposit = /\b(pay\s+(?:the\s+)?deposit|deposit\s+please|just\s+(?:the\s+)?deposit|^deposit$|35%|^pay\s+35)\b/i.test(userTextRaw)
        || /^deposit\b/i.test(userTextLower);
      const wantsFull = /\b(pay\s+(?:in\s+)?full|full\s+payment|pay\s+everything|pay\s+all|^full$|pay\s+the\s+full|pay\s+balance|pay\s+the\s+balance|balance\s+please|^balance$)\b/i.test(userTextRaw)
        || /^full\b/i.test(userTextLower);
      const wantsPayGeneric = /^(pay|pay\s+now|payment\s+link|send\s+(?:me\s+)?(?:the\s+)?(?:payment|link)|i\s+want\s+to\s+pay|ready\s+to\s+pay)\b/i.test(userTextLower);

      if ((wantsDeposit || wantsFull || wantsPayGeneric) && (session.lastBookingId || session.lastRfqId)) {
        const bid = session.lastBookingId || session.lastRfqId;
        // If generic, look back at the last assistant message for default
        let paymentType = wantsDeposit ? 'deposit' : (wantsFull ? 'full' : 'full');
        if (wantsPayGeneric && !wantsDeposit && !wantsFull) {
          // Default to full unless we already issued a deposit-pending state.
          // Safer: ask before guessing. Skip intercept and let GPT clarify.
          // Only intercept generic if the customer literally already said "deposit"/"full" earlier.
          let priorChoice = '';
          for (let i = session.messages.length - 1; i >= 0 && i > session.messages.length - 10; i--) {
            const m = session.messages[i];
            if (m && m.role === 'user' && typeof m.content === 'string') {
              if (/\bdeposit\b/i.test(m.content)) { priorChoice = 'deposit'; break; }
              if (/\bfull\b/i.test(m.content)) { priorChoice = 'full'; break; }
            }
          }
          if (!priorChoice) {
            // Don't intercept — let GPT ask the question.
          } else {
            paymentType = priorChoice;
          }
        }
        const shouldIntercept = wantsDeposit || wantsFull || (wantsPayGeneric && (paymentType === 'deposit' || paymentType === 'full'));
        if (shouldIntercept) {
          console.log(`[payment-intercept] ${maskPhone(session.phone)}: "${userTextRaw}" → request_payment_link(${bid}, ${paymentType})`);
          const argsObj = { bookingId: bid, paymentType };
          session._lastToolsCalled.push('request_payment_link');
          let reply = '';
          try {
            const toolResult = await executeWaTool('request_payment_link', argsObj, session);
            reply = (toolResult && (toolResult.message || toolResult.error)) || '';
          } catch (toolErr) {
            console.error(`[payment-intercept] request_payment_link threw:`, toolErr && toolErr.stack || toolErr);
          }
          if (!reply) {
            reply = 'I had trouble generating your payment link. Please try again in a moment, or open the Square 15 app to pay.';
          }
          session.messages.push({ role: 'assistant', content: reply });
          return reply;
        }
      }
    } catch (e) {
      console.warn('[payment-intercept] failed:', e && e.message);
    }

    let response;
    try {
      response = await openai.chat.completions.create({
        model: 'gpt-4o-mini',
        temperature: 0.4,
        max_tokens: 500,
        messages: [
          ...sysMessages,
          ...session.messages,
        ],
        tools: waTools,
        tool_choice: 'auto',
      });
    } catch (aiErr) {
      console.error('[handleMessage] initial OpenAI failed, retrying once:', aiErr.message);
      await new Promise(r => setTimeout(r, 800));
      response = await openai.chat.completions.create({
        model: 'gpt-4o-mini',
        temperature: 0.4,
        max_tokens: 300,
        messages: [
          ...sysMessages,
          ...session.messages,
        ],
        tools: waTools,
        tool_choice: 'auto',
      });
    }

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
        session._lastToolsCalled.push(tc.function.name);
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

      // Get follow-up response (with one retry on transient OpenAI errors)
      let followUp;
      try {
        followUp = await openai.chat.completions.create({
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
      } catch (aiErr) {
        console.error('[handleMessage] followUp OpenAI failed, retrying once:', aiErr.message);
        try {
          await new Promise(r => setTimeout(r, 800));
          followUp = await openai.chat.completions.create({
            model: 'gpt-4o-mini',
            temperature: 0.4,
            max_tokens: 300,
            messages: [
              { role: 'system', content: SYSTEM_PROMPT },
              ...session.messages,
            ],
            tool_choice: 'none',
          });
        } catch (aiErr2) {
          console.error('[handleMessage] followUp retry also failed:', aiErr2.message);
          // If the last tool call was submit_rfq and it produced a message, use that.
          const lastToolMsg = [...session.messages].reverse().find(m => m.role === 'tool');
          let fallbackText = "Thanks — I've logged your request. Our admin will review it and get back to you on WhatsApp shortly.";
          try {
            const parsed = lastToolMsg ? JSON.parse(lastToolMsg.content) : null;
            if (parsed && parsed.message) fallbackText = String(parsed.message);
          } catch (_) {}
          assistantMessage = { role: 'assistant', content: fallbackText };
          break;
        }
      }
      assistantMessage = followUp.choices[0].message;
    }

    const reply = assistantMessage.content || "I'm sorry, I couldn't process that. Please try again.";

    // ─────────────────────────────────────────────────────────────────────
    // HALLUCINATED-PRICE GUARD (Apr 28 2026)
    // Symptom: GPT recalls a price from PRIOR turns (e.g. yesterday's R480
    // shower-door reply) even though no pricing tool was called this turn,
    // or all pricing tools returned matched=false. The customer sees a
    // confident but fabricated quote.
    //
    // Rule: a reply is allowed to contain "R{number}" ONLY if at least one
    // tool was called THIS TURN that legitimately returned a Rand amount —
    // namely lookup_pricing(matched=true), create_booking(success), or any
    // RFQ tool returning a quote. Otherwise we rewrite the reply with a
    // safe RFQ-prompt.
    // ─────────────────────────────────────────────────────────────────────
    let safeReply = reply;
    try {
      const _hg = require('./hallucination-guard');
      if (_hg.PRICE_RE.test(reply)) {
        const PRICE_TOOLS = new Set([
          'lookup_pricing','create_booking','submit_rfq','accept_rfq_quote',
          'check_rfq_status','reject_rfq_quote','request_payment_link',
          'check_booking_status','check_payment','check_wallet_balance',
          'list_my_bookings','show_material_options','explain_quote',
          'apply_promo_code','reschedule_booking','cancel_booking',
        ]);
        const calledThisTurn = Array.isArray(session._lastToolsCalled)
          ? session._lastToolsCalled.filter(n => PRICE_TOOLS.has(n)) : [];
        // Did any of those tools return a positive Rand amount this turn?
        // Walk back through session.messages to the last tool round.
        let toolReturnedPrice = false;
        for (let i = session.messages.length - 1; i >= 0; i--) {
          const m = session.messages[i];
          if (m.role === 'assistant' && Array.isArray(m.tool_calls)) break; // older round
          if (m.role !== 'tool') continue;
          const txt = typeof m.content === 'string' ? m.content : '';
          if (_hg.PRICE_RE.test(txt)) { toolReturnedPrice = true; break; }
          // Numeric grand_total / fixedPrice fields.
          if (/"(grand_total|fixedPrice|cost|total|quoted_price|amount)"\s*:\s*("?R?\s*\d|[1-9]\d*)/i.test(txt)) {
            toolReturnedPrice = true; break;
          }
        }

        const decision = _hg.decideGuardAction({
          reply,
          toolReturnedPrice,
          sessionMessages: session.messages,
          userMessage,
        });
        if (decision.action === 'allow') {
          // Either tools justified the price, or the user themselves typed
          // it and Lizzy is just echoing — leave the reply untouched.
          if (decision.reason === 'user_echo') {
            console.log(`[hallucination-guard] allow — user-echoed price (tools this turn: ${calledThisTurn.join(',') || 'none'})`);
          }
        } else if (decision.action === 'break_loop') {
          // The previous assistant message was already the canned RFQ
          // prompt — repeating it would loop. Log + send an ack instead.
          console.warn(`[hallucination-guard] LOOP DETECTED — canned prompt was already sent last turn. Breaking loop.`);
          console.warn(`[hallucination-guard] Original draft: ${reply.substring(0,200)}`);
          try {
            await logErrorToAdmin(
              'hallucination_guard_loop_break',
              `Guard would have repeated canned RFQ prompt; broke loop. user="${(typeof userMessage === 'string' ? userMessage : '').substring(0,200)}"`,
              'whatsapp_bot.handleMessage.hallucinationGuard',
              '',
              session.phone,
              'medium'
            );
          } catch (_) {}
          safeReply = decision.safeReply;
        } else {
          // action === 'replace'
          console.warn(`[hallucination-guard] Stripping R-price from reply (tools this turn: ${calledThisTurn.join(',') || 'none'})`);
          console.warn(`[hallucination-guard] Original reply: ${reply.substring(0,200)}`);
          safeReply = decision.safeReply;
        }
      }
    } catch (guardErr) {
      console.warn('[hallucination-guard] error (allowing reply):', guardErr.message);
    }

    session.messages.push({ role: 'assistant', content: safeReply });

    // Persist session to Firestore (fire-and-forget)
    const firestore = db();
    if (firestore) {
      // Strip orphaned tool messages before persisting
      let persistMsgs = session.messages.slice(-10);
      while (persistMsgs.length > 0 && persistMsgs[0].role === 'tool') {
        persistMsgs.shift();
      }
      firestore.collection('wa_sessions').doc(session.phone).set({
        phone: session.phone,
        linkedUserId: session.linkedUserId || null,
        messages: persistMsgs.map(m => {
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
      }).catch(e => {
        // Surface persist failures so we know when sessions silently die on
        // Render restart (was previously swallowed with `.catch(() => {})`).
        console.error(`[session-persist] CRITICAL: ${maskPhone(session.phone)} persist failed: ${e && e.message}`);
      });
    }

    return safeReply;
  } catch (err) {
    console.error('[handleMessage] Error:', err.message);
    try {
      await logErrorToAdmin(
        'whatsapp_bot_error',
        `Bot failed to respond to ${session && session.phone ? session.phone : 'a customer'}. They received a generic "try again" message.`,
        'whatsapp_bot',
        `${err && err.stack ? err.stack : err && err.message ? err.message : String(err)}`,
        null,
        'high'
      );
    } catch (_) {}
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

// ─── Webhook idempotency (in-memory dedupe of Meta message ids) ───
// Meta retries webhook delivery if our HTTP 200 takes too long. The same
// `msg.id` arriving 2-3 times caused duplicate OpenAI calls and Firestore
// writes. Keep ids for 10 minutes; that's well beyond Meta's retry window.
const _seenMessageIds = new Map();
const MSG_ID_TTL_MS = 10 * 60 * 1000;
setInterval(() => {
  const now = Date.now();
  for (const [id, ts] of _seenMessageIds) {
    if (now - ts > MSG_ID_TTL_MS) _seenMessageIds.delete(id);
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

// ─── Photo batching ───
// WhatsApp delivers albums of photos as separate webhook events arriving ~milliseconds
// to seconds apart. Processing each one individually causes duplicate replies and
// wasted vision calls. We collect pending photos per-session and process them as ONE
// batch after a short quiet period (PHOTO_BATCH_DEBOUNCE_MS).
const PHOTO_BATCH_DEBOUNCE_MS = 4000;

async function _flushPendingPhotos(from, contactName) {
  const session = sessions.get(from);
  if (!session || !session.pendingPhotos || session.pendingPhotos.length === 0) return;

  const photos = session.pendingPhotos;
  session.pendingPhotos = [];
  session.pendingPhotoTimer = null;

  const n = photos.length;
  const captions = photos.map(p => p.caption).filter(Boolean);
  const captionText = captions.length ? ` Customer caption(s): ${captions.map(c => `"${c}"`).join(' | ')}.` : '';
  const plural = n === 1 ? 'a photo' : `${n} photos`;
  const userText = `[Customer sent ${plural} of a maintenance/repair issue.${captionText}] Analyse the image(s) together and identify the single underlying problem. Then follow the pricing rules: first call lookup_pricing with the specific service. If it returns matched=true use that fixed price and wait for confirmation. If it returns matched=false, follow the AI RFQ flow strictly in order — (1) confirm your understanding in one sentence, (2) ask whether the customer or the artisan will buy the materials, (3) if the artisan will buy materials and the job needs a specific fixture/part, call show_material_options and wait for their pick, (4) ask for the client's budget, (5) only then call submit_rfq with materialsResponsibility, clientBudget and (if applicable) materialChoice.`;

  // Filter to vision-safe images
  const VISION_MAX = 3 * 1024 * 1024;
  const safeUrls = photos
    .filter(p => p.supportedVisionMime && p.approxBytes <= VISION_MAX)
    .map(p => p.dataUrl);
  const dropped = photos.length - safeUrls.length;
  const textForAi = dropped > 0
    ? `${userText} Note: ${dropped} of the ${photos.length} image(s) could not be analysed (unsupported format or too large) — base your analysis on the ones you can see.`
    : userText;

  let reply = '';
  try {
    reply = safeUrls.length > 0
      ? await handleMessage(session, textForAi, safeUrls)
      : await handleMessage(session, `${textForAi} None of the photos could be analysed — please ask the customer for ONE clear JPG/PNG close-up.`);
  } catch (err) {
    console.error(`[photo-batch] ${from}: vision processing failed:`, err && err.message);
    try {
      await logErrorToAdmin(
        'whatsapp_vision_error',
        `Photo batch analysis failed for ${from} (${photos.length} photo(s)). Falling back to text-only reply.`,
        'whatsapp_bot',
        `count=${photos.length} err=${err && err.message}`,
        null,
        'high'
      );
    } catch (_) {}
    try {
      reply = await handleMessage(session, `${textForAi} Image analysis failed on the last batch — continue with text-only diagnosis.`);
    } catch (_) { reply = ''; }
  }

  if (!reply || !reply.trim()) {
    reply = n === 1
      ? 'Thanks, I received your photo. Please briefly describe the issue as well so I can assist.'
      : `Thanks, I received all ${n} photos. Please briefly describe the issue so I can assist.`;
  }

  // Deduplicate: if this exact reply was sent in the last 30s, skip sending again.
  const now = Date.now();
  if (session._lastReplyText === reply && (now - (session._lastReplyAt || 0)) < 30000) {
    console.log(`[photo-batch] ${from}: suppressed duplicate reply`);
    return;
  }
  session._lastReplyText = reply;
  session._lastReplyAt = now;

  logChatMessage(from, 'outgoing', reply, { linkedUserId: session.linkedUserId, displayName: contactName || null, toolsCalled: session._lastToolsCalled || [], bookingRef: session.lastBookingId || session.lastRfqId || null });
  const chunks = reply.match(/.{1,4000}/gs) || [reply];
  for (const chunk of chunks) {
    try { await sendWhatsAppMessage(from, chunk); } catch (_) {}
  }
}

function _queuePhoto(from, contactName, photo) {
  const session = sessions.get(from);
  if (!session) return;
  if (!Array.isArray(session.pendingPhotos)) session.pendingPhotos = [];
  session.pendingPhotos.push(photo);
  if (session.pendingPhotoTimer) {
    clearTimeout(session.pendingPhotoTimer);
  }
  session.pendingPhotoTimer = setTimeout(() => {
    _flushPendingPhotos(from, contactName).catch(err => {
      console.error('[photo-batch] flush error:', err && err.message);
    });
  }, PHOTO_BATCH_DEBOUNCE_MS);
}

// Incoming messages
app.post('/webhook', async (req, res) => {
  // Verify Meta webhook signature (X-Hub-Signature-256) when the secret is
  // configured. If missing, log loudly but DO NOT reject — that would take
  // the bot offline whenever the env var isn't deployed. Set
  // WHATSAPP_STRICT_WEBHOOK=1 to enforce hard rejection in production.
  const appSecret = process.env.WHATSAPP_APP_SECRET || process.env.META_APP_SECRET || '';
  const strict = process.env.WHATSAPP_STRICT_WEBHOOK === '1';
  if (appSecret) {
    const signature = req.headers['x-hub-signature-256'] || '';
    const rawBody = req.rawBody || Buffer.from(JSON.stringify(req.body));
    const expected = 'sha256=' + require('crypto').createHmac('sha256', appSecret).update(rawBody).digest('hex');
    try {
      const a = Buffer.from(signature);
      const b = Buffer.from(expected);
      const ok = a.length === b.length && require('crypto').timingSafeEqual(a, b);
      if (!ok) {
        console.warn('[webhook] Invalid signature — rejecting');
        return res.sendStatus(403);
      }
    } catch (e) {
      console.warn('[webhook] signature compare error:', e && e.message);
      return res.sendStatus(403);
    }
  } else if (strict) {
    console.error('[webhook] STRICT mode: WHATSAPP_APP_SECRET missing — rejecting');
    return res.sendStatus(403);
  } else {
    console.warn('[webhook] No WHATSAPP_APP_SECRET configured — signature verification disabled. Set it in Render env to enable, or WHATSAPP_STRICT_WEBHOOK=1 to enforce.');
  }

  // Always respond 200 quickly to Meta
  res.sendStatus(200);

  try {
    const entry = req.body?.entry?.[0];
    const changes = entry?.changes?.[0];
    const value = changes?.value;

    if (!value?.messages) return; // status update, not a message

    // Grab WhatsApp profile name for chat logs
    const _contactName = value?.contacts?.[0]?.profile?.name || null;

    for (const msg of value.messages) {
      // Defensive: malformed payloads from Meta have crashed the worker before.
      // Skip anything that isn't a well-formed object with `from` + `type`.
      if (!msg || typeof msg !== 'object' || typeof msg.from !== 'string' || typeof msg.type !== 'string') {
        console.warn('[webhook] skipping malformed message:', JSON.stringify(msg).slice(0, 200));
        continue;
      }
      // Idempotency: Meta retries webhook delivery on 5xx / timeout. Without
      // dedupe, a single user message can be processed 2-3 times (double
      // OpenAI calls, duplicate Firestore writes, repeated WA replies).
      if (msg.id && typeof msg.id === 'string') {
        if (_seenMessageIds.has(msg.id)) {
          console.log(`[webhook] duplicate message id ${msg.id} \u2014 skipping`);
          continue;
        }
        _seenMessageIds.set(msg.id, Date.now());
      }
      const from = msg.from; // phone number
      let userText = '';

      try {
      // CRITICAL-1 fix (audit 2026-05-15): serialise per-phone so concurrent
      // webhook deliveries (Meta retries / rapid bursts) cannot interleave
      // session mutations (lastBookingId, lastRfqId, photoUrls, promoCode,
      // messages[]). withPhoneLock chains promises keyed by phone — different
      // phones still parallelise. `continue` inside this block is replaced
      // with `return` so the arrow exits the locked critical section and the
      // outer for-loop iterates to the next message naturally.
      await withPhoneLock(from, async () => {

      // Rate-limit check (prevents abuse / runaway OpenAI costs)
      if (isRateLimited(from)) {
        console.warn(`[webhook] Rate limited: ${from}`);
        return;
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
            console.log(`[auto-link] Matched WhatsApp ${maskPhone(session.phone)} to app user ${appUser.id} (${appUser.name || 'unknown'})`);
          }
        } catch (e) {
          console.warn('[auto-link] Phone lookup failed:', e.message);
        }
      }

      switch (msg.type) {
        case 'text':
          userText = (msg.text && typeof msg.text.body === 'string') ? msg.text.body : '';
          if (!userText) { return; }
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
          if (!imageMedia) {
            await sendWhatsAppMessage(
              from,
              'I could not download your photo. Please send the photo again, or describe the issue in text.'
            );
            return;
          }

          // Upload to Firebase Storage so artisans can see it alongside the job.
          const storageUrl = await uploadImageToStorage(imageMedia.buffer, imageMedia.mimeType);
          if (storageUrl) {
            session.photoUrls.push(storageUrl);
            console.log(`[msg] ${from}: [IMAGE uploaded to Storage, ${session.photoUrls.length} total]`);
          }
          logChatMessage(from, 'incoming', caption || '[Photo]', { messageType: 'image', linkedUserId: session.linkedUserId, displayName: _contactName });

          const mime = (imageMedia.mimeType || '').toLowerCase();
          const supportedVisionMime = mime.includes('jpeg') || mime.includes('jpg') || mime.includes('png') || mime.includes('webp');
          const approxBytes = Math.floor((imageMedia.base64.length * 3) / 4);

          // Queue the photo and let the debounced batcher produce ONE consolidated reply
          // even when customers send albums of 2–10 photos in quick succession.
          _queuePhoto(from, _contactName, {
            dataUrl: imageMedia.dataUrl,
            caption,
            mime,
            approxBytes,
            supportedVisionMime,
          });
          return;
        }
        case 'document': {
          // BHV-9: previously the placeholder text was passed to GPT but the
          // customer received NO acknowledgement, leaving them confused.
          // Send an explicit reply so they know to retry as text/photo.
          const fname = msg.document?.filename || '';
          await sendWhatsAppMessage(
            from,
            `Thanks${fname ? ` for "${fname}"` : ''}! I can't read documents (PDFs, Word, etc.) yet. Please describe your issue in a text message, or send a photo of the problem and I'll take it from there.`
          );
          logChatMessage(from, 'incoming', `[document: ${fname || 'unknown'}]`, { messageType: 'document', linkedUserId: session.linkedUserId, displayName: _contactName });
          return;
        }
        case 'audio': {
          // Transcribe voice note via Whisper
          const audioTranscript = await transcribeAudio(msg.audio?.id);
          if (audioTranscript && audioTranscript.trim()) {
            userText = audioTranscript.trim();
            console.log(`[msg] ${from}: [VOICE NOTE transcribed: "${userText.substring(0, 80)}"]`);
          } else {
            // BHV-16: log empty/null transcripts (Whisper succeeded but
            // returned nothing — usually unsupported language or audio too
            // quiet). Without this, admin has no visibility into how often
            // voice-note onboarding is failing.
            logErrorToAdmin(
              'transcription_error',
              'Whisper returned empty transcript',
              'whatsapp_bot',
              JSON.stringify({ phone: from, audio_id: msg.audio?.id || null }),
              null,
              'low'
            ).catch(() => {});
            await sendWhatsAppMessage(
              from,
              'I could not transcribe that voice note. Please try sending it again, or type your request in text.'
            );
            return;
          }
          break;
        }
        case 'location': {
          // Persist GPS coordinates on the session so create_booking can store them
          session.sharedLatitude = msg.location.latitude;
          session.sharedLongitude = msg.location.longitude;
          if (msg.location.address) session.sharedAddress = msg.location.address;

          // BUG-FIX (May 2026): WhatsApp's location-pin payload usually omits
          // an address string. Without one, downstream auto-dispatch can't
          // infer the customer's city/country and admin sees only "lat, lng"
          // in the booking — both lead to artisan-matching failures and a
          // poor admin UX. Reverse-geocode using OpenStreetMap Nominatim
          // (free, no API key, 1 req/sec). Best-effort with 5s timeout —
          // if it fails we keep the raw coords and continue.
          if (!session.sharedAddress) {
            try {
              const r = await fetch(
                `https://nominatim.openstreetmap.org/reverse?format=jsonv2&lat=${encodeURIComponent(msg.location.latitude)}&lon=${encodeURIComponent(msg.location.longitude)}&zoom=18&addressdetails=1`,
                {
                  headers: { 'User-Agent': 'Square15-WA-Bot/1.0 (support@square15.co.za)' },
                  signal: AbortSignal.timeout(5000),
                }
              );
              if (r && r.ok) {
                const j = await r.json();
                const display = String(j.display_name || '').trim();
                if (display) {
                  session.sharedAddress = display;
                  console.log(`[location] reverse-geocoded ${from}: ${display}`);
                }
              }
            } catch (geoErr) {
              console.warn(`[location] reverse-geocode failed for ${from}: ${geoErr && geoErr.message}`);
            }
          }

          // Build the userText AFTER geocoding so the AI sees the resolved address.
          userText = `[Customer shared location: ${msg.location.latitude}, ${msg.location.longitude}]`;
          if (session.sharedAddress) userText += ` Address: ${session.sharedAddress}`;
          console.log(`[location] ${from}: saved lat=${session.sharedLatitude} lng=${session.sharedLongitude} addr=${session.sharedAddress || 'none'}`);
          break;
        }
        case 'sticker': {
          // BHV-9: don't silently drop. Briefly acknowledge so the customer
          // knows the bot is alive and what to send instead.
          if (!session._stickerNudged) {
            await sendWhatsAppMessage(
              from,
              'Cute sticker! 😊 To help with your maintenance request, please send a text describing the issue or a photo of the problem.'
            );
            session._stickerNudged = true; // only nudge once per session to avoid spam
          }
          return;
        }
        default: {
          // BHV-9: previously the placeholder text was passed to GPT but the
          // customer never received any reply. Send an explicit one.
          await sendWhatsAppMessage(
            from,
            `I can't process "${msg.type}" messages yet. Please send a text describing your issue or a photo of the problem.`
          );
          return;
        }
      }

      if (!userText.trim()) return;

      // Truncate excessively long messages to prevent OpenAI token abuse
      if (userText.length > 10000) {
        userText = userText.substring(0, 10000) + '...[message truncated]';
      }

      console.log(`[msg] ${from}: ${userText.substring(0, 100)}`);

      // Log incoming user message
      const _logMsgType = msg.type === 'audio' ? 'audio' : msg.type === 'location' ? 'location' : msg.type === 'document' ? 'document' : 'text';
      logChatMessage(from, 'incoming', userText, { messageType: _logMsgType, linkedUserId: session.linkedUserId, displayName: _contactName });

      const reply = await handleMessage(session, userText);
      if (!reply || !reply.trim()) {
        await sendWhatsAppMessage(
          from,
          'I could not generate a reply for that yet. Please rephrase your request, or send Hi to restart.'
        );
        return;
      }

      // Duplicate-reply guard (30s window) — protects against Meta retry storms
      // and rapid-fire identical bot responses.
      {
        const now = Date.now();
        if (session._lastReplyText === reply && (now - (session._lastReplyAt || 0)) < 30000) {
          console.log(`[webhook] ${from}: suppressed duplicate reply`);
          return;
        }
        session._lastReplyText = reply;
        session._lastReplyAt = now;
      }

      // Log outgoing bot reply
      logChatMessage(from, 'outgoing', reply, { linkedUserId: session.linkedUserId, displayName: _contactName, toolsCalled: session._lastToolsCalled || [], bookingRef: session.lastBookingId || session.lastRfqId || null });

      // Split long replies into chunks (WhatsApp has ~4096 char limit)
      const chunks = reply.match(/.{1,4000}/gs) || [reply];
      for (const chunk of chunks) {
        await sendWhatsAppMessage(from, chunk);
      }
      }); // end withPhoneLock (CRITICAL-1 fix)
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
app.get('/health', (req, res) => res.json({ status: 'ok', service: 'square15-whatsapp-bot', version: 'rfq-spec-capture-v27', commit: process.env.RENDER_GIT_COMMIT || 'unknown', deployedAt: process.env.RENDER_DEPLOY_TIME || new Date().toISOString() }));

// ════════════════════════════════════════════════════════════════════════════
// LIVE E2E TEST DIAGNOSTIC ENDPOINTS (auth: x-internal-secret)
// Remove after full-flow validation. Used by test-full-flow.js to drive a
// real customer journey on WhatsApp end-to-end.
// ════════════════════════════════════════════════════════════════════════════

// 1) Inject a WA message into the bot pipeline as if it came from a webhook.
//    Bot processes it, sends a real reply via Meta API, returns the reply.
//    Body: { phone, text, reset?, contactName?, imageDataUrl? }
app.post('/debug/inject-message', requireInternalSecret, async (req, res) => {
  const { phone, text, reset, contactName, imageDataUrl } = req.body || {};
  if (!phone) return res.status(400).json({ error: 'phone required' });
  const from = String(phone).replace(/[^\d]/g, '');
  if (!from) return res.status(400).json({ error: 'invalid phone' });
  try {
    let reply = '';
    let toolsCalled = [];
    let sentChunks = 0;
    let lastBookingId = null, lastRfqId = null;
    await withPhoneLock(from, async () => {
      if (reset) {
        try { sessions.delete(from); } catch {}
        try { const f = db(); if (f) await f.collection('wa_sessions').doc(from).delete(); } catch {}
      }
      if (isRateLimited(from)) { reply = '[rate-limited]'; return; }
      const session = getSession(from);
      if (!reset) await restoreSessionFromFirestore(session);
      if (!session.linkedUserId) {
        try { const u = await findUserByPhone(session.phone); if (u) session.linkedUserId = u.id; } catch {}
      }
      const userText = String(text || '');
      logChatMessage(from, 'incoming', userText, { messageType: imageDataUrl ? 'image' : 'text', linkedUserId: session.linkedUserId, displayName: contactName || 'E2ETest', source: 'inject' });
      // Mirror real webhook behaviour: when an image arrives, also persist a
      // marker URL into session.photoUrls so downstream tools (submit_rfq
      // photo gate, RFQ work_images) treat the photo as received.
      if (imageDataUrl) {
        if (!Array.isArray(session.photoUrls)) session.photoUrls = [];
        session.photoUrls.push('https://test/e2e-injected-photo.jpg');
      }
      const r = imageDataUrl ? await handleMessage(session, userText, [imageDataUrl]) : await handleMessage(session, userText);
      reply = r || '';
      toolsCalled = session._lastToolsCalled || [];
      lastBookingId = session.lastBookingId || null;
      lastRfqId = session.lastRfqId || null;
      if (!reply.trim()) {
        await sendWhatsAppMessage(from, 'I could not generate a reply for that yet. Please rephrase, or send Hi to restart.');
        sentChunks = 1; return;
      }
      session._lastReplyText = reply; session._lastReplyAt = Date.now();
      logChatMessage(from, 'outgoing', reply, { linkedUserId: session.linkedUserId, displayName: contactName || 'E2ETest', toolsCalled, source: 'inject' });
      const chunks = reply.match(/.{1,4000}/gs) || [reply];
      for (const chunk of chunks) {
        try { await sendWhatsAppMessage(from, chunk); sentChunks++; } catch (e) { console.error('[inject] send failed:', e.message); }
      }
    });
    return res.json({ ok: true, reply, toolsCalled, sentChunks, lastBookingId, lastRfqId, phone: from });
  } catch (e) {
    console.error('[inject] error:', e.stack || e.message);
    return res.status(500).json({ error: String(e.message || e) });
  }
});

// 2) Look up wallet balance + linked user + an active artisan to use in the test.
app.get('/debug/test-info', requireInternalSecret, async (req, res) => {
  try {
    const phone = String(req.query.phone || '').replace(/[^\d]/g, '');
    if (!phone) return res.status(400).json({ error: 'phone required' });
    const firestore = db();
    if (!firestore) return res.status(503).json({ error: 'firestore unavailable' });
    const user = await findUserByPhone(phone);
    let balance = null, userId = null, userName = null;
    if (user) {
      userId = user.id;
      const uDoc = await firestore.collection('users').doc(user.id).get();
      if (uDoc.exists) {
        balance = parseFloat(uDoc.data().balance || '0');
        userName = uDoc.data().name || uDoc.data().fullName || null;
      }
    }
    // Pick first active artisan with at least basic info
    let artisan = null;
    try {
      const snap = await firestore.collection('serviceProvider').limit(20).get();
      for (const d of snap.docs) {
        const x = d.data() || {};
        if (x.status && String(x.status).toLowerCase() === 'inactive') continue;
        artisan = { id: d.id, name: x.name || x.fullName || x.businessName || 'Test Artisan', phone: x.phone || x.contact || '' };
        break;
      }
    } catch {}
    res.json({ phone, userId, userName, walletBalance: balance, artisan });
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

// 3) Top up the customer's wallet (test only).
app.post('/debug/top-up-wallet', requireInternalSecret, async (req, res) => {
  try {
    const { phone, amount } = req.body || {};
    const amt = Number(amount);
    if (!phone || !amt || amt <= 0) return res.status(400).json({ error: 'phone and positive amount required' });
    const firestore = db();
    if (!firestore) return res.status(503).json({ error: 'firestore unavailable' });
    const user = await findUserByPhone(String(phone).replace(/[^\d]/g, ''));
    if (!user) return res.status(404).json({ error: 'user not linked' });
    const uRef = firestore.collection('users').doc(user.id);
    let newBalance = 0;
    await firestore.runTransaction(async (txn) => {
      const s = await txn.get(uRef);
      const cur = parseFloat((s.data() && s.data().balance) || '0');
      newBalance = cur + amt;
      txn.update(uRef, { balance: newBalance.toFixed(2) });
    });
    await firestore.collection('transactionLogs').add({
      user_id: user.id, type: 'topup', subtype: 'e2e_test_topup', amount: amt,
      source: 'debug_endpoint', status: 'success',
      created_at: admin.firestore.FieldValue.serverTimestamp(),
    });
    res.json({ ok: true, userId: user.id, newBalance: newBalance.toFixed(2) });
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

// 4) Patch the RFQ doc to attach an admin quote so the customer can accept.
//    Input: { rfqId, totalCost, breakdown? }
//    Sets cost + admin_quote_total + rfq_status='quoted'. Then the customer
//    can reply "accept R<amount>" via WA and `accept_rfq_quote` will fire.
app.post('/debug/quote-rfq', requireInternalSecret, async (req, res) => {
  try {
    const { rfqId, totalCost, breakdown } = req.body || {};
    if (!rfqId || !totalCost) return res.status(400).json({ error: 'rfqId and totalCost required' });
    const firestore = db();
    if (!firestore) return res.status(503).json({ error: 'firestore unavailable' });
    const cost = Number(totalCost);
    const updates = {
      cost: cost.toFixed(2),
      admin_quote_total: cost.toFixed(2),
      rfq_status: 'quoted',
      status: 'quoted',
      quoted_at: new Date().toISOString(),
      admin_quote_breakdown: breakdown || `Labor + materials: R${cost.toFixed(2)}`,
    };
    // Patch both collections (futureBookings is canonical for RFQs)
    await firestore.collection('futureBookings').doc(rfqId).set(updates, { merge: true });
    try { await firestore.collection('tasksManagement').doc(rfqId).set(updates, { merge: true }); } catch {}
    res.json({ ok: true, rfqId, updates });
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

// 4c) Look up Firebase Auth UID by email (returns null if not in Auth).
app.get('/debug/find-auth-uid', requireInternalSecret, async (req, res) => {
  try {
    const email = String(req.query.email || '').trim().toLowerCase();
    if (!email) return res.status(400).json({ error: 'email required' });
    try {
      const u = await admin.auth().getUserByEmail(email);
      return res.json({ email, uid: u.uid, displayName: u.displayName || null, phone: u.phoneNumber || null, disabled: u.disabled, providers: (u.providerData || []).map(p => p.providerId) });
    } catch (e) {
      return res.json({ email, uid: null, error: e.code || e.message });
    }
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

// 4d) Backfill artisan Firebase Auth UID on every serviceProvider doc that is
//     missing it. Looks up Auth by email and writes `uid` field. Idempotent.
//     Required so FCM pushes (keyed by auth.uid) actually reach the artisan.
//     POST /debug/backfill-artisan-uids?dryRun=1 to preview without writing.
app.post('/debug/backfill-artisan-uids', requireInternalSecret, async (req, res) => {
  try {
    const dryRun = String(req.query.dryRun || req.body?.dryRun || '') === '1';
    const firestore = db();
    if (!firestore) return res.status(503).json({ error: 'firestore unavailable' });
    const snap = await firestore.collection('serviceProvider').limit(2000).get();
    const results = { scanned: snap.size, alreadyOk: 0, fixed: 0, noEmail: 0, noAuthMatch: 0, errors: 0, fixes: [], skipped: [] };
    for (const d of snap.docs) {
      const x = d.data() || {};
      const existing = String(x.uid || x.userId || '').trim();
      const email = String(x.email || x.userEmail || x.contact_email || '').trim().toLowerCase();
      if (existing) { results.alreadyOk += 1; continue; }
      if (!email) { results.noEmail += 1; results.skipped.push({ id: d.id, reason: 'no_email', name: x.name || x.userName || null }); continue; }
      try {
        const u = await admin.auth().getUserByEmail(email);
        if (!dryRun) {
          await firestore.collection('serviceProvider').doc(d.id).update({ uid: u.uid, updated_at: new Date().toISOString() });
        }
        results.fixed += 1;
        results.fixes.push({ id: d.id, email, uid: u.uid, name: x.name || x.userName || null });
      } catch (e) {
        if (String(e.code || '').includes('user-not-found')) {
          results.noAuthMatch += 1;
          results.skipped.push({ id: d.id, email, reason: 'no_auth_user' });
        } else {
          results.errors += 1;
          results.skipped.push({ id: d.id, email, reason: e.code || e.message });
        }
      }
    }
    results.dryRun = dryRun;
    res.json(results);
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

// 4b) Find artisan by email/name (for picking the test artisan).
app.get('/debug/find-artisan', requireInternalSecret, async (req, res) => {
  try {
    const email = String(req.query.email || '').trim().toLowerCase();
    const name = String(req.query.name || '').trim().toLowerCase();
    const firestore = db();
    if (!firestore) return res.status(503).json({ error: 'firestore unavailable' });
    const snap = await firestore.collection('serviceProvider').limit(500).get();
    const matches = [];
    for (const d of snap.docs) {
      const x = d.data() || {};
      const eml = String(x.email || x.userEmail || x.contact_email || '').toLowerCase();
      const nm = String(x.name || x.userName || x.full_name || x.businessName || '').toLowerCase();
      if ((email && eml === email) || (name && nm.includes(name))) {
        matches.push({ id: d.id, authUid: x.uid || x.userId || null, name: x.name || x.userName || x.full_name || null, email: x.email || x.userEmail || null, mainCategory: x.mainCategory || null, status: x.status || null, active: x.active });
      }
    }
    res.json({ count: matches.length, matches });
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

// 5) Simulate artisan acceptance: set accept=1 + artisan_confirmed=yes,
//    Body: { bookingId, artisanId, artisanName? }
app.post('/debug/artisan-accept', requireInternalSecret, async (req, res) => {
  try {
    const { bookingId, artisanId, artisanName } = req.body || {};
    if (!bookingId || !artisanId) return res.status(400).json({ error: 'bookingId and artisanId required' });
    const firestore = db();
    if (!firestore) return res.status(503).json({ error: 'firestore unavailable' });
    const main = bookingId.includes('_') ? bookingId.split('_')[0] : bookingId;
    const aName = artisanName || 'Test Artisan';
    // Mark accepted in both collections
    const updates = {
      accept: '1',
      artisan_confirmed: 'yes',
      service_provider_id: artisanId,
      service_provider_name: aName,
      status: 'pending_payment',
      rfq_status: 'accepted',
      artisan_accepted_at: new Date().toISOString(),
    };
    await firestore.collection('futureBookings').doc(main).set(updates, { merge: true });
    await firestore.collection('tasksManagement').doc(main).set(updates, { merge: true });
    // Forward to the canonical webhook so the customer WA message gets sent through the same code path
    const fakeReq = { body: { bookingId: `${main}_${artisanId}`, artisanName: aName } };
    // Reuse the customer-notify section by calling sendWhatsAppMessage directly here would skip dedup.
    // Easiest: have the test runner call /api/artisan-accepted itself with that body.
    res.json({ ok: true, bookingId: main, artisanId, instruct: 'now POST /api/artisan-accepted with bookingId=' + `${main}_${artisanId}` });
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

// Diagnostic: run buildersSearchOptions live and report what happens.
// GET /diag/builders?q=shower+mixer&limit=3
// Auth: requires x-internal-secret header (admin-only diagnostic).
app.get('/diag/builders', requireInternalSecret, async (req, res) => {
  const q = String(req.query.q || 'shower mixer').trim();
  const limit = Math.min(5, Math.max(1, Number(req.query.limit) || 3));
  const raw = String(req.query.raw || '') === '1';
  const t0 = Date.now();
  try {
    const cfg = await getBuildersBffConfig();
    const tCfg = Date.now() - t0;
    if (raw && cfg) {
      const qn = normalizeBuildersQuery(q);
      const uri = `https://www.builders.co.za/wmapi/bff/graphql/${cfg.searchKey}/${cfg.searchHash}`;
      const r = await buildersFetch(uri, {
        method: 'POST',
        headers: buildersBffHeaders({ operationName: cfg.searchKey, operationHash: cfg.searchHash }),
        body: JSON.stringify({ variables: { keyword: qn, offset: 0, pageSize: 24, dynamicPriceRange: true, site: cfg.site } }),
        timeoutMs: 12000,
      });
      const txt = await r.text().catch(() => '');
      return res.json({
        q, qn,
        http_status: r.status,
        http_ok: r.ok,
        bff_config: { hasHash: !!cfg.searchHash, site: cfg.site, hashPrefix: (cfg.searchHash || '').slice(0, 8) },
        response_preview: txt.slice(0, 2000),
      });
    }
    const opts = await buildersSearchOptions(q, limit);
    const tAll = Date.now() - t0;
    res.json({
      q,
      limit,
      timings_ms: { bff_config_ms: tCfg, total_ms: tAll },
      bff_config: cfg ? { hasHash: !!cfg.searchHash, site: cfg.site } : null,
      options_count: opts.length,
      options: opts.map(o => ({
        label: o.label,
        price: o.price,
        has_image: !!o.image_url,
        image_preview: (o.image_url || '').slice(0, 120),
        product_url: o.product_url,
      })),
    });
  } catch (e) {
    console.error('[diag/builders] error:', e);
    res.status(500).json({ error: 'internal_error' });
  }
});

// ─── Builders product search (admin app picker) ───
// Returns full options with non-truncated image_url + product_url.
// Auth-protected so only trusted admin clients can hit it.
app.get('/api/builders-search', requireInternalSecret, async (req, res) => {
  const q = String(req.query.q || '').trim();
  const limit = Math.min(8, Math.max(1, Number(req.query.limit) || 5));
  if (!q) return res.json({ q, options: [] });
  try {
    const opts = await buildersSearchOptions(q, limit);
    res.json({
      q,
      options: (opts || []).map(o => ({
        label: o.label || '',
        price: Number(o.price || 0),
        image_url: o.image_url || '',
        product_url: o.product_url || '',
      })),
    });
  } catch (e) {
    res.status(500).json({ error: e.message, options: [] });
  }
});

// ─── Diagnostic: fetch a Builders product page directly to test if Render IP is blocked ───
// GET /diag/builders-product?url=https://www.builders.co.za/.../p/744580
app.get('/diag/builders-product', async (req, res) => {
  const url = String(req.query.url || '').trim();
  if (!url || !/^https?:\/\/(www\.)?builders\.co\.za\//i.test(url)) {
    return res.status(400).json({ error: 'url must be a https://www.builders.co.za/... URL' });
  }
  try {
    const r = await buildersFetch(url, { headers: buildersHeaders({ referer: 'https://www.builders.co.za/' }), timeoutMs: 20000 });
    const html = await r.text().catch(() => '');
    const blocked = !r.ok || /\/blocked\?/.test(html) || /perimeterx|captcha\.js/i.test(html);
    const ogTitle = (html.match(/property="og:title"\s+content="([^"]{3,200})"/i) || [])[1] || '';
    const ogImage = extractOgImageFromHtml(html) || '';
    const price = extractRetailPriceFromHtml(html) || 0;
    res.json({
      url, http_status: r.status, http_ok: r.ok, html_len: html.length,
      looks_blocked: blocked, og_title: ogTitle, og_image: ogImage, price,
    });
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

// ─── Hydrate a pasted Builders product URL into a picker option ───
// GET /api/builders-hydrate?url=...   (admin-authenticated)
// Returns { label, price, image_url, product_url } if it can be fetched.
app.get('/api/builders-hydrate', requireInternalSecret, async (req, res) => {
  const url = String(req.query.url || '').trim();
  if (!url || !/^https?:\/\/(www\.)?builders\.co\.za\//i.test(url)) {
    return res.status(400).json({ error: 'url must be a https://www.builders.co.za/... product URL' });
  }
  try {
    const r = await buildersFetch(url, { headers: buildersHeaders({ referer: 'https://www.builders.co.za/' }), timeoutMs: 20000 });
    if (!r.ok) return res.status(502).json({ error: `upstream ${r.status}` });
    const html = await r.text().catch(() => '');
    if (!html || /\/blocked\?/.test(html)) return res.status(502).json({ error: 'upstream blocked' });
    const ogTitle = (html.match(/property="og:title"\s+content="([^"]{3,200})"/i) || [])[1] || '';
    const image_url = extractOgImageFromHtml(html) || '';
    const price = extractRetailPriceFromHtml(html) || 0;
    if (!ogTitle && !price) return res.status(502).json({ error: 'could not parse product page' });
    res.json({ label: ogTitle, price, image_url, product_url: url });
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

// ─── Diagnostic: test Firebase read/write (auth-protected) ───
app.get('/debug/firebase-test', requireInternalSecret, async (req, res) => {
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
app.post('/api/artisan-accepted', requireInternalSecret, async (req, res) => {
  try {
    if (!req.body || typeof req.body !== 'object') {
      return res.status(400).json({ error: 'Invalid request body' });
    }
    const { bookingId, artisanName } = req.body;
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
    let mainStatus = '';
    let mainRfqStatus = '';
    let mainAccept = '';
    if (fbDoc.exists) {
      const d = fbDoc.data();
      customerPhone = d.user_phone || d.customerPhone || d.contact || d.client_phone || d.phone || '';
      bookingCost = d.cost || '';
      bookingDescription = d.description || d.subcategory || d.category_name || '';
      orderNo = d.order_no || '';
      mainStatus = String(d.status || '').toLowerCase();
      mainRfqStatus = String(d.rfq_status || '').toLowerCase();
      mainAccept = String(d.accept || '');
    }

    // Fallback to tasksManagement
    if (!customerPhone) {
      const tmDoc = await firestore.collection('tasksManagement').doc(mainBookingId).get();
      if (tmDoc.exists) {
        const d = tmDoc.data();
        customerPhone = d.customerPhone || d.contact || d.user_phone || d.client_phone || d.phone || '';
        bookingCost = d.cost || '';
        bookingDescription = d.description || d.subcategory || d.category_name || '';
        orderNo = d.order_no || '';
        if (!mainStatus) mainStatus = String(d.status || '').toLowerCase();
        if (!mainRfqStatus) mainRfqStatus = String(d.rfq_status || '').toLowerCase();
        if (!mainAccept) mainAccept = String(d.accept || '');
      }
    }

    // ── Status guards (CRITICAL-1, CRITICAL idempotency) ──
    // (a) Refuse to "resurrect" a booking the admin/customer killed.
    const TERMINAL_BAD = new Set(['rejected', 'cancelled', 'canceled', 'closed']);
    if (TERMINAL_BAD.has(mainStatus) || TERMINAL_BAD.has(mainRfqStatus)) {
      console.warn(`[api/artisan-accepted] booking ${mainBookingId} is in terminal status (${mainStatus}/${mainRfqStatus}) — refusing late artisan-accept webhook`);
      return res.status(409).json({ error: 'Booking is no longer active', status: mainStatus, rfq_status: mainRfqStatus });
    }
    // (b) Idempotency: webhook delivered twice → don't re-message customer.
    // Use the SAME flag as the Firestore snapshot listener so the two paths
    // (HTTP webhook + onSnapshot) can never both send the acceptance message.
    let acceptanceAlreadySent = false;
    if (fbDoc.exists && fbDoc.data().wa_artisan_acceptance_sent_at) acceptanceAlreadySent = true;
    if (acceptanceAlreadySent || mainStatus === 'paid' || mainStatus === 'deposit_paid') {
      console.log(`[api/artisan-accepted] booking ${mainBookingId} already notified (status=${mainStatus}, sent_at=${fbDoc.exists ? fbDoc.data().wa_artisan_acceptance_sent_at : ''}) — skipping duplicate notification`);
      return res.json({ ok: true, deduped: true, status: mainStatus });
    }

    if (!customerPhone) {
      return res.status(404).json({ error: 'No customer phone found for booking' });
    }

    // ── Atomic dedup claim (May 14 2026) ──
    // Belt-and-braces: the early check above catches the obvious case, but
    // does NOT close the millisecond race against the snapshot listener.
    // claimArtisanAcceptanceSend() uses a Firestore transaction (atomic
    // check-and-set of wa_artisan_acceptance_sent_at) plus a shared
    // in-memory Set, so only one of {HTTP webhook, snapshot listener}
    // can win the right to send the customer message.
    const _claim = await claimArtisanAcceptanceSend(firestore, mainBookingId);
    if (!_claim.claimed) {
      console.log(`[api/artisan-accepted] booking ${mainBookingId} claim refused (${_claim.reason}) — skipping duplicate notification`);
      return res.json({ ok: true, deduped: true, reason: _claim.reason });
    }

    // Extract artisan ID from bridge bookingId (e.g. WA-XXX_artisanId → artisanId)
    const artisanId = bookingId.includes('_') ? bookingId.split('_').slice(1).join('_') : '';

    // Read canonical data from futureBookings so we can populate the main tasksManagement doc
    let userId = '', bookingSource = 'whatsapp';
    if (fbDoc.exists) {
      const fd = fbDoc.data();
      userId = fd.user_id || fd.userId || fd.uid || '';
      bookingSource = fd.source || 'whatsapp';
    }

    // Update the main tasksManagement doc to mark as accepted (so payment check passes)
    // CRITICAL: include phone, source, service_provider_id, user_id so processSuccessfulPayment
    // can send WhatsApp receipt and artisan push notifications
    try {
      await firestore.collection('tasksManagement').doc(mainBookingId).set({
        accept: '1',
        artisan_confirmed: 'yes',
        status: 'pending_payment',
        service_provider_name: artisanName || '',
        source: bookingSource,
        ...(customerPhone && { phone: customerPhone, customerPhone: customerPhone, contact: customerPhone, user_phone: customerPhone, client_phone: customerPhone }),
        ...(artisanId && { service_provider_id: artisanId }),
        ...(userId && { user_id: userId, userId: userId }),
        ...(orderNo && { order_no: orderNo }),
        ...(bookingCost && { cost: bookingCost, total_cost: bookingCost }),
        ...(bookingDescription && { description: bookingDescription }),
        // BUG-FIX (May 13 2026): clear stale timeout_escalated flag so the
        // admin dashboard shows the booking as assigned again on late-accept.
        // Admin can still manually re-assign via the normal admin flows.
        ...(mainRfqStatus === 'timeout_escalated' && {
          rfq_status: 'accepted',
          late_accept_at: new Date().toISOString(),
        }),
        updated_at: new Date().toISOString(),
      }, { merge: true });
    } catch (e) { console.warn('[api/artisan-accepted] main doc update failed:', e.message); }

    // Also update futureBookings to ensure consistency. The dedup flag
    // (wa_artisan_acceptance_sent_at) is already written atomically by
    // claimArtisanAcceptanceSend() above, so we don't re-write it here.
    try {
      await firestore.collection('futureBookings').doc(mainBookingId).set({
        artisan_confirmed: 'yes',
        status: 'pending_payment',
        ...(artisanId && { service_provider_id: artisanId }),
        ...(artisanName && { service_provider_name: artisanName }),
        // Clear stale timeout flag on late accept.
        ...(mainRfqStatus === 'timeout_escalated' && {
          rfq_status: 'accepted',
          late_accept_at: new Date().toISOString(),
        }),
        updated_at: new Date().toISOString(),
      }, { merge: true });
    } catch (e) { console.warn('[api/artisan-accepted] futureBookings update failed:', e.message); }

    // Normalise phone to international format (27...)
    let to = customerPhone.replace(/[^0-9]/g, '');
    if (to.length === 10 && to.startsWith('0')) to = '27' + to.slice(1); // ZA local 10-digit only; E.164 numbers (>= 11 digits) left untouched

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
    msg += `\n🔒 *Your money is safe:* Payment is held in escrow — released to the artisan ONLY after you confirm the job is done right.\n`;
    msg += `🛡️ *Your safety:* ${name} is registered & ID-verified with Square 15. We'll share their photo with you shortly so you can match them at the door.\n`;
    msg += `💸 *Not happy with the work?* Reply *"refund"* or *"complaint"* — we'll investigate before any money is released.\n`;
    msg += `\nReply anytime if you have questions! 😊`;

    let _sendFailed = false;
    try {
      await sendWhatsAppMessage(to, msg);
      console.log(`[api/artisan-accepted] Sent acceptance notification to ${to} for booking ${mainBookingId}`);
    } catch (sendErr) {
      _sendFailed = true;
      console.error(`[api/artisan-accepted] sendWhatsAppMessage failed for ${mainBookingId}:`, sendErr.message);
      // Roll back the dedup flag so a retry can re-send. Release the
      // in-memory claim too so a follow-up listener tick isn't blocked.
      await releaseArtisanAcceptanceClaim(firestore, mainBookingId, { rollback: true });
      return res.status(502).json({ error: 'whatsapp_send_failed', message: sendErr.message });
    }

    // ── Send artisan profile photo so customer can recognise who's coming. ──
    try {
      const ref = orderNo || mainBookingId;
      let spId = artisanId;
      if (!spId) {
        try {
          const tmSnap = await firestore.collection('tasksManagement').doc(mainBookingId).get();
          if (tmSnap.exists) spId = String((tmSnap.data() || {}).service_provider_id || '').trim();
        } catch (_) {}
      }
      if (!spId && fbDoc.exists) spId = String((fbDoc.data() || {}).service_provider_id || '').trim();
      if (spId) {
        const prof = await getArtisanProfile(firestore, spId);
        if (prof && prof.imageUrl) {
          const who = prof.name || name;
          const ratingStr = (prof.rating && Number(prof.rating) > 0) ? ` ⭐ ${Number(prof.rating).toFixed(1)}` : '';
          await sendWhatsAppImage(to, prof.imageUrl, `👷 Meet ${who}${ratingStr} — your assigned Square 15 artisan for booking #${ref}. For your safety, please confirm this is the person who arrives at your door before letting them in.`);
        }
      }
    } catch (e) { console.warn('[api/artisan-accepted] artisan photo send failed:', e.message); }

    // Push notification to linked customer app
    await notifyLinkedCustomer(firestore, {
      phone: customerPhone,
      userId: userId,
      title: 'Artisan Accepted Your Booking',
      body: `${artisanName || 'An artisan'} has accepted your booking${orderNo ? ' #' + orderNo : ''}. Open the app to proceed with payment.`,
      data: { type: 'artisan_accepted', booking_id: mainBookingId },
    });

    // Update the customer's WA session so the next "pay deposit"/"pay full"
    // intercept resolves to THIS newly-accepted booking instead of an older
    // stale lastBookingId from a previous conversation.
    try {
      const liveSess = sessions.get(to);
      if (liveSess) {
        liveSess.lastBookingId = mainBookingId;
        liveSess.lastRfqId = mainBookingId;
        liveSess.paymentStatus = 'pending';
        console.log(`[api/artisan-accepted] in-memory session updated for ${to} → lastBookingId=${mainBookingId}`);
      }
      await firestore.collection('wa_sessions').doc(to).set({
        phone: to,
        lastBookingId: mainBookingId,
        lastRfqId: mainBookingId,
        lastBookingAt: Date.now(),
        lastActivity: admin.firestore.FieldValue.serverTimestamp(),
      }, { merge: true });
      console.log(`[api/artisan-accepted] wa_sessions doc updated for ${to} → lastBookingId=${mainBookingId}`);
    } catch (e) {
      console.warn('[api/artisan-accepted] session update failed:', e && e.message);
    }

    // Release the in-memory claim (flag stays in Firestore as the durable dedup).
    await releaseArtisanAcceptanceClaim(firestore, mainBookingId);

    res.json({ success: true, to, bookingId: mainBookingId });
  } catch (err) {
    // MED-17: surface webhook failures to error_logs so admin sees stuck
    // bookings instead of relying on Render console output.
    console.error('[api/artisan-accepted] error:', err.message);
    try {
      const bid = (req.body && req.body.bookingId) || '';
      await logErrorToAdmin('webhook_artisan_accepted_failed', `/api/artisan-accepted threw: ${err.message}`, 'whatsapp_bot./api/artisan-accepted', err.message, bid, 'high');
    } catch (_) {}
    // Best-effort: release in-memory claim + rollback flag so a retry/listener tick can recover.
    try {
      const bid2 = (req.body && req.body.bookingId) || '';
      const mainBid = bid2.includes('_') ? bid2.split('_')[0] : bid2;
      if (mainBid) await releaseArtisanAcceptanceClaim(db(), mainBid, { rollback: true });
    } catch (_) {}
    res.status(500).json({ error: err.message });
  }
});

// ─── Artisan App → WhatsApp: Notify client of booking status changes ───
// Dedup map to prevent duplicate messages within 60 seconds
const _recentStatusMessages = new Map(); // key: `${bookingId}:${status}` → timestamp
setInterval(() => {
  const now = Date.now();
  for (const [k, ts] of _recentStatusMessages) {
    if (now - ts > 60000) _recentStatusMessages.delete(k);
  }
}, 30000);

app.post('/api/booking-status-update', requireInternalSecret, async (req, res) => {
  try {
    const { bookingId, status, message: customMsg } = req.body || {};
    if (!bookingId || !status) return res.status(400).json({ error: 'bookingId and status required' });

    const firestore = db();
    if (!firestore) return res.status(503).json({ error: 'Database unavailable' });

    const mainBookingId = bookingId.includes('_') ? bookingId.split('_')[0] : bookingId;

    // ── Dedup guard: skip if same booking+status sent within 60s (in-memory) ──
    const dedupKey = `${mainBookingId}:${status}`;
    const lastSent = _recentStatusMessages.get(dedupKey);
    if (lastSent && Date.now() - lastSent < 60000) {
      console.log(`[api/booking-status-update] Dedup: skipping duplicate "${status}" for ${mainBookingId} (sent ${Math.round((Date.now() - lastSent) / 1000)}s ago)`);
      return res.json({ success: true, deduplicated: true, status });
    }

    // ── Persistent cross-path dedup: respect lifecycle flags written by
    //    /api/job-status-update OR startJobLifecycleListener so the same
    //    job-complete / progress / cancelled WA isn't sent twice. ──
    try {
      const lifecycleStatus = (status === 'in_progress') ? 'progress'
        : (status === 'done' || status === 'closed') ? 'completed'
        : (status === 'canceled') ? 'cancelled'
        : status;
      if (['progress', 'completed', 'cancelled'].includes(lifecycleStatus)) {
        const flagKey = `wa_lifecycle_${lifecycleStatus}_sent_at`;
        const tmCheck = await firestore.collection('tasksManagement').doc(mainBookingId).get();
        const fbCheck = await firestore.collection('futureBookings').doc(mainBookingId).get();
        const tmFlag = tmCheck.exists && tmCheck.data() ? tmCheck.data()[flagKey] : null;
        const fbFlag = fbCheck.exists && fbCheck.data() ? fbCheck.data()[flagKey] : null;
        if (tmFlag || fbFlag) {
          console.log(`[api/booking-status-update] Persistent dedup: "${status}" for ${mainBookingId} already sent (flag ${flagKey} present)`);
          _recentStatusMessages.set(dedupKey, Date.now());
          return res.json({ success: true, deduplicated: true, status, skipped: 'lifecycle_flag_present' });
        }
      }
    } catch (e) {
      console.warn('[api/booking-status-update] persistent dedup check failed:', e.message);
    }

    _recentStatusMessages.set(dedupKey, Date.now());

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
    if (to.length === 10 && to.startsWith('0')) to = '27' + to.slice(1); // ZA local 10-digit only; E.164 numbers (>= 11 digits) left untouched

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

    // Push notification to linked customer app
    const pushTitles = {
      'in_progress': 'Job In Progress', 'progress': 'Job In Progress',
      'completed': 'Job Completed', 'closed': 'Job Closed',
      'cancelled': 'Booking Cancelled', 'payment_received': 'Payment Received',
    };
    await notifyLinkedCustomer(firestore, {
      phone: customerPhone,
      title: pushTitles[status] || 'Booking Update',
      body: msg.replace(/[*_~`]/g, '').substring(0, 200),
      data: { type: 'booking_status_update', booking_id: mainBookingId, status },
    });

    res.json({ success: true, to, status });
  } catch (err) {
    console.error('[api/booking-status-update] error:', err.message);
    try {
      const bid = (req.body && req.body.bookingId) || '';
      const st = (req.body && req.body.status) || '';
      await logErrorToAdmin('webhook_booking_status_update_failed', `/api/booking-status-update threw on status=${st}: ${err.message}`, 'whatsapp_bot./api/booking-status-update', err.message, bid, 'high');
    } catch (_) {}
    res.status(500).json({ error: err.message });
  }
});

// ─── App → WhatsApp: Update session state after payment (NO message — booking-status-update handles that) ───
app.post('/api/payment-confirmed', requireInternalSecret, async (req, res) => {
  try {
    const { bookingId, paymentStatus } = req.body || {};
    if (!bookingId) return res.status(400).json({ error: 'bookingId required' });

    const mainBookingId = bookingId.includes('_') ? bookingId.split('_')[0] : bookingId;

    // Update any active WA session that references this booking
    for (const [sid, session] of sessions) {
      if (session.lastBookingId === mainBookingId) {
        session.paymentStatus = paymentStatus || 'paid';
        console.log(`[api/payment-confirmed] Updated session ${sid} paymentStatus=${session.paymentStatus}`);
      }
    }

    console.log(`[api/payment-confirmed] Session state updated for ${mainBookingId} (no WA message sent — handled by booking-status-update)`);
    res.json({ success: true, bookingId: mainBookingId });
  } catch (err) {
    console.error('[api/payment-confirmed] error:', err.message);
    res.status(500).json({ error: err.message });
  }
});

// ─── Admin → WhatsApp: Send RFQ response back to client ───
app.post('/api/send-rfq-response', requireInternalSecret, async (req, res) => {
  try {
    const { phone, rfqNo, message } = req.body || {};
    if (!phone || !message) {
      return res.status(400).json({ error: 'phone and message are required' });
    }
    // Normalise to international format (27…)
    let to = phone.replace(/[^0-9]/g, '');
    if (to.length === 10 && to.startsWith('0')) to = '27' + to.slice(1); // ZA local 10-digit only; E.164 numbers (>= 11 digits) left untouched
    if (to.length < 10 || to.length > 15) {
      return res.status(400).json({ error: 'Invalid phone number length' });
    }
    await sendWhatsAppMessage(to, message);
    res.json({ success: true, to, rfqNo });
  } catch (err) {
    console.error('[send-rfq-response] error:', err.message);
    res.status(500).json({ error: err.message });
  }
});

// ─── App → WhatsApp: Notify client of artisan job lifecycle events ───
app.post('/api/job-status-update', requireInternalSecret, async (req, res) => {
  try {
    const { bookingId, status, artisanName, imageUrl, force } = req.body || {};
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
    if (to.length === 10 && to.startsWith('0')) to = '27' + to.slice(1); // ZA local 10-digit only; E.164 numbers (>= 11 digits) left untouched

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
      'balance_collected': `✅ *Balance payment received!*\n\nYour artisan has confirmed receipt of the balance payment for booking #${ref}.\n\nThank you for your payment! Your booking is now fully paid. 🙏`,
    };

    const msg = statusMessages[status] || `📋 Your booking #${ref} status has been updated to: *${status}*`;

    // Idempotency: skip duplicates if the corresponding listener has already sent the message.
    // This prevents the same notification from being delivered twice when both the HTTP push
    // (from the artisan app) and the Firestore listener fire for the same event.
    // CHECK BOTH tasksManagement AND futureBookings — the listener writes the flag on
    // futureBookings while this endpoint historically wrote on tasksManagement, which
    // caused job-complete duplicates in production.
    try {
      const tmCur = await firestore.collection('tasksManagement').doc(mainBookingId).get();
      const fbCur = await firestore.collection('futureBookings').doc(mainBookingId).get();
      const tmData = tmCur.exists ? (tmCur.data() || {}) : {};
      const fbData = fbCur.exists ? (fbCur.data() || {}) : {};
      // Also look up the LINKED doc via cross-id references. tasksManagement
      // and futureBookings often have different ids (e.g. TM=auto-uuid,
      // FB=RFQ-XXXX). Without this cross-lookup, the HTTP endpoint won't see
      // a flag the listener wrote on the linked doc, and vice versa, which
      // caused 4x "Job completed!" sends in production.
      let linkedTmData = {};
      let linkedFbData = {};
      try {
        const linkedFbId = String(tmData.future_booking_id || fbData.future_booking_id || '').trim();
        if (linkedFbId && linkedFbId !== mainBookingId) {
          const linkedFb = await firestore.collection('futureBookings').doc(linkedFbId).get();
          if (linkedFb.exists) linkedFbData = linkedFb.data() || {};
        }
        const linkedTmId = String(fbData.task_management_id || fbData.tm_id || '').trim();
        if (linkedTmId && linkedTmId !== mainBookingId) {
          const linkedTm = await firestore.collection('tasksManagement').doc(linkedTmId).get();
          if (linkedTm.exists) linkedTmData = linkedTm.data() || {};
        }
        // Reverse: TM may not store future_booking_id but FB might be queryable
        // by task_management_id. As a last resort, query futureBookings where
        // task_management_id == mainBookingId.
        if (!linkedFbData || !Object.keys(linkedFbData).length) {
          const q = await firestore.collection('futureBookings').where('task_management_id', '==', mainBookingId).limit(1).get();
          if (!q.empty) linkedFbData = q.docs[0].data() || {};
        }
      } catch (_) {}
      const flagFor = (s) => s === 'before_photo' ? 'wa_artisan_images_1_sent_at'
        : s === 'after_photo' ? 'wa_artisan_images_2_sent_at'
        : s === 'buying_material' ? 'wa_buying_material_sent_at'
        : s === 'progress' ? 'wa_lifecycle_progress_sent_at'
        : s === 'completed' ? 'wa_lifecycle_completed_sent_at'
        : '';
      const httpFlagKey = flagFor(status);
      const alreadySent = httpFlagKey && !force && (
        tmData[httpFlagKey] || fbData[httpFlagKey] ||
        linkedTmData[httpFlagKey] || linkedFbData[httpFlagKey]
      );
      if (alreadySent) {
        console.log(`[api/job-status-update] Skipping duplicate "${status}" send for ${mainBookingId} (flag ${httpFlagKey} already set on linked doc)`);
        return res.json({ success: true, to, status, skipped: 'already_sent' });
      }
    } catch (e) {
      console.warn('[api/job-status-update] idempotency check failed:', e.message);
    }

    const sendResult = await sendWhatsAppMessage(to, msg);
    if (sendResult && sendResult.ok === false) {
      console.error('[api/job-status-update] WA send failed:', sendResult.error);
    }

    // ── Safety: when the artisan is on the way, send their profile photo so
    //    the customer knows who is arriving (parity with the in-app feature). ──
    if (status === 'progress') {
      try {
        // Resolve artisan id from whichever doc we already loaded.
        let spId = '';
        try {
          const tmSnap = await firestore.collection('tasksManagement').doc(mainBookingId).get();
          if (tmSnap.exists) spId = String((tmSnap.data() || {}).service_provider_id || '').trim();
        } catch (_) {}
        if (!spId) {
          try {
            const fbSnap2 = await firestore.collection('futureBookings').doc(mainBookingId).get();
            if (fbSnap2.exists) spId = String((fbSnap2.data() || {}).service_provider_id || '').trim();
          } catch (_) {}
        }
        if (spId) {
          const prof = await getArtisanProfile(firestore, spId);
          if (prof.imageUrl) {
            const who = prof.name || name;
            await sendWhatsAppImage(to, prof.imageUrl, `👷 ${who} is on the way to booking #${ref}. For your safety, please confirm this is the person who arrives at your door.`);
          }
        }
      } catch (e) { console.warn('[job-status-update] artisan photo send failed:', e.message); }
    }

    // Set the flag IMMEDIATELY after sending so any concurrent listener pass skips.
    // Mirror to BOTH tasksManagement and futureBookings — the futureBookings listener
    // only checks its own doc, so without this mirror it would re-fire and duplicate.
    try {
      const flagPatch = {};
      if (status === 'before_photo') flagPatch.wa_artisan_images_1_sent_at = new Date().toISOString();
      else if (status === 'after_photo') flagPatch.wa_artisan_images_2_sent_at = new Date().toISOString();
      else if (status === 'buying_material') flagPatch.wa_buying_material_sent_at = new Date().toISOString();
      else if (status === 'progress') flagPatch.wa_lifecycle_progress_sent_at = new Date().toISOString();
      else if (status === 'completed') flagPatch.wa_lifecycle_completed_sent_at = new Date().toISOString();
      if (Object.keys(flagPatch).length) {
        const writes = [
          firestore.collection('tasksManagement').doc(mainBookingId).set(flagPatch, { merge: true }).catch(() => {}),
          firestore.collection('futureBookings').doc(mainBookingId).set(flagPatch, { merge: true }).catch(() => {}),
        ];
        // Mirror to linked docs (different ids — TM auto-uuid vs FB RFQ-XXXX)
        // so concurrent listeners on either collection see the same flag and
        // skip. Without this, 4× "Job completed!" sends were observed.
        try {
          const tmCur2 = await firestore.collection('tasksManagement').doc(mainBookingId).get();
          const fbCur2 = await firestore.collection('futureBookings').doc(mainBookingId).get();
          const linkedFbId = String(
            (tmCur2.exists && tmCur2.data().future_booking_id) ||
            (fbCur2.exists && fbCur2.data().future_booking_id) || ''
          ).trim();
          if (linkedFbId && linkedFbId !== mainBookingId) {
            writes.push(firestore.collection('futureBookings').doc(linkedFbId).set(flagPatch, { merge: true }).catch(() => {}));
          }
          const linkedTmId = String((fbCur2.exists && (fbCur2.data().task_management_id || fbCur2.data().tm_id)) || '').trim();
          if (linkedTmId && linkedTmId !== mainBookingId) {
            writes.push(firestore.collection('tasksManagement').doc(linkedTmId).set(flagPatch, { merge: true }).catch(() => {}));
          }
          // Reverse: find FB by task_management_id == mainBookingId
          const q2 = await firestore.collection('futureBookings').where('task_management_id', '==', mainBookingId).limit(1).get();
          if (!q2.empty && q2.docs[0].id !== mainBookingId) {
            writes.push(q2.docs[0].ref.set(flagPatch, { merge: true }).catch(() => {}));
          }
        } catch (_) {}
        await Promise.all(writes);
      }
    } catch (_) {}

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
        // Merge data from both collections so deposit/balance fields are always available
        let bd = {};
        const tmDoc = await firestore.collection('tasksManagement').doc(mainBookingId).get();
        const fbDoc2 = await firestore.collection('futureBookings').doc(mainBookingId).get();
        if (fbDoc2.exists) Object.assign(bd, fbDoc2.data());
        if (tmDoc.exists) Object.assign(bd, tmDoc.data());  // tasksManagement wins on conflicts
        if (tmDoc.exists || fbDoc2.exists) {
          const isDepositPaid = bd.payment_status === 'deposit_paid';
          const balanceDone = bd.balance_paid === true;
          const totalCost = parseFloat(bd.cost || bd.total_cost || '0');
          const depositAmt = parseFloat(bd.deposit_amount || '0') || Math.round(totalCost * 0.35 * 100) / 100;
          const balanceAmt = parseFloat(bd.balance_remaining || bd.balance_amount || '0') || Math.round((totalCost - depositAmt) * 100) / 100;

          if (isDepositPaid && !balanceDone && balanceAmt > 0 && status === 'completed') {
            // Auto-generate balance payment link
            let balancePaymentUrl = '';
            try {
              const backendUrl = process.env.LIVEKIT_BACKEND_URL || 'https://square15-livekit-backend.onrender.com';
              const resp = await fetch(`${backendUrl}/api/payment/whatsapp-initiate`, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json', 'x-internal-secret': process.env.INTERNAL_API_SECRET || '' },
                body: JSON.stringify({
                  amount: balanceAmt.toFixed(2),
                  booking_id: mainBookingId,
                  customer_name: bd.customerName || bd.name || '',
                  customer_phone: to,
                  description: `Balance payment for ${bd.description || bd.subcategory || bd.category_name || 'booking'} #${ref}`,
                }),
                signal: AbortSignal.timeout(15000),
              });
              const result = await resp.json();
              if (result.ok && result.payment_url) balancePaymentUrl = result.payment_url;
            } catch (e) { console.warn('[job-status-update] balance payment link generation failed:', e.message); }

            let balanceMsg = `💰 *Balance payment due: R${balanceAmt.toFixed(2)}*\n\nYour artisan has completed the work for booking #${ref}. You still owe a balance of R${balanceAmt.toFixed(2)} (total R${totalCost.toFixed(2)} minus deposit of R${depositAmt.toFixed(2)}).`;
            if (balancePaymentUrl) {
              balanceMsg += `\n\n💳 *Pay now:* ${balancePaymentUrl}\n\nClick the link above to pay your remaining balance securely.`;
            } else {
              balanceMsg += `\n\nWould you like to pay the balance now? Reply "pay balance" to get a payment link.`;
            }
            await sendWhatsAppMessage(to, balanceMsg);
            // FINANCIAL-SAFETY: pin session to the balance-due booking so
            // a follow-up "send me a new link" doesn't resolve to a stale
            // fully-paid booking.
            try {
              // Prefer the FB id (RFQ-XXXX) over TM uuid for session continuity.
              let bidForSession = mainBookingId;
              try {
                const tmS = await firestore.collection('tasksManagement').doc(mainBookingId).get();
                if (tmS.exists) {
                  const linkedFb = String((tmS.data() || {}).future_booking_id || '').trim();
                  if (linkedFb) bidForSession = linkedFb;
                }
              } catch (_) {}
              const liveSess = sessions.get(to);
              if (liveSess) {
                liveSess.lastBookingId = bidForSession;
                liveSess.paymentStatus = 'balance_due';
              }
              await firestore.collection('wa_sessions').doc(to).set({
                phone: to,
                lastBookingId: bidForSession,
                lastBookingAt: Date.now(),
                lastActivity: admin.firestore.FieldValue.serverTimestamp(),
              }, { merge: true });
            } catch (e) { console.warn('[job-status-update] session pin failed:', e && e.message); }
          }
        }
      } catch (e) { console.warn('[job-status-update] balance check failed:', e.message); }
    }

    console.log(`[api/job-status-update] Status "${status}" sent to ${to} for ${mainBookingId}${imageUrl ? ' (with image)' : ''}`);

    // Push notification to linked customer app
    const jobPushTitles = {
      'progress': 'Artisan On The Way', 'buying_material': 'Buying Materials',
      'before_photo': 'Artisan Has Arrived', 'after_photo': 'Work Completed',
      'completed': 'Job Completed', 'balance_due': 'Balance Payment Due',
      'additional_work': 'Additional Work Found', 'balance_collected': 'Balance Received',
    };
    await notifyLinkedCustomer(firestore, {
      phone: customerPhone,
      title: jobPushTitles[status] || 'Job Update',
      body: msg.replace(/[*_~`]/g, '').substring(0, 200),
      data: { type: 'job_status_update', booking_id: mainBookingId, status },
    });

    res.json({ success: true, to, status, sendResult: sendResult || null });
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

// ─── Global error capture: process-level + express middleware ───
// Dedups identical error messages within a 60s window and caps at 200 reports per hour
// so a crash-loop cannot flood Firestore / admin popups.
const _errorDedup = new Map(); // key -> { firstSeen, lastSeen, count }
let _errorsThisHour = 0;
let _errorsHourStartedAt = Date.now();

// Auto-heal: classify transient errors so they get logged as auto_resolved instead
// of cluttering the admin Live Issues screen.
function _tryAutoHeal(kind, err) {
  const s = String((err && (err.message || err)) || '').toLowerCase();
  if (kind === 'unhandled_rejection' || kind === 'express_error') {
    if (s.includes('econnrefused') || s.includes('enotfound') ||
        s.includes('etimedout') || s.includes('socket hang up') ||
        s.includes('network') || s.includes('timeout') ||
        s.includes('503') || s.includes('504') || s.includes('502')) {
      return { healed: true, action: 'transient_network_auto_recovered' };
    }
  }
  return { healed: false, action: '' };
}

// Background sweeper: auto-resolve open error_logs older than 60 min (every 5 min).
function _startAutoResolveSweeper() {
  const INTERVAL_MS = 5 * 60 * 1000;
  const STALE_AFTER_MS = 60 * 60 * 1000;
  setInterval(async () => {
    try {
      const firestore = db();
      if (!firestore) return;
      const cutoff = admin.firestore.Timestamp.fromMillis(Date.now() - STALE_AFTER_MS);
      const snap = await firestore.collection('error_logs')
        .where('status', '==', 'open')
        .where('created_at', '<', cutoff)
        .limit(50)
        .get();
      if (snap.empty) return;
      const batch = firestore.batch();
      snap.docs.forEach((d) => {
        batch.update(d.ref, {
          status: 'auto_resolved',
          resolved_by: 'auto_heal_sweeper',
          auto_resolved_at: admin.firestore.FieldValue.serverTimestamp(),
        });
      });
      await batch.commit();
      console.log(`[auto-heal] Sweeper auto-resolved ${snap.size} stale open errors.`);
    } catch (e) {
      console.warn('[auto-heal] sweeper error:', e && e.message);
    }
  }, INTERVAL_MS).unref?.();
}

function _plainEnglishFromError(err) {
  const m = (err && (err.message || err.toString())) || '';
  const s = m.toLowerCase();
  if (s.includes('econnrefused') || s.includes('enotfound') || s.includes('etimedout') || s.includes('socket hang up')) {
    return 'The bot could not reach an external service (network/API unreachable). It will keep running and retry.';
  }
  if (s.includes('permission-denied') || s.includes('permission denied')) {
    return 'Firestore rejected a write. A security rule or missing admin claim is blocking the bot.';
  }
  if (s.includes('quota') || s.includes('resource-exhausted')) {
    return 'Firebase/Firestore quota hit. Requests will be throttled until quota resets.';
  }
  if (s.includes('invalid-argument') || s.includes('invalid argument')) {
    return 'Bad data was sent to Firestore (invalid field or type). See stack trace for exact field.';
  }
  if (s.includes('whatsapp') || s.includes('graph.facebook')) {
    return 'WhatsApp Graph API call failed. Check WHATSAPP_TOKEN / phone-number-id.';
  }
  if (s.includes('openai') || s.includes('gpt') || s.includes('401') && s.includes('api')) {
    return 'OpenAI/Whisper call failed (auth or rate limit). Check OPENAI_API_KEY.';
  }
  if (s.includes('payfast') || s.includes('ozow')) {
    return 'Payment gateway call failed. Customer may need to retry payment.';
  }
  if (s.includes('timeout')) {
    return 'An operation timed out. Bot kept running and will retry on next message.';
  }
  return 'Unexpected error in WhatsApp bot. Auto-recovered — bot still running. See stack for details.';
}

async function _captureProcessError(kind, err) {
  try {
    // rate-limit
    const now = Date.now();
    if (now - _errorsHourStartedAt > 60 * 60 * 1000) {
      _errorsHourStartedAt = now;
      _errorsThisHour = 0;
    }
    if (_errorsThisHour >= 200) return;

    const msg = (err && (err.stack || err.message || String(err))) || 'unknown error';
    const key = `${kind}::${(err && err.message) || String(err)}`.slice(0, 256);
    const dedup = _errorDedup.get(key);
    if (dedup && now - dedup.lastSeen < 60 * 1000) {
      dedup.lastSeen = now;
      dedup.count += 1;
      return; // skip duplicate within 60s window
    }
    _errorDedup.set(key, { firstSeen: now, lastSeen: now, count: 1 });
    // prune old entries
    if (_errorDedup.size > 500) {
      for (const [k, v] of _errorDedup.entries()) {
        if (now - v.lastSeen > 10 * 60 * 1000) _errorDedup.delete(k);
      }
    }
    _errorsThisHour += 1;

    const severity = kind === 'uncaught_exception' ? 'critical' : 'high';
    const heal = _tryAutoHeal(kind, err);
    const logId = await logErrorToAdmin(
      kind,
      heal.healed ? `[auto-healed] ${_plainEnglishFromError(err)}` : _plainEnglishFromError(err),
      'whatsapp_bot',
      String(msg).slice(0, 4000),
      '',
      heal.healed ? 'low' : severity
    );
    if (heal.healed && logId) {
      try {
        const firestore = db();
        if (firestore) {
          await firestore.collection('error_logs').doc(logId).update({
            status: 'auto_resolved',
            resolved_by: 'auto_heal',
            auto_fix_applied: heal.action,
          });
        }
      } catch (_) {}
    }
  } catch (reportErr) {
    console.error('[errorReport] capture failed:', reportErr && reportErr.message);
  }
}

process.on('unhandledRejection', (reason) => {
  console.error('[process] unhandledRejection:', reason && (reason.stack || reason.message || reason));
  const err = reason instanceof Error ? reason : new Error(String(reason));
  _captureProcessError('unhandled_rejection', err);
  // DO NOT exit — let bot keep serving other webhooks
});

process.on('uncaughtException', (err) => {
  console.error('[process] uncaughtException:', err && (err.stack || err.message));
  _captureProcessError('uncaught_exception', err);
  // DO NOT exit for non-fatal errors. Render will restart us if truly broken.
});

// Express error middleware — catches sync/async errors inside request handlers
app.use((err, req, res, next) => {
  console.error('[express] handler error on', req.method, req.originalUrl, ':', err && (err.stack || err.message));
  _captureProcessError('express_error', err);
  if (res.headersSent) return next(err);
  try {
    res.status(500).json({ ok: false, error: 'internal_error' });
  } catch (_) {}
});

// ─── Quote Relay Listener (v27) ───
// When admin sends a curated quote (status=rfq_sent and admin_quote.items
// populated with image_urls from the Builders WebView picker), the bot
// forwards each item as a separate WhatsApp image + caption to the client,
// followed by a totals summary. Idempotent — a `whatsapp_quote_relayed=true`
// flag prevents double-relay if the listener fires multiple times.
let _quoteRelayUnsubscribe = null;
const _quoteRelayInFlight = new Set();
const _adminAssignRelayInFlight = new Set();
const _balancePromptInFlight = new Set();
const _lifecycleInFlight = new Set();

// ── Cross-path artisan-acceptance dedup (May 14 2026) ──
// Implementation lives in ./acceptance-dedup.js (kept separate so it can be
// unit-tested without booting the full server). It uses a Firestore
// transaction (atomic check-and-set of wa_artisan_acceptance_sent_at) plus
// a shared in-memory Set, so only one of {HTTP webhook /api/artisan-accepted,
// snapshot listener startArtisanAcceptanceListener} can win the right to
// send the customer-facing "Great news!" + artisan photo.
const { claimArtisanAcceptanceSend, releaseArtisanAcceptanceClaim } = require('./acceptance-dedup');

// Look up artisan profile photo URL + display name from serviceProvider/{id}.
// Used by the 'on the way' (progress) WA so the customer can see who is
// arriving — a safety feature already present in-app, now mirrored to WhatsApp.
async function getArtisanProfile(firestore, artisanId) {
  const out = { imageUrl: '', name: '', rating: 0 };
  const id = String(artisanId || '').trim();
  if (!firestore || !id || id === 'admin') return out;
  try {
    const snap = await firestore.collection('serviceProvider').doc(id).get();
    if (!snap.exists) return out;
    const d = snap.data() || {};
    const candidates = [d.imageUrl, d.image, d.profile_image, d.profileImage, d.photo_url, d.photoURL, d.profile_picture, d.profilePicture];
    for (const c of candidates) {
      const u = String(c || '').trim();
      if (u && /^https?:\/\//i.test(u) && !u.includes('maintenance-app-d320b.appspot.com')) {
        out.imageUrl = u;
        break;
      }
    }
    out.name = String(d.name || d.fullName || d.full_name || '').trim();
    const r = Number(d.rating || d.avgRating || d.average_rating || d.averageRating || 0);
    out.rating = Number.isFinite(r) && r > 0 ? r : 0;
  } catch (e) {
    console.warn('[getArtisanProfile] failed for', id, ':', e.message);
  }
  return out;
}
function startQuoteRelayListener() {
  try {
    const firestore = db();
    if (!firestore) {
      console.warn('[quote-relay] firestore not ready, skipping listener init');
      return;
    }
    if (_quoteRelayUnsubscribe) {
      try { _quoteRelayUnsubscribe(); } catch (_) {}
      _quoteRelayUnsubscribe = null;
    }
    // Listen for WhatsApp-source RFQs that have just transitioned to rfq_sent.
    // We filter on source=='whatsapp' to avoid relaying client-app RFQs.
    _quoteRelayUnsubscribe = firestore
      .collection('futureBookings')
      .where('source', '==', 'whatsapp')
      .where('status', '==', 'rfq_sent')
      .onSnapshot(async (snap) => {
        for (const change of snap.docChanges()) {
          if (change.type !== 'added' && change.type !== 'modified') continue;
          const doc = change.doc;
          const data = doc.data() || {};
          if (data.whatsapp_quote_relayed === true) continue;
          // Only relay once admin_quote.items has been written by the admin app.
          const aq = data.admin_quote || {};
          const itemsRaw = Array.isArray(aq.items) ? aq.items : [];
          // Filter out empty / malformed items so we don't send junk "Item 1 — R0" captions.
          const items = itemsRaw.filter(it => it && typeof it === 'object' && (it.description || it.name));
          if (!items.length) continue;

          const phone = String(data.user_phone || '').replace(/\D/g, '');
          if (!phone) {
            console.warn('[quote-relay] RFQ', doc.id, 'has no user_phone — skipping');
            continue;
          }
          const rfqNo = data.rfq_no || data.order_no || doc.id;

          // ── MARK-BEFORE-SEND with rollback (2026-05-07) ──
          // Race / crash safety: stamp `whatsapp_quote_relayed=true` BEFORE
          // sending so a process crash between send-success and flag-write
          // can't cause duplicate delivery on restart. If the WA API send
          // fails, we roll back the flag in `catch` so the next snapshot
          // tick retries cleanly. Combined with the in-memory in-flight
          // lock to suppress simultaneous onSnapshot deliveries.
          if (_quoteRelayInFlight.has(doc.id)) continue;
          _quoteRelayInFlight.add(doc.id);

          let relaySucceeded = false;
          let flagStamped = false;
          try {
            // Re-read to catch a racing process that beat us to it.
            try {
              const fresh = await firestore.collection('futureBookings').doc(doc.id).get();
              if (fresh.exists && fresh.data().whatsapp_quote_relayed === true) {
                _quoteRelayInFlight.delete(doc.id);
                continue;
              }
              await firestore.collection('futureBookings').doc(doc.id).update({
                whatsapp_quote_relayed: true,
                whatsapp_quote_relayed_at: admin.firestore.FieldValue.serverTimestamp(),
              });
              flagStamped = true;
            } catch (e) {
              console.warn('[quote-relay] pre-send flag stamp failed for', doc.id, '-', e.message);
              _quoteRelayInFlight.delete(doc.id);
              continue;
            }
            try {
              await sendWhatsAppMessage(phone, `Hi${data.user_name ? ' ' + String(data.user_name).split(' ')[0] : ''}! Your quote for ${rfqNo} is ready. Here are the items our admin has selected:`);
            } catch (_) {}

          // Send each item as a separate WhatsApp image + caption.
          for (let i = 0; i < items.length; i++) {
            const it = items[i] || {};
            const desc = String(it.description || it.name || `Item ${i + 1}`);
            const qty = Number(it.qty || 1);
            const unit = String(it.uom || it.unit || 'ea');
            const unitPrice = Number(it.unit_price || 0);
            const lineTotal = Number(it.line_total || (qty * unitPrice));
            const imageUrl = String(it.image_url || '').trim();
            const productUrl = String(it.product_url || it.sourceKey || '').trim();
            // Note: we intentionally do NOT include the product URL in the
            // caption — the client doesn't need to know the supplier.
            const caption = `*${i + 1}. ${desc}*\n${qty} ${unit} × R${unitPrice.toFixed(2)} = R${lineTotal.toFixed(2)}`;

            let delivered = false;
            if (imageUrl && /^https?:\/\//i.test(imageUrl)) {
              const r = await sendWhatsAppImage(phone, imageUrl, caption).catch(e => ({ ok: false, error: e.message }));
              if (r && r.ok) delivered = true;
              else console.warn('[quote-relay] image send failed for', doc.id, 'item', i, '-', r && r.error);
            }
            if (!delivered) {
              try { await sendWhatsAppMessage(phone, caption); } catch (_) {}
            }
            // Small delay so WhatsApp doesn't throttle / re-order the messages.
            await new Promise(r => setTimeout(r, 600));
          }

          // Totals summary — sent ONLY after every item image has been
          // delivered, so the client sees the full materials list before
          // being asked to confirm. Wording matches what the bot's LLM is
          // trained to recognise ("has been reviewed" → YES = accept_rfq_quote).
          try {
            const subtotal = Number(aq.subtotal || 0);
            const vatAmount = Number(aq.vat_amount || 0);
            const total = Number(aq.total || data.admin_quote_total || data.cost || 0);
            const notes = String(aq.notes || '').trim();
            const lines = [];
            lines.push(`Hi! Your quote request (${rfqNo}) has been reviewed.`);
            lines.push('');
            lines.push(`📋 *Quote Total (Including Labour)*`);
            if (subtotal > 0)  lines.push(`Subtotal: R${subtotal.toFixed(2)}`);
            if (vatAmount > 0) lines.push(`VAT: R${vatAmount.toFixed(2)}`);
            lines.push(`*Total (incl. labour): R${total.toFixed(2)}*`);
            if (notes) {
              lines.push('');
              lines.push(`Note from admin: _${notes}_`);
            }
            lines.push('');
            lines.push('Please reply *YES* to accept or *NO* to reject. If accepted, we will ask when you would like the work scheduled. You can also open the Square 15 app to review. If you would like to change something (e.g. swap an item or different brand), just tell me what to adjust.');
            const totalsMsg = lines.join('\n');
            await sendWhatsAppMessage(phone, totalsMsg);

            // ── Bridge admin-amended quote into the bot's session so the LLM
            // recognises the next "yes" / "no" reply. Without this, the
            // outgoing relay messages are invisible to GPT and the client's
            // "yes" lands with no context, dead-ending the flow.
            try {
              const sessRef = firestore.collection('wa_sessions').doc(phone);
              const sessSnap = await sessRef.get();
              const sessData = sessSnap.exists ? (sessSnap.data() || {}) : {};
              const prevMsgs = Array.isArray(sessData.messages) ? sessData.messages : [];
              const stitched = prevMsgs.concat([
                { role: 'assistant', content: totalsMsg },
              ]).slice(-20); // keep recent window only
              await sessRef.set({
                phone,
                messages: stitched,
                lastRfqId: doc.id,
                lastRfqNo: rfqNo,
                lastRfqAt: Date.now(),
                lastActivity: admin.firestore.FieldValue.serverTimestamp(),
              }, { merge: true });
              console.log(`[quote-relay] session bridged for ${phone} → lastRfqId=${doc.id}`);
              // Also update in-memory session if one already exists, so the
              // next inbound message sees lastRfqId without needing a Firestore round-trip.
              try {
                const liveSess = sessions.get(phone);
                if (liveSess) {
                  liveSess.lastRfqId = doc.id;
                  liveSess.lastBookingId = doc.id;
                  liveSess.messages = stitched;
                  console.log(`[quote-relay] in-memory session also updated for ${phone}`);
                }
              } catch (_) {}
            } catch (e) {
              console.warn('[quote-relay] session bridge failed for', doc.id, '-', e.message);
            }
            relaySucceeded = true;
          } catch (e) {
            console.warn('[quote-relay] totals send failed for', doc.id, '-', e.message);
          }

          // If we stamped the flag pre-send but the send failed, ROLL BACK
          // so the next snapshot tick retries. If the send succeeded the
          // flag is already correctly set.
          if (flagStamped && !relaySucceeded) {
            try {
              await firestore.collection('futureBookings').doc(doc.id).update({
                whatsapp_quote_relayed: false,
                whatsapp_quote_relayed_at: admin.firestore.FieldValue.delete(),
              });
              console.warn(`[quote-relay] RFQ ${rfqNo} → ${phone}: send FAILED, flag rolled back for retry.`);
            } catch (e) {
              console.warn('[quote-relay] flag rollback failed for', doc.id, '—', e.message);
            }
          } else if (relaySucceeded) {
            console.log(`[quote-relay] RFQ ${rfqNo} → ${phone}: ${items.length} item(s) delivered.`);
          }
          } finally {
            _quoteRelayInFlight.delete(doc.id);
          }
        }
      }, (err) => {
        console.error('[quote-relay] listener error:', err && err.message);
      });

    console.log('[quote-relay] listener started (futureBookings where source=whatsapp & status=rfq_sent).');
  } catch (e) {
    console.error('[quote-relay] init failed:', e && e.message);
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Admin-assignment → WhatsApp relay
// Fires when admin (a) broadcasts the RFQ to all artisans, (b) assigns it
// to a specific artisan, or (c) accepts internally. The customer must be told
// over WhatsApp that admin has acted; previously they were left in silence.
// Idempotent via `whatsapp_admin_assigned_relayed` flag.
// ─────────────────────────────────────────────────────────────────────────────
let _adminAssignmentRelayUnsubscribe = null;
function startAdminAssignmentRelayListener() {
  try {
    const firestore = db();
    if (!firestore) {
      console.warn('[admin-assign-relay] firestore not ready, skipping listener init');
      return;
    }
    if (_adminAssignmentRelayUnsubscribe) {
      try { _adminAssignmentRelayUnsubscribe(); } catch (_) {}
      _adminAssignmentRelayUnsubscribe = null;
    }
    // Watch RFQs whose admin-review timestamp has been set. Filtering on
    // rfq_status would miss the internal-acceptance path which sets it to
    // 'accepted_converted'. Instead we rely on rfq_admin_reviewed_at being
    // a non-empty marker that admin has performed an assignment action.
    _adminAssignmentRelayUnsubscribe = firestore
      .collection('futureBookings')
      .where('rfq_status', 'in', [
        'pending_artisan_acceptance',
        'accepted_converted',
      ])
      .onSnapshot(async (snap) => {
        for (const change of snap.docChanges()) {
          if (change.type !== 'added' && change.type !== 'modified') continue;
          const doc = change.doc;
          const data = doc.data() || {};
          if (data.whatsapp_admin_assigned_relayed === true) continue;
          // Must be an RFQ (otherwise we're triggering on unrelated bookings)
          const isRfq = (data.is_rfq === 'yes') || (data.order_type === 'rfq')
            || !!data.rfq_no || !!data.admin_quote;
          if (!isRfq) continue;

          const phoneRaw = String(data.user_phone || data.phone || '').replace(/\D/g, '');
          if (!phoneRaw) {
            console.warn('[admin-assign-relay] no phone for', doc.id, '- skipping');
            continue;
          }
          let phone = phoneRaw;
          if (phone.startsWith('0')) phone = '27' + phone.slice(1);

          const rfqNo = data.rfq_no || data.order_no || doc.id;
          const rfqStatus = String(data.rfq_status || '').toLowerCase();
          const assignType = String(data.rfq_assigned_type || '').toLowerCase();
          const artisanName = String(data.rfq_assigned_artisan_name || '').trim();
          const broadcast = data.rfq_broadcast === true;
          const costNum = parseFloat(String(data.cost || '0').replace(/[^0-9.]/g, '')) || 0;
          const costStr = costNum > 0 ? `R${costNum.toFixed(2)}` : '';
          const schedDate = String(data.scheduled_date || data.date || '').trim();
          const schedTime = String(data.scheduled_time || '').trim();
          const firstName = String(data.user_name || '').split(' ')[0];
          const greet = firstName ? `Hi ${firstName}!` : 'Hi!';

          // Build the message based on which assignment path admin took.
          let msg = '';
          let kind = '';
          if (rfqStatus === 'pending_artisan_acceptance' && artisanName) {
            kind = 'specific';
            msg = `${greet} ✅ Good news — your quote (${rfqNo}) has been assigned to *${artisanName}*.\n\n`;
            msg += `📋 *Job:* ${data.category_name || data.description || 'your maintenance request'}\n`;
            if (costStr) msg += `💰 *Cost:* ${costStr}\n`;
            if (schedDate) msg += `📅 *Scheduled:* ${schedDate}${schedTime ? ' at ' + schedTime : ''}\n`;
            msg += `\nWe'll notify you the moment ${artisanName} accepts. 🛠️`;
          } else if (rfqStatus === 'pending_artisan_acceptance' && broadcast) {
            kind = 'broadcast';
            msg = `${greet} ✅ Your quote (${rfqNo}) has been broadcast to our network of available artisans.\n\n`;
            msg += `📋 *Job:* ${data.category_name || data.description || 'your maintenance request'}\n`;
            if (costStr) msg += `💰 *Cost:* ${costStr}\n`;
            if (schedDate) msg += `📅 *Scheduled:* ${schedDate}${schedTime ? ' at ' + schedTime : ''}\n`;
            msg += `\nWe'll notify you the moment an artisan accepts. 🛠️`;
          } else if (assignType === 'internal' || (rfqStatus === 'accepted_converted' && data.status === 'pending_payment')) {
            kind = 'internal';
            msg = `${greet} ✅ Your quote (${rfqNo}) has been accepted by our *Square 15 internal team*.\n\n`;
            msg += `📋 *Job:* ${data.category_name || data.description || 'your maintenance request'}\n`;
            if (costStr) msg += `💰 *Cost:* ${costStr}\n`;
            if (schedDate) msg += `📅 *Scheduled:* ${schedDate}${schedTime ? ' at ' + schedTime : ''}\n`;
            // Payment options (mirrors /api/artisan-accepted)
            if (costNum > 0) {
              const depositAmt = (Math.round(costNum * 0.35 * 100) / 100).toFixed(2);
              const balanceAmt = (costNum - parseFloat(depositAmt)).toFixed(2);
              msg += `\n💳 *Ready to pay? Choose an option:*\n`;
              msg += `1️⃣ *Full amount:* ${costStr}\n`;
              msg += `2️⃣ *Deposit (35%):* R${depositAmt} now (R${balanceAmt} due after job)\n`;
              msg += `\nReply *"pay full"* or *"pay deposit"* to get your secure payment link.\n`;
              msg += `\n🔒 Your payment is held in escrow until you confirm satisfaction.`;
            } else {
              msg += `\nOur team will be in touch shortly to confirm the next steps.`;
            }
          } else {
            // Unknown / not-yet-actionable state — skip without marking relayed.
            continue;
          }

          // Send-then-mark with in-flight lock to prevent duplicate sends
          // when onSnapshot fires twice for the same change.
          if (_adminAssignRelayInFlight.has(doc.id)) continue;
          _adminAssignRelayInFlight.add(doc.id);
          try {
            try {
              await sendWhatsAppMessage(phone, msg);
              console.log(`[admin-assign-relay] sent (${kind}) for ${rfqNo} → ${phone}`);
            } catch (e) {
              console.error('[admin-assign-relay] WA send failed for', doc.id, '-', e.message);
              continue;
            }
            try {
              await firestore.collection('futureBookings').doc(doc.id).update({
                whatsapp_admin_assigned_relayed: true,
                whatsapp_admin_assigned_relayed_at: admin.firestore.FieldValue.serverTimestamp(),
                whatsapp_admin_assigned_kind: kind,
              });
            } catch (e) {
              console.warn('[admin-assign-relay] flag update failed for', doc.id, '-', e.message);
            }
          } finally {
            _adminAssignRelayInFlight.delete(doc.id);
          }

          // Push to linked customer app as well.
          try {
            await notifyLinkedCustomer(firestore, {
              phone: phoneRaw,
              userId: data.user_id || data.userId || '',
              title: kind === 'internal' ? 'Quote Accepted — Choose Payment'
                : kind === 'specific' ? `Assigned to ${artisanName}`
                : 'Quote Sent to Artisans',
              body: kind === 'internal'
                ? `Your quote ${rfqNo} (${costStr}) was accepted by Square 15. Tap to choose payment.`
                : kind === 'specific'
                  ? `${artisanName} has been assigned your quote ${rfqNo}. Awaiting their acceptance.`
                  : `Your quote ${rfqNo} has been broadcast to artisans. We'll notify you on acceptance.`,
              data: { type: 'rfq_admin_assigned', booking_id: doc.id, kind },
            });
          } catch (_) {}
        }
      }, (err) => {
        console.error('[admin-assign-relay] listener error:', err && err.message);
      });

    console.log('[admin-assign-relay] listener started (futureBookings where rfq_admin_reviewed_at != "").');
  } catch (e) {
    console.error('[admin-assign-relay] init failed:', e && e.message);
  }
}

// ─── Listener: WhatsApp acceptance message when artisan accepts via app ───
// The artisan app writes `artisan_confirmed='yes'` + `status='pending_payment'`
// directly to Firestore (it doesn't POST to /api/artisan-accepted). Without
// this listener, WhatsApp clients are stuck on "I've notified the artisan".
function startArtisanAcceptanceListener() {
  try {
    const firestore = db();
    if (!firestore) return;
    // Atomic check-and-set via claimArtisanAcceptanceSend() now handles the
    // cross-path (listener vs /api/artisan-accepted) race. We no longer need
    // a local in-flight Set here.
    firestore.collection('futureBookings')
      .where('artisan_confirmed', '==', 'yes')
      .onSnapshot(async (snap) => {
        for (const change of snap.docChanges()) {
          if (change.type !== 'added' && change.type !== 'modified') continue;
          const doc = change.doc;
          const data = doc.data() || {};
          const src = (data.source || data.accepted_via || '').toString().toLowerCase();
          const isWa = src.includes('whatsapp') || String(doc.id).startsWith('RFQ-') || String(doc.id).startsWith('WA-');
          if (!isWa) continue;
          // Fast path: skip if flag already set (avoids tx round-trip).
          if (data.wa_artisan_acceptance_sent_at) continue;
          // Atomic claim — only the winner proceeds to send.
          const claim = await claimArtisanAcceptanceSend(firestore, doc.id);
          if (!claim.claimed) {
            // Either an in-flight peer, or another path already stamped the flag.
            continue;
          }
          const customerPhone = data.user_phone || data.customerPhone || data.contact || data.client_phone || data.phone || '';
          if (!customerPhone) {
            await releaseArtisanAcceptanceClaim(firestore, doc.id, { rollback: true });
            continue;
          }

          const rfqId = doc.id;
          const orderNo = data.order_no || data.rfq_no || rfqId;
          const artisanName = data.service_provider_name || data.artisan_name || data.artisanName || 'Your artisan';
          const cost = data.cost || data.total_price || data.quoted_price || data.admin_quote_total || data.rfq_total || '';
          const costNum = parseFloat(cost) || 0;
          const costStr = costNum > 0 ? `R${costNum.toFixed(2)}` : '';
          const descStr = data.description || data.problem_description || data.subcategory || data.category_name || 'your maintenance request';

          let to = customerPhone.replace(/[^0-9]/g, '');
          if (to.length === 10 && to.startsWith('0')) to = '27' + to.slice(1); // ZA local 10-digit only; E.164 numbers (>= 11 digits) left untouched

          let msg = `✅ *Great news!* ${artisanName} has accepted your booking (#${orderNo})!\n\n`;
          msg += `📋 *Job:* ${descStr}\n`;
          if (costStr) msg += `💰 *Cost:* ${costStr}\n`;
          msg += `\n${artisanName} will contact you to confirm the schedule and arrive at your location.\n`;
          if (costNum > 0) {
            const depositAmt = (Math.round(costNum * 0.35 * 100) / 100).toFixed(2);
            const balanceAmt = (costNum - parseFloat(depositAmt)).toFixed(2);
            msg += `\n💳 *Ready to pay? Choose an option:*\n`;
            msg += `1️⃣ *Full amount:* ${costStr}\n`;
            msg += `2️⃣ *Deposit (35%):* R${depositAmt} now (R${balanceAmt} due after job)\n`;
            msg += `\nReply *"pay full"* or *"pay deposit"* to get your secure payment link.\n`;
            msg += `\n🔒 *Your money is safe:* Payment is held in escrow — released ONLY after you confirm the work is done right.\n`;
            msg += `🛡️ *Your safety:* ${artisanName} is registered & ID-verified. We'll share their photo with you shortly.\n`;
            msg += `💸 *Not happy?* Reply *"refund"* or *"complaint"* — we'll investigate before any money is released.`;
          }

          try {
            await sendWhatsAppMessage(to, msg);
            // ── Send artisan profile photo for safety/recognition. ──
            try {
              const spId = String(data.service_provider_id || '').trim();
              if (spId) {
                const prof = await getArtisanProfile(firestore, spId);
                if (prof && prof.imageUrl) {
                  const who = prof.name || artisanName;
                  const ratingStr = (prof.rating && Number(prof.rating) > 0) ? ` ⭐ ${Number(prof.rating).toFixed(1)}` : '';
                  await sendWhatsAppImage(to, prof.imageUrl, `👷 Meet ${who}${ratingStr} — your assigned Square 15 artisan for booking #${orderNo}. For your safety, please confirm this is the person who arrives at your door before letting them in.`);
                  // ── Follow-up CTA so the client always knows the next step. ──
                  try {
                    const ctaLines = [
                      `✅ *What happens next:*`,
                      `1️⃣ ${who} will call you to confirm the visit time.`,
                      `2️⃣ When they arrive, check the photo above matches.`,
                      ``,
                      `💬 *Quick replies anytime:*`,
                      `• *"track"* — see when artisan is on the way`,
                      `• *"reschedule"* — change the appointment time`,
                      `• *"help"* — talk to Square 15 support`,
                      `• *"complaint"* — report an issue (funds stay in escrow)`,
                    ];
                    await sendWhatsAppMessage(to, ctaLines.join('\n'));
                  } catch (ctaErr) {
                    console.warn(`[artisan-accept-listener] CTA send failed for ${rfqId}:`, ctaErr.message);
                  }
                }
              }
            } catch (e) { console.warn(`[artisan-accept-listener] photo send failed for ${rfqId}:`, e.message); }
            // Flag was already stamped above before sending; don't re-write here.
            console.log(`[artisan-accept-listener] sent acceptance WA to ${to} for ${rfqId} (artisan=${artisanName})`);
            // CRITICAL-2 fix (audit 2026-05-15): previously silent catch
            // left tasksManagement stale (showing pending_artisan_acceptance)
            // while futureBookings showed pending_payment. Admin dashboards
            // and payment-status queries that hit TM then saw the wrong
            // state, causing duplicate dispatches and stuck payments.
            // Retry once, then surface to admin so ops can reconcile.
            try {
              const tmPayload = {
                accept: '1',
                artisan_confirmed: 'yes',
                status: 'pending_payment',
                service_provider_id: data.service_provider_id || '',
                service_provider_name: artisanName,
                phone: customerPhone, customerPhone, contact: customerPhone, user_phone: customerPhone, client_phone: customerPhone,
                user_id: data.user_id || data.userId || '',
                cost: costNum.toFixed(2), total_cost: costNum.toFixed(2),
                description: descStr,
                updated_at: new Date().toISOString(),
              };
              try {
                await firestore.collection('tasksManagement').doc(rfqId).set(tmPayload, { merge: true });
              } catch (firstErr) {
                console.warn(`[artisan-accept-listener] TM update failed (retrying): ${firstErr.message}`);
                await new Promise(r => setTimeout(r, 500));
                await firestore.collection('tasksManagement').doc(rfqId).set(tmPayload, { merge: true });
              }
            } catch (tmErr) {
              console.error(`[artisan-accept-listener] TM update FAILED for ${rfqId}: ${tmErr && tmErr.message}`);
              try {
                await logErrorToAdmin(
                  'tm_sync_failure_artisan_accept',
                  `Booking ${rfqId}: futureBookings updated to pending_payment but tasksManagement update failed after retry. Manual reconciliation needed so admin views + payment listeners see correct state. Error: ${tmErr && tmErr.message}`,
                  'whatsapp_bot.startArtisanAcceptanceListener',
                  tmErr && tmErr.message || '',
                  rfqId,
                  'critical'
                );
              } catch (_) {}
            }
            // Update the customer's WA session so the next "pay deposit"/
            // "pay full" intercept resolves to THIS newly-accepted booking.
            try {
              const liveSess = sessions.get(to);
              if (liveSess) {
                liveSess.lastBookingId = rfqId;
                liveSess.lastRfqId = rfqId;
                liveSess.paymentStatus = 'pending';
              }
              await firestore.collection('wa_sessions').doc(to).set({
                phone: to,
                lastBookingId: rfqId,
                lastRfqId: rfqId,
                lastBookingAt: Date.now(),
                lastActivity: admin.firestore.FieldValue.serverTimestamp(),
              }, { merge: true });
            } catch (e) { console.warn('[artisan-accept-listener] session update failed:', e && e.message); }
          } catch (e) {
            console.warn(`[artisan-accept-listener] WA send failed for ${rfqId}:`, e.message);
            // Roll back the dedup flag so the next snapshot tick can retry.
            await releaseArtisanAcceptanceClaim(firestore, doc.id, { rollback: true });
            continue;
          }
          // Success path: release the in-memory claim (the Firestore flag
          // stays set as the durable dedup marker).
          await releaseArtisanAcceptanceClaim(firestore, doc.id);
        }
      }, (err) => {
        console.error('[artisan-accept-listener] listener error:', err && err.message);
      });
    console.log('[artisan-accept-listener] listener started (futureBookings where artisan_confirmed == "yes").');
  } catch (e) {
    console.error('[artisan-accept-listener] init failed:', e && e.message);
  }
}

// ─── Listener: escalate to admin when >= 3 artisans reject the RFQ ───
function startArtisanRejectionEscalationListener() {
  try {
    const firestore = db();
    if (!firestore) return;
    firestore.collection('futureBookings')
      .where('rfq_artisan_rejection_count', '>=', 3)
      .onSnapshot(async (snap) => {
        for (const change of snap.docChanges()) {
          if (change.type !== 'added' && change.type !== 'modified') continue;
          const doc = change.doc;
          const data = doc.data() || {};
          // Skip if already escalated or already assigned to a single artisan
          if (data.rfq_3_rejections_escalated === true) continue;
          if (data.status === 'pending_admin_review') continue;
          if (data.rfq_status === 'rfq_approved_waiting_assignment') continue;

          const rfqId = doc.id;
          const rejCount = data.rfq_artisan_rejection_count || 0;
          console.log(`[reject-escalate] RFQ ${rfqId} reached ${rejCount} rejections — escalating to admin`);
          try {
            await doc.ref.update({
              rfq_status: 'rfq_approved_waiting_assignment',
              status: 'pending_admin_review',
              requires_admin_assignment: true,
              rfq_3_rejections_escalated: true,
              rfq_3_rejections_escalated_at: new Date().toISOString(),
              updated_at: new Date().toISOString(),
            });
            try {
              await firestore.collection('tasksManagement').doc(rfqId).set({
                status: 'pending_admin_review',
                rfq_status: 'rfq_approved_waiting_assignment',
                requires_admin_assignment: true,
                updated_at: new Date().toISOString(),
              }, { merge: true });
            } catch (_) {}
            // Push admin
            const priceN = parseFloat(data.admin_quote_total || data.rfq_total || data.quoted_price || data.cost || 0);
            await pushAdminNotification({
              title: '⚠️ 3 Artisans Rejected — Manual Action Needed',
              body: `RFQ ${data.rfq_no || rfqId} (R${priceN.toFixed(2)}) has been rejected by ${rejCount} artisans. Open Admin > RFQ Requests > Waiting Assignment to amend the quote or assign manually.`,
              type: 'rfq_3_rejections',
              bookingId: rfqId,
              extraData: { price: String(priceN), rejection_count: String(rejCount) },
            });
            // Notify customer they may experience a delay
            const custPhone = data.customerPhone || data.contact || data.user_phone || '';
            if (custPhone) {
              try {
                await sendWhatsAppMessage(custPhone,
                  `Hi — quick update on your booking ${data.rfq_no || rfqId}. Our team is reviewing the assignment to make sure the right artisan handles your job. We'll be back to you shortly. 🙏`);
              } catch (_) {}
            }
          } catch (e) {
            console.warn(`[reject-escalate] update failed for ${rfqId}:`, e.message);
          }
        }
      }, (err) => {
        console.error('[reject-escalate] listener error:', err && err.message);
      });
    console.log('[reject-escalate] listener started (futureBookings where rfq_artisan_rejection_count >= 3).');
  } catch (e) {
    console.error('[reject-escalate] init failed:', e && e.message);
  }
}

// ─── Listener: prompt customer to pay balance when artisan completes a deposit-paid job ───
// When a booking with payment_status='deposit_paid' transitions to status='completed' (or 'done'/'closed'),
// send a WhatsApp message asking the customer to pay the outstanding balance.
// Idempotent via wa_balance_prompt_sent_at flag.
function startBalancePromptListener() {
  try {
    const firestore = db();
    if (!firestore) return;
    // Watch tasksManagement (where artisan marks completion). We filter status in-code
    // because Firestore can't combine multiple "in" filters efficiently here.
    firestore.collection('tasksManagement')
      .where('payment_status', '==', 'deposit_paid')
      .onSnapshot(async (snap) => {
        for (const change of snap.docChanges()) {
          if (change.type !== 'added' && change.type !== 'modified') continue;
          const doc = change.doc;
          const data = doc.data() || {};
          const status = String(data.status || '').toLowerCase();
          if (!['completed', 'done', 'closed'].includes(status)) continue;
          if (data.balance_paid === true) continue;
          if (data.wa_balance_prompt_sent_at) continue;
          // HIGH: in-flight guard prevents duplicate sends if onSnapshot
          // fires twice (modified + added) before the Firestore flag
          // write commits. Pairs with _balancePromptInFlight declared
          // alongside the other relay locks above.
          if (_balancePromptInFlight.has(doc.id)) continue;
          _balancePromptInFlight.add(doc.id);

          // Resolve WA source via futureBookings link (TM bridge docs typically have
          // source='future_booking' even for WA-originated bookings)
          const src = String(data.source || '').toLowerCase();
          let isWa = src.includes('whatsapp') || String(doc.id).startsWith('RFQ-') || String(doc.id).startsWith('WA-');
          let phoneRaw = data.user_phone || data.customerPhone || data.contact || data.client_phone || data.phone || '';
          let artisanName = data.service_provider_name || data.artisan_name || '';
          let orderNo = data.order_no || data.rfq_no || doc.id;
          const fbLinkId = String(data.future_booking_id || '').trim();
          if (fbLinkId) {
            try {
              const fbDoc = await firestore.collection('futureBookings').doc(fbLinkId).get();
              if (fbDoc.exists) {
                const fb = fbDoc.data() || {};
                const fbSrc = String(fb.source || '').toLowerCase();
                if (fbSrc.includes('whatsapp') || fbLinkId.startsWith('RFQ-') || fbLinkId.startsWith('WA-')) {
                  isWa = true;
                }
                if (!phoneRaw) phoneRaw = fb.user_phone || fb.customerPhone || fb.contact || fb.client_phone || fb.phone || '';
                if (!artisanName) artisanName = fb.service_provider_name || fb.artisan_name || '';
                if (!orderNo || orderNo === doc.id) orderNo = fb.order_no || fb.rfq_no || orderNo;
              }
            } catch (_) {}
          }
          if (!isWa) continue;
          if (!phoneRaw) continue;
          let to = phoneRaw.replace(/[^0-9]/g, '');
          if (to.length === 10 && to.startsWith('0')) to = '27' + to.slice(1); // ZA local 10-digit only; E.164 numbers (>= 11 digits) left untouched

          // Pull cost fields, falling back to FB if TM doesn't have them
          let totalCost = parseFloat(data.cost || data.total_cost || '0');
          let depositAmt = parseFloat(data.deposit_amount || '0');
          let balanceAmt = parseFloat(data.balance_remaining || data.balance_amount || '0');
          if ((!totalCost || !balanceAmt) && fbLinkId) {
            try {
              const fbDoc = await firestore.collection('futureBookings').doc(fbLinkId).get();
              if (fbDoc.exists) {
                const fb = fbDoc.data() || {};
                if (!totalCost) totalCost = parseFloat(fb.cost || fb.total_cost || fb.total || fb.totalPrice || '0');
                if (!depositAmt) depositAmt = parseFloat(fb.deposit_amount || '0');
                if (!balanceAmt) balanceAmt = parseFloat(fb.balance_remaining || fb.balance_amount || '0');
              }
            } catch (_) {}
          }
          if (!depositAmt) depositAmt = Math.round(totalCost * 0.35 * 100) / 100;
          if (!balanceAmt) balanceAmt = Math.round((totalCost - depositAmt) * 100) / 100;
          if (balanceAmt <= 0) continue;

          if (!artisanName) artisanName = 'your artisan';

          const msg = `✅ *Job complete!* ${artisanName} has marked booking #${orderNo} as completed.\n\n` +
            `💳 *Outstanding balance:* R${balanceAmt.toFixed(2)}\n` +
            `(Deposit of R${depositAmt.toFixed(2)} already paid — total R${totalCost.toFixed(2)})\n\n` +
            `Reply *"pay balance"* to receive your secure payment link.\n\n` +
            `After paying, please rate your artisan to help others choose great service. ⭐`;

          try {
            await sendWhatsAppMessage(to, msg);
            await doc.ref.update({ wa_balance_prompt_sent_at: new Date().toISOString() });
            // Mirror flag on futureBookings so we don't re-prompt from a parallel listener
            try {
              await firestore.collection('futureBookings').doc(doc.id).set({
                wa_balance_prompt_sent_at: new Date().toISOString(),
              }, { merge: true });
            } catch (_) {}
            // FINANCIAL-SAFETY: pin the customer's WA session to THIS
            // balance-due booking so the next "send me a new link" / "pay
            // balance" resolves to the correct unpaid booking (not a
            // stale fully-paid lastBookingId).
            try {
              const bidForSession = fbLinkId || doc.id;
              const liveSess = sessions.get(to);
              if (liveSess) {
                liveSess.lastBookingId = bidForSession;
                liveSess.paymentStatus = 'balance_due';
              }
              await firestore.collection('wa_sessions').doc(to).set({
                phone: to,
                lastBookingId: bidForSession,
                lastBookingAt: Date.now(),
                lastActivity: admin.firestore.FieldValue.serverTimestamp(),
              }, { merge: true });
            } catch (e) { console.warn('[balance-prompt] session pin failed:', e && e.message); }
            console.log(`[balance-prompt] sent balance prompt for ${doc.id} to ${to} (R${balanceAmt.toFixed(2)})`);
          } catch (e) {
            console.warn(`[balance-prompt] WA send failed for ${doc.id}:`, e.message);
          } finally {
            _balancePromptInFlight.delete(doc.id);
          }
        }
      }, (err) => {
        console.error('[balance-prompt] listener error:', err && err.message);
      });
    console.log('[balance-prompt] listener started (tasksManagement where payment_status == "deposit_paid").');
  } catch (e) {
    console.error('[balance-prompt] init failed:', e && e.message);
  }
}

// ─── Listener: artisan job-lifecycle status changes (futureBookings.status) ───
// The artisan app's "Go to Site" / "Complete" buttons update Firestore + POST
// to /api/job-status-update. The HTTP call can fail silently (Render free-tier
// sleep, network blip, missing/stale internal secret). This listener is a
// safety net: when futureBookings.status changes to a lifecycle event for a
// WA-originated booking, the customer gets the WhatsApp message regardless.
// Idempotent via wa_lifecycle_<status>_sent_at flags, so it can co-exist with
// the HTTP path without sending duplicates.
function startJobLifecycleListener() {
  try {
    const firestore = db();
    if (!firestore) return;
    const LIFECYCLE_STATUSES = ['progress', 'in_progress', 'completed', 'done', 'closed', 'cancelled', 'canceled'];
    firestore.collection('futureBookings')
      .onSnapshot(async (snap) => {
        for (const change of snap.docChanges()) {
          if (change.type !== 'modified' && change.type !== 'added') continue;
          const doc = change.doc;
          const data = doc.data() || {};
          const status = String(data.status || '').toLowerCase();
          if (!LIFECYCLE_STATUSES.includes(status)) continue;
          // Only WA-originated bookings
          const src = String(data.source || '').toLowerCase();
          const isWa = src.includes('whatsapp') || String(doc.id).startsWith('RFQ-') || String(doc.id).startsWith('WA-');
          if (!isWa) continue;
          // Normalise: 'in_progress'→'progress', 'done'/'closed'→'completed', 'canceled'→'cancelled'
          let normStatus = status;
          if (status === 'in_progress') normStatus = 'progress';
          else if (status === 'done' || status === 'closed') normStatus = 'completed';
          else if (status === 'canceled') normStatus = 'cancelled';

          const flagKey = `wa_lifecycle_${normStatus}_sent_at`;
          if (data[flagKey]) continue; // already sent (futureBookings flag)
          // Cross-check tasksManagement. The TM doc id often DIFFERS from the
          // FB doc id (TM=auto-uuid, FB=RFQ-XXXX). Resolve via:
          //   1) FB.task_management_id field (canonical link)
          //   2) FB.doc.id as TM id (legacy / same-id bookings)
          //   3) Query tasksManagement where future_booking_id == FB.doc.id
          // Without (1) and (3), the listener fires AGAIN after the HTTP path
          // already sent — producing 4× "Job completed!" in production.
          try {
            const tmIds = new Set();
            const linkedTmId = String(data.task_management_id || data.tm_id || '').trim();
            if (linkedTmId) tmIds.add(linkedTmId);
            tmIds.add(doc.id);
            let foundFlag = null;
            for (const id of tmIds) {
              try {
                const s = await firestore.collection('tasksManagement').doc(id).get();
                if (s.exists && s.data() && s.data()[flagKey]) { foundFlag = s.data()[flagKey]; break; }
              } catch (_) {}
            }
            if (!foundFlag) {
              try {
                const q = await firestore.collection('tasksManagement').where('future_booking_id', '==', doc.id).limit(1).get();
                if (!q.empty && q.docs[0].data()[flagKey]) foundFlag = q.docs[0].data()[flagKey];
              } catch (_) {}
            }
            if (foundFlag) {
              try { await doc.ref.update({ [flagKey]: foundFlag }); } catch (_) {}
              continue;
            }
          } catch (_) {}
          const phoneRaw = data.user_phone || data.customerPhone || data.contact || data.client_phone || data.phone || '';
          if (!phoneRaw) continue;
          let to = phoneRaw.replace(/[^0-9]/g, '');
          if (to.length === 10 && to.startsWith('0')) to = '27' + to.slice(1); // ZA local 10-digit only; E.164 numbers (>= 11 digits) left untouched

          const orderNo = data.order_no || data.rfq_no || doc.id;
          const artisanName = data.service_provider_name || data.artisan_name || data.artisanName || 'Your artisan';
          const ref = orderNo;

          // Skip the deposit-paid 'completed' branch — it's already handled by
          // startBalancePromptListener which sends a balance-due message.
          if (normStatus === 'completed' && data.payment_status === 'deposit_paid' && data.balance_paid !== true) {
            try { await doc.ref.update({ [flagKey]: new Date().toISOString() }); } catch (_) {}
            continue;
          }

          let msg;
          switch (normStatus) {
            case 'progress':
              msg = `🚗 *${artisanName} is on the way!*\n\nYour artisan is heading to your location for booking #${ref}. You can track their location in the Square 15 app.\n\nPlease ensure access to the site is available. 🏠`;
              break;
            case 'completed':
              msg = `✅ *Job completed!*\n\nThe work for booking #${ref} has been completed by ${artisanName}.\n\n🙏 *Thank you for choosing Square 15!* We truly appreciate your trust in our service.\n\nPlease review the work and rate your artisan. ⭐`;
              break;
            case 'cancelled':
              msg = `❌ *Booking cancelled*\n\nYour booking #${ref} has been cancelled. If you need help or have questions, just reply here. 🙏`;
              break;
            default:
              continue;
          }

          // Send-then-mark with in-flight lock so we don't lose messages on
          // transient WA failures and don't double-send on rapid re-emits.
          if (_lifecycleInFlight.has(doc.id + ':' + normStatus)) continue;
          _lifecycleInFlight.add(doc.id + ':' + normStatus);

          // Transactional claim: re-read flag and set it atomically before
          // sending. Prevents racing the HTTP /api/job-status-update path
          // that may have just written the flag on a linked TM doc.
          let claimed = false;
          try {
            claimed = await firestore.runTransaction(async (tx) => {
              const snap2 = await tx.get(doc.ref);
              if (!snap2.exists) return false;
              const d2 = snap2.data() || {};
              if (d2[flagKey]) return false;
              tx.update(doc.ref, { [flagKey]: new Date().toISOString() });
              return true;
            });
          } catch (e) {
            console.warn(`[job-lifecycle] claim failed for ${doc.id}:`, e.message);
          }
          if (!claimed) {
            _lifecycleInFlight.delete(doc.id + ':' + normStatus);
            continue;
          }
          try {
            try {
              await sendWhatsAppMessage(to, msg);
              console.log(`[job-lifecycle] sent "${normStatus}" WA to ${to} for ${doc.id}`);
              // Safety: also send artisan profile photo when they are on the way.
              if (normStatus === 'progress') {
                try {
                  const spId = String(data.service_provider_id || '').trim();
                  if (spId) {
                    const prof = await getArtisanProfile(firestore, spId);
                    if (prof.imageUrl) {
                      const who = prof.name || artisanName;
                      await sendWhatsAppImage(to, prof.imageUrl, `👷 ${who} is on the way to booking #${ref}. For your safety, please confirm this is the person who arrives at your door.`);
                    }
                  }
                } catch (e) { console.warn('[job-lifecycle] artisan photo send failed:', e.message); }
              }
            } catch (e) {
              console.warn(`[job-lifecycle] WA send failed for ${doc.id}:`, e.message);
              continue;
            }
            const sentAt = new Date().toISOString();
            // Mirror flag to linked tasksManagement docs so the HTTP
            // /api/job-status-update endpoint sees it and won't re-send.
            // Resolve TM via FB.task_management_id OR FB.doc.id, AND query
            // tasksManagement.where(future_booking_id == FB.doc.id).
            try {
              const tmIds = new Set();
              const linkedTmId = String(data.task_management_id || data.tm_id || '').trim();
              if (linkedTmId) tmIds.add(linkedTmId);
              tmIds.add(doc.id);
              try {
                const q = await firestore.collection('tasksManagement').where('future_booking_id', '==', doc.id).limit(1).get();
                if (!q.empty) tmIds.add(q.docs[0].id);
              } catch (_) {}
              await Promise.all(Array.from(tmIds).map(id =>
                firestore.collection('tasksManagement').doc(id).set({ [flagKey]: sentAt }, { merge: true }).catch(() => {})
              ));
              // Sync TM status (only on the real linked TM, not phantoms)
              for (const id of tmIds) {
                try {
                  const tmSnap = await firestore.collection('tasksManagement').doc(id).get();
                  if (tmSnap.exists) {
                    await firestore.collection('tasksManagement').doc(id).set({
                      status: normStatus === 'progress' ? 'progress' : (normStatus === 'completed' ? 'completed' : 'cancelled'),
                      updated_at: new Date().toISOString(),
                    }, { merge: true });
                  }
                } catch (_) {}
              }
            } catch (_) {}
            // Track pending rating in sessions so bot prompts on next message
            if (normStatus === 'completed') {
              const session = sessions.get(to);
              if (session) {
                session.pendingRatingBookingId = doc.id;
                session.messages.push({
                  role: 'system',
                  content: `[SYSTEM STATUS UPDATE] Booking #${ref} (${doc.id}): status changed to "completed".`,
                });
              }
            }
          } finally {
            _lifecycleInFlight.delete(doc.id + ':' + normStatus);
          }
        }
      }, (err) => {
        console.error('[job-lifecycle] listener error:', err && err.message);
      });
    console.log('[job-lifecycle] listener started (futureBookings status changes for WA-originated bookings).');
  } catch (e) {
    console.error('[job-lifecycle] init failed:', e && e.message);
  }
}

// ─── Listener: artisan "Buying Material" toggle on tasksManagement ──────────
// Fires when tasksManagement.buying_material flips to 'true'. Sends the
// "🛒 buying materials" WA message regardless of whether the artisan-side
// HTTP push to /api/job-status-update succeeded. Idempotent via
// wa_buying_material_sent_at on the same doc.
function startBuyingMaterialListener() {
  try {
    const firestore = db();
    if (!firestore) return;
    firestore.collection('tasksManagement')
      .where('buying_material', '==', 'true')
      .onSnapshot(async (snap) => {
        for (const change of snap.docChanges()) {
          if (change.type !== 'modified' && change.type !== 'added') continue;
          const doc = change.doc;
          const data = doc.data() || {};
          if (data.wa_buying_material_sent_at) continue;
          const src = String(data.source || '').toLowerCase();
          let isWa = src.includes('whatsapp') || String(doc.id).startsWith('RFQ-') || String(doc.id).startsWith('WA-');

          // Resolve customer phone (prefer futureBookings since tasksManagement
          // sometimes lacks user_phone for WA-originated bookings).
          let phoneRaw = data.user_phone || data.customerPhone || data.phone || '';
          let artisanName = data.service_provider_name || data.artisan_name || '';
          let orderNo = data.order_no || data.rfq_no || doc.id;
          // tasksManagement bridge docs often have source='future_booking' even
          // though the underlying booking is from WhatsApp. Resolve via the
          // future_booking_id link to make the WA-source decision authoritative.
          const fbLinkId = String(data.future_booking_id || '').trim();
          if (fbLinkId) {
            try {
              const fbDoc = await firestore.collection('futureBookings').doc(fbLinkId).get();
              if (fbDoc.exists) {
                const fb = fbDoc.data() || {};
                const fbSrc = String(fb.source || '').toLowerCase();
                if (fbSrc.includes('whatsapp') || fbLinkId.startsWith('RFQ-') || fbLinkId.startsWith('WA-')) {
                  isWa = true;
                }
                if (!phoneRaw) phoneRaw = fb.user_phone || fb.customerPhone || fb.phone || '';
                if (!artisanName) artisanName = fb.service_provider_name || fb.artisan_name || '';
                if (!orderNo || orderNo === doc.id) orderNo = fb.order_no || fb.rfq_no || orderNo;
              }
            } catch (_) {}
          } else if (!phoneRaw || !artisanName) {
            // Fallback: try doc id direct (legacy WA-* ids share id with futureBookings)
            try {
              const fbDoc = await firestore.collection('futureBookings').doc(doc.id).get();
              if (fbDoc.exists) {
                const fb = fbDoc.data() || {};
                if (!phoneRaw) phoneRaw = fb.user_phone || fb.customerPhone || fb.phone || '';
                if (!artisanName) artisanName = fb.service_provider_name || fb.artisan_name || '';
                if (!orderNo || orderNo === doc.id) orderNo = fb.order_no || fb.rfq_no || orderNo;
              }
            } catch (_) {}
          }
          if (!isWa) continue;
          if (!phoneRaw) continue;
          let to = phoneRaw.replace(/[^0-9]/g, '');
          if (to.length === 10 && to.startsWith('0')) to = '27' + to.slice(1); // ZA local 10-digit only; E.164 numbers (>= 11 digits) left untouched

          const name = artisanName || 'Your artisan';
          const ref = orderNo;
          const msg = `🛒 *${name} is buying materials!*\n\nYour artisan is purchasing the materials needed for booking #${ref}. They will head to your site once ready.\n\nWe'll keep you updated on progress. 🔧`;

          // Mark BEFORE send to prevent duplicates
          try {
            await doc.ref.update({ wa_buying_material_sent_at: new Date().toISOString() });
          } catch (e) {
            console.warn(`[buying-material] flag update failed for ${doc.id}:`, e.message);
            continue;
          }

          try {
            await sendWhatsAppMessage(to, msg);
            console.log(`[buying-material] sent WA to ${to} for ${doc.id}`);
          } catch (e) {
            console.warn(`[buying-material] WA send failed for ${doc.id}:`, e.message);
          }
        }
      }, (err) => {
        console.error('[buying-material] listener error:', err && err.message);
      });
    console.log('[buying-material] listener started (tasksManagement where buying_material == "true").');
  } catch (e) {
    console.error('[buying-material] init failed:', e && e.message);
  }
}

// ─── Listener: artisan before/after photo uploads ───────────────────────────
// Fires when tasksManagement.artisan_images flips to "1" (before-work photo
// uploaded) or "2" (after-work photo uploaded). Sends the appropriate WA
// message with the actual photo as an image attachment, regardless of whether
// the artisan-side HTTP push succeeded. Idempotent via
// wa_artisan_images_<n>_sent_at flags. Resolves WA source via the
// future_booking_id link (TM bridge docs typically have source='future_booking'
// even for WA-originated bookings).
function startArtisanPhotoListener() {
  try {
    const firestore = db();
    if (!firestore) return;
    firestore.collection('tasksManagement')
      .onSnapshot(async (snap) => {
        for (const change of snap.docChanges()) {
          if (change.type !== 'modified' && change.type !== 'added') continue;
          const doc = change.doc;
          const data = doc.data() || {};
          const ai = String(data.artisan_images || '').trim();
          if (ai !== '1' && ai !== '2') continue;
          const flagKey = ai === '1' ? 'wa_artisan_images_1_sent_at' : 'wa_artisan_images_2_sent_at';
          if (data[flagKey]) continue;

          // Atomic check-and-claim: re-read the flag inside a transaction and
          // set it before sending. This prevents racing with the concurrent
          // HTTP /api/job-status-update path that may have just written the
          // flag while we were processing this stale snapshot — which caused
          // 2× after-photo sends in production.
          try {
            const claimed = await firestore.runTransaction(async (tx) => {
              const snap2 = await tx.get(doc.ref);
              if (!snap2.exists) return false;
              const d2 = snap2.data() || {};
              if (d2[flagKey]) return false;
              tx.update(doc.ref, { [flagKey]: new Date().toISOString() });
              return true;
            });
            if (!claimed) {
              console.log(`[artisan-photo] race-lost ai=${ai} for ${doc.id}: flag ${flagKey} already set`);
              continue;
            }
          } catch (e) {
            console.warn(`[artisan-photo] claim failed for ${doc.id}:`, e.message);
            continue;
          }

          // Resolve WA source via future_booking_id link if not directly WA
          const src = String(data.source || '').toLowerCase();
          let isWa = src.includes('whatsapp') || String(doc.id).startsWith('RFQ-') || String(doc.id).startsWith('WA-');
          let phoneRaw = data.user_phone || data.customerPhone || data.phone || '';
          let artisanName = data.service_provider_name || data.artisan_name || '';
          let orderNo = data.order_no || data.rfq_no || doc.id;
          const fbLinkId = String(data.future_booking_id || '').trim();
          if (fbLinkId) {
            try {
              const fbDoc = await firestore.collection('futureBookings').doc(fbLinkId).get();
              if (fbDoc.exists) {
                const fb = fbDoc.data() || {};
                const fbSrc = String(fb.source || '').toLowerCase();
                if (fbSrc.includes('whatsapp') || fbLinkId.startsWith('RFQ-') || fbLinkId.startsWith('WA-')) {
                  isWa = true;
                }
                if (!phoneRaw) phoneRaw = fb.user_phone || fb.customerPhone || fb.phone || '';
                if (!artisanName) artisanName = fb.service_provider_name || fb.artisan_name || '';
                if (!orderNo || orderNo === doc.id) orderNo = fb.order_no || fb.rfq_no || orderNo;
              }
            } catch (_) {}
          }
          if (!isWa) continue;
          if (!phoneRaw) continue;
          let to = phoneRaw.replace(/[^0-9]/g, '');
          if (to.length === 10 && to.startsWith('0')) to = '27' + to.slice(1); // ZA local 10-digit only; E.164 numbers (>= 11 digits) left untouched

          // Resolve photo URL from artisanTasksImages doc
          let imageUrl = '';
          const imageDocId = String(data.artisan_image_doc_id || '').trim();
          if (imageDocId) {
            try {
              const imgDoc = await firestore.collection('artisanTasksImages').doc(imageDocId).get();
              if (imgDoc.exists) {
                const img = imgDoc.data() || {};
                imageUrl = ai === '1'
                  ? String(img.before_work || img.beforeWork || '')
                  : String(img.after_work || img.afterWork || '');
              }
            } catch (_) {}
          }

          // Don't notify the customer if we have no actual photo to attach.
          // Sending "Work completed!" with no image is misleading and breaks
          // trust. Wait until the artisanTasksImages doc has the URL and
          // re-fire on the next snapshot pass.
          if (!imageUrl) {
            console.warn(`[artisan-photo] skipping ai=${ai} for ${doc.id}: no image URL yet (doc_id=${imageDocId})`);
            continue;
          }

          const name = artisanName || 'Your artisan';
          const ref = orderNo;
          const msg = ai === '1'
            ? `📸 *${name} has arrived!*\n\nYour artisan has arrived at the site and taken a before-work photo for booking #${ref}. Work is about to begin.\n\nWe'll keep you updated on progress. 🔧`
            : `📸 *Work completed!*\n\nYour artisan has finished the job and uploaded an after-work photo for booking #${ref}.\n\nPlease review the work in the Square 15 app. ✅`;

          try {
            await sendWhatsAppMessage(to, msg);
            if (imageUrl) {
              const caption = ai === '1'
                ? `📸 Before-work photo for booking #${ref}`
                : `📸 After-work photo for booking #${ref}`;
              try { await sendWhatsAppImage(to, imageUrl, caption); } catch (e) {
                console.warn(`[artisan-photo] image send failed:`, e.message);
              }
            }
            console.log(`[artisan-photo] sent ai=${ai} WA to ${to} for ${doc.id}`);
          } catch (e) {
            console.warn(`[artisan-photo] WA send failed for ${doc.id}:`, e.message);
          }
        }
      }, (err) => {
        console.error('[artisan-photo] listener error:', err && err.message);
      });
    console.log('[artisan-photo] listener started (tasksManagement.artisan_images changes).');
  } catch (e) {
    console.error('[artisan-photo] init failed:', e && e.message);
  }
}

// ─── Listener: rating prompt after job is fully paid ───────────────────────
// Fires when tasksManagement reaches a fully-paid + completed state (either
// balance_paid flips to true on a deposit booking, or payment_status === 'paid'
// for full-payment bookings) and no rating has been collected yet. Sends a
// "please rate your artisan" message asking the customer for a 1-5 star rating.
// Idempotent via wa_rating_request_sent_at.
function startRatingPromptListener() {
  try {
    const firestore = db();
    if (!firestore) return;
    firestore.collection('tasksManagement')
      .onSnapshot(async (snap) => {
        for (const change of snap.docChanges()) {
          if (change.type !== 'modified' && change.type !== 'added') continue;
          const doc = change.doc;
          const data = doc.data() || {};
          if (data.wa_rating_request_sent_at) continue;
          if (data.rating) continue;
          const status = String(data.status || '').toLowerCase();
          if (!['completed', 'done', 'closed'].includes(status)) continue;
          const paymentStatus = String(data.payment_status || '').toLowerCase();
          const fullyPaid = data.balance_paid === true
            || paymentStatus === 'paid'
            || paymentStatus === 'fully_paid'
            || paymentStatus === 'balance_paid';
          if (!fullyPaid) continue;

          // Resolve WA source via futureBookings link
          const src = String(data.source || '').toLowerCase();
          let isWa = src.includes('whatsapp') || String(doc.id).startsWith('RFQ-') || String(doc.id).startsWith('WA-');
          let phoneRaw = data.user_phone || data.customerPhone || data.contact || data.client_phone || data.phone || '';
          let artisanName = data.service_provider_name || data.artisan_name || '';
          let orderNo = data.order_no || data.rfq_no || doc.id;
          const fbLinkId = String(data.future_booking_id || '').trim();
          if (fbLinkId) {
            try {
              const fbDoc = await firestore.collection('futureBookings').doc(fbLinkId).get();
              if (fbDoc.exists) {
                const fb = fbDoc.data() || {};
                const fbSrc = String(fb.source || '').toLowerCase();
                if (fbSrc.includes('whatsapp') || fbLinkId.startsWith('RFQ-') || fbLinkId.startsWith('WA-')) {
                  isWa = true;
                }
                if (!phoneRaw) phoneRaw = fb.user_phone || fb.customerPhone || fb.contact || fb.client_phone || fb.phone || '';
                if (!artisanName) artisanName = fb.service_provider_name || fb.artisan_name || '';
                if (!orderNo || orderNo === doc.id) orderNo = fb.order_no || fb.rfq_no || orderNo;
              }
            } catch (_) {}
          }
          if (!isWa) continue;
          if (!phoneRaw) continue;
          let to = phoneRaw.replace(/[^0-9]/g, '');
          if (to.length === 10 && to.startsWith('0')) to = '27' + to.slice(1); // ZA local 10-digit only; E.164 numbers (>= 11 digits) left untouched

          const name = artisanName || 'your artisan';
          const ref = orderNo;
          const msg = `🎉 *Booking #${ref} fully paid — thank you!*\n\n` +
            `We hope you're happy with the work ${name} completed.\n\n` +
            `⭐ *Please rate your artisan from 1 to 5 stars:*\n` +
            `Just reply with a number (1 = poor, 5 = excellent).\n\n` +
            `Your honest feedback helps us maintain quality service and helps other customers choose great artisans. 🙏`;

          // Mark BEFORE send to prevent duplicate fires
          try {
            await doc.ref.update({ wa_rating_request_sent_at: new Date().toISOString() });
          } catch (e) {
            console.warn(`[rating-prompt] flag update failed for ${doc.id}:`, e.message);
            continue;
          }

          try {
            await sendWhatsAppMessage(to, msg);
            // Track pending rating in session so the AI knows to capture the next number reply
            const session = sessions.get(to);
            if (session) {
              session.pendingRatingBookingId = doc.id;
              session.messages.push({
                role: 'system',
                content: `[PENDING RATING] Booking #${ref} (${doc.id}) is fully paid and awaiting a 1-5 star rating from the customer. If their next message is a number 1-5, treat it as a rating and call submit_rating.`,
              });
            }
            // Persist pendingRatingBookingId to Firestore so it survives bot cold-starts
            try {
              await firestore.collection('wa_sessions').doc(to).set({
                pendingRatingBookingId: doc.id,
                phone: to,
                lastActivity: admin.firestore.FieldValue.serverTimestamp(),
              }, { merge: true });
            } catch (e) {
              console.warn(`[rating-prompt] wa_sessions persist failed for ${to}:`, e.message);
            }
            console.log(`[rating-prompt] sent rating request to ${to} for ${doc.id}`);
          } catch (e) {
            console.warn(`[rating-prompt] WA send failed for ${doc.id}:`, e.message);
          }
        }
      }, (err) => {
        console.error('[rating-prompt] listener error:', err && err.message);
      });
    console.log('[rating-prompt] listener started (tasksManagement completed + fully paid).');
  } catch (e) {
    console.error('[rating-prompt] init failed:', e && e.message);
  }
}


app.listen(PORT, () => {
  console.log(`[whatsapp-bot] listening on :${PORT}`);
  initFirebase();
  try { _startAutoResolveSweeper(); console.log('[auto-heal] sweeper started (every 5 min).'); } catch (_) {}
  // Start the quote relay listener after Firebase is up. Wrapped in setTimeout
  // so initFirebase has a moment to complete its async init.
  setTimeout(() => { try { startQuoteRelayListener(); } catch (e) { console.error('[quote-relay] start failed:', e.message); } }, 2000);
  setTimeout(() => { try { startAdminAssignmentRelayListener(); } catch (e) { console.error('[admin-assign-relay] start failed:', e.message); } }, 2500);
  setTimeout(() => { try { startArtisanRejectionEscalationListener(); } catch (e) { console.error('[reject-escalate] start failed:', e.message); } }, 3000);
  setTimeout(() => { try { startArtisanAcceptanceListener(); } catch (e) { console.error('[artisan-accept-listener] start failed:', e.message); } }, 3500);
  setTimeout(() => { try { startBalancePromptListener(); } catch (e) { console.error('[balance-prompt] start failed:', e.message); } }, 4000);
  setTimeout(() => { try { startJobLifecycleListener(); } catch (e) { console.error('[job-lifecycle] start failed:', e.message); } }, 4500);
  setTimeout(() => { try { startBuyingMaterialListener(); } catch (e) { console.error('[buying-material] start failed:', e.message); } }, 5000);
  setTimeout(() => { try { startArtisanPhotoListener(); } catch (e) { console.error('[artisan-photo] start failed:', e.message); } }, 5500);
  setTimeout(() => { try { startRatingPromptListener(); } catch (e) { console.error('[rating-prompt] start failed:', e.message); } }, 6000);

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

// ─── Graceful shutdown ──────────────────────────────────────────────────────
// Render sends SIGTERM before forcefully killing the process. Capture both
// SIGTERM and SIGINT, unsubscribe known Firestore listeners (best-effort),
// and exit cleanly so in-flight writes can flush. Without this, Firebase
// gRPC connections may take seconds to time out, delaying redeploys and
// occasionally causing the next instance to overlap.
let _shuttingDown = false;
function _gracefulShutdown(signal) {
  if (_shuttingDown) return;
  _shuttingDown = true;
  console.log(`[shutdown] ${signal} received — cleaning up listeners and exiting…`);
  try { if (typeof _quoteRelayUnsubscribe === 'function') _quoteRelayUnsubscribe(); } catch (_) {}
  try { if (typeof _adminAssignmentRelayUnsubscribe === 'function') _adminAssignmentRelayUnsubscribe(); } catch (_) {}
  // Give listeners ~2s to flush, then force-exit. Render's grace is ~30s,
  // 2s is plenty for typical in-flight writes without delaying redeploys.
  setTimeout(() => process.exit(0), 2000).unref();
}
process.on('SIGTERM', () => _gracefulShutdown('SIGTERM'));
process.on('SIGINT', () => _gracefulShutdown('SIGINT'));
// Surface uncaught errors to admin so we don't fail silently during ops.
process.on('uncaughtException', (err) => {
  console.error('[uncaught] exception:', err && err.stack || err);
  try {
    if (typeof logErrorToAdmin === 'function') {
      logErrorToAdmin('uncaught_exception', String(err && err.message || err), 'whatsapp_bot.process', String(err && err.stack || ''), '', 'critical').catch(() => {});
    }
  } catch (_) {}
});
process.on('unhandledRejection', (reason) => {
  console.error('[unhandled] promise rejection:', reason);
  try {
    if (typeof logErrorToAdmin === 'function') {
      logErrorToAdmin('unhandled_rejection', String((reason && reason.message) || reason), 'whatsapp_bot.process', String((reason && reason.stack) || ''), '', 'high').catch(() => {});
    }
  } catch (_) {}
});
