/**
 * REAL E2E test for Lizzy VOICE pipeline auth + token issuance + agent dispatch.
 * Drives /api/voice/start exactly as the Flutter app does, then validates the
 * returned LiveKit access token structure. (Actual WebRTC audio would need
 * the LiveKit Node SDK + microphone simulation — out of scope here.)
 */
const WA_BOT = process.env.WA_BOT_URL || 'https://square15-whatsapp-bot.onrender.com';
const LK = process.env.LK_URL || 'https://square15-livekit-backend.onrender.com';
const SECRET = process.env.INTERNAL_API_SECRET;
if (!SECRET) {
  console.error('FATAL: INTERNAL_API_SECRET env var not set. Export it before running this test.');
  process.exit(1);
}
const UID = process.env.TEST_UID || 'ANulx1ZGL4gskDZzK64VwdR8B3a2';

function decodeJwtPayload(jwt) {
  const parts = jwt.split('.');
  if (parts.length < 2) return null;
  const buf = Buffer.from(parts[1].replace(/-/g, '+').replace(/_/g, '/'), 'base64');
  return JSON.parse(buf.toString('utf8'));
}

async function mintIdToken() {
  const r = await fetch(`${WA_BOT}/debug/mint-id-token`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'x-internal-secret': SECRET },
    body: JSON.stringify({ uid: UID }),
  });
  const j = await r.json();
  if (!r.ok || !j.idToken) throw new Error('mint failed: ' + JSON.stringify(j));
  return j.idToken;
}

async function voiceStart(authHeader, body = {}) {
  const headers = { 'Content-Type': 'application/json' };
  if (authHeader) headers.Authorization = authHeader;
  const r = await fetch(`${LK}/api/voice/start`, {
    method: 'POST', headers, body: JSON.stringify(body),
  });
  const txt = await r.text();
  let j = null; try { j = JSON.parse(txt); } catch (_) {}
  return { status: r.status, body: j || txt };
}

const results = [];
function record(name, ok, detail) {
  results.push({ name, ok, detail });
  console.log(`${ok ? '✓' : '✗'} ${name}${detail ? '  — ' + detail : ''}`);
}

async function main() {
  // 1) Security: no auth → 401
  {
    const r = await voiceStart(null, { roomName: 'sec-test-noauth' });
    record('no-auth → 401', r.status === 401, `status=${r.status}`);
  }

  // 2) Security: garbage bearer → 401
  {
    const r = await voiceStart('Bearer garbage.token.here', { roomName: 'sec-test-bad' });
    record('bad-token → 401', r.status === 401, `status=${r.status}`);
  }

  // 3) Mint real ID token
  let token;
  try { token = await mintIdToken(); record('mint Firebase ID token', true, `uid=${UID}`); }
  catch (e) { record('mint Firebase ID token', false, e.message); console.log(results); process.exit(1); }

  // 4) Real auth → 200 + LiveKit room + access token
  let voiceSession;
  {
    const r = await voiceStart(`Bearer ${token}`, { roomName: `voice-e2e-${Date.now()}` });
    voiceSession = r.body;
    const ok = r.status === 200 && r.body && r.body.token && r.body.roomName && r.body.url;
    record('valid-token → 200 + LiveKit token', ok,
      ok ? `room=${r.body.roomName} url=${r.body.url}` : `status=${r.status} body=${JSON.stringify(r.body).slice(0, 200)}`);
    if (!ok) { process.exit(1); }
  }

  // 5) Validate the issued LiveKit JWT shape
  {
    const payload = decodeJwtPayload(voiceSession.token);
    const ok = payload && payload.video && payload.video.room === voiceSession.roomName && payload.video.roomJoin === true;
    record('LiveKit JWT has room-bound grants', ok,
      ok ? `sub=${payload.sub} room=${payload.video.room} agent=${payload.video.agent || 'n/a'}` : JSON.stringify(payload).slice(0, 300));
    // identity must be bound to firebase uid (security)
    record('LiveKit JWT identity bound to firebase uid', payload && payload.sub && payload.sub.includes(UID.slice(0, 6)),
      `sub=${payload && payload.sub}`);
  }

  // 6) Voice-start with oversized roomName → 400
  {
    const big = 'x'.repeat(200);
    const r = await voiceStart(`Bearer ${token}`, { roomName: big });
    record('oversized roomName → 400', r.status === 400, `status=${r.status}`);
  }

  // 7) Lizzy voice photo pipeline still resolvable
  {
    const r = await fetch(`${LK}/health`);
    const j = await r.json();
    record('livekit-backend healthy', r.ok && j.status === 'ok' && j.livekit && j.livekit.agentName === 'square15-voice-assistant',
      `agent=${j.livekit && j.livekit.agentName}`);
  }

  const pass = results.filter(r => r.ok).length;
  const fail = results.length - pass;
  console.log(`\n=== Lizzy voice E2E: pass=${pass} fail=${fail} of ${results.length} ===`);
  process.exit(fail ? 1 : 0);
}

main().catch(e => { console.error('fatal', e); process.exit(2); });
