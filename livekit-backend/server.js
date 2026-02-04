const express = require('express');
const cors = require('cors');
const { AccessToken, AgentDispatchClient } = require('livekit-server-sdk');
const admin = require('firebase-admin');
const rateLimit = require('express-rate-limit');
const crypto = require('crypto');
const fs = require('fs');
require('dotenv').config();

function sanitizeEnvValue(value) {
  if (typeof value !== 'string') return value;
  let v = value.trim();
  // Render UI copy/paste sometimes includes surrounding quotes
  if ((v.startsWith('"') && v.endsWith('"')) || (v.startsWith("'") && v.endsWith("'"))) {
    v = v.slice(1, -1).trim();
  }
  return v;
}

function env(name) {
  return sanitizeEnvValue(process.env[name]);
}

const app = express();
const PORT = process.env.PORT || 3000;

// Middleware
app.use(cors({
  origin: process.env.ALLOWED_ORIGINS ? process.env.ALLOWED_ORIGINS.split(',') : '*',
  credentials: true
}));
app.use(express.json({ limit: process.env.JSON_BODY_LIMIT || '200kb' }));

const apiLimiter = rateLimit({
  windowMs: 60 * 1000,
  max: Number(process.env.RATE_LIMIT_PER_MINUTE || 120),
  standardHeaders: true,
  legacyHeaders: false,
});

app.use('/api/', apiLimiter);

function nowIso() {
  return new Date().toISOString();
}

function randomId(prefix = '') {
  const id = crypto.randomUUID();
  return prefix ? `${prefix}${id}` : id;
}

function stableStringify(value) {
  if (value === null || value === undefined) return 'null';
  if (typeof value !== 'object') return JSON.stringify(value);
  if (Array.isArray(value)) return `[${value.map(stableStringify).join(',')}]`;
  const keys = Object.keys(value).sort();
  return `{${keys.map((k) => `${JSON.stringify(k)}:${stableStringify(value[k])}`).join(',')}}`;
}

function sha256Hex(input) {
  return crypto.createHash('sha256').update(String(input || ''), 'utf8').digest('hex');
}

function normalizeRole(decoded) {
  const raw = String(decoded && (decoded.role || decoded.user_role || decoded.user_type) ? (decoded.role || decoded.user_role || decoded.user_type) : 'client')
    .trim()
    .toLowerCase();
  if (raw === 'admin' || raw === 'administrator') return 'admin';
  if (raw === 'artisan' || raw === 'provider' || raw === 'worker') return 'artisan';
  if (raw === 'client' || raw === 'user') return 'client';
  return raw;
}

function isAllowedRole(role) {
  return role === 'client' || role === 'admin' || role === 'artisan';
}

function ensureActionAllowed({ action, actorRole }) {
  const policies = {
    create_order_booking: { roles: ['client', 'admin'] },
  };

  const p = policies[action];
  if (!p) {
    return { ok: false, status: 400, error: 'unsupported_action' };
  }
  if (!p.roles.includes(actorRole)) {
    return { ok: false, status: 403, error: 'forbidden' };
  }
  return { ok: true };
}

function getBearerToken(req) {
  const header = req.headers.authorization || req.headers.Authorization;
  if (!header || typeof header !== 'string') return '';
  const m = header.match(/^Bearer\s+(.+)$/i);
  return m ? m[1].trim() : '';
}

function getServiceAccountFromEnv() {
  const jsonRaw = env('FIREBASE_SERVICE_ACCOUNT_JSON');
  if (jsonRaw) {
    try {
      return JSON.parse(jsonRaw);
    } catch {
      throw new Error('FIREBASE_SERVICE_ACCOUNT_JSON is not valid JSON');
    }
  }

  const filePath = env('FIREBASE_SERVICE_ACCOUNT_FILE');
  if (filePath) {
    try {
      const raw = fs.readFileSync(filePath, 'utf8');
      return JSON.parse(raw);
    } catch {
      throw new Error('FIREBASE_SERVICE_ACCOUNT_FILE is not a readable JSON file');
    }
  }

  const b64 = env('FIREBASE_SERVICE_ACCOUNT_BASE64');
  if (b64) {
    try {
      const decoded = Buffer.from(b64, 'base64').toString('utf8');
      return JSON.parse(decoded);
    } catch {
      throw new Error('FIREBASE_SERVICE_ACCOUNT_BASE64 is not valid base64 JSON');
    }
  }

  return null;
}

let firebaseInitialized = false;
let firebaseInitError = null;
let firebaseProjectIdHint = null;
let firebaseClientEmailHint = null;

function initFirebaseIfPossible() {
  if (firebaseInitialized) return;
  try {
    const sa = getServiceAccountFromEnv();
    if (!sa) {
      firebaseInitError = new Error(
        'Firebase Admin is not configured. Set FIREBASE_SERVICE_ACCOUNT_JSON or FIREBASE_SERVICE_ACCOUNT_BASE64 on the backend service.'
      );
      firebaseInitialized = true;
      return;
    }

    firebaseProjectIdHint = sa.project_id || sa.projectId || null;
    firebaseClientEmailHint = sa.client_email || sa.clientEmail || null;
    admin.initializeApp({
      credential: admin.credential.cert(sa),
    });
    firebaseInitialized = true;
  } catch (e) {
    firebaseInitError = e;
    firebaseInitialized = true;
  }
}

