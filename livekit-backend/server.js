const express = require('express');
const cors = require('cors');
const { AccessToken, AgentDispatchClient } = require('livekit-server-sdk');
const admin = require('firebase-admin');
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
app.use(express.json());

function nowIso() {
  return new Date().toISOString();
}

function randomId(prefix = '') {
  const id = crypto.randomUUID();
  return prefix ? `${prefix}${id}` : id;
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

async function executeBookingAction({ firestore, action, actorUid, actorRole, payload }) {
  if (action !== 'create_order_booking') {
    return { ok: false, status: 400, error: 'unsupported_action' };
  }

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
    artisan_confirmed: isRFQFlag ? 'pending' : 'pending',
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
  const action = normalizeAction(req.body && req.body.action);
  const payload = (req.body && typeof req.body.payload === 'object' && req.body.payload) || {};
  const context = (req.body && typeof req.body.context === 'object' && req.body.context) || {};

  const firestore = requireFirebase(res);
  if (!firestore) return;

  const decoded = await verifyFirebaseAuth(req, res);
  if (!decoded) return;

  const actorUid = decoded.uid;
  const actorRole = String(decoded.role || decoded.user_role || decoded.user_type || 'client').trim().toLowerCase();

  const auditRef = firestore.collection('assistant_action_audit').doc(idempotencyKey);
  const existing = await auditRef.get();
  if (existing.exists) {
    const data = existing.data() || {};
    if (data.status === 'success') {
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
      return res.status(409).json({
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
    context,
    payload,
  };

  await writeAudit({ firestore, auditId: idempotencyKey, audit: auditBase });

  try {
    const result = await executeBookingAction({
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
        result: result.data || null,
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