function requireFirebase(res) {
  initFirebaseIfPossible();
  if (firebaseInitError) {
    res.status(503).json({
      error: 'Firebase Admin not configured',
      message: firebaseInitError.message,
      hint:
        'Configure FIREBASE_SERVICE_ACCOUNT_JSON, FIREBASE_SERVICE_ACCOUNT_BASE64, or FIREBASE_SERVICE_ACCOUNT_FILE in Render env vars for the livekit-backend service.',
    });
    return null;
  }
  return admin.firestore();
}

function getFirestoreOrNull() {
  initFirebaseIfPossible();
  if (firebaseInitError) {
    console.error('❌ Firebase Admin not configured:', firebaseInitError.message);
    return null;
  }
  return admin.firestore();
}

async function verifyFirebaseAuth(req, res) {
  initFirebaseIfPossible();
  if (firebaseInitError) {
    res.status(503).json({
      error: 'Firebase Admin not configured',
      message: firebaseInitError.message,
    });
    return null;
  }

  const idToken = getBearerToken(req);
  if (!idToken) {
    res.status(401).json({
      error: 'Unauthorized',
      message: 'Missing Authorization: Bearer <Firebase ID token>',
    });
    return null;
  }

  try {
    const decoded = await admin.auth().verifyIdToken(idToken);
    return decoded;
  } catch (e) {
    res.status(401).json({
      error: 'Unauthorized',
      message: 'Invalid Firebase ID token',
      details: e && e.message ? String(e.message) : undefined,
    });
    return null;
  }
}

function isTruthy(v) {
  if (v === true) return true;
  if (v === false) return false;
  if (v == null) return false;
  const s = String(v).trim().toLowerCase();
  return s === '1' || s === 'true' || s === 'yes' || s === 'y';
}

function normalizeAction(action) {
  return String(action || '').trim().toLowerCase();
}

function normalizeBookingId(payload) {
  const p = payload && typeof payload === 'object' ? payload : {};
  const id = String(p.booking_id || p.bookingId || '').trim();
  return id;
}

function isPlainObject(v) {
  if (!v || typeof v !== 'object') return false;
  const proto = Object.getPrototypeOf(v);
  return proto === Object.prototype || proto === null;
}

function safeTrimString(v, { maxLen = 5000 } = {}) {
  if (v == null) return '';
  const s = String(v).trim();
  if (!s) return '';
  return s.length > maxLen ? s.slice(0, maxLen) : s;
}

function coerceBooleanish(v) {
  if (v === true || v === false) return v;
  if (v == null) return null;
  const s = String(v).trim().toLowerCase();
  if (s === '1' || s === 'true' || s === 'yes' || s === 'y') return true;
  if (s === '0' || s === 'false' || s === 'no' || s === 'n') return false;
  return null;
}

function validateActionExecuteBody(body) {
  const errors = [];
  const b = isPlainObject(body) ? body : {};

  // Only allow known top-level keys.
  const allowedTopKeys = new Set(['action', 'payload', 'context']);
  for (const k of Object.keys(b)) {
    if (!allowedTopKeys.has(k)) {
      errors.push({ field: k, message: 'Unknown top-level field' });
    }
  }

  const action = normalizeAction(b.action);
  if (!action) {
    errors.push({ field: 'action', message: 'Missing action' });
  }

  const rawPayload = b.payload;
  if (rawPayload != null && !isPlainObject(rawPayload)) {
    errors.push({ field: 'payload', message: 'payload must be an object' });
  }

  const rawContext = b.context;
  if (rawContext != null && !isPlainObject(rawContext)) {
    errors.push({ field: 'context', message: 'context must be an object' });
  }

  // Canonical actions supported by this backend.
  const supportedActions = new Set(['create_order_booking']);
  if (action && !supportedActions.has(action)) {
    errors.push({ field: 'action', message: `Unsupported action: ${action}` });
  }

  const payload = isPlainObject(rawPayload) ? rawPayload : {};

  // Validate create_order_booking payload.
  let normalizedPayload = payload;
  if (action === 'create_order_booking') {
    const vp = validateCreateOrderBookingPayload(payload);
    normalizedPayload = vp.payload;
    errors.push(...vp.errors);
  }

  const context = isPlainObject(rawContext) ? rawContext : {};
  const normalizedContext = {
    session_id: safeTrimString(context.session_id, { maxLen: 200 }) || undefined,
    room_name: safeTrimString(context.room_name, { maxLen: 200 }) || undefined,
  };

  return {
    ok: errors.length === 0,
    errors,
    action,
    payload: normalizedPayload,
    context: normalizedContext,
  };
}

function validateCreateOrderBookingPayload(payload) {
  const errors = [];
  const p = isPlainObject(payload) ? payload : {};

  // Allow only known fields to prevent accidental/unsafe writes.
  const allowed = new Set([
    'is_rfq_requested',
    'is_rfq',
    'isRFQ',
    'isRfq',
    'category_name',
    'categoryName',
    'problem_description',
    'problemDescription',
    'job_ids',
    'jobIds',
    'materials_responsibility',
    'materialsResponsibility',
    'service_on_current_location',
    'serviceOnCurrentLocation',
    'scheduled_date',
    'scheduledDate',
    'scheduled_time',
    'scheduledTime',
    'booking_id',
    'bookingId',
  ]);

  for (const k of Object.keys(p)) {
    if (!allowed.has(k)) {
      errors.push({ field: `payload.${k}`, message: 'Unknown payload field' });
    }
  }

  const isRfq = isTruthy(p.is_rfq_requested ?? p.is_rfq ?? p.isRFQ ?? p.isRfq);

  const problem = safeTrimString(p.problem_description ?? p.problemDescription, { maxLen: 2000 });
  if (!problem) {
    errors.push({ field: 'payload.problem_description', message: 'problem_description is required' });
  }

  const category = safeTrimString(p.category_name ?? p.categoryName, { maxLen: 200 });

  const jobIdsRaw = p.job_ids ?? p.jobIds;
  const jobIds = Array.isArray(jobIdsRaw)
    ? jobIdsRaw.map((x) => safeTrimString(x, { maxLen: 200 })).filter(Boolean)
    : [];

  if (!isRfq) {
    if (jobIds.length < 1) {
      errors.push({ field: 'payload.job_ids', message: 'job_ids must be a non-empty array for non-RFQ orders' });
    }
  }

  const materials = safeTrimString(p.materials_responsibility ?? p.materialsResponsibility, { maxLen: 50 });
  if (materials && !['artisan', 'client'].includes(materials.toLowerCase())) {
    errors.push({ field: 'payload.materials_responsibility', message: 'materials_responsibility must be artisan|client' });
  }

  const scheduledDate = safeTrimString(p.scheduled_date ?? p.scheduledDate, { maxLen: 20 });
  const scheduledTime = safeTrimString(p.scheduled_time ?? p.scheduledTime, { maxLen: 10 });
  if (scheduledDate && !/^\d{4}-\d{2}-\d{2}$/.test(scheduledDate)) {
    errors.push({ field: 'payload.scheduled_date', message: 'scheduled_date must be YYYY-MM-DD' });
  }
  if (scheduledTime && !/^\d{2}:\d{2}$/.test(scheduledTime)) {
    errors.push({ field: 'payload.scheduled_time', message: 'scheduled_time must be HH:MM' });
  }

  const serviceOnCurrentLocation =
    coerceBooleanish(p.service_on_current_location ?? p.serviceOnCurrentLocation) ?? undefined;

  return {
    ok: errors.length === 0,
    errors,
    payload: {
      is_rfq_requested: isRfq,
      category_name: category || undefined,
      problem_description: problem,
      job_ids: jobIds,
      materials_responsibility: materials ? materials.toLowerCase() : undefined,
      service_on_current_location: serviceOnCurrentLocation,
      scheduled_date: scheduledDate || undefined,
      scheduled_time: scheduledTime || undefined,
      booking_id: safeTrimString(p.booking_id ?? p.bookingId, { maxLen: 200 }) || undefined,
    },
  };
}

function getIdempotencyKey(req) {
  const k = req.headers['idempotency-key'] || req.headers['Idempotency-Key'];
  const s = typeof k === 'string' ? k.trim() : '';
  const raw = s || randomId('idem-');
  return raw.replace(/\//g, '_');
}

async function writeAudit({ firestore, auditId, audit }) {
  await firestore.collection('assistant_action_audit').doc(auditId).set(audit, { merge: true });
}

async function writeNotification({ firestore, userId, userType, title, message, type, data }) {
  const doc = {
    user_id: String(userId || '').trim(),
    user_type: String(userType || '').trim(),
    title: String(title || '').trim() || 'Notification',
    message: String(message || '').trim(),
    type: String(type || '').trim(),
    booking_id: (data && (data.booking_id || data.bookingId)) ? String(data.booking_id || data.bookingId) : '',
    data: data && typeof data === 'object' ? data : {},
    read: false,
    view: false,
    created_at: nowIso(),
    updated_at: nowIso(),
  };

  await firestore.collection('notifications').add(doc);
}

async function handleCreateOrderBooking({ firestore, actorUid, actorRole, payload }) {
  if (!actorUid) {
    return { ok: false, status: 401, error: 'unauthorized' };
  }

  // For now, allow any authenticated user to create a booking.
  // Admin/artisan can also create, but the actorUid becomes client_id/user_id.
  const p = payload && typeof payload === 'object' ? payload : {};
  const isRFQFlag = isTruthy(p.is_rfq_requested ?? p.is_rfq ?? p.isRFQ ?? p.isRfq);

  const categoryName = String(p.category_name || p.categoryName || '').trim();
  const problemDescription = String(p.problem_description || p.problemDescription || '').trim();

  const scheduledDate = String(p.scheduled_date || p.scheduledDate || new Date().toISOString().slice(0, 10)).trim();
  const scheduledTime = String(p.scheduled_time || p.scheduledTime || new Date().toTimeString().slice(0, 5)).trim();

  const bookingRef = firestore.collection('futureBookings').doc();
  const bookingIdLocal = bookingRef.id;

  const jobIds = Array.isArray(p.job_ids || p.jobIds) ? (p.job_ids || p.jobIds) : [];

  const status = isRFQFlag ? 'rfq_submitted' : 'pending_assignment';
  const bookingDoc = {
    booking_id: bookingIdLocal,
    bookingId: bookingIdLocal,

    user_id: actorUid,
    client_id: actorUid,
    user_type: actorRole || 'client',

    is_rfq: isRFQFlag ? 'yes' : 'no',
    is_rfq_requested: isRFQFlag ? 'yes' : 'no',
    order_type: isRFQFlag ? 'rfq' : 'order',

    category_name: categoryName,
    problem_description: problemDescription,
    job_ids: jobIds,

    scheduled_date: scheduledDate,
    scheduled_time: scheduledTime,

    service_provider_id: 'admin',
    artisan_confirmed: 'pending',
    status,

    created_at: nowIso(),
    updated_at: nowIso(),
  };

  await bookingRef.set(bookingDoc);

  // Admin notification (shows in Admin Inbox).
  await writeNotification({
    firestore,
    userId: 'admin',
    userType: 'admin',
    title: isRFQFlag ? 'RFQ Request' : 'New Booking',
    message: isRFQFlag
      ? `New RFQ request for ${categoryName || 'service'} (booking ${bookingIdLocal}).`
      : `New booking created for ${categoryName || 'service'} (booking ${bookingIdLocal}).`,
    type: isRFQFlag ? 'rfq' : 'order',
    data: { booking_id: bookingIdLocal, order_type: isRFQFlag ? 'rfq' : 'order' },
  });

  // Personal notification to the requesting user.
  await writeNotification({
    firestore,
    userId: actorUid,
    userType: 'user',
    title: isRFQFlag ? 'RFQ submitted' : 'Booking created',
    message: isRFQFlag
      ? 'Your request has been submitted for a quote. Admin will review and assign the best available artisan.'
      : 'Your booking was created. We are assigning the nearest available artisan.',
    type: isRFQFlag ? 'rfq' : 'order',
    data: { booking_id: bookingIdLocal, status },
  });

  return {
    ok: true,
    status: 200,
    data: {
      booking_id: bookingIdLocal,
      bookingId: bookingIdLocal,
      is_rfq: isRFQFlag,
      isRFQ: isRFQFlag,
      status,
    },
  };
}

const ACTION_HANDLERS = {
  create_order_booking: handleCreateOrderBooking,
};

async function executeAction({ firestore, action, actorUid, actorRole, payload, context }) {
  if (!action || typeof action !== 'string') {
    return { ok: false, status: 400, error: 'missing_action' };
  }

  const handler = ACTION_HANDLERS[action];
  if (!handler) {
    return { ok: false, status: 400, error: 'unsupported_action' };
  }

  return handler({ firestore, actorUid, actorRole, payload, context });
}

function getLiveKitWsUrl() {
  return env('LIVEKIT_WS_URL') || env('LIVEKIT_URL');
}

function getLiveKitHttpUrl() {
  const wsUrl = getLiveKitWsUrl();
  if (!wsUrl) return undefined;
  if (wsUrl.startsWith('wss://')) return wsUrl.replace('wss://', 'https://');
  if (wsUrl.startsWith('ws://')) return wsUrl.replace('ws://', 'http://');
  // If already http(s), keep as-is
  return wsUrl;
}

function getAgentName() {
  return env('LIVEKIT_AGENT_NAME') || 'square15-voice-assistant';
}

function validateLiveKitEnv(res) {
  const wsUrl = getLiveKitWsUrl();
  const apiKey = env('LIVEKIT_API_KEY');
  const apiSecret = env('LIVEKIT_API_SECRET');

  if (!wsUrl || !apiKey || !apiSecret) {
    console.error('❌ Livekit credentials not configured');
    res.status(500).json({
      error: 'Server configuration error',
      message:
        'Missing LIVEKIT_WS_URL/LIVEKIT_URL, LIVEKIT_API_KEY, or LIVEKIT_API_SECRET',
    });
    return null;
  }

  return { wsUrl, apiKey, apiSecret };
}

function getSdkVersion() {
  try {
    // eslint-disable-next-line global-require
    return require('livekit-server-sdk/package.json').version;
  } catch {
    // Some package managers / export maps may prevent requiring package.json.
    // Fall back to the version range declared in this service's package.json.
    try {
      // eslint-disable-next-line global-require
      const pkg = require('./package.json');
      return (
        (pkg.dependencies && pkg.dependencies['livekit-server-sdk']) ||
        (pkg.devDependencies && pkg.devDependencies['livekit-server-sdk']) ||
        'unknown'
      );
    } catch {
      return 'unknown';
    }
  }
}

function isLiveKitInvalidTokenError(error) {
  const msg = (error && error.message ? String(error.message) : '').toLowerCase();
  return msg.includes('invalid token') || msg.includes('unauthorized') || msg.includes('401');
}

// Health check endpoint
app.get('/health', (req, res) => {
  const wsUrl = getLiveKitWsUrl();
  const httpUrl = getLiveKitHttpUrl();
  const apiKey = env('LIVEKIT_API_KEY');
  const apiSecret = env('LIVEKIT_API_SECRET');
  initFirebaseIfPossible();
  res.json({ 
    status: 'ok', 
    message: 'Livekit Token Server is running',
    timestamp: new Date().toISOString(),
    deploy: {
      node: process.version,
      render: {
        gitCommit: process.env.RENDER_GIT_COMMIT || null,
        gitBranch: process.env.RENDER_GIT_BRANCH || null,
        serviceId: process.env.RENDER_SERVICE_ID || null,
        serviceName: process.env.RENDER_SERVICE_NAME || null,
        externalUrl: process.env.RENDER_EXTERNAL_URL || null,
        region: process.env.RENDER_REGION || null,
        instanceId: process.env.RENDER_INSTANCE_ID || null,
      },
    },
    sdkVersion: getSdkVersion(),
    firebase: {
      initialized: firebaseInitialized,
      configured: firebaseInitialized && !firebaseInitError,
      projectId: firebaseProjectIdHint,
      clientEmail: firebaseClientEmailHint,
      initError: firebaseInitError ? firebaseInitError.message : null,
    },
    livekit: {
      wsUrl: wsUrl || null,
      httpUrl: httpUrl || null,
      agentName: getAgentName(),
      apiKeyPrefix: apiKey ? apiKey.slice(0, 6) : null,
      apiKeyLength: apiKey ? apiKey.length : 0,
      apiSecretLength: apiSecret ? apiSecret.length : 0,
    },
  });
});

/**
 * Start a voice session (recommended for mobile)
 * POST /api/voice/start
 * Body: { roomName?: string, participantName?: string, metadata?: string }
 * Returns: { roomName, participantName, token, url }
 */
app.post('/api/voice/start', async (req, res) => {
  try {
    const env = validateLiveKitEnv(res);
    if (!env) return;

    const agentName = getAgentName();
    const httpUrl = getLiveKitHttpUrl();

    const roomName = req.body.roomName || `square15-voice-${Date.now()}`;
    const participantName =
      req.body.participantName || `user-${Date.now()}`;
    const metadata = typeof req.body.metadata === 'string' ? req.body.metadata : '';

    // 1) Generate access token (server-side)
    const at = new AccessToken(env.apiKey, env.apiSecret, {
      identity: participantName,
      name: participantName,
      metadata,
    });

    at.addGrant({
      room: roomName,
      roomJoin: true,
      canPublish: true,
      canSubscribe: true,
      canPublishData: true,
    });

    const token = await at.toJwt();

    // 2) Explicitly dispatch the agent to the room
    const dispatchClient = new AgentDispatchClient(httpUrl, env.apiKey, env.apiSecret);
    const dispatch = await dispatchClient.createDispatch(roomName, agentName, {
      metadata: metadata || undefined,
    });

    console.log(`✅ Session started. room=${roomName} user=${participantName} agent=${agentName}`);

    res.json({
      roomName,
      participantName,
      token,
      url: env.wsUrl,
      agentName,
      dispatch,
    });
  } catch (error) {
    console.error('❌ Error starting voice session:', error);
    res.status(500).json({
      error: 'Voice session start failed',
      message: error && error.message ? error.message : 'Unknown error',
      hint: isLiveKitInvalidTokenError(error)
        ? 'LiveKit returned an auth error. Most commonly the backend LIVEKIT_API_KEY/LIVEKIT_API_SECRET do not match the LiveKit project URL, or they do not match each other. Compare the backend /health apiKeyPrefix/apiKeyLength/apiSecretLength with the worker service values, or rotate the key/secret in LiveKit Cloud and update BOTH services.'
        : undefined,
      debug: {
        sdkVersion: getSdkVersion(),
        livekit: {
          wsUrl: getLiveKitWsUrl() || null,
          httpUrl: getLiveKitHttpUrl() || null,
          agentName: getAgentName(),
        },
      },
    });
  }
});

/**
 * Generate Livekit Access Token
 * POST /api/token
 * Body: { roomName: string, participantName: string, metadata?: string }
 */
app.post('/api/token', async (req, res) => {
  try {
    const { roomName, participantName, metadata } = req.body;

    // Validate required fields
    if (!roomName || !participantName) {
      return res.status(400).json({
        error: 'Missing required fields',
        message: 'roomName and participantName are required'
      });
    }

    const env = validateLiveKitEnv(res);
    if (!env) return;

    // Create access token
    const at = new AccessToken(
      env.apiKey,
      env.apiSecret,
      {
        identity: participantName,
        name: participantName,
        metadata: metadata || '',
      }
    );

    // Grant permissions
    at.addGrant({
      room: roomName,
      roomJoin: true,
      canPublish: true,
      canSubscribe: true,
      canPublishData: true,
    });

    // Generate JWT token
    const token = await at.toJwt();

    console.log(`✅ Token generated for ${participantName} in room ${roomName}`);

    res.json({
      token: token,
      url: env.wsUrl,
      roomName: roomName,
      participantName: participantName
    });

  } catch (error) {
    console.error('❌ Error generating token:', error);
    res.status(500).json({
      error: 'Token generation failed',
      message: error.message
    });
  }
});

/**
 * Create a new AI voice agent room
 * POST /api/create-room
 * Body: { roomName?: string }
 */
app.post('/api/create-room', async (req, res) => {
  try {
    const roomName = req.body.roomName || `voice-assistant-${Date.now()}`;
    
    res.json({
      roomName: roomName,
      url: getLiveKitWsUrl(),
      message: 'Room created successfully'
    });

  } catch (error) {
    console.error('❌ Error creating room:', error);
    res.status(500).json({
      error: 'Room creation failed',
      message: error.message
    });
  }
});

/**
 * Dispatch agent to room
 * POST /api/dispatch-agent
 * Body: { roomName: string }
 */
app.post('/api/dispatch-agent', async (req, res) => {
  try {
    const { roomName, metadata } = req.body;

    if (!roomName) {
      return res.status(400).json({
        error: 'Missing roomName',
        message: 'roomName is required'
      });
    }

    const env = validateLiveKitEnv(res);
    if (!env) return;

    const agentName = getAgentName();
    const httpUrl = getLiveKitHttpUrl();
    const dispatchClient = new AgentDispatchClient(httpUrl, env.apiKey, env.apiSecret);
    const dispatch = await dispatchClient.createDispatch(roomName, agentName, {
      metadata: typeof metadata === 'string' ? metadata : undefined,
    });

    console.log(`✅ Agent dispatched to room: ${roomName} (agent=${agentName})`);
    res.json({
      success: true,
      roomName,
      agentName,
      dispatch,
      message: 'Agent dispatched successfully'
    });

  } catch (error) {
    console.error('❌ Error dispatching agent:', error);
    res.status(500).json({
      error: 'Agent dispatch failed',
      message: error && error.message ? error.message : 'Unknown error',
      hint: isLiveKitInvalidTokenError(error)
        ? 'LiveKit returned an auth error. Ensure backend LIVEKIT_API_KEY and LIVEKIT_API_SECRET are correct for this LiveKit Cloud project and that there are no hidden quotes/spaces. If the worker registers but backend fails, the backend env vars are likely different.'
        : undefined,
      debug: {
        sdkVersion: getSdkVersion(),
        livekit: {
          wsUrl: getLiveKitWsUrl() || null,
          httpUrl: getLiveKitHttpUrl() || null,
          agentName: getAgentName(),
        },
      },
    });
  }
});

/**
 * Secure assistant action execution
 * POST /api/action/execute
 * Headers: Authorization: Bearer <Firebase ID Token>
 * Optional: Idempotency-Key: <string>
 * Body: { action: string, payload: object, context?: object }
 */
app.post('/api/action/execute', async (req, res) => {
  const startedAt = nowIso();
  const idempotencyKey = getIdempotencyKey(req);
  const validation = validateActionExecuteBody(req.body);
  const action = validation.action;
  const payload = validation.payload;
  const context = validation.context;

  const firestore = requireFirebase(res);
  if (!firestore) return;

  const decoded = await verifyFirebaseAuth(req, res);
  if (!decoded) return;

  if (!validation.ok) {
    return res.status(400).json({
      error: 'invalid_request',
      message: 'Request validation failed',
      idempotencyKey,
      details: validation.errors,
    });
  }

  const actorUid = decoded.uid;
  const actorRole = normalizeRole(decoded);
  if (!isAllowedRole(actorRole)) {
    return res.status(403).json({
      error: 'forbidden',
      message: 'Role is not allowed to perform actions',
      idempotencyKey,
    });
  }

  const policy = ensureActionAllowed({ action, actorRole });
  if (!policy.ok) {
    return res.status(policy.status).json({
      error: policy.error,
      message: 'Action not permitted',
      idempotencyKey,
    });
  }

  const requestHash = sha256Hex(
    stableStringify({
      v: 1,
      actor_uid: actorUid,
      action,
      payload,
      context,
    })
  );

  const prefer = String(req.headers.prefer || '').toLowerCase();
  const wantsAsync = prefer.includes('respond-async') || String(req.query.async || '').trim() === '1';

  const auditRef = firestore.collection('assistant_action_audit').doc(idempotencyKey);
  const existing = await auditRef.get();
  if (existing.exists) {
    const data = existing.data() || {};
    if (data.status === 'success') {
      if (data.request_hash && String(data.request_hash) !== requestHash) {
        return res.status(409).json({
          error: 'idempotency_key_mismatch',
          message: 'Idempotency-Key was already used for a different request',
          idempotencyKey,
        });
      }
      return res.json({
        ok: true,
        success: true,
        idempotencyKey,
        action,
        reused: true,
        data: data.result || null,
        result: data.result || null,
      });
    }
    if (data.status === 'started') {
      return res.status(wantsAsync ? 202 : 409).json({
        error: 'duplicate_in_flight',
        message: 'This action is already being processed',
        idempotencyKey,
      });
    }
  }

  const auditBase = {
    id: idempotencyKey,
    created_at: startedAt,
    updated_at: startedAt,
    status: 'started',
    action,
    actor_uid: actorUid,
    actor_role: actorRole,
    booking_id: normalizeBookingId(payload) || null,
    request_hash: requestHash,
    context,
    payload,
  };

  await writeAudit({ firestore, auditId: idempotencyKey, audit: auditBase });

  if (wantsAsync) {
    const jobRef = firestore.collection('assistant_action_jobs').doc(idempotencyKey);
    const jobDoc = {
      id: idempotencyKey,
      created_at: startedAt,
      updated_at: startedAt,
      status: 'queued',
      action,
      actor_uid: actorUid,
      actor_role: actorRole,
      request_hash: requestHash,
      booking_id: normalizeBookingId(payload) || null,
      attempts: 0,
      payload,
      context,
    };
    await jobRef.set(jobDoc, { merge: true });

    setImmediate(() => {
      processActionJob({ jobId: idempotencyKey }).catch((e) => {
        console.error('❌ Background job processing failed:', e && e.message ? e.message : e);
      });
    });

    return res.status(202).json({
      ok: true,
      accepted: true,
      idempotencyKey,
      action,
      job: { id: idempotencyKey, status: 'queued' },
      poll: `/api/action/job/${encodeURIComponent(idempotencyKey)}`,
    });
  }

  try {
    const result = await executeAction({
      firestore,
      action,
      actorUid,
      actorRole,
      payload,
      context,
    });

    if (!result.ok) {
      await writeAudit({
        firestore,
        auditId: idempotencyKey,
        audit: {
          status: 'error',
          updated_at: nowIso(),
          error: result.error,
          http_status: result.status,
          response_hash: sha256Hex(stableStringify({ ok: false, error: result.error, status: result.status })),
        },
      });
      return res.status(result.status).json({
        error: result.error,
        message: 'Action failed',
        idempotencyKey,
      });
    }

    await writeAudit({
      firestore,
      auditId: idempotencyKey,
      audit: {
        status: 'success',
        updated_at: nowIso(),
        completed_at: nowIso(),
        booking_id: normalizeBookingId(result.data) || normalizeBookingId(payload) || null,
        result: result.data || null,
        response_hash: sha256Hex(stableStringify({ ok: true, data: result.data || null })),
      },
    });

    return res.json({
      ok: true,
      success: true,
      idempotencyKey,
      action,
      data: result.data || null,
      result: result.data || null,
    });
  } catch (e) {
    await writeAudit({
      firestore,
      auditId: idempotencyKey,
      audit: {
        status: 'error',
        updated_at: nowIso(),
        completed_at: nowIso(),
        error: 'exception',
        exception_message: e && e.message ? String(e.message) : String(e),
      },
    });
    return res.status(500).json({
      error: 'internal_error',
      message: 'Action execution failed',
      idempotencyKey,
    });
  }
});

async function processActionJob({ jobId }) {
  const firestore = getFirestoreOrNull();
  if (!firestore) return;

  const jobRef = firestore.collection('assistant_action_jobs').doc(jobId);

  const claim = await firestore.runTransaction(async (tx) => {
    const snap = await tx.get(jobRef);
    if (!snap.exists) return { ok: false, reason: 'missing' };
    const job = snap.data() || {};
    if (job.status === 'success' || job.status === 'error') return { ok: false, reason: 'done', job };
    if (job.status !== 'queued' && job.status !== 'started') return { ok: false, reason: 'invalid', job };

    const attempts = Number(job.attempts || 0) + 1;
    tx.update(jobRef, { status: 'started', attempts, updated_at: nowIso(), started_at: job.started_at || nowIso() });
    return { ok: true, job: { ...job, attempts } };
  });

  if (!claim.ok) return;

  const job = claim.job;
  try {
    const result = await executeAction({
      firestore,
      action: job.action,
      actorUid: job.actor_uid,
      actorRole: job.actor_role,
      payload: job.payload,
      context: job.context,
    });

    if (!result.ok) {
      await jobRef.set(
        {
          status: 'error',
          updated_at: nowIso(),
          completed_at: nowIso(),
          error: result.error,
          http_status: result.status,
          response_hash: sha256Hex(stableStringify({ ok: false, error: result.error, status: result.status })),
        },
        { merge: true }
      );

      await writeAudit({
        firestore,
        auditId: jobId,
        audit: {
          status: 'error',
          updated_at: nowIso(),
          completed_at: nowIso(),
          error: result.error,
          http_status: result.status,
          response_hash: sha256Hex(stableStringify({ ok: false, error: result.error, status: result.status })),
        },
      });
      return;
    }

    const bookingId = normalizeBookingId(result.data) || normalizeBookingId(job.payload) || null;

    await jobRef.set(
      {
        status: 'success',
        updated_at: nowIso(),
        completed_at: nowIso(),
        booking_id: bookingId,
        result: result.data || null,
        response_hash: sha256Hex(stableStringify({ ok: true, data: result.data || null })),
      },
      { merge: true }
    );

    await writeAudit({
      firestore,
      auditId: jobId,
      audit: {
        status: 'success',
        updated_at: nowIso(),
        completed_at: nowIso(),
        booking_id: bookingId,
        result: result.data || null,
        response_hash: sha256Hex(stableStringify({ ok: true, data: result.data || null })),
      },
    });
  } catch (e) {
    await jobRef.set(
      {
        status: 'error',
        updated_at: nowIso(),
        completed_at: nowIso(),
        error: 'exception',
        exception_message: e && e.message ? String(e.message) : String(e),
      },
      { merge: true }
    );

    await writeAudit({
      firestore,
      auditId: jobId,
      audit: {
        status: 'error',
        updated_at: nowIso(),
        completed_at: nowIso(),
        error: 'exception',
        exception_message: e && e.message ? String(e.message) : String(e),
      },
    });
  }
}

app.get('/api/action/job/:id', async (req, res) => {
  const firestore = requireFirebase(res);
  if (!firestore) return;

  const decoded = await verifyFirebaseAuth(req, res);
  if (!decoded) return;

  const actorUid = decoded.uid;
  const actorRole = normalizeRole(decoded);
  const jobId = String(req.params.id || '').trim();
  if (!jobId) {
    return res.status(400).json({ error: 'invalid_request', message: 'Missing job id' });
  }

  const snap = await firestore.collection('assistant_action_jobs').doc(jobId).get();
  if (!snap.exists) {
    return res.status(404).json({ error: 'not_found', message: 'Job not found' });
  }
  const job = snap.data() || {};
  if (job.actor_uid !== actorUid && actorRole !== 'admin') {
    return res.status(403).json({ error: 'forbidden', message: 'Not allowed to read this job' });
  }
  return res.json({ ok: true, job });
});

function requireAdminRole(decoded, res) {
  const role = normalizeRole(decoded);
  if (role !== 'admin') {
    res.status(403).json({ error: 'forbidden', message: 'Admin role required' });
    return null;
  }
  return role;
}

app.get('/api/admin/audit/:id', async (req, res) => {
  const firestore = requireFirebase(res);
  if (!firestore) return;
  const decoded = await verifyFirebaseAuth(req, res);
  if (!decoded) return;
  if (!requireAdminRole(decoded, res)) return;

  const id = String(req.params.id || '').trim();
  const snap = await firestore.collection('assistant_action_audit').doc(id).get();
  if (!snap.exists) return res.status(404).json({ error: 'not_found', message: 'Audit not found' });
  return res.json({ ok: true, audit: snap.data() || null });
});

app.get('/api/admin/jobs/:id', async (req, res) => {
  const firestore = requireFirebase(res);
  if (!firestore) return;
  const decoded = await verifyFirebaseAuth(req, res);
  if (!decoded) return;
  if (!requireAdminRole(decoded, res)) return;

  const id = String(req.params.id || '').trim();
  const snap = await firestore.collection('assistant_action_jobs').doc(id).get();
  if (!snap.exists) return res.status(404).json({ error: 'not_found', message: 'Job not found' });
  return res.json({ ok: true, job: snap.data() || null });
});

app.post('/api/admin/jobs/process-next', async (req, res) => {
  const firestore = requireFirebase(res);
  if (!firestore) return;
  const decoded = await verifyFirebaseAuth(req, res);
  if (!decoded) return;
  if (!requireAdminRole(decoded, res)) return;

  const limit = Math.min(Math.max(Number(req.query.limit || 1) || 1, 1), 10);
  const qs = await firestore
    .collection('assistant_action_jobs')
    .where('status', '==', 'queued')
    .limit(limit)
    .get();

  const jobIds = qs.docs.map((d) => d.id);
  for (const id of jobIds) {
    // sequential to reduce contention
    await processActionJob({ jobId: id });
  }

  return res.json({ ok: true, processed: jobIds.length, jobIds });
});

// Error handling middleware
app.use((err, req, res, next) => {
  console.error('❌ Server error:', err);
  res.status(500).json({
    error: 'Internal server error',
    message: err.message
  });
});

// 404 handler
app.use((req, res) => {
  res.status(404).json({
    error: 'Not found',
    message: 'The requested endpoint does not exist'
  });
});

// Export app for serverless/tests
module.exports = app;
module.exports._internals = {
  stableStringify,
  sha256Hex,
  normalizeRole,
  isAllowedRole,
  ensureActionAllowed,
};

// Start server only when executed directly (node server.js)
if (require.main === module) {
  app.listen(PORT, () => {
    console.log('🚀 Square 15 Livekit Backend');
    console.log(`📡 Server running on port ${PORT}`);
    console.log(`🌐 Health check: http://localhost:${PORT}/health`);
    console.log(`🔑 Token endpoint: http://localhost:${PORT}/api/token`);
    console.log(`🧠 Voice start endpoint: http://localhost:${PORT}/api/voice/start`);
    console.log(`📦 Environment: ${process.env.NODE_ENV}`);
    console.log('✅ Server ready to accept requests\n');
  });
}
