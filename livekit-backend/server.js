const express = require('express');
const cors = require('cors');
const helmet = require('helmet');
const { AccessToken, AgentDispatchClient } = require('livekit-server-sdk');
const admin = require('firebase-admin');
const crypto = require('crypto');
const fs = require('fs');
const OpenAI = require('openai');
require('dotenv').config();

// ─── Prompt sanitization (prevent injection via user-supplied text) ───
function sanitizeForPrompt(text, maxLen = 500) {
  if (!text || typeof text !== 'string') return '';
  return text
    .replace(/[\x00-\x08\x0B\x0C\x0E-\x1F]/g, '') // strip control chars
    .replace(/\r\n|\r/g, '\n')                       // normalise line endings
    .slice(0, maxLen)
    .trim();
}

// ─── OpenAI (for AI RFQ quote generation) ───
let _openai = null;
function getOpenAI() {
  if (_openai) return _openai;
  const key = process.env.OPENAI_API_KEY;
  if (!key) { console.warn('[openai] No OPENAI_API_KEY set'); return null; }
  _openai = new OpenAI({ apiKey: key });
  return _openai;
}

// ─── Builders.co.za Real-Time Pricing (ported from Cloud Functions) ───

let _buildersBffCache = { fetchedAt: 0, ttlMs: 12 * 60 * 60 * 1000, value: null };

function _asString(v) { return v == null ? '' : String(v); }

function normalizeBuildersQuery(name) {
  let q = _asString(name);
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

async function fetchWithTimeout(url, { method = 'GET', headers, body, timeoutMs = 15000 } = {}) {
  const controller = new AbortController();
  const id = setTimeout(() => controller.abort(), timeoutMs);
  try {
    return await fetch(url, { method, headers, body, signal: controller.signal });
  } finally {
    clearTimeout(id);
  }
}

function extractLiters(s) {
  const lowerS = _asString(s).toLowerCase();
  const m = lowerS.match(/\b(\d{2,4})\s*(?:l|lt|litre|liter|litres|liters)\b/);
  if (!m) return null;
  const v = parseInt(m[1], 10);
  if (!Number.isFinite(v) || v < 40 || v > 600) return null;
  return v;
}

function buildersTokens(s) {
  const cleaned = _asString(s).toLowerCase().replace(/[()[\],]/g, ' ').replace(/[^a-z0-9\s./-]/g, ' ').replace(/\s+/g, ' ').trim();
  if (!cleaned) return [];
  return cleaned.split(' ').map(t => t.trim()).filter(t => t.length > 2);
}

function parseZarPrice(raw) {
  const s = _asString(raw);
  if (!s) return null;
  const cleaned = s.replace(/[^0-9,.]/g, '');
  if (!cleaned) return null;
  const normalized = cleaned.replace(/,/g, '');
  const v = parseFloat(normalized);
  return Number.isFinite(v) ? v : null;
}

function extractRetailPriceFromProductHtml(html) {
  const meta = html.match(/(product:price:amount|og:price:amount|twitter:data1)"\s+content="([0-9.,]+)"/i);
  if (meta && meta[2]) { const p = parseZarPrice(meta[2]); if (p && p > 0) return p; }
  const jsonLd = html.match(/"price"\s*:\s*"?([0-9]{1,3}(?:,[0-9]{3})*(?:\.[0-9]{2})?)"?/i);
  if (jsonLd && jsonLd[1]) { const p = parseZarPrice(jsonLd[1]); if (p && p > 0) return p; }
  const visible = html.match(/R\s*([0-9]{1,3}(?:,[0-9]{3})*(?:\.[0-9]{2})?)/);
  if (visible && visible[1]) { const p = parseZarPrice(visible[1]); if (p && p > 0) return p; }
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
      const formatted = v.formattedValue ?? v.formatted ?? v.display;
      const p1 = parseZarPrice(formatted);
      if (p1 && p1 > 0) return p1;
      if (typeof v.value === 'number') return v.value;
      const p2 = parseZarPrice(v.value); if (p2 && p2 > 0) return p2;
      if (typeof v.current === 'number') return v.current;
      const p3 = parseZarPrice(v.current); if (p3 && p3 > 0) return p3;
      if (typeof v.retail === 'number') return v.retail;
      const p4 = parseZarPrice(v.retail); if (p4 && p4 > 0) return p4;
      return null;
    }
    return null;
  };
  let p = fromAny(candidate);
  if (p && p > 0) return p;
  if (candidate && typeof candidate === 'object') {
    p = fromAny(candidate.retail) ?? fromAny(candidate.current) ?? fromAny(candidate.selling);
    if (p && p > 0) return p;
  }
  for (const k of ['formattedPrice', 'priceFormatted', 'sellingPrice', 'retailPrice', 'priceInclVat', 'price_incl_vat']) {
    p = parseZarPrice(item?.[k]); if (p && p > 0) return p;
  }
  return null;
}

async function getBuildersBffConfig() {
  const now = Date.now();
  if (now - _buildersBffCache.fetchedAt <= _buildersBffCache.ttlMs) return _buildersBffCache.value;
  try {
    const extractScriptSrcs = (htmlText) => {
      const out = [];
      const re = /\bsrc="([^"]+\.js[^"]*)"/gi;
      for (const m of htmlText.matchAll(re)) {
        const s = _asString(m[1]);
        if (!s || /googletagmanager|google-analytics|gtm\.js/i.test(s)) continue;
        out.push(s);
      }
      return [...new Set(out)];
    };
    const toAbs = (u) => { if (!u) return null; return u.startsWith('http') ? u : `https://www.builders.co.za${u.startsWith('/') ? '' : '/'}${u}`; };
    const bootstrapUrls = [
      'https://www.builders.co.za/',
      'https://www.builders.co.za/Plumbing-Bathroom-and-Kitchen/Geysers-and-Water-Heaters/Geysers/Kwikot-DSG-200-5-400KPA-Superline-Dual-Geyser-200-L/p/000000000000659070',
    ];
    let html = null;
    for (const u of bootstrapUrls) {
      const htmlResp = await fetchWithTimeout(u, { headers: buildersHeaders({ referer: 'https://www.builders.co.za/' }), timeoutMs: 20000 });
      if (!htmlResp.ok || _asString(htmlResp.url).includes('/blocked?')) continue;
      const text = await htmlResp.text();
      if (text) { html = text; break; }
    }
    if (!html) { _buildersBffCache = { ..._buildersBffCache, fetchedAt: now, value: null }; return null; }
    const scriptSrcs = extractScriptSrcs(html).map(toAbs).filter(Boolean);
    if (!scriptSrcs.length) { _buildersBffCache = { ..._buildersBffCache, fetchedAt: now, value: null }; return null; }
    const preferred = [...scriptSrcs].sort((a, b) => {
      const score = (u) => { const s = _asString(u); if (/\/main\.[a-z0-9]{8,40}\.js/i.test(s)) return 0; if (/runtimechunk~main\.[a-z0-9]{8,40}\.js/i.test(s)) return 2; if (/\.js$/i.test(s)) return 5; return 9; };
      return score(a) - score(b);
    });
    let hash = null, site = null;
    for (const jsUrl of preferred.slice(0, 12)) {
      const jsResp = await fetchWithTimeout(jsUrl, { headers: buildersHeaders({ referer: 'https://www.builders.co.za/' }), timeoutMs: 25000 });
      if (!jsResp.ok) continue;
      const js = await jsResp.text();
      if (!js) continue;
      const hashMatch = js.match(/SearchHash\s*=\s*"([a-f0-9]{32,80})"/i) || js.match(/\/wmapi\/bff\/graphql\/search\/([a-f0-9]{32,80})/i);
      hash = hashMatch ? hashMatch[1] : null;
      const siteMatch = js.match(/BFF_SITE_VALUE\s*=\s*"([A-Z0-9]{3,10})"/);
      site = siteMatch ? siteMatch[1] : null;
      if (hash) break;
    }
    if (!hash) { _buildersBffCache = { ..._buildersBffCache, fetchedAt: now, value: null }; return null; }
    const cfg = { searchKey: 'search', searchHash: hash, site: site || 'BWH1' };
    _buildersBffCache = { ..._buildersBffCache, fetchedAt: now, value: cfg };
    return cfg;
  } catch (e) {
    console.error('[builders] BFF config fetch failed:', e.message);
    _buildersBffCache = { ..._buildersBffCache, fetchedAt: now, value: null };
    return null;
  }
}

async function hydrateCandidateFromProductPage(candidate, { referer } = {}) {
  try {
    const resp = await fetchWithTimeout(candidate.url, { headers: buildersHeaders({ referer }), timeoutMs: 20000 });
    if (!resp.ok) return null;
    const html = await resp.text();
    const price = extractRetailPriceFromProductHtml(html);
    if (!price || price <= 0) return null;
    const og = html.match(/property="og:title"\s+content="([^"]{3,200})"/i);
    const title = og && og[1] ? og[1] : candidate.title;
    return { ...candidate, title, priceZar: price };
  } catch (e) { console.warn('\u26a0\ufe0f buildersProductPage fetch:', e.message); return null; }
}

async function lookupBuildersPriceOne(rawName) {
  const q = normalizeBuildersQuery(rawName);
  if (!q) return null;
  const targetLiters = extractLiters(q);
  const wantsKwikot = q.toLowerCase().includes('kwikot');
  const cfg = await getBuildersBffConfig();
  if (!cfg) return null;
  const uri = `https://www.builders.co.za/wmapi/bff/graphql/${cfg.searchKey}/${cfg.searchHash}`;
  const variables = { keyword: q, offset: 0, pageSize: 20, dynamicPriceRange: true, site: cfg.site };
  let decoded;
  try {
    const resp = await fetchWithTimeout(uri, {
      method: 'POST',
      headers: buildersBffHeaders({ operationName: cfg.searchKey, operationHash: cfg.searchHash }),
      body: JSON.stringify({ variables }),
      timeoutMs: 12000,
    });
    if (!resp.ok) {
      if (resp.status === 412) return { title: '', url: '', priceZar: 0, source: 'builders_blocked', blocked: true };
      return null;
    }
    decoded = await resp.json();
  } catch (e) { console.warn('\u26a0\ufe0f buildersProductPrice JSON parse:', e.message); return null; }
  if (decoded?.redirectUrl && _asString(decoded.redirectUrl).includes('/blocked')) {
    return { title: '', url: '', priceZar: 0, source: 'builders_blocked', blocked: true };
  }
  const items = decoded?.data?.search?.data?.results?.items;
  if (!Array.isArray(items) || items.length === 0) return null;
  const qt = new Set(buildersTokens(q));
  const referer = `https://www.builders.co.za/search?text=${encodeURIComponent(q)}`;
  const scored = [];
  for (const it of items) {
    if (!it || typeof it !== 'object') continue;
    const title = _asString(it.name || it.title || it.productName);
    if (!title) continue;
    const liters = extractLiters(title);
    if (targetLiters != null && liters != null && liters !== targetLiters) continue;
    let urlPath = _asString(it.url || it.productUrl || it.seoUrl || it.link);
    if (!urlPath) { const code = _asString(it.code || it.id || it.productCode); if (code) urlPath = `/p/${code}`; }
    if (!urlPath) continue;
    const url = urlPath.startsWith('http') ? urlPath : `https://www.builders.co.za${urlPath.startsWith('/') ? '' : '/'}${urlPath}`;
    const tt = new Set(buildersTokens(title));
    let score = 0;
    for (const t of qt) if (tt.has(t)) score += 1;
    if (targetLiters != null) { if (liters === targetLiters) score += 6; if (liters == null) score -= 2; }
    const hasKwikot = title.toLowerCase().includes('kwikot');
    if (hasKwikot) score += 2;
    if (wantsKwikot && !hasKwikot) score -= 3;
    const price = extractPriceFromBffItem(it);
    const hasPrice = price != null && price > 0;
    if (hasPrice) score += 2;
    scored.push({ score, candidate: { title, url, priceZar: hasPrice ? price : 0, source: hasPrice ? 'builders_bff' : 'builders_bff_no_price' } });
  }
  if (!scored.length) return null;
  scored.sort((a, b) => (b.score || 0) - (a.score || 0));
  for (const row of scored.slice(0, 4)) {
    const c = row.candidate;
    if (c.priceZar && c.priceZar > 0) return c;
    const hydrated = await hydrateCandidateFromProductPage(c, { referer });
    if (!hydrated) continue;
    if (targetLiters != null) { const hl = extractLiters(hydrated.title); if (hl != null && hl !== targetLiters) continue; }
    return { ...hydrated, source: 'builders_bff_hydrated' };
  }
  return null;
}

async function buildersPriceLookupBatch(materialNames, concurrency = 4) {
  const results = new Array(materialNames.length);
  let i = 0;
  const workers = new Array(Math.min(concurrency, materialNames.length)).fill(0).map(async () => {
    while (true) {
      const idx = i++;
      if (idx >= materialNames.length) return;
      try { results[idx] = await lookupBuildersPriceOne(materialNames[idx]); } catch (e) { console.warn('\u26a0\ufe0f buildersPriceLookupBatch worker:', e.message); results[idx] = null; }
    }
  });
  await Promise.all(workers);
  return results;
}

async function lookupMaterialsCatalog(firestore, name) {
  if (!firestore || !name) return null;
  try {
    const normalized = name.toLowerCase().replace(/\s+/g, '_');
    // Try by doc ID
    let doc = await firestore.collection('materialsCatalog').doc(normalized).get();
    if (doc.exists) { const d = doc.data(); const p = parseFloat(d.unit_price || d.price_incl_vat || d.price || 0); if (p > 0) return { price: p, source: 'catalog_doc_id' }; }
    // Try by name_lower field
    let snap = await firestore.collection('materialsCatalog').where('name_lower', '==', normalized).limit(1).get();
    if (!snap.empty) { const d = snap.docs[0].data(); const p = parseFloat(d.unit_price || d.price_incl_vat || d.price || 0); if (p > 0) return { price: p, source: 'catalog_name_lower' }; }
    // Try by aliases
    snap = await firestore.collection('materialsCatalog').where('aliases', 'array-contains', name.toLowerCase()).limit(1).get();
    if (!snap.empty) { const d = snap.docs[0].data(); const p = parseFloat(d.unit_price || d.price_incl_vat || d.price || 0); if (p > 0) return { price: p, source: 'catalog_alias' }; }
  } catch (e) { console.error('[catalog] lookup error:', e.message); }
  return null;
}

async function getLearningFactor(firestore, categoryId, categoryName) {
  if (!firestore) return 1.0;
  try {
    const catSlug = (categoryId || categoryName || '').toLowerCase().replace(/\s+/g, '_');
    if (!catSlug) return 1.0;
    const snap = await firestore.collection('aiQuoteCorrections')
      .where('category_id', '==', catSlug)
      .orderBy('created_at', 'desc')
      .limit(20)
      .get();
    if (snap.empty) return 1.0;
    let total = 0, count = 0;
    snap.docs.forEach(doc => {
      const d = doc.data();
      const aiTotal = parseFloat(d.ai_total);
      const adminTotal = parseFloat(d.admin_total);
      if (aiTotal > 0 && adminTotal > 0) { total += adminTotal / aiTotal; count++; }
    });
    if (count === 0) return 1.0;
    const avg = total / count;
    return Math.max(0.6, Math.min(1.6, avg)); // Clamped [0.6, 1.6]
  } catch (e) {
    console.error('[learning-factor] error:', e.message);
    return 1.0;
  }
}

// ─── End Builders Pricing ───

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

function isEnvTruthy(name) {
  const v = env(name);
  if (v == null) return false;
  const s = String(v).trim().toLowerCase();
  return s === '1' || s === 'true' || s === 'yes' || s === 'y' || s === 'on';
}

const app = express();
const PORT = process.env.PORT || 3000;

// Render/Proxies: ensure req.ip and rate limiting work correctly.
if (isEnvTruthy('TRUST_PROXY')) {
  app.set('trust proxy', 1);
}

function parseIntEnv(name, fallback) {
  const raw = env(name);
  if (raw == null || String(raw).trim() === '') return fallback;
  const n = Number.parseInt(String(raw), 10);
  return Number.isFinite(n) ? n : fallback;
}

function getRequestId(req) {
  const incoming = req.headers['x-request-id'];
  const s = typeof incoming === 'string' ? incoming.trim() : '';
  if (s && s.length <= 128) return s;
  return randomId('req-');
}

function getClientIp(req) {
  const xf = req.headers['x-forwarded-for'];
  if (typeof xf === 'string' && xf.trim()) {
    return xf.split(',')[0].trim();
  }
  return req.ip || (req.socket && req.socket.remoteAddress) || '';
}

function createInMemoryRateLimiter({ windowMs, max, keyFn, name }) {
  const hits = new Map();
  const safeWindowMs = Math.max(1000, Number(windowMs) || 60_000);
  const safeMax = Math.max(1, Number(max) || 60);

  setInterval(() => {
    const now = Date.now();
    for (const [k, v] of hits.entries()) {
      if (!v || (now - v.windowStart) > safeWindowMs) {
        hits.delete(k);
      }
    }
  }, Math.min(safeWindowMs, 60_000)).unref?.();

  return (req, res, next) => {
    const key = String((keyFn ? keyFn(req) : '') || '').trim() || 'unknown';
    const now = Date.now();
    const entry = hits.get(key);
    if (!entry || (now - entry.windowStart) > safeWindowMs) {
      hits.set(key, { windowStart: now, count: 1 });
      return next();
    }
    entry.count += 1;
    if (entry.count > safeMax) {
      res.setHeader('Retry-After', String(Math.ceil((safeWindowMs - (now - entry.windowStart)) / 1000)));
      return res.status(429).json({
        error: 'rate_limited',
        message: `Too many requests${name ? ` (${name})` : ''}. Please try again shortly.`,
        request_id: req.requestId || null,
      });
    }
    return next();
  };
}

const jsonBodyLimit = env('JSON_BODY_LIMIT') || '1mb';
const corsOriginsRaw = env('ALLOWED_ORIGINS');
const corsOrigins = corsOriginsRaw
  ? corsOriginsRaw.split(',').map((s) => s.trim()).filter(Boolean)
  : '*';
const corsOriginOption = corsOrigins === '*' ? true : corsOrigins;

// Security headers
app.use(helmet({
  contentSecurityPolicy: false, // API server, no HTML
  crossOriginEmbedderPolicy: false,
}));

// Middleware
app.use(cors({
  origin: corsOriginOption,
  credentials: true,
  allowedHeaders: [
    'Content-Type',
    'Authorization',
    'Idempotency-Key',
    'X-Request-Id',
    'X-Firebase-AppCheck',
  ],
  exposedHeaders: ['x-request-id'],
}));
app.use(express.json({ limit: jsonBodyLimit }));

// Request tracing: propagate/generate x-request-id for observability.
app.use((req, res, next) => {
  const rid = getRequestId(req);
  req.requestId = rid;
  res.setHeader('x-request-id', rid);
  return next();
});

const assistantRateWindowMs = parseIntEnv('ASSISTANT_RATE_WINDOW_MS', 60_000);
const assistantRateMax = parseIntEnv('ASSISTANT_RATE_MAX', 120);
const adminRateWindowMs = parseIntEnv('ADMIN_RATE_WINDOW_MS', 60_000);
const adminRateMax = parseIntEnv('ADMIN_RATE_MAX', 240);

const assistantLimiter = createInMemoryRateLimiter({
  windowMs: assistantRateWindowMs,
  max: assistantRateMax,
  keyFn: (req) => `${getClientIp(req)}:${String(req.path || '')}`,
  name: 'assistant',
});

const adminLimiter = createInMemoryRateLimiter({
  windowMs: adminRateWindowMs,
  max: adminRateMax,
  keyFn: (req) => `${getClientIp(req)}:${String(req.path || '')}`,
  name: 'admin',
});

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
    } catch (e) {
      throw new Error('FIREBASE_SERVICE_ACCOUNT_JSON is not valid JSON');
    }
  }

  const filePath = env('FIREBASE_SERVICE_ACCOUNT_FILE');
  if (filePath) {
    try {
      const raw = fs.readFileSync(filePath, 'utf8');
      return JSON.parse(raw);
    } catch (e) {
      throw new Error('FIREBASE_SERVICE_ACCOUNT_FILE is not a readable JSON file');
    }
  }

  const b64 = env('FIREBASE_SERVICE_ACCOUNT_BASE64');
  if (b64) {
    try {
      const decoded = Buffer.from(b64, 'base64').toString('utf8');
      return JSON.parse(decoded);
    } catch (e) {
      throw new Error('FIREBASE_SERVICE_ACCOUNT_BASE64 is not valid base64 JSON');
    }
  }

  return null;
}

let firebaseInitialized = false;
let firebaseInitError = null;

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
        'Configure FIREBASE_SERVICE_ACCOUNT_JSON or FIREBASE_SERVICE_ACCOUNT_BASE64 in Render env vars for the livekit-backend service.',
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
    });
    return null;
  }
}

// Express middleware wrapper — verifyFirebaseAuth returns a value but never
// calls next(), so using it directly as middleware hangs the request.
function authMiddleware(req, res, next) {
  verifyFirebaseAuth(req, res).then(decoded => {
    if (!decoded) return; // response already sent by verifyFirebaseAuth
    req.user = decoded;
    next();
  }).catch(err => {
    console.error('❌ Auth middleware error:', err);
    if (!res.headersSent) res.status(500).json({ error: 'Internal auth error' });
  });
}

async function verifyFirebaseAppCheck(req, res, { required = false } = {}) {
  initFirebaseIfPossible();
  if (firebaseInitError) {
    if (required) {
      res.status(503).json({
        error: 'Firebase Admin not configured',
        message: firebaseInitError.message,
        request_id: req.requestId || null,
      });
      return null;
    }
    return { ok: false, reason: 'firebase_not_configured' };
  }

  const header = req.headers['x-firebase-appcheck'] || req.headers['X-Firebase-AppCheck'];
  const token = typeof header === 'string' ? header.trim() : '';
  if (!token) {
    if (required) {
      res.status(401).json({
        error: 'Unauthorized',
        message: 'Missing X-Firebase-AppCheck token',
        request_id: req.requestId || null,
      });
      return null;
    }
    return { ok: false, reason: 'missing' };
  }

  try {
    const decoded = await admin.appCheck().verifyToken(token);
    return { ok: true, decoded };
  } catch (e) {
    if (required) {
      res.status(401).json({
        error: 'Unauthorized',
        message: 'Invalid App Check token',
        request_id: req.requestId || null,
      });
      return null;
    }
    return { ok: false, reason: 'invalid' };
  }
}

async function resolveRole({ firestore, uid, decodedToken }) {
  // SECURITY: Only trust Firebase custom claims for admin role.
  // Firestore fallback is allowed for 'artisan' and 'client' but NOT 'admin'
  // to prevent privilege escalation via self-editable Firestore documents.
  const fromClaims =
    (decodedToken && (decodedToken.role || decodedToken.user_role || decodedToken.user_type)) ||
    '';
  const claimRole = String(fromClaims).trim().toLowerCase();
  if (claimRole === 'admin' || claimRole === 'artisan' || claimRole === 'client') return claimRole;

  try {
    const userSnap = await firestore.collection('users').doc(uid).get();
    if (userSnap.exists) {
      const data = userSnap.data() || {};

      // Check string role fields first
      const v =
        data.role ||
        data.user_role ||
        data.userType ||
        data.user_type ||
        data.type ||
        data.account_type;
      const r = String(v || '').trim().toLowerCase();
      // Only allow non-admin roles from Firestore to prevent privilege escalation
      if (r === 'artisan' || r === 'client') return r;
      // If Firestore says admin, require custom claims confirmation
      if (r === 'admin') {
        console.warn(`⚠️ User ${uid} has admin role in Firestore but NOT in custom claims — denying admin access`);
        return 'client';
      }

      // Check boolean flag schema (isAdmin, isServiceProvider, isUser)
      // This handles apps that use boolean flags instead of string roles.
      if (data.isAdmin === true) {
        console.warn(`⚠️ User ${uid} has isAdmin=true in Firestore but NOT in custom claims — denying admin access`);
        return 'client';
      }
      if (data.isServiceProvider === true) return 'artisan';
      if (data.isUser === true) return 'client';
    }
  } catch (e) {
    console.warn(`⚠️ Role lookup (users doc) failed for ${uid}:`, e.message);
  }

  // Fallback: check the serviceProvider collection — artisan profiles live
  // there keyed by UID (or linked via user_id/uid fields), not in 'users'.
  try {
    const spSnap = await firestore.collection('serviceProvider').doc(uid).get();
    if (spSnap.exists) return 'artisan';
    // Also try querying by user_id field in case doc ID differs from auth UID
    for (const field of ['user_id', 'uid', 'userId', 'provider_id']) {
      const q = await firestore.collection('serviceProvider').where(field, '==', uid).limit(1).get();
      if (!q.empty) return 'artisan';
    }
  } catch (e) {
    console.warn(`⚠️ Role lookup (serviceProvider) failed for ${uid}:`, e.message);
  }

  return 'client';
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
  return s || randomId('idem-');
}

function getIdempotencyKeyOr(req, fallback) {
  const k = req.headers['idempotency-key'] || req.headers['Idempotency-Key'];
  const s = typeof k === 'string' ? k.trim() : '';
  return s || String(fallback || '').trim() || randomId('idem-');
}

// Phase 1: action tiering + policy enforcement.
// Tier A = read-only; Tier B = normal state changes; Tier C = financial / high-risk (blocked unless you later add step-up + approvals).
const ACTION_TIERS = Object.freeze({
  get_booking_status: 'A',
  get_messages: 'A',
  list_user_bookings: 'A',
  list_my_bookings: 'A',
  get_booking_analytics: 'A',
  explain_rfq_quote: 'A',
  explain_quote: 'A',
  get_payment_status: 'A',
  check_payment: 'A',
  get_wallet_balance: 'A',
  get_case_status: 'A',
  lookup_service_pricing: 'A',
  list_services: 'A',
  get_transaction_history: 'A',
  get_deposit_requests: 'A',
  get_service_categories: 'A',
  get_notifications: 'A',
  get_scheduled_bookings: 'A',
  get_artisan_info: 'A',
  create_order_booking: 'B',
  create_order_booking_order: 'B',
  dispatch_artisan: 'B',
  cancel_booking: 'B',
  reschedule_booking: 'B',
  mark_booking_in_progress: 'B',
  request_reassignment: 'B',
  artisan_cancel_and_reassign: 'B',
  reassign_booking: 'B',
  send_message_to_artisan: 'B',
  send_message_to_client: 'B',
  send_message_to_admin: 'B',
  create_case: 'B',
  update_case: 'B',
  reply_to_case: 'B',
  list_my_cases: 'A',
  list_cases: 'A',
  check_sla_escalation: 'B',
  submit_rating: 'B',
  submit_complaint: 'B',
  // Phase 4: Admin automation tools (Tier B — admin role required)
  admin_bulk_reassign: 'B',
  admin_close_stale_cases: 'B',
  admin_broadcast_notification: 'B',
  admin_flag_user: 'B',
  // Phase 5.1: Finance read-only (Tier A)
  get_finance_summary: 'A',
  get_daily_revenue: 'A',
  get_failed_payments: 'A',
  get_refund_history: 'A',
  get_payout_status: 'A',
  get_fraud_alerts: 'A',
  // Phase 5.2: Money-moving (Tier C — requires approval pipeline)
  request_refund: 'C',
  request_wallet_adjustment: 'C',
  request_payout: 'C',
  request_fee_override: 'C',
  approve_finance_request: 'C',
  reject_finance_request: 'C',
});

function actionTier(action) {
  const a = normalizeAction(action);
  return ACTION_TIERS[a] || null;
}

function tierRank(t) {
  const s = String(t || '').trim().toUpperCase();
  if (s === 'A') return 1;
  if (s === 'B') return 2;
  if (s === 'C') return 3;
  return 99;
}

async function enforceAssistantSessionBinding({ firestore, req, actorUid, action, context, required }) {
  if (!required) return { ok: true, session: null };

  const sessionId = String(context.session_id || context.sessionId || '').trim();
  const sessionNonce = String(context.session_nonce || context.sessionNonce || '').trim();
  const roomName = String(context.room_name || context.roomName || '').trim();

  if (!sessionId || !sessionNonce) {
    return {
      ok: false,
      status: 400,
      error: 'missing_session_context',
      message: 'Missing context.session_id or context.session_nonce',
    };
  }

  const snap = await firestore.collection('assistant_voice_sessions').doc(sessionId).get();
  if (!snap.exists) {
    return {
      ok: false,
      status: 401,
      error: 'invalid_session',
      message: 'Unknown voice session',
    };
  }

  const session = snap.data() || {};
  if (String(session.uid || '').trim() !== actorUid) {
    return {
      ok: false,
      status: 403,
      error: 'session_uid_mismatch',
      message: 'Voice session is not owned by this user',
    };
  }

  if (String(session.session_nonce || '').trim() !== sessionNonce) {
    return {
      ok: false,
      status: 401,
      error: 'invalid_session_nonce',
      message: 'Invalid voice session nonce',
    };
  }

  if (session.revoked_at) {
    return {
      ok: false,
      status: 401,
      error: 'session_revoked',
      message: 'Voice session has been revoked',
    };
  }

  const exp = String(session.expires_at || '').trim();
  if (exp) {
    const expMs = Date.parse(exp);
    if (Number.isFinite(expMs) && Date.now() > expMs) {
      return {
        ok: false,
        status: 401,
        error: 'session_expired',
        message: 'Voice session expired',
      };
    }
  }

  if (roomName && session.room_name && String(session.room_name).trim() !== roomName) {
    return {
      ok: false,
      status: 401,
      error: 'session_room_mismatch',
      message: 'Voice session room mismatch',
    };
  }

  const allowed = session.allowed_actions;
  if (Array.isArray(allowed) && allowed.length > 0) {
    const norm = allowed.map((x) => String(x || '').trim().toLowerCase()).filter(Boolean);
    if (!norm.includes('*') && !norm.includes(action)) {
      return {
        ok: false,
        status: 403,
        error: 'action_not_allowed',
        message: 'Action not allowed for this voice session',
      };
    }
  }

  try {
    await firestore.collection('assistant_voice_sessions').doc(sessionId).set(
      { last_used_at: nowIso(), last_action: action, last_request_id: req.requestId || null },
      { merge: true }
    );
  } catch (e) { console.warn('\u26a0\ufe0f voice session metadata write:', e.message);
    // Best-effort only
  }

  return { ok: true, session };
}

async function writeAudit({ firestore, auditId, audit }) {
  await firestore.collection('assistant_action_audit').doc(auditId).set(audit, { merge: true });
}

async function executeBookingAction({ firestore, action, actorUid, actorRole, payload, context }) {
  const bookingId = normalizeBookingId(payload);
  const now = nowIso();

  let bookingRef = bookingId ? firestore.collection('futureBookings').doc(bookingId) : null;

  async function loadBooking() {
    if (!bookingRef) return null;
    const snap = await bookingRef.get();
    if (snap.exists) return snap.data() || {};

    // Fallback: try to find booking by order_no or rfq_no (user may provide short ID like "0519B50E")
    if (bookingId) {
      const candidates = [bookingId, `ORD-${bookingId}`, `RFQ-${bookingId}`, bookingId.toUpperCase()];
      for (const candidate of candidates) {
        for (const field of ['order_no', 'rfq_no']) {
          try {
            const q = await firestore.collection('futureBookings')
              .where(field, '==', candidate).limit(1).get();
            if (!q.empty) {
              bookingRef = q.docs[0].ref;
              return q.docs[0].data() || {};
            }
          } catch (e) { console.warn('\u26a0\ufe0f booking lookup by alt field:', e.message); }
        }
      }
    }
    return null;
  }

  // Helpers mirrored from app-side logic.
  function toNumber(v) {
    if (v == null) return null;
    if (typeof v === 'number') return v;
    const cleaned = String(v).trim().replace(/[^0-9.\-]/g, '');
    const n = Number.parseFloat(cleaned);
    return Number.isFinite(n) ? n : null;
  }

  function shortId(id, length = 8) {
    const trimmed = String(id || '').trim();
    if (!trimmed) return '';
    const safeLen = Math.min(32, Math.max(4, length));
    return trimmed.length <= safeLen ? trimmed.toUpperCase() : trimmed.slice(0, safeLen).toUpperCase();
  }

  // Format a Date as DD/MM/YYYY.
  function _todayDateStr(d) {
    d = d || new Date();
    const dd = String(d.getDate()).padStart(2, '0');
    const mm = String(d.getMonth() + 1).padStart(2, '0');
    const yyyy = d.getFullYear();
    return `${dd}/${mm}/${yyyy}`;
  }

  // Allocate a sequential daily counter for a given prefix (RFQ or ORD).
  async function _nextDailySeq(prefix) {
    const dateKey = _todayDateStr().replace(/\//g, '-'); // e.g. "06-03-2026"
    const counterRef = firestore.collection('metadata').doc('counters');
    let seq = 1;
    try {
      await firestore.runTransaction(async (tx) => {
        const snap = await tx.get(counterRef);
        let current = 0;
        if (snap.exists) {
          const data = snap.data() || {};
          const daily = data.dailyCounters || {};
          const prefixMap = daily[prefix] || {};
          if (prefixMap[dateKey] != null) {
            const raw = prefixMap[dateKey];
            current = typeof raw === 'number' ? raw : (parseInt(raw, 10) || 0);
          }
        }
        seq = current + 1;
        tx.set(counterRef, {
          dailyCounters: { [prefix]: { [dateKey]: seq } }
        }, { merge: true });
      });
    } catch (e) {
      console.warn(`⚠️ Counter increment failed for ${prefix}/${dateKey}: ${e.message}; using timestamp fallback`);
      seq = Date.now() % 1000 + 1;
    }
    return seq;
  }

  // Generate date-based RFQ number: RFQ-DD/MM/YYYY-NN
  async function generateDateBasedRfqNo() {
    const seq = await _nextDailySeq('RFQ');
    return `RFQ-${_todayDateStr()}-${String(seq).padStart(2, '0')}`;
  }

  // Generate date-based Order number: ORD-DD/MM/YYYY-NN
  async function generateDateBasedOrderNo() {
    const seq = await _nextDailySeq('ORD');
    return `ORD-${_todayDateStr()}-${String(seq).padStart(2, '0')}`;
  }

  // Legacy sync functions (kept as fallbacks)
  function generateOrderNo(id) {
    const s = shortId(id);
    return s ? `ORD-${s}` : '';
  }

  function generateRfqNo(id) {
    const s = shortId(id);
    return s ? `RFQ-${s}` : '';
  }

  function isTruthyExtended(value) {
    if (value === true) return true;
    if (value === false) return false;
    if (value == null) return false;
    if (typeof value === 'number') return value !== 0;
    const s = String(value).trim().toLowerCase();
    return ['true', 'yes', 'y', '1', 'active', 'online', 'available', 'on'].includes(s);
  }

  function isPublished(status) {
    const raw = String(status || '').trim();
    if (!raw) return true;
    const s = raw.toLowerCase();
    return s === 'publish' || s === 'published' || s === 'approved' || s === 'approve';
  }

  function isArtisanActive(artisanData) {
    const candidates = [
      artisanData && artisanData.isActive,
      artisanData && artisanData.active,
      artisanData && artisanData.is_active,
      artisanData && artisanData.online,
      artisanData && artisanData.is_online,
      artisanData && artisanData.availability,
      artisanData && artisanData.available,
      artisanData && artisanData.isAvailable,
      artisanData && artisanData.is_available,
      artisanData && artisanData.availability_status,
      artisanData && artisanData.status_online,
    ];

    let anyPresent = false;
    let anyTruthy = false;
    for (const v of candidates) {
      if (v == null) continue;
      const s = String(v).trim();
      if (!s) continue;
      anyPresent = true;
      if (isTruthyExtended(v)) {
        anyTruthy = true;
        break;
      }
    }
    if (!anyPresent) return true;
    return anyTruthy;
  }

  function extractLatLng(artisanData) {
    const tryParse = (v) => {
      if (v == null) return null;
      if (typeof v === 'number') return v;
      const n = Number.parseFloat(String(v));
      return Number.isFinite(n) ? n : null;
    };

    let lat =
      tryParse(artisanData && artisanData.lat) ??
      tryParse(artisanData && artisanData.latitude) ??
      tryParse(artisanData && artisanData.positionLat) ??
      tryParse(artisanData && artisanData.position_lat) ??
      0.0;
    let lng =
      tryParse(artisanData && artisanData.lng) ??
      tryParse(artisanData && artisanData.longitude) ??
      tryParse(artisanData && artisanData.positionLong) ??
      tryParse(artisanData && artisanData.positionLng) ??
      tryParse(artisanData && artisanData.position_long) ??
      tryParse(artisanData && artisanData.position_lng) ??
      0.0;

    const loc = artisanData && artisanData.location;
    if ((lat === 0.0 || lng === 0.0) && loc && typeof loc.latitude === 'number' && typeof loc.longitude === 'number') {
      lat = loc.latitude;
      lng = loc.longitude;
    }
    return { lat, lng };
  }

  function degreesToRadians(degrees) {
    return (degrees * Math.PI) / 180;
  }

  function calculateDistanceKm(lat1, lng1, lat2, lng2) {
    const earthRadius = 6371;
    const dLat = degreesToRadians(lat2 - lat1);
    const dLon = degreesToRadians(lng2 - lng1);
    const a =
      Math.sin(dLat / 2) * Math.sin(dLat / 2) +
      Math.cos(degreesToRadians(lat1)) *
        Math.cos(degreesToRadians(lat2)) *
        Math.sin(dLon / 2) *
        Math.sin(dLon / 2);
    const c = 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
    return earthRadius * c;
  }

  function parseDateParts(dateStr) {
    const raw = String(dateStr || '').trim();
    if (!raw) return null;
    const first = raw.split(' ')[0].trim();
    const normalized = first.replace(/\./g, '/').replace(/-/g, '/');
    const parts = normalized.split('/').map((p) => p.trim()).filter(Boolean);
    if (parts.length !== 3) return null;
    const a = parts[0];
    const b = parts[1];
    const c = parts[2];
    const n1 = Number.parseInt(a, 10);
    const n2 = Number.parseInt(b, 10);
    const n3 = Number.parseInt(c, 10);
    if (![n1, n2, n3].every((n) => Number.isFinite(n))) return null;
    if (a.length === 4) {
      return { y: n1, m: n2, d: n3 };
    }
    if (c.length === 4) {
      return { y: n3, m: n2, d: n1 };
    }
    return null;
  }

  function parseTimeParts(timeStr) {
    const raw = String(timeStr || '').trim();
    if (!raw) return null;
    const t = raw.split(' ')[0].trim();
    const parts = t.split(':').map((p) => p.trim()).filter(Boolean);
    if (parts.length < 2) return null;
    const hh = Number.parseInt(parts[0], 10);
    const mm = Number.parseInt(parts[1], 10);
    const ss = parts.length >= 3 ? Number.parseInt(parts[2], 10) : 0;
    if (![hh, mm, ss].every((n) => Number.isFinite(n))) return null;
    if (hh < 0 || hh > 23 || mm < 0 || mm > 59 || ss < 0 || ss > 59) return null;
    return { hh, mm, ss };
  }

  function parseScheduledDateTime(dateStr, timeValue) {
    const d = parseDateParts(dateStr);
    const t = parseTimeParts(timeValue);
    if (!d || !t) return null;
    return new Date(d.y, d.m - 1, d.d, t.hh, t.mm, t.ss, 0);
  }

  async function getServiceProviderDocByAnyId(idOrUid) {
    const key = String(idOrUid || '').trim();
    if (!key) return null;
    try {
      const doc = await firestore.collection('serviceProvider').doc(key).get();
      if (doc.exists) return doc;
    } catch (e) { console.warn('\u26a0\ufe0f getServiceProviderDoc direct fetch:', e.message);
      // ignore and try query fallbacks
    }

    async function tryField(field) {
      try {
        const snap = await firestore.collection('serviceProvider').where(field, '==', key).limit(1).get();
        if (snap.empty) return null;
        return snap.docs[0];
      } catch (e) { console.warn('\u26a0\ufe0f getServiceProviderDoc field query:', e.message);
        return null;
      }
    }

    return (await tryField('user_id')) || (await tryField('uid')) || (await tryField('userId')) || (await tryField('provider_id'));
  }

  function artisanHasTask({ artisanData, taskId, categoryId, categoryName }) {
    const matchesTaskId = (candidate) => {
      const c = String(candidate || '').trim();
      return c && c === taskId;
    };

    const rawTaskList = (artisanData && (artisanData.task_list || artisanData.tasks)) || null;
    if (Array.isArray(rawTaskList)) {
      for (const t of rawTaskList) {
        if (typeof t === 'string') {
          if (matchesTaskId(t)) return true;
        } else if (t && typeof t === 'object') {
          if (matchesTaskId(t.task_id)) return true;
          if (matchesTaskId(t.taskId)) return true;
          if (matchesTaskId(t.id)) return true;
        }
      }
    }

    if (categoryId && String(categoryId).trim()) {
      const cats = artisanData && (artisanData.category_ids || artisanData.categories || artisanData.categoryId || artisanData.category_id);
      if (typeof cats === 'string') {
        if (cats.trim() === String(categoryId).trim()) return true;
      } else if (Array.isArray(cats)) {
        for (const c of cats) {
          if (c != null && String(c).trim() === String(categoryId).trim()) return true;
        }
      }
    }

    if (categoryName && String(categoryName).trim()) {
      const prof = String((artisanData && (artisanData.profession || artisanData.trade)) || '').trim();
      if (prof && prof.toLowerCase().includes(String(categoryName).trim().toLowerCase())) return true;
    }
    return false;
  }

  async function candidateArtisanIdsForTask(taskId) {
    const t = String(taskId || '').trim();
    if (!t) return new Set();
    let snap = null;
    try {
      snap = await firestore.collection('userTasks').where('task_id', '==', t).get();
    } catch (e) { console.warn('\u26a0\ufe0f candidateArtisans task_id query:', e.message);
      snap = null;
    }

    if (!snap || snap.empty) {
      try {
        snap = await firestore.collection('userTasks').where('taskId', '==', t).get();
      } catch (e) { console.warn('\u26a0\ufe0f candidateArtisans taskId query:', e.message);
        snap = null;
      }
    }

    if (!snap || snap.empty) {
      try {
        const catSnap = await firestore.collection('userTasks').where('category_id', '==', t).get();
        if (!catSnap.empty) snap = catSnap;
      } catch (e) { console.warn('\u26a0\ufe0f candidateArtisans category_id query:', e.message);
        // ignore
      }
    }

    if (!snap || snap.empty) {
      try {
        const catSnap2 = await firestore.collection('userTasks').where('categoryId', '==', t).get();
        if (!catSnap2.empty) snap = catSnap2;
      } catch (e) { console.warn('\u26a0\ufe0f candidateArtisans categoryId query:', e.message);
        // ignore
      }
    }

    const ids = new Set();
    if (!snap || snap.empty) return ids;

    for (const doc of snap.docs) {
      const data = doc.data() || {};
      const status = data.status ?? data.state ?? data.publish_status;
      if (status != null && !isPublished(status)) continue;
      const candidates = [data.user_id, data.artisan_id, data.provider_id, data.service_provider_id, data.uid];
      for (const c of candidates) {
        const id = String(c || '').trim();
        if (id) ids.add(id);
      }
    }
    return ids;
  }

  async function checkArtisanAvailability({ artisanId, scheduledDate, scheduledTime, excludeBookingId }) {
    if (!String(scheduledDate || '').trim() || !String(scheduledTime || '').trim()) return true;
    let bookingsSnap;
    try {
      bookingsSnap = await firestore.collection('futureBookings').where('service_provider_id', '==', artisanId).get();
    } catch (e) { console.warn('\u26a0\ufe0f checkArtisanAvailability:', e.message);
      return true;
    }
    if (!bookingsSnap || bookingsSnap.empty) return true;

    const requestedDateTime = parseScheduledDateTime(scheduledDate, scheduledTime);
    if (!requestedDateTime) return true;

    for (const doc of bookingsSnap.docs) {
      if (excludeBookingId && String(doc.id).trim() === String(excludeBookingId).trim()) continue;
      const data = doc.data() || {};
      const status = String(data.status || '').trim().toLowerCase();
      if (status !== 'pending' && status !== 'confirmed') continue;
      const isRfq = String(data.is_rfq || '').trim().toLowerCase();
      if (isRfq === 'yes') continue;
      const bookedDate = String(data.scheduled_date || '').trim();
      if (bookedDate !== String(scheduledDate || '').trim()) continue;

      const bookedDateTime = parseScheduledDateTime(bookedDate, data.scheduled_time);
      if (!bookedDateTime) continue;
      const diffMs = Math.abs(requestedDateTime.getTime() - bookedDateTime.getTime());
      if (diffMs < 2 * 60 * 60 * 1000) {
        return false;
      }
    }
    return true;
  }

  async function findAvailableArtisanByLocation({
    taskId,
    scheduledDate,
    scheduledTime,
    userLat,
    userLng,
    excludeArtisanId,
    categoryId,
    categoryName,
    bookingId,
  }) {
    const clientLat = Number.parseFloat(String(userLat || '0')) || 0.0;
    const clientLng = Number.parseFloat(String(userLng || '0')) || 0.0;

    const availableWithDistance = [];
    const candidates = await candidateArtisanIdsForTask(taskId);

    if (candidates && candidates.size > 0) {
      for (const candidateId of candidates.values()) {
        const providerDoc = await getServiceProviderDocByAnyId(candidateId);
        if (!providerDoc || !providerDoc.exists) continue;
        const artisanDocId = providerDoc.id;
        if (excludeArtisanId && (artisanDocId === excludeArtisanId || candidateId === excludeArtisanId)) continue;
        const artisanData = providerDoc.data() || {};
        if (!isPublished(artisanData.status)) continue;
        if (!isArtisanActive(artisanData)) continue;
        const isAvail = await checkArtisanAvailability({
          artisanId: artisanDocId,
          scheduledDate,
          scheduledTime,
          excludeBookingId: bookingId,
        });
        if (!isAvail) continue;

        const coords = extractLatLng(artisanData);
        const aLat = coords.lat || 0.0;
        const aLng = coords.lng || 0.0;
        const distance = clientLat !== 0.0 && clientLng !== 0.0 && aLat !== 0.0 && aLng !== 0.0 ? calculateDistanceKm(clientLat, clientLng, aLat, aLng) : 9999.0;
        availableWithDistance.push({ artisan_id: artisanDocId, distance });
      }
    } else {
      let snap;
      try {
        snap = await firestore.collection('serviceProvider').where('status', '==', 'publish').limit(200).get();
        if (snap.empty) snap = await firestore.collection('serviceProvider').limit(200).get();
      } catch (e) { console.warn('\u26a0\ufe0f findAvailableArtisan fallback query:', e.message);
        snap = await firestore.collection('serviceProvider').limit(200).get();
      }

      for (const doc of snap.docs) {
        const artisanDocId = doc.id;
        if (excludeArtisanId && artisanDocId === excludeArtisanId) continue;
        const artisanData = doc.data() || {};
        if (!isPublished(artisanData.status)) continue;
        if (!isArtisanActive(artisanData)) continue;

        const hasTask = artisanHasTask({ artisanData, taskId, categoryId, categoryName });
        const acceptAnyway = !hasTask && categoryName && String(categoryName).trim();
        if (!hasTask && !acceptAnyway) continue;

        const isAvail = await checkArtisanAvailability({
          artisanId: artisanDocId,
          scheduledDate,
          scheduledTime,
          excludeBookingId: bookingId,
        });
        if (!isAvail) continue;

        const coords = extractLatLng(artisanData);
        const aLat = coords.lat || 0.0;
        const aLng = coords.lng || 0.0;
        const distance = clientLat !== 0.0 && clientLng !== 0.0 && aLat !== 0.0 && aLng !== 0.0 ? calculateDistanceKm(clientLat, clientLng, aLat, aLng) : 9999.0;
        availableWithDistance.push({ artisan_id: artisanDocId, distance });
      }
    }

    if (availableWithDistance.length === 0) return null;
    availableWithDistance.sort((a, b) => a.distance - b.distance);
    return String(availableWithDistance[0].artisan_id || '').trim() || null;
  }

  function stringList(v) {
    if (!v) return [];
    if (Array.isArray(v)) return v.map((e) => String(e)).filter((s) => s.trim());
    return [];
  }

  async function resolveTaskCost(taskId) {
    const t = String(taskId || '').trim();
    if (!t) return null;
    try {
      const doc = await firestore.collection('tasks').doc(t).get();
      if (!doc.exists) return null;
      const data = doc.data() || {};
      const amount = toNumber(data.cost ?? data.price ?? data.amount ?? data.unit_price);
      return amount && amount > 0 ? amount : null;
    } catch (e) { console.warn('\u26a0\ufe0f resolveTaskCost:', e.message);
      return null;
    }
  }

  async function writePersonalNotification({ userId, userType, title, message, data }) {
    return await _writeNotificationImpl({ userId, userType, title, message, data, sendPush: true });
  }

  async function writeAdminNotification({ title, message, data }) {
    // Write notification doc for admin UI
    await _writeNotificationImpl({
      userId: 'admin',
      userType: 'admin',
      title,
      message,
      data,
      sendPush: false,
    });

    // Also send FCM push to admin devices (enabled by default).
    {
      try {
        const adminSnap = await firestore.collection('users')
          .where('isAdmin', '==', true)
          .limit(10)
          .get();
        const tokens = [];
        const seen = new Set();
        for (const doc of adminSnap.docs) {
          for (const t of collectTokensFromDocData(doc.data() || {})) {
            if (!seen.has(t)) { seen.add(t); tokens.push(t); }
          }
        }
        if (tokens.length > 0) {
          await sendPushToTokens({
            tokens,
            title: String(title || '').trim(),
            body: String(message || '').trim(),
            data: {
              type: (data && data.type) ? String(data.type) : 'admin_notification',
              ...(data && typeof data === 'object' ? Object.fromEntries(
                Object.entries(data).filter(([k]) => k !== 'type').map(([k, v]) => [String(k), String(v ?? '')])
              ) : {}),
            },
          });
        }
      } catch (e) {
        console.warn('writeAdminNotification push error (ignored):', e.message || e);
      }
    }
  }

  function collectTokensFromDocData(docData) {
    const d = docData && typeof docData === 'object' ? docData : {};
    const candidates = [
      d.deviceToken,
      d.device_token,
      d.fcm_token,
      d.fcmToken,
      d.token,
      d.push_token,
      d.pushToken,
    ];

    const tokens = [];
    const seen = new Set();
    for (const c of candidates) {
      const t = String(c || '').trim();
      if (!t || seen.has(t)) continue;
      seen.add(t);
      tokens.push(t);
    }

    // Some schemas store multiple tokens.
    const listCandidates = [d.tokens, d.fcm_tokens, d.deviceTokens];
    for (const list of listCandidates) {
      if (!Array.isArray(list)) continue;
      for (const item of list) {
        const t = String(item || '').trim();
        if (!t || seen.has(t)) continue;
        seen.add(t);
        tokens.push(t);
      }
    }
    return tokens;
  }

  function toStringMap(v) {
    const obj = v && typeof v === 'object' ? v : {};
    const out = {};
    for (const [k, val] of Object.entries(obj)) {
      if (val == null) continue;
      out[String(k)] = String(val);
    }
    return out;
  }

  async function sendPushToTokens({ tokens, title, body, data }) {
    if (!tokens || tokens.length === 0) return { attempted: 0, success: 0, failure: 0 };
    try {
      // sendEachForMulticast returns per-token responses.
      const notifType = (data && data.type) ? String(data.type) : '';
      const ORDER_REQUEST_SET = new Set([
        'Order Request', 'order_request', 'rfq_broadcast', 'rfq_assignment',
        'rfq_amended', 'rfq_assigned', 'rfq_updated',
        'future_booking', 'booking_request', 'new_booking',
        'wallet_topup', 'wallet_credit',
        'chat_message', 'case_reply',
      ]);
      const cId = ORDER_REQUEST_SET.has(notifType)
        ? 'order_request_channel'
        : 'high_importance_channel';

      const resp = await admin.messaging().sendEachForMulticast({
        tokens,
        notification: {
          title: String(title || '').trim() || undefined,
          body: String(body || '').trim() || undefined,
        },
        data: toStringMap(data),
        android: { priority: 'high', notification: { channelId: cId } },
      });
      return {
        attempted: tokens.length,
        success: resp.successCount || 0,
        failure: resp.failureCount || 0,
      };
    } catch (e) { console.warn('\u26a0\ufe0f sendPushToTokens:', e.message);
      return { attempted: tokens.length, success: 0, failure: tokens.length };
    }
  }

  async function getUserTokens(uid) {
    const id = String(uid || '').trim();
    if (!id) return [];
    try {
      const snap = await firestore.collection('users').doc(id).get();
      if (!snap.exists) return [];
      return collectTokensFromDocData(snap.data() || {});
    } catch (e) { console.warn('\u26a0\ufe0f getUserTokens:', e.message);
      return [];
    }
  }

  async function _writeNotificationImpl({ userId, userType, title, message, data, sendPush }) {
    const uid = String(userId || '').trim();
    const utype = String(userType || '').trim().toLowerCase();
    if (!uid || (utype !== 'user' && utype !== 'artisan' && utype !== 'admin')) return;
    try {
      const payloadData = data && typeof data === 'object' ? data : {};
      const bookingId = String(payloadData.booking_id || payloadData.bookingId || '').trim();
      const tasksManagementId = String(
        payloadData.tasks_management_id || payloadData.tasksManagementId || payloadData.tasks_management || ''
      ).trim();
      const notifType = String(payloadData.type || '').trim();
      const ref = firestore.collection('notifications').doc();

      await ref.set({
        id: ref.id,
        user_id: uid,
        user_type: utype,
        title: String(title || '').trim(),
        message: String(message || '').trim(),
        ...(bookingId ? { booking_id: bookingId } : {}),
        ...(tasksManagementId ? { tasks_management_id: tasksManagementId } : {}),
        ...(notifType ? { type: notifType } : {}),
        read: false,
        view: false,
        time: now,
        created_at: now,
        // Debuggable metadata without breaking existing app queries.
        recipient_uid: uid,
        data: payloadData,
      });

      // FCM push for client users and artisans (enabled by default when Firebase is configured).
      if (sendPush && (utype === 'user' || utype === 'artisan')) {
        const tokens = utype === 'user' ? await getUserTokens(uid) : [];
        // For artisans, also try serviceProvider collection tokens.
        if (utype === 'artisan') {
          try {
            const spSnap = await firestore.collection('serviceProvider').doc(uid).get();
            if (spSnap.exists) {
              for (const t of collectTokensFromDocData(spSnap.data() || {})) {
                if (!tokens.includes(t)) tokens.push(t);
              }
            }
          } catch (e) { console.warn('\u26a0\ufe0f FCM token collection:', e.message); }
          // Also try user doc tokens for artisans (they may also have a users doc)
          for (const t of await getUserTokens(uid)) {
            if (!tokens.includes(t)) tokens.push(t);
          }
        }
        const push = await sendPushToTokens({
          tokens,
          title: String(title || '').trim(),
          body: String(message || '').trim(),
          data: {
            type: notifType || 'square15',
            notification_id: ref.id,
            user_type: utype,
            booking_id: payloadData.booking_id || payloadData.bookingId || '',
          },
        });
        await ref.set(
          {
            push: {
              enabled: true,
              attempted: push.attempted,
              success: push.success,
              failure: push.failure,
              sent_at: nowIso(),
            },
          },
          { merge: true }
        );
      }
    } catch (e) { console.warn('\u26a0\ufe0f writeNotification impl:', e.message);
      // ignore
    }
  }

  function pickPrimaryAuthUidFromProviderData(providerDoc) {
    if (!providerDoc || !providerDoc.exists) return '';
    const data = providerDoc.data() || {};
    const candidates = [data.user_id, data.uid, data.userId, data.user_uid, data.auth_uid];
    for (const c of candidates) {
      const v = String(c || '').trim();
      if (v) return v;
    }
    return '';
  }

  async function writePersonalNotificationForProviderDoc(providerDoc, title, message, data) {
    if (!providerDoc || !providerDoc.exists) return;
    const pd = providerDoc.data() || {};
    const providerDocId = String(providerDoc.id || '').trim();
    const primaryUid = pickPrimaryAuthUidFromProviderData(providerDoc);

    const ids = new Set();
    if (primaryUid) ids.add(primaryUid);
    if (providerDocId) ids.add(providerDocId);
    for (const k of ['user_id', 'uid', 'userId', 'provider_id']) {
      const v = String(pd[k] || '').trim();
      if (v) ids.add(v);
    }

    const payloadData = {
      ...(data && typeof data === 'object' ? data : {}),
      service_provider_id: providerDocId || null,
      service_provider_user_id: String(pd.user_id || '').trim() || null,
    };

    // FCM push using tokens from provider doc + primary user doc (enabled by default).
    {
      const tokens = [];
      const seen = new Set();
      for (const t of collectTokensFromDocData(pd)) {
        if (!seen.has(t)) {
          seen.add(t);
          tokens.push(t);
        }
      }
      if (primaryUid) {
        for (const t of await getUserTokens(primaryUid)) {
          if (!seen.has(t)) {
            seen.add(t);
            tokens.push(t);
          }
        }
      }
      await sendPushToTokens({
        tokens,
        title: String(title || '').trim(),
        body: String(message || '').trim(),
        data: {
          type: (data && data.type) ? String(data.type) : 'square15',
          user_type: 'artisan',
          booking_id: payloadData.booking_id || payloadData.bookingId || '',
          tasks_management_id: payloadData.tasks_management_id || '',
          provider_doc_id: providerDocId || '',
          provider_uid: primaryUid || '',
        },
      });
    }

    for (const id of ids.values()) {
      await _writeNotificationImpl({
        userId: id,
        userType: 'artisan',
        title,
        message,
        data: payloadData,
        // Push is already handled above (single send), avoid duplicates.
        sendPush: false,
      });
    }
  }

  async function createTasksManagementRequestForFutureBooking({ bookingIdLocal, bookingDataLocal, artisanIdLocal }) {
    const userIdLocal = String(bookingDataLocal.user_id || '').trim();
    if (!userIdLocal || !String(artisanIdLocal || '').trim()) return null;

    let effectiveTaskId = String(bookingDataLocal.task_id || '').trim();
    let jobIds = stringList(bookingDataLocal.job_ids ?? bookingDataLocal.jobIds);
    if (jobIds.length === 0 && effectiveTaskId) jobIds = [effectiveTaskId];
    if (!effectiveTaskId && jobIds.length > 0) effectiveTaskId = String(jobIds[0] || '').trim();

    const providerDoc = await getServiceProviderDocByAnyId(artisanIdLocal);
    const providerListenerId = providerDoc && providerDoc.exists ? String(providerDoc.id).trim() : String(artisanIdLocal).trim();
    if (!providerListenerId) return null;

    const workImages = stringList(bookingDataLocal.work_images ?? bookingDataLocal.workImages);
    const firstImage = workImages.length > 0 ? workImages[0] : '';
    const secondImage = workImages.length > 1 ? workImages[1] : '';
    const description = String(bookingDataLocal.description || '').trim();
    const scheduledDate = String(bookingDataLocal.scheduled_date || '').trim();
    const scheduledTime = String(bookingDataLocal.scheduled_time || '').trim();

    const isCurrent = String(
      bookingDataLocal.is_service_on_current_location ?? bookingDataLocal.isServiceOnCurrentLocation ?? 'no'
    )
      .trim()
      .toLowerCase() === 'yes';
    const providedAddress = String(bookingDataLocal.user_provided_address ?? bookingDataLocal.userProvidedAddress ?? '').trim();
    const effectiveAddress = providedAddress || (isCurrent ? 'Client current location' : 'N/A');

    let userLatLocal = String(bookingDataLocal.user_lat || '').trim();
    let userLngLocal = String(bookingDataLocal.user_lng || '').trim();
    let otherLatLocal = String(bookingDataLocal.other_lat || '').trim();
    let otherLngLocal = String(bookingDataLocal.other_lng || '').trim();

    // For current-location bookings, prefer live users/{uid}.lat/lng.
    if (isCurrent) {
      try {
        const uSnap = await firestore.collection('users').doc(userIdLocal).get();
        if (uSnap.exists) {
          const ud = uSnap.data() || {};
          userLatLocal = String((ud.lat ?? userLatLocal) || '0');
          userLngLocal = String((ud.lng ?? userLngLocal) || '0');
        }
      } catch (e) { console.warn('\u26a0\ufe0f user location lookup:', e.message);
        // ignore
      }
    }

    const effectiveLat = isCurrent ? userLatLocal : otherLatLocal;
    const effectiveLng = isCurrent ? userLngLocal : otherLngLocal;

    // Keep order numbers consistent across futureBookings and tasksManagement.
    const bookingOrderNoRaw = String(bookingDataLocal.order_no || '').trim();
    const hasNumericOrderNo = /^\d+$/.test(bookingOrderNoRaw);
    let orderSeq = null;
    if (!hasNumericOrderNo) {
      try {
        await firestore.runTransaction(async (tx) => {
          const counterRef = firestore.collection('metadata').doc('counters');
          const snap = await tx.get(counterRef);
          let current = 0;
          if (snap.exists) {
            const data = snap.data() || {};
            const taskCounter = data.taskManagementCounter || {};
            const raw = taskCounter.nextOrderNo;
            if (typeof raw === 'number') current = raw;
            else current = Number.parseInt(String(raw || '0'), 10) || 0;
          }
          const next = current + 1;
          tx.set(counterRef, { taskManagementCounter: { nextOrderNo: next } }, { merge: true });
          orderSeq = next;
        });
      } catch (e) {
        console.warn(`⚠️ Order counter transaction failed: ${e.message}; falling back to date-based order number`);
        orderSeq = null;
      }
    }

    const resolvedOrderNo = hasNumericOrderNo ? bookingOrderNoRaw : orderSeq != null ? String(orderSeq) : await generateDateBasedOrderNo();

    // Resolve costs best-effort.
    const resolvedTaskCosts = {};
    for (const jobTaskId of jobIds) {
      const id = String(jobTaskId || '').trim();
      if (!id) continue;
      const fetched = await resolveTaskCost(id);
      if (fetched != null && fetched > 0) resolvedTaskCosts[id] = fetched;
    }
    let totalCost = Object.values(resolvedTaskCosts).reduce((sum, c) => sum + (typeof c === 'number' ? c : 0), 0);
    if (!(totalCost > 0)) {
      const fallback = toNumber(bookingDataLocal.cost);
      if (fallback && fallback > 0) totalCost = fallback;
    }

    const tmId = crypto.randomUUID();
    const tmRef = firestore.collection('tasksManagement').doc(tmId);
    const bookingRefLocal = firestore.collection('futureBookings').doc(bookingIdLocal);

    const batch = firestore.batch();
    batch.set(tmRef, {
      id: tmId,
      order_no: resolvedOrderNo,
      order_seq: orderSeq,
      accept: '',
      status: 'pending',
      user_id: userIdLocal,
      service_provider_id: providerListenerId,
      task_id: effectiveTaskId,
      cost: totalCost > 0 ? totalCost.toFixed(2) : String(bookingDataLocal.cost || 'TBD'),
      payment: '',
      payment_status: '',
      rating: '',
      fee: '',
      area: '',
      artisan_images: '0',
      artisan_image_doc_id: '',
      attachment: firstImage || '',
      additional_attachment: secondImage || '',
      image_urls: workImages,
      additional_description: '',
      creation_date: now,
      updated_at: now,
      updated_by: userIdLocal,
      description,
      service_on_location: isCurrent ? 'yes' : 'no',
      provided_address: effectiveAddress,
      other_lat: effectiveLat,
      other_lng: effectiveLng,
      source: 'future_booking',
      future_booking_id: bookingIdLocal,
      scheduled_date: scheduledDate,
      scheduled_time: scheduledTime,
    });

    // Ensure futureBookings uses the same order number + bridge id.
    batch.set(bookingRefLocal, { order_no: resolvedOrderNo, tasks_management_id: tmId, updated_at: now }, { merge: true });

    for (const jobTaskId of jobIds) {
      const id = String(jobTaskId || '').trim();
      if (!id) continue;
      const jobDocId = crypto.randomUUID();
      const jobCost = resolvedTaskCosts[id] ?? 0.0;
      batch.set(tmRef.collection('jobs').doc(jobDocId), {
        id: jobDocId,
        task_id: id,
        height: '',
        width: '',
        area: '',
        cost: jobCost > 0 ? Number(jobCost).toFixed(2) : '0',
        description,
        image: firstImage || '',
      });
    }

    await batch.commit();
    return tmId;
  }

  function moneyString(v) {
    const n = typeof v === 'number' ? v : Number(v);
    if (!Number.isFinite(n)) return '0.00';
    return n.toFixed(2);
  }

  async function refundWalletForBookingTx(tx, bookingIdLocal, bookingData, reason) {
    const wasDeducted = isTruthy(bookingData.wallet_deducted) || bookingData.wallet_deducted === true;
    if (!wasDeducted) return { refunded: false, reason: 'not_deducted' };
    const alreadyRefunded = isTruthy(bookingData.wallet_refunded) || bookingData.wallet_refunded === true;
    if (alreadyRefunded) return { refunded: true, reason: 'already_refunded' };

    const userId = String(bookingData.user_id || '').trim();
    if (!userId) return { refunded: false, reason: 'missing_user_id' };

    const amount =
      toNumber(bookingData.wallet_deduct_amount) ??
      toNumber(bookingData.wallet_deducted_amount) ??
      toNumber(bookingData.cost);
    if (!amount || amount <= 0) return { refunded: false, reason: 'invalid_amount' };

    const userRef = firestore.collection('users').doc(userId);
    const userSnap = await tx.get(userRef);
    const userData = userSnap.exists ? userSnap.data() || {} : {};
    const currentBalance = toNumber(userData.balance) ?? 0.0;
    const newBalance = currentBalance + amount;

    const txId = randomId('tx-');
    const bookingRefLocal = firestore.collection('futureBookings').doc(bookingIdLocal);
    const transactionLogsRef = firestore.collection('transactionLogs').doc(txId);

    tx.set(userRef, { balance: moneyString(newBalance) }, { merge: true });
    tx.set(
      bookingRefLocal,
      {
        wallet_refunded: 'yes',
        wallet_refund_reason: reason,
        wallet_refund_amount: amount,
        wallet_refunded_at: now,
        wallet_refund_txn_id: txId,
        updated_at: now,
      },
      { merge: true }
    );

    tx.set(transactionLogsRef, {
      id: txId,
      amount: moneyString(amount),
      transaction_at: now,
      status: 'success',
      booking_id: bookingIdLocal,
      tasks_management_id: String(bookingData.tasks_management_id || '').trim(),
      task_id: String(bookingData.task_id || ''),
      task_name: String(bookingData.task_name || ''),
      transaction_by: userId,
      type: 'wallet',
      subtype: 'future_booking_refund',
      direction: 'out',
      cash_movement: false,
      profit: '0.00',
      schema_version: 2,
      reason,
      balance: moneyString(newBalance),
      assistant_context: {
        actor_uid: actorUid,
        actor_role: actorRole,
        session_id: context && context.session_id ? context.session_id : null,
        room_name: context && context.room_name ? context.room_name : null,
      },
    });

    return { refunded: true, reason: 'refunded', txId };
  }

  async function createOrderBookingFromPayload() {
    if (!(actorRole === 'client' || actorRole === 'admin')) {
      return { ok: false, status: 403, error: 'forbidden' };
    }

    const p = payload && typeof payload === 'object' ? payload : {};

    function normalizeDateTime(date, time) {
      const d = String(date || '').trim();
      let t = String(time || '').trim();
      if (d && t && /^\d{2}:\d{2}$/.test(t)) t = `${t}:00`;
      return { date: d, time: t };
    }

    function inferEmergencyFlag() {
      if (isTruthyExtended(p.is_emergency ?? p.isEmergency)) return true;
      const combined = `${String(p.problem_description ?? p.problemDescription ?? p.description ?? '')} ${String(
        p.additional_notes ?? p.additionalNotes ?? ''
      )}`.toLowerCase();
      return (
        combined.includes('urgent') ||
        combined.includes('asap') ||
        combined.includes('emergency') ||
        combined.includes('right now') ||
        combined.includes('now')
      );
    }

    function smartDefaultSchedule(isEmergency) {
      const nowLocal = new Date();
      if (isEmergency) {
        const later = new Date(nowLocal.getTime() + 60 * 60 * 1000);
        const yyyy = later.getFullYear();
        const mm = String(later.getMonth() + 1).padStart(2, '0');
        const dd = String(later.getDate()).padStart(2, '0');
        const hh = String(later.getHours()).padStart(2, '0');
        const mi = String(later.getMinutes()).padStart(2, '0');
        return { date: `${yyyy}-${mm}-${dd}`, time: `${hh}:${mi}:00` };
      }

      if (nowLocal.getHours() < 16) {
        const yyyy = nowLocal.getFullYear();
        const mm = String(nowLocal.getMonth() + 1).padStart(2, '0');
        const dd = String(nowLocal.getDate()).padStart(2, '0');
        const roundHour = nowLocal.getHours() < 9 ? 9 : nowLocal.getHours() + 1;
        return { date: `${yyyy}-${mm}-${dd}`, time: `${String(roundHour).padStart(2, '0')}:00:00` };
      }

      const tomorrow = new Date(nowLocal.getTime() + 24 * 60 * 60 * 1000);
      const yyyy = tomorrow.getFullYear();
      const mm = String(tomorrow.getMonth() + 1).padStart(2, '0');
      const dd = String(tomorrow.getDate()).padStart(2, '0');
      return { date: `${yyyy}-${mm}-${dd}`, time: '09:00:00' };
    }

    function tryParseScheduledAt(date, time) {
      const d = String(date || '').trim();
      const t = String(time || '').trim();
      if (!/^\d{4}-\d{2}-\d{2}$/.test(d)) return null;
      if (!/^\d{2}:\d{2}:\d{2}$/.test(t)) return null;
      const js = new Date(`${d}T${t}`);
      if (Number.isNaN(js.getTime())) return null;
      return admin.firestore.Timestamp.fromDate(js);
    }

    async function resolveClientDoc(uid) {
      const id = String(uid || '').trim();
      if (!id) return null;
      try {
        const snap = await firestore.collection('users').doc(id).get();
        if (!snap.exists) return null;
        return snap.data() || {};
      } catch (e) { console.warn('\u26a0\ufe0f resolveClientDoc:', e.message);
        return null;
      }
    }

    async function resolveTaskName(taskId) {
      const t = String(taskId || '').trim();
      if (!t) return '';
      try {
        const doc = await firestore.collection('tasks').doc(t).get();
        if (!doc.exists) return '';
        const data = doc.data() || {};
        return String(data.name || data.task_name || '').trim();
      } catch (e) { console.warn('\u26a0\ufe0f resolveTaskName:', e.message);
        return '';
      }
    }

    const categoryId = String(p.category_id || p.categoryId || '').trim() || null;
    const categoryName = String(p.category_name || p.categoryName || '').trim() || null;
    const problem = String(p.problem_description || p.problemDescription || p.description || '').trim();
    const notes = String(p.additional_notes || p.additionalNotes || '').trim();
    const effectiveDescription =
      problem ||
      (categoryName ? `Voice request: ${categoryName}${notes ? ` - ${notes}` : ''}` : `Voice request${notes ? ` - ${notes}` : ''}`);

    const materialsRaw = String(p.materials_responsibility || p.materialsResponsibility || 'artisan')
      .trim()
      .toLowerCase();
    const materialsResponsibility = materialsRaw === 'client' ? 'client' : 'artisan';

    const workImages = stringList(
      p.work_image_urls ||
        p.workImageUrls ||
        p.image_urls ||
        p.imageUrls ||
        p.work_images ||
        p.workImages ||
        p.images
    )
      .map((s) => String(s || '').trim())
      .filter((s) => s);

    const isRFQRequested = isTruthyExtended(p.is_rfq_requested ?? p.isRFQRequested ?? p.is_rfq ?? p.isRFQ);
    const rfqReason = String(p.rfq_reason || p.rfqReason || '').trim();

    let jobIds = stringList(p.job_ids ?? p.jobIds ?? p.jobs ?? []);
    jobIds = jobIds.map((s) => String(s || '').trim()).filter((s) => s);

    const resolvedCostsById = {};
    for (const id of jobIds) {
      const c = await resolveTaskCost(id);
      if (c != null && c > 0) resolvedCostsById[id] = c;
    }
    const totalCost = Object.values(resolvedCostsById).reduce((sum, c) => sum + (typeof c === 'number' ? c : 0), 0);

    if (!isRFQRequested && (jobIds.length === 0 || !(totalCost > 0))) {
      return { ok: false, status: 400, error: 'missing_priced_service' };
    }

    const serviceOnCurrentLocation = isTruthyExtended(
      p.service_on_current_location ??
        p.serviceOnCurrentLocation ??
        p.is_service_on_current_location ??
        p.isServiceOnCurrentLocation
    );

    const providedAddress = String(
      p.provided_address ||
        p.user_provided_address ||
        p.userProvidedAddress ||
        p.service_address ||
        p.serviceAddress ||
        ''
    ).trim();

    let userLat = String(p.user_lat || p.userLat || '').trim();
    let userLng = String(p.user_lng || p.userLng || '').trim();
    let otherLat = String(p.other_lat || p.otherLat || p.service_lat || p.serviceLat || '').trim();
    let otherLng = String(p.other_lng || p.otherLng || p.service_lng || p.serviceLng || '').trim();

    if (serviceOnCurrentLocation && (!userLat || !userLng)) {
      const ud = await resolveClientDoc(actorUid);
      if (ud) {
        userLat = String(ud.lat ?? userLat ?? '').trim();
        userLng = String(ud.lng ?? userLng ?? '').trim();
      }
    }

    const coordsLat = serviceOnCurrentLocation ? userLat : otherLat;
    const coordsLng = serviceOnCurrentLocation ? userLng : otherLng;

    const rawDate = String(p.scheduled_date || p.scheduledDate || '').trim();
    const rawTime = String(p.scheduled_time || p.scheduledTime || '').trim();
    const emergency = inferEmergencyFlag();
    let { date: scheduledDate, time: scheduledTime } = normalizeDateTime(rawDate, rawTime);
    if (!scheduledDate || !scheduledTime) {
      const d = smartDefaultSchedule(emergency);
      scheduledDate = scheduledDate || d.date;
      scheduledTime = scheduledTime || d.time;
    }

    const createdBy = String(p.created_by || p.createdBy || 'voice_ai').trim() || 'voice_ai';

    const bookingIdLocal = crypto.randomUUID();
    const bookingRefLocal = firestore.collection('futureBookings').doc(bookingIdLocal);

    const clientData = await resolveClientDoc(actorUid);
    const clientName = clientData ? String(clientData.name || clientData.userName || clientData.full_name || 'Unknown') : 'Unknown';
    const clientPhone = clientData ? String(clientData.contact || clientData.phone || clientData.mobile || '') : '';
    const clientEmail = clientData ? String(clientData.email || '') : '';

    const taskId = jobIds.length ? String(jobIds[0] || '').trim() : '';
    const taskNameParts = [];
    for (const id of jobIds) {
      const name = await resolveTaskName(id);
      if (name) taskNameParts.push(name);
    }
    const taskName = taskNameParts.length ? taskNameParts.join(', ') : String(p.task_name || p.taskName || categoryName || '').trim();

    let assignedArtisanId = '';
    if (!isRFQRequested) {
      assignedArtisanId =
        (await findAvailableArtisanByLocation({
          taskId,
          scheduledDate,
          scheduledTime,
          userLat: coordsLat,
          userLng: coordsLng,
          excludeArtisanId: null,
          categoryId,
          categoryName,
          bookingId: bookingIdLocal,
        })) ||
        '';
    }

    const assignedSuccessfully = !isRFQRequested && assignedArtisanId.trim().length > 0;
    const status = isRFQRequested ? 'rfq_pending' : assignedSuccessfully ? 'pending' : 'pending_assignment';
    const serviceProviderId = isRFQRequested ? 'admin' : assignedSuccessfully ? assignedArtisanId.trim() : 'admin';

    const scheduledAt = tryParseScheduledAt(scheduledDate, scheduledTime);
    const isRFQFlag = !!isRFQRequested;

    const bookingDoc = {
      id: bookingIdLocal,
      user_id: actorUid,
      userId: actorUid,
      uid: actorUid,

      service_provider_id: serviceProviderId,
      original_service_provider_id: serviceProviderId,

      task_id: taskId,
      task_name: taskName,
      job_ids: jobIds,

      scheduled_date: scheduledDate,
      scheduled_time: scheduledTime,
      ...(scheduledAt ? { scheduled_at: scheduledAt } : {}),

      created_at: now,
      created_at_ts: admin.firestore.FieldValue.serverTimestamp(),
      created_by: createdBy,

      status,
      order_type: isRFQFlag ? 'rfq' : 'order',
      is_rfq: isRFQFlag ? 'yes' : 'no',
      rfq_reason: isRFQFlag ? (rfqReason || 'voice_assistant') : '',
      rfq_status: isRFQFlag ? 'pending_admin_review' : '',

      cost: isRFQFlag ? (totalCost > 0 ? moneyString(totalCost) : 'TBD') : moneyString(totalCost),
      materials_responsibility: materialsResponsibility,

      description: effectiveDescription,
      user_confirmed: 'yes',
      artisan_confirmed: 'pending',

      one_day_reminder_sent: 'no',
      one_hour_reminder_sent: 'no',
      reassigned_count: '0',

      is_service_on_current_location: serviceOnCurrentLocation ? 'yes' : 'no',
      user_provided_address: providedAddress,
      user_lat: String(userLat || ''),
      user_lng: String(userLng || ''),
      other_lat: serviceOnCurrentLocation ? '' : String(otherLat || ''),
      other_lng: serviceOnCurrentLocation ? '' : String(otherLng || ''),

      category_id: categoryId,
      category_name: categoryName,

      work_images: workImages,
      workImages: workImages,
      image_urls: workImages,
      imageUrls: workImages,
      has_photos: workImages.length > 0 ? 'yes' : 'no',

      order_no: isRFQFlag ? '' : await generateDateBasedOrderNo(),
      rfq_no: isRFQFlag ? await generateDateBasedRfqNo() : '',

      client_name: clientName,
      client_phone: clientPhone,
      client_email: clientEmail,
      client_id: actorUid,

      ...(p.ai_session_id || p.aiSessionId ? { ai_session_id: String(p.ai_session_id || p.aiSessionId).trim() } : {}),
      ...(p.ai_transcript || p.aiTranscript ? { ai_transcript: String(p.ai_transcript || p.aiTranscript).trim() } : {}),
      ...(p.ai_quote || p.aiQuote ? { ai_quote: p.ai_quote || p.aiQuote } : {}),

      updated_at: now,
    };

    await bookingRefLocal.set(bookingDoc);

    let tasksManagementId = null;
    if (!isRFQFlag && assignedSuccessfully) {
      tasksManagementId = await createTasksManagementRequestForFutureBooking({
        bookingIdLocal: bookingIdLocal,
        bookingDataLocal: bookingDoc,
        artisanIdLocal: assignedArtisanId.trim(),
      });
    }

    if (isRFQFlag) {
      await writeAdminNotification({
        title: 'RFQ Request',
        message: `New RFQ request for ${categoryName || 'service'} (booking ${bookingIdLocal}).`,
        data: { booking_id: bookingIdLocal, order_type: 'rfq' },
      });
      await writePersonalNotification({
        userId: actorUid,
        userType: 'user',
        title: 'RFQ submitted',
        message: 'Your request has been submitted for a quote. Admin will review and assign the best available artisan.',
        data: { booking_id: bookingIdLocal, status },
      });
    } else if (assignedSuccessfully) {
      const providerDoc = await getServiceProviderDocByAnyId(assignedArtisanId.trim());
      await writePersonalNotificationForProviderDoc(
        providerDoc,
        'New booking assigned',
        `New booking request for ${scheduledDate} at ${scheduledTime} for ${categoryName || 'a service'}.`,
        { booking_id: bookingIdLocal, tasks_management_id: tasksManagementId || null, order_type: 'order', type: 'new_booking' }
      );
      await writePersonalNotification({
        userId: actorUid,
        userType: 'user',
        title: 'Booking created',
        message: 'Booking created and sent to a nearby artisan. Waiting for acceptance.',
        data: {
          booking_id: bookingIdLocal,
          service_provider_id: assignedArtisanId.trim(),
          tasks_management_id: tasksManagementId || null,
          status,
        },
      });
    } else {
      await writeAdminNotification({
        title: 'Booking Assignment Needed',
        message: `Booking ${bookingIdLocal} needs manual artisan assignment.`,
        data: { booking_id: bookingIdLocal, order_type: 'order' },
      });
      await writePersonalNotification({
        userId: actorUid,
        userType: 'user',
        title: 'Booking created',
        message: 'Your booking was created. We are finding the nearest available artisan to accept.',
        data: { booking_id: bookingIdLocal, status: 'pending_assignment' },
      });
    }

    return {
      ok: true,
      status: 200,
      data: {
        booking_id: bookingIdLocal,
        bookingId: bookingIdLocal,
        is_rfq: isRFQFlag,
        isRFQ: isRFQFlag,
        status,
        assigned_artisan_id: assignedSuccessfully ? assignedArtisanId.trim() : '',
        assignedArtisanId: assignedSuccessfully ? assignedArtisanId.trim() : '',
        tasks_management_id: tasksManagementId || null,
        tasksManagementId: tasksManagementId || null,
      },
    };
  }

  if (action === 'create_order_booking') {
    return await createOrderBookingFromPayload();
  }

  if (action === 'dispatch_artisan') {
    // For now, dispatch_artisan is treated as create_order_booking.
    // If a booking_id is present, refuse to avoid accidental duplicate bookings.
    if (bookingId) return { ok: false, status: 400, error: 'dispatch_with_booking_id_not_supported' };
    return await createOrderBookingFromPayload();
  }

  // ═══════════════════════════════════════════════════════════════
  // Phase 3: Messaging & Case Management (inlined to access scope)
  // ═══════════════════════════════════════════════════════════════

  if (action === 'get_messages') {
    const msgBookingId = String(payload.booking_id || payload.bookingId || '').trim();
    const msgTmIdRaw = String(payload.tasks_management_id || payload.tasksManagementId || payload.tm_id || '').trim();
    const msgLimit = Math.max(1, Math.min(100, Number(payload.limit || 50)));

    if (!msgTmIdRaw && !msgBookingId) {
      return { ok: false, status: 400, error: 'missing_tasks_management_id_or_booking_id' };
    }

    let msgTmId = msgTmIdRaw;
    if (!msgTmId && msgBookingId) {
      const bRef = firestore.collection('futureBookings').doc(msgBookingId);
      const bSnap = await bRef.get();
      if (!bSnap.exists) return { ok: false, status: 404, error: 'booking_not_found' };
      const bData = bSnap.data() || {};
      msgTmId = String(bData.tasks_management_id || '').trim();
      if (!msgTmId) return { ok: false, status: 400, error: 'no_tasks_management_id_for_booking' };
    }

    const tmRef2 = firestore.collection('tasksManagement').doc(msgTmId);
    const tmSnap2 = await tmRef2.get();
    if (!tmSnap2.exists) return { ok: false, status: 404, error: 'tasks_management_not_found' };

    const tmData2 = tmSnap2.data() || {};
    const tmUserId = String(tmData2.user_id || tmData2.userId || '').trim();
    const tmArtisanId = String(tmData2.service_provider_id || tmData2.serviceProviderId || '').trim();
    const msgAllowed = actorRole === 'admin' ||
      (actorRole === 'client' && tmUserId === actorUid) ||
      (actorRole === 'artisan' && tmArtisanId === actorUid);
    if (!msgAllowed) return { ok: false, status: 403, error: 'forbidden' };

    const messagesQuery = await tmRef2.collection('chat').orderBy('timestamp', 'desc').limit(msgLimit).get();
    const messages = messagesQuery.docs.map((doc) => {
      const d = doc.data() || {};
      return {
        id: doc.id,
        sender_id: String(d.sender_id || d.senderId || ''),
        receiver_id: String(d.receiver_id || d.receiverId || ''),
        message: String(d.message || ''),
        timestamp: d.timestamp || null,
        read: Boolean(d.read),
      };
    });

    return {
      ok: true, status: 200,
      data: { tasks_management_id: msgTmId, messages: messages.reverse(), count: messages.length },
    };
  }

  if (action === 'send_message_to_artisan') {
    const smBookingId = String(payload.booking_id || payload.bookingId || '').trim();
    const smMessage = String(payload.message || '').trim();
    if (!smBookingId || !smMessage) return { ok: false, status: 400, error: 'missing_booking_id_or_message' };
    if (smMessage.length > 1000) return { ok: false, status: 400, error: 'message_too_long', message: 'Message must be under 1000 characters' };

    const smBookingRef = firestore.collection('futureBookings').doc(smBookingId);
    const smBookingSnap = await smBookingRef.get();
    if (!smBookingSnap.exists) return { ok: false, status: 404, error: 'booking_not_found' };

    const smBookingData = smBookingSnap.data() || {};
    const smUserId = String(smBookingData.user_id || '').trim();
    const smArtisanId = String(smBookingData.service_provider_id || '').trim();
    const smTmId = String(smBookingData.tasks_management_id || '').trim();

    if (actorRole !== 'admin' && !(actorRole === 'client' && smUserId === actorUid)) {
      return { ok: false, status: 403, error: 'forbidden' };
    }
    if (!smArtisanId || smArtisanId === 'admin') return { ok: false, status: 400, error: 'no_artisan_assigned' };
    if (!smTmId) return { ok: false, status: 400, error: 'no_tasks_management_id' };

    const chatRef = firestore.collection('tasksManagement').doc(smTmId).collection('chat').doc();
    await chatRef.set({
      id: chatRef.id,
      sender_id: actorUid,
      receiver_id: smArtisanId,
      message: smMessage,
      timestamp: now,
      read: false,
      isRead: false,
      created_at: now,
    });

    // Update unread count on the tasksManagement doc for badge display
    try {
      await firestore.collection('tasksManagement').doc(smTmId).set({
        unread_artisan: admin.firestore.FieldValue.increment(1),
        last_message: smMessage.substring(0, 100),
        last_message_at: now,
        last_message_by: 'client',
      }, { merge: true });
    } catch (e) { console.warn('\u26a0\ufe0f chat unread count update:', e.message); }

    try {
      const providerDoc = await getServiceProviderDocByAnyId(smArtisanId);
      await writePersonalNotificationForProviderDoc(
        providerDoc,
        'New message from client',
        smMessage.substring(0, 100),
        { booking_id: smBookingId, tasks_management_id: smTmId, type: 'chat_message' }
      );
    } catch (_notifErr) { /* best-effort notification */ }

    return {
      ok: true, status: 200,
      data: { message_id: chatRef.id, tasks_management_id: smTmId, sent: true },
    };
  }

  if (action === 'send_message_to_client') {
    const scBookingId = String(payload.booking_id || payload.bookingId || '').trim();
    const scMessage = String(payload.message || '').trim();
    if (!scBookingId || !scMessage) return { ok: false, status: 400, error: 'missing_booking_id_or_message' };
    if (scMessage.length > 1000) return { ok: false, status: 400, error: 'message_too_long', message: 'Message must be under 1000 characters' };

    const scBookingRef = firestore.collection('futureBookings').doc(scBookingId);
    const scBookingSnap = await scBookingRef.get();
    if (!scBookingSnap.exists) return { ok: false, status: 404, error: 'booking_not_found' };

    const scBookingData = scBookingSnap.data() || {};
    const scClientId = String(scBookingData.user_id || '').trim();
    const scArtisanId = String(scBookingData.service_provider_id || '').trim();
    const scTmId = String(scBookingData.tasks_management_id || '').trim();

    // Only the assigned artisan or admin can message the client
    if (actorRole !== 'admin' && !(actorRole === 'artisan' && scArtisanId === actorUid)) {
      return { ok: false, status: 403, error: 'forbidden' };
    }
    if (!scClientId) return { ok: false, status: 400, error: 'no_client_on_booking' };
    if (!scTmId) return { ok: false, status: 400, error: 'no_tasks_management_id' };

    const scChatRef = firestore.collection('tasksManagement').doc(scTmId).collection('chat').doc();
    await scChatRef.set({
      id: scChatRef.id,
      sender_id: actorUid,
      receiver_id: scClientId,
      message: scMessage,
      timestamp: now,
      read: false,
      isRead: false,
      created_at: now,
    });

    // Update unread count on the tasksManagement doc for badge display
    try {
      await firestore.collection('tasksManagement').doc(scTmId).set({
        unread_client: admin.firestore.FieldValue.increment(1),
        last_message: scMessage.substring(0, 100),
        last_message_at: now,
        last_message_by: 'artisan',
      }, { merge: true });
    } catch (e) { console.warn('\u26a0\ufe0f chat unread count update (artisan):', e.message); }

    try {
      await writePersonalNotification({
        userId: scClientId,
        userType: 'user',
        title: 'Message from your artisan',
        message: scMessage.substring(0, 100),
        data: { booking_id: scBookingId, tasks_management_id: scTmId, type: 'chat_message' },
      });
    } catch (_notifErr) { /* best-effort notification */ }

    return {
      ok: true, status: 200,
      data: { message_id: scChatRef.id, tasks_management_id: scTmId, sent: true },
    };
  }

  if (action === 'send_message_to_admin') {
    const saBookingId = String(payload.booking_id || payload.bookingId || '').trim();
    const saMessage = String(payload.message || '').trim();
    const saSubject = String(payload.subject || 'Support Request').trim();
    if (!saMessage) return { ok: false, status: 400, error: 'missing_message' };
    if (saMessage.length > 2000) return { ok: false, status: 400, error: 'message_too_long', message: 'Message must be under 2000 characters' };

    const caseRef = firestore.collection('assistant_cases').doc();
    await caseRef.set({
      case_id: caseRef.id,
      type: 'support_message',
      booking_id: saBookingId || null,
      client_uid: actorUid,
      subject: saSubject,
      message: saMessage,
      state: 'open',
      priority: 'normal',
      created_at: now,
      updated_at: now,
      sla_deadline: new Date(Date.now() + 2 * 60 * 60 * 1000).toISOString(),
      timeline: [{ timestamp: now, actor: actorUid, action: 'case_created', notes: saMessage }],
    });

    try {
      await writeAdminNotification({
        title: `Support Request${saBookingId ? ` (Booking ${saBookingId})` : ''}`,
        message: `${saSubject}: ${saMessage.substring(0, 150)}`,
        data: { case_id: caseRef.id, booking_id: saBookingId || null, type: 'support_request' },
      });
      await writePersonalNotification({
        userId: actorUid,
        userType: 'user',
        title: 'Support request received',
        message: 'Our team will respond shortly. You will be notified when we reply.',
        data: { case_id: caseRef.id, booking_id: saBookingId || null },
      });
    } catch (_notifErr) { /* best-effort */ }

    return {
      ok: true, status: 200,
      data: { case_id: caseRef.id, message: 'Support request submitted successfully' },
    };
  }

  if (action === 'get_case_status') {
    const csCaseId = String(payload.case_id || payload.caseId || '').trim();
    if (!csCaseId) return { ok: false, status: 400, error: 'missing_case_id' };

    const csRef = firestore.collection('assistant_cases').doc(csCaseId);
    const csSnap = await csRef.get();
    if (!csSnap.exists) return { ok: false, status: 404, error: 'case_not_found' };

    const csData = csSnap.data() || {};
    const csClientUid = String(csData.client_uid || '').trim();
    if (actorRole !== 'admin' && csClientUid !== actorUid) return { ok: false, status: 403, error: 'forbidden' };

    return {
      ok: true, status: 200,
      data: {
        case_id: csCaseId,
        type: String(csData.type || ''),
        state: String(csData.state || ''),
        priority: String(csData.priority || 'normal'),
        subject: String(csData.subject || ''),
        booking_id: String(csData.booking_id || ''),
        created_at: csData.created_at || null,
        updated_at: csData.updated_at || null,
        resolved_at: csData.resolved_at || null,
        timeline: csData.timeline || [],
      },
    };
  }

  if (action === 'create_case') {
    const ccType = String(payload.type || 'general').trim();
    const ccBookingId = String(payload.booking_id || payload.bookingId || '').trim();
    const ccDesc = String(payload.description || payload.message || '').trim();
    const ccPriority = String(payload.priority || 'normal').trim();
    if (!ccDesc) return { ok: false, status: 400, error: 'missing_description' };

    const validTypes = ['late_artisan', 'dispute', 'reschedule_request', 'reassignment', 'quality_issue', 'support_message', 'general'];
    if (!validTypes.includes(ccType)) return { ok: false, status: 400, error: 'invalid_case_type', valid_types: validTypes };

    const validPriorities = ['low', 'normal', 'high', 'urgent'];
    const safePriority = validPriorities.includes(ccPriority) ? ccPriority : 'normal';
    const slaHours = { urgent: 1, high: 2, normal: 4, low: 24 };
    const slaDeadline = new Date(Date.now() + (slaHours[safePriority] || 4) * 60 * 60 * 1000).toISOString();

    const ccRef = firestore.collection('assistant_cases').doc();
    await ccRef.set({
      case_id: ccRef.id, type: ccType, booking_id: ccBookingId || null, client_uid: actorUid,
      description: ccDesc, state: 'open', priority: safePriority,
      created_at: now, updated_at: now, sla_deadline: slaDeadline,
      timeline: [{ timestamp: now, actor: actorUid, action: 'case_created', notes: ccDesc }],
    });

    try {
      await writeAdminNotification({
        title: `New Case: ${ccType}${ccBookingId ? ` (Booking ${ccBookingId})` : ''}`,
        message: ccDesc.substring(0, 150),
        data: { case_id: ccRef.id, type: ccType, priority: safePriority, booking_id: ccBookingId || null },
      });
    } catch (_notifErr) { /* best-effort */ }

    return {
      ok: true, status: 200,
      data: { case_id: ccRef.id, state: 'open', sla_deadline: slaDeadline },
    };
  }

  if (action === 'update_case') {
    const ucCaseId = String(payload.case_id || payload.caseId || '').trim();
    const ucNewState = String(payload.state || '').trim();
    const ucNotes = String(payload.notes || '').trim();
    if (!ucCaseId) return { ok: false, status: 400, error: 'missing_case_id' };

    const ucRef = firestore.collection('assistant_cases').doc(ucCaseId);
    const ucSnap = await ucRef.get();
    if (!ucSnap.exists) return { ok: false, status: 404, error: 'case_not_found' };

    const ucData = ucSnap.data() || {};
    const ucClientUid = String(ucData.client_uid || '').trim();
    if (actorRole !== 'admin' && ucClientUid !== actorUid) return { ok: false, status: 403, error: 'forbidden' };

    const ucValidStates = ['open', 'pending_artisan', 'pending_admin', 'in_progress', 'resolved', 'closed'];
    const ucUpdates = { updated_at: now };
    if (ucNewState) {
      if (!ucValidStates.includes(ucNewState)) return { ok: false, status: 400, error: 'invalid_state', valid_states: ucValidStates };
      ucUpdates.state = ucNewState;
      if (ucNewState === 'resolved' || ucNewState === 'closed') ucUpdates.resolved_at = now;
    }

    const ucTimeline = ucData.timeline || [];
    ucTimeline.push({ timestamp: now, actor: actorUid, action: ucNewState ? `state_changed_to_${ucNewState}` : 'case_updated', notes: ucNotes || '' });
    ucUpdates.timeline = ucTimeline;
    await ucRef.set(ucUpdates, { merge: true });

    return {
      ok: true, status: 200,
      data: { case_id: ucCaseId, state: ucNewState || ucData.state, updated_at: now },
    };
  }

  // ── Reply to Case (threaded conversation) ──
  if (action === 'reply_to_case') {
    const rcCaseId = String(payload.case_id || payload.caseId || '').trim();
    const rcMessage = String(payload.message || '').trim();
    if (!rcCaseId) return { ok: false, status: 400, error: 'missing_case_id' };
    if (!rcMessage) return { ok: false, status: 400, error: 'missing_message' };
    if (rcMessage.length > 2000) return { ok: false, status: 400, error: 'message_too_long' };

    const rcRef = firestore.collection('assistant_cases').doc(rcCaseId);
    const rcSnap = await rcRef.get();
    if (!rcSnap.exists) return { ok: false, status: 404, error: 'case_not_found' };

    const rcData = rcSnap.data() || {};
    const rcClientUid = String(rcData.client_uid || '').trim();
    if (actorRole !== 'admin' && rcClientUid !== actorUid) return { ok: false, status: 403, error: 'forbidden' };

    const rcTimeline = rcData.timeline || [];
    rcTimeline.push({
      timestamp: now,
      actor: actorUid,
      actor_role: actorRole,
      action: 'reply',
      notes: rcMessage,
    });

    const rcUpdates = { updated_at: now, timeline: rcTimeline };
    // If admin is replying to an open case, mark it in_progress
    if (actorRole === 'admin' && rcData.state === 'open') {
      rcUpdates.state = 'in_progress';
    }

    await rcRef.set(rcUpdates, { merge: true });

    // Notify the other party
    try {
      if (actorRole === 'admin' && rcClientUid) {
        await writePersonalNotification({
          userId: rcClientUid,
          userType: 'user',
          title: `Support reply (Case ${rcCaseId.substring(0, 8)})`,
          message: rcMessage.substring(0, 150),
          data: { case_id: rcCaseId, type: 'case_reply' },
        });
      } else {
        await writeAdminNotification({
          title: `Client reply (Case ${rcCaseId.substring(0, 8)})`,
          message: rcMessage.substring(0, 150),
          data: { case_id: rcCaseId, type: 'case_reply' },
        });
      }
    } catch (e) { console.warn('\u26a0\ufe0f case reply notification:', e.message); }

    return {
      ok: true, status: 200,
      data: { case_id: rcCaseId, replies: rcTimeline.length },
    };
  }

  // ── List My Cases ──
  if (action === 'list_my_cases' || action === 'list_cases') {
    const lcState = String(payload.state || payload.status || '').trim().toLowerCase();
    const lcLimit = Math.min(Math.max(parseInt(payload.limit || '10', 10) || 10, 1), 50);

    try {
      let query = firestore.collection('assistant_cases')
        .where('client_uid', '==', actorUid)
        .orderBy('updated_at', 'desc')
        .limit(lcLimit);

      if (lcState && ['open', 'pending_admin', 'in_progress', 'resolved', 'closed'].includes(lcState)) {
        query = firestore.collection('assistant_cases')
          .where('client_uid', '==', actorUid)
          .where('state', '==', lcState)
          .orderBy('updated_at', 'desc')
          .limit(lcLimit);
      }

      const lcSnap = await query.get();
      const cases = lcSnap.docs.map(doc => {
        const d = doc.data() || {};
        return {
          case_id: d.case_id || doc.id,
          type: d.type || 'general',
          state: d.state || 'open',
          priority: d.priority || 'normal',
          subject: d.subject || d.description || '',
          booking_id: d.booking_id || null,
          created_at: d.created_at || null,
          updated_at: d.updated_at || null,
          sla_deadline: d.sla_deadline || null,
          reply_count: (d.timeline || []).length,
        };
      });

      return {
        ok: true, status: 200,
        data: { cases, total: cases.length },
      };
    } catch (lcErr) {
      // Fallback: query without ordering if index is missing
      try {
        const lcSnap = await firestore.collection('assistant_cases')
          .where('client_uid', '==', actorUid)
          .get();

        let cases = lcSnap.docs.map(doc => {
          const d = doc.data() || {};
          return {
            case_id: d.case_id || doc.id,
            type: d.type || 'general',
            state: d.state || 'open',
            priority: d.priority || 'normal',
            subject: d.subject || d.description || '',
            booking_id: d.booking_id || null,
            created_at: d.created_at || null,
            updated_at: d.updated_at || null,
            sla_deadline: d.sla_deadline || null,
            reply_count: (d.timeline || []).length,
          };
        });

        if (lcState) cases = cases.filter(c => c.state === lcState);
        cases.sort((a, b) => (b.updated_at || '').localeCompare(a.updated_at || ''));
        cases = cases.slice(0, lcLimit);

        return { ok: true, status: 200, data: { cases, total: cases.length } };
      } catch (e2) {
        return { ok: false, status: 500, error: String(e2.message || e2) };
      }
    }
  }

  // ── Auto-Escalation Check ──
  if (action === 'check_sla_escalation') {
    // Admin-only: check for overdue cases and escalate their priority
    if (actorRole !== 'admin') return { ok: false, status: 403, error: 'admin_only' };

    try {
      const nowMs = Date.now();
      const openSnap = await firestore.collection('assistant_cases')
        .where('state', 'in', ['open', 'pending_admin', 'in_progress'])
        .get();

      let escalated = 0;
      const batch = firestore.batch();

      for (const doc of openSnap.docs) {
        const d = doc.data() || {};
        const deadline = d.sla_deadline ? new Date(d.sla_deadline).getTime() : 0;
        if (!deadline || deadline > nowMs) continue; // not overdue

        const current = d.priority || 'normal';
        const escalation = { low: 'normal', normal: 'high', high: 'urgent' };
        const next = escalation[current];
        if (!next) continue; // already urgent

        const timeline = d.timeline || [];
        timeline.push({
          timestamp: now,
          actor: 'system',
          action: 'auto_escalated',
          notes: `SLA deadline passed. Priority escalated from ${current} to ${next}.`,
        });

        // Extend SLA by the new priority window
        const slaHours = { urgent: 1, high: 2, normal: 4, low: 24 };
        const newDeadline = new Date(nowMs + (slaHours[next] || 2) * 60 * 60 * 1000).toISOString();

        batch.update(doc.ref, {
          priority: next,
          sla_deadline: newDeadline,
          updated_at: now,
          timeline,
        });
        escalated++;
      }

      if (escalated > 0) await batch.commit();

      return {
        ok: true, status: 200,
        data: { escalated, message: `${escalated} case(s) auto-escalated due to SLA breach.` },
      };
    } catch (e) {
      return { ok: false, status: 500, error: String(e.message || e) };
    }
  }

  // ── Service Pricing Lookup ──
  if (action === 'lookup_service_pricing' || action === 'list_services') {
    try {
      const categoryName = String(payload.category_name || payload.categoryName || '').trim().toLowerCase();
      const taskName = String(payload.task_name || payload.taskName || '').trim().toLowerCase();
      const searchQuery = String(payload.query || payload.search || '').trim().toLowerCase();

      // Combine all search terms
      const searchTerms = [categoryName, taskName, searchQuery].filter(s => s.length > 0).join(' ');

      // Synonym/related-terms expansion so broad queries like "plumbing" also
      // match tasks stored under different category names (e.g. "Bathroom").
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

      // Expand search tokens with synonyms
      let expandedTerms = searchTerms;
      for (const [key, synonyms] of Object.entries(SYNONYMS)) {
        if (searchTerms.includes(key)) {
          expandedTerms += ' ' + synonyms.join(' ');
        }
        // Also expand if any synonym is in the search terms
        for (const syn of synonyms) {
          if (syn.length >= 3 && searchTerms.includes(syn) && !expandedTerms.includes(key)) {
            expandedTerms += ' ' + key + ' ' + synonyms.join(' ');
            break;
          }
        }
      }

      // Load all categories
      const catSnap = await firestore.collection('categories').get();
      const categoryMap = {}; // id -> name
      for (const doc of catSnap.docs) {
        const d = doc.data() || {};
        const name = String(d.name || '').trim();
        const id = String(d.id || doc.id).trim();
        if (name) {
          categoryMap[id] = name;
          categoryMap[doc.id] = name;
        }
      }

      // Load tasks - try with different status values
      let taskDocs = [];
      for (const sv of ['publish', 'Published', 'active', 'Active']) {
        try {
          const r = await firestore.collection('tasks').where('status', '==', sv).get();
          if (r.docs.length > 0) {
            taskDocs = r.docs;
            break;
          }
        } catch (e) { console.warn('\u26a0\ufe0f task status query:', e.message); }
      }
      // Fallback: all tasks without status filter
      if (taskDocs.length === 0) {
        try {
          const r = await firestore.collection('tasks').limit(200).get();
          taskDocs = r.docs;
        } catch (e) { console.warn('\u26a0\ufe0f task fallback query:', e.message); }
      }

      if (taskDocs.length === 0) {
        return { ok: true, success: true, data: { services: [], message: 'No services found in the system.' } };
      }

      // Build services list with pricing
      const services = [];
      const allServices = []; // unfiltered list as fallback
      const searchTokens = expandedTerms
        .replace(/[^a-z0-9\s]/g, ' ')
        .split(/\s+/)
        .filter(t => t.length >= 2);
      // Deduplicate tokens
      const uniqueTokens = [...new Set(searchTokens)];

      for (const doc of taskDocs) {
        const d = doc.data() || {};
        const name = String(d.name || d.title || d.task_name || d.taskName || '').trim();
        if (!name) continue;

        const cost = toNumber(d.cost ?? d.price ?? d.amount ?? d.unit_price);
        const catId = String(d.categoryId || d.category_id || d.subCategoryId || d.sub_category_id || d.subcategoryId || d.subcategory_id || '').trim();
        const catName = categoryMap[catId] || '';
        const taskId = String(d.id || doc.id).trim();

        const entry = {
          task_id: taskId,
          name: name,
          cost: cost != null && cost > 0 ? cost : null,
          cost_formatted: cost != null && cost > 0 ? `R${cost.toFixed(2)}` : 'Quote on request',
          category_id: catId,
          category_name: catName,
        };

        allServices.push(entry);

        // If search terms provided, filter by relevance
        if (uniqueTokens.length > 0) {
          const nameL = name.toLowerCase();
          const catL = catName.toLowerCase();
          const combined = `${nameL} ${catL}`;
          let matches = false;
          for (const token of uniqueTokens) {
            if (combined.includes(token)) { matches = true; break; }
          }
          if (!matches) continue;
        }

        services.push(entry);
      }

      // If filtered search found nothing, return ALL services so the agent
      // can still answer pricing questions.
      const finalServices = services.length > 0 ? services : allServices;

      // Sort by category then name
      finalServices.sort((a, b) => {
        const catCmp = (a.category_name || '').localeCompare(b.category_name || '');
        if (catCmp !== 0) return catCmp;
        return (a.name || '').localeCompare(b.name || '');
      });

      return {
        ok: true,
        success: true,
        data: {
          services: finalServices.slice(0, 50),
          total_found: finalServices.length,
          filtered: services.length > 0,
          search_terms: searchTerms || 'all',
          expanded_terms: expandedTerms !== searchTerms ? expandedTerms.trim() : undefined,
          message: services.length > 0
            ? `Found ${services.length} service(s) matching "${searchTerms}".`
            : allServices.length > 0
              ? `No exact match for "${searchTerms}", showing all ${allServices.length} available services.`
              : `No services found.`,
        },
      };
    } catch (e) {
      return { ok: false, success: false, error: 'pricing_lookup_failed', message: String(e) };
    }
  }

  // ── Booking Analytics (admin only, capped at 500 docs) ──
  if (action === 'get_booking_analytics') {
    if (actorRole !== 'admin') {
      return { ok: false, success: false, error: 'forbidden', message: 'Booking analytics is restricted to admin users.' };
    }
    try {
      const snap = await firestore.collection('futureBookings').orderBy('created_at', 'desc').limit(500).get();
      const byStatus = {};
      const urgentBookings = [];
      const recentBookings = [];
      let total = 0;

      for (const doc of snap.docs) {
        total++;
        const d = doc.data();
        const status = String(d.status || d.rfq_status || 'unknown').trim().toLowerCase();
        byStatus[status] = (byStatus[status] || 0) + 1;

        // Detect urgent: has "urgent" flag or is overdue
        const isUrgent = (String(d.urgency || '').toLowerCase() === 'urgent' ||
                         String(d.priority || '').toLowerCase() === 'high' ||
                         String(d.is_urgent || '').toLowerCase() === 'yes');
        if (isUrgent) {
          urgentBookings.push({
            booking_id: doc.id,
            client_name: d.client_name || d.user_name || d.name || 'Unknown',
            category_name: d.category_name || d.categoryName || 'Service',
            status: status,
          });
        }

        // Collect recent bookings (by created_at or updated_at)
        const createdAt = d.created_at || d.created_at_ts || d.updated_at || '';
        recentBookings.push({
          booking_id: doc.id,
          category_name: d.category_name || d.categoryName || 'Service',
          status: status,
          created_at: createdAt,
          client_name: d.client_name || d.user_name || d.name || 'Unknown',
        });
      }

      // Sort recent by created_at descending, take top 5
      recentBookings.sort((a, b) => String(b.created_at).localeCompare(String(a.created_at)));
      const topRecent = recentBookings.slice(0, 5);

      return {
        ok: true,
        status: 200,
        data: {
          total_bookings: total,
          by_status: byStatus,
          urgent_bookings: urgentBookings.slice(0, 5),
          recent_bookings: topRecent,
        },
      };
    } catch (err) {
      return { ok: false, status: 500, error: `analytics_error: ${err.message}` };
    }
  }

  // ── List My Bookings ──
  if (action === 'list_my_bookings' || action === 'list_user_bookings') {
    if (!actorUid) return { ok: false, status: 401, error: 'unauthorized' };

    const statusFilter = String(payload.status || '').trim().toLowerCase();
    const limit = Math.min(Math.max(Number(payload.limit || 10), 1), 50);

    let query = firestore.collection('futureBookings');

    // Admin can see all; users see only their own
    if (actorRole === 'artisan') {
      query = query.where('service_provider_id', '==', actorUid);
    } else if (actorRole !== 'admin') {
      query = query.where('user_id', '==', actorUid);
    }

    if (statusFilter) {
      query = query.where('status', '==', statusFilter);
    }

    // Helper to extract booking fields from a Firestore doc
    const _extractBooking = (doc) => {
      const b = doc.data() || {};
      return {
        booking_id: doc.id,
        status: String(b.status || '').trim(),
        rfq_status: String(b.rfq_status || '').trim(),
        order_type: String(b.is_rfq || '').toLowerCase() === 'yes' ? 'rfq' : 'order',
        rfq_no: String(b.rfq_no || '').trim(),
        order_no: String(b.order_no || '').trim(),
        order_number: String(b.order_no || b.order_number || '').trim(),
        category_name: String(b.category_name || '').trim(),
        problem_description: String(b.problem_description || '').trim(),
        scheduled_date: String(b.scheduled_date || '').trim(),
        scheduled_time: String(b.scheduled_time || '').trim(),
        total_price: String(b.total_price || b.quoted_price || b.price || '').trim(),
        created_at: String(b.created_at || '').trim(),
      };
    };

    // Try with orderBy (requires composite index); fallback without it
    let bookings = [];
    try {
      const orderedQuery = query.orderBy('created_at', 'desc').limit(limit);
      const qs = await orderedQuery.get();
      bookings = qs.docs.map(_extractBooking);
    } catch (err) {
      // Composite index missing – fall back to unordered query + JS sort
      if (err.code === 9 || (err.message && err.message.includes('index'))) {
        console.warn('[list_bookings] composite index missing, falling back to JS sort');
        try {
          const qs = await query.limit(limit * 2).get();   // fetch a bit more to compensate for no ordering
          bookings = qs.docs.map(_extractBooking);
          bookings.sort((a, b) => (b.created_at || '').localeCompare(a.created_at || ''));
          bookings = bookings.slice(0, limit);
        } catch (err2) {
          return { ok: false, status: 500, error: `list_bookings_error: ${err2.message}` };
        }
      } else {
        return { ok: false, status: 500, error: `list_bookings_error: ${err.message}` };
      }
    }

    return { ok: true, status: 200, data: { bookings, count: bookings.length } };
  }

  // ── Get Wallet Balance ──
  if (action === 'get_wallet_balance') {
    if (!actorUid) return { ok: false, status: 401, error: 'unauthorized' };

    try {
      const snap = await firestore.collection('users').doc(actorUid).get();
      if (!snap.exists) return { ok: false, status: 404, error: 'user_not_found' };

      const u = snap.data() || {};
      const balanceRaw = (u.balance ?? u.wallet_balance ?? u.walletBalance ?? '0');
      const balance = String(balanceRaw).trim() || '0';

      return {
        ok: true,
        status: 200,
        data: { uid: actorUid, role: actorRole || null, balance },
      };
    } catch (err) {
      return { ok: false, status: 500, error: `wallet_error: ${err.message}` };
    }
  }

  // ── Check Payment Status (can work with booking_id OR tasks_management_id) ──
  if (action === 'check_payment' || action === 'get_payment_status') {
    if (!actorUid) return { ok: false, status: 401, error: 'unauthorized' };

    try {
      const tmIdDirect = String(payload.tasks_management_id || payload.tasksManagementId || '').trim();
      const searchId = bookingId || tmIdDirect;

      if (!searchId) {
        return { ok: false, status: 400, error: 'missing_booking_id_or_tasks_management_id' };
      }

      // Try to find payment in transactionLogs by booking_id
      let qs = null;
      if (bookingId) {
        qs = await firestore.collection('transactionLogs')
          .where('booking_id', '==', bookingId)
          .orderBy('created_at', 'desc')
          .limit(5)
          .get();
      }

      // Fallback: try tasks_management_id
      if (!qs || qs.empty) {
        let tmIdToSearch = tmIdDirect;
        if (!tmIdToSearch && bookingId) {
          const bData = await loadBooking();
          tmIdToSearch = String((bData || {}).tasks_management_id || '').trim();
        }
        if (tmIdToSearch) {
          qs = await firestore.collection('transactionLogs')
            .where('tasks_management_id', '==', tmIdToSearch)
            .orderBy('created_at', 'desc')
            .limit(5)
            .get();
        }
      }

      if (!qs || qs.empty) {
        // Check the booking's own payment_status field
        if (bookingId) {
          const bData = await loadBooking();
          const paymentStatus = String((bData || {}).payment_status || '').trim();
          return {
            ok: true,
            status: 200,
            data: {
              payment_status: paymentStatus || 'not_found',
              message: paymentStatus ? `Booking payment status: ${paymentStatus}` : 'No payment records found for this booking',
            },
          };
        }
        return {
          ok: true,
          status: 200,
          data: { payment_status: 'not_found', message: 'No payment records found' },
        };
      }

      const transactions = [];
      for (const doc of qs.docs) {
        const tx = doc.data() || {};
        const txUserId = String(tx.user_id || tx.client_id || '').trim();
        if (actorRole !== 'admin' && txUserId !== actorUid) continue;
        transactions.push({
          transaction_id: doc.id,
          type: String(tx.transaction_type || tx.type || '').trim(),
          amount: String(tx.amount || '').trim(),
          status: String(tx.status || tx.payment_status || '').trim(),
          created_at: String(tx.created_at || '').trim(),
        });
      }

      const latestTx = transactions[0] || null;
      return {
        ok: true,
        status: 200,
        data: {
          payment_status: latestTx ? latestTx.status : 'unknown',
          transactions,
          message: latestTx ? `Latest payment: ${latestTx.status}` : 'No payment records found',
        },
      };
    } catch (err) {
      return { ok: false, status: 500, error: `check_payment_error: ${err.message}` };
    }
  }

  if (!bookingId) {
    return { ok: false, status: 400, error: 'missing_booking_id' };
  }

  if (action === 'get_booking_status') {
    const data = await loadBooking();
    if (!data) return { ok: false, status: 404, error: 'booking_not_found' };
    const userId = String(data.user_id || '').trim();
    const artisanId = String(data.service_provider_id || '').trim();
    const allowed =
      (actorRole === 'client' && userId === actorUid) ||
      (actorRole === 'artisan' && artisanId === actorUid) ||
      actorRole === 'admin';
    if (!allowed) return { ok: false, status: 403, error: 'forbidden' };

    // Enrich with artisan name/phone from serviceProvider collection
    let artisanInfo = null;
    if (artisanId && artisanId !== 'admin') {
      try {
        const providerDoc = await getServiceProviderDocByAnyId(artisanId);
        if (providerDoc && providerDoc.exists) {
          const pd = providerDoc.data() || {};
          artisanInfo = {
            name: String(pd.name || pd.full_name || pd.displayName || pd.firstName || '').trim() || null,
            phone: String(pd.phone || pd.phoneNumber || pd.phone_number || pd.mobile || '').trim() || null,
            trade: String(pd.profession || pd.trade || pd.specialization || '').trim() || null,
          };
        }
      } catch (e) { console.warn('\u26a0\ufe0f artisan info lookup:', e.message); }
    }

    return {
      ok: true,
      status: 200,
      data: {
        booking_id: bookingId,
        status: String(data.status || ''),
        category_name: String(data.category_name || '').trim(),
        problem_description: String(data.problem_description || '').trim(),
        scheduled_date: String(data.scheduled_date || ''),
        scheduled_time: String(data.scheduled_time || ''),
        payment_status: String(data.payment_status || ''),
        total_price: String(data.total_price || data.quoted_price || data.price || '').trim(),
        artisan_confirmed: String(data.artisan_confirmed || ''),
        service_provider_id: artisanId,
        artisan: artisanInfo,
        tasks_management_id: String(data.tasks_management_id || '').trim(),
        order_no: String(data.order_no || '').trim(),
        order_number: String(data.order_no || data.order_number || '').trim(),
        rfq_no: String(data.rfq_no || '').trim(),
        rfq_status: String(data.rfq_status || '').trim(),
        order_type: String(data.is_rfq || '').toLowerCase() === 'yes' ? 'rfq' : 'order',
        created_at: String(data.created_at || '').trim(),
        service_address: String(data.service_address || data.address || '').trim(),
      },
    };
  }

  // ── Explain Quote (RFQ details, scope of work) ──
  if (action === 'explain_quote' || action === 'explain_rfq_quote') {
    const data = await loadBooking();
    if (!data) {
      // Fallback: try to find by rfq_no if bookingId looks like an RFQ number
      if (bookingId.toUpperCase().startsWith('RFQ')) {
        try {
          const rfqSnap = await firestore.collection('futureBookings')
            .where('rfq_no', '==', bookingId.toUpperCase())
            .limit(1)
            .get();
          if (!rfqSnap.empty) {
            const rfqDoc = rfqSnap.docs[0];
            const rfqData = rfqDoc.data() || {};
            const rfqUserId = String(rfqData.user_id || rfqData.client_id || '').trim();
            const rfqArtisanId = String(rfqData.service_provider_id || '').trim();
            if (actorRole !== 'admin' && rfqUserId !== actorUid && rfqArtisanId !== actorUid) {
              return { ok: false, status: 403, error: 'forbidden' };
            }
            const result = {
              booking_id: rfqDoc.id,
              rfq_no: String(rfqData.rfq_no || '').trim(),
              status: String(rfqData.status || '').trim(),
              rfq_status: String(rfqData.rfq_status || '').trim(),
              category_name: String(rfqData.category_name || '').trim(),
              problem_description: String(rfqData.problem_description || '').trim(),
              scope_of_work: String(rfqData.scope_of_work || rfqData.scopeOfWork || rfqData.description || rfqData.problem_description || '').trim(),
              created_at: String(rfqData.created_at || '').trim(),
              quote_status: 'pending',
              explanation: 'Your RFQ has been submitted. Details are being reviewed.',
            };
            if (rfqData.quoted_price || rfqData.quote_price || rfqData.total_price) {
              result.quote_status = 'quoted';
              result.quoted_price = String(rfqData.quoted_price || rfqData.quote_price || rfqData.total_price || '').trim();
              result.quote_details = String(rfqData.quote_details || rfqData.quote_notes || '').trim();
              result.explanation = `A quote of R${result.quoted_price} has been provided for your ${result.category_name} request.`;
            }
            return { ok: true, status: 200, data: result };
          }
        } catch (e) { console.warn('\u26a0\ufe0f RFQ data lookup:', e.message); }
      }
      return { ok: false, status: 404, error: 'booking_not_found' };
    }

    const bUserId = String(data.user_id || data.client_id || '').trim();
    const bArtisanId = String(data.service_provider_id || '').trim();
    if (actorRole !== 'admin' && bUserId !== actorUid && bArtisanId !== actorUid) {
      return { ok: false, status: 403, error: 'forbidden' };
    }

    const isRfq = String(data.is_rfq || data.is_rfq_requested || '').toLowerCase() === 'yes';
    const result = {
      booking_id: bookingId,
      rfq_no: String(data.rfq_no || '').trim(),
      status: String(data.status || '').trim(),
      rfq_status: String(data.rfq_status || '').trim(),
      category_name: String(data.category_name || '').trim(),
      problem_description: String(data.problem_description || '').trim(),
      scope_of_work: String(data.scope_of_work || data.scopeOfWork || data.description || data.problem_description || '').trim(),
      created_at: String(data.created_at || '').trim(),
      quote_status: isRfq ? 'pending' : 'n/a',
      explanation: isRfq
        ? 'Your RFQ has been submitted. Admin will review and provide a detailed quote shortly.'
        : 'This is a standard booking, not an RFQ.',
    };

    if (data.quoted_price || data.quote_price || data.total_price) {
      result.quote_status = 'quoted';
      result.quoted_price = String(data.quoted_price || data.quote_price || data.total_price || '').trim();
      result.quote_details = String(data.quote_details || data.quote_notes || '').trim();
      result.explanation = `A quote of R${result.quoted_price} has been provided for your ${result.category_name} request.`;
    }

    return { ok: true, status: 200, data: result };
  }

  // ── Generate AI RFQ Quote (with Builders.co.za real-time pricing) ──
  if (action === 'generate_rfq_quote') {
    const data = await loadBooking();
    if (!data) return { ok: false, status: 404, error: 'booking_not_found' };

    const isRfq = String(data.is_rfq || data.is_rfq_requested || '').toLowerCase() === 'yes';
    if (!isRfq) return { ok: false, status: 400, error: 'not_an_rfq' };

    // If already quoted, return existing quote
    if (data.ai_quote && data.ai_quote.grand_total) {
      return {
        ok: true, status: 200, data: {
          already_quoted: true,
          ai_quote: data.ai_quote,
          grand_total: data.ai_quote.grand_total,
          rfq_no: String(data.rfq_no || '').trim(),
        }
      };
    }

    const oai = getOpenAI();
    if (!oai) return { ok: false, status: 500, error: 'ai_unavailable' };

    const category = sanitizeForPrompt(String(data.category_name || ''), 100);
    const categoryId = String(data.category_id || '').trim();
    const description = sanitizeForPrompt(String(data.problem_description || data.description || ''), 1000);
    const materialsResp = sanitizeForPrompt(String(data.materials_responsibility || 'artisan'), 50);

    // Look up pricing guidance
    let laborRate = 150;
    let pricingCtx = '';
    try {
      const catSlug = category.toLowerCase().replace(/\s+/g, '_');
      const guidanceDoc = await firestore.collection('pricingGuidance').doc(catSlug).get();
      if (guidanceDoc.exists) {
        const gd = guidanceDoc.data();
        laborRate = parseFloat(gd.labor_cost_per_hour || gd.laborCostPerHour || 150);
        const sp = gd.service_prices || gd.servicePrices || {};
        pricingCtx = `Labor rate: R${laborRate}/hr. Service prices: ${JSON.stringify(sp)}`;
      }
    } catch (e) { console.warn('\u26a0\ufe0f pricing guidance fetch:', e.message); }

    try {
      // Step 1: Generate BOM with GPT (same as before, but instruct to use Builders-stocked items)
      const completion = await oai.chat.completions.create({
        model: 'gpt-4o-mini',
        temperature: 0.3,
        max_tokens: 1500,
        response_format: { type: 'json_object' },
        messages: [
          { role: 'system', content: 'You are a South African maintenance quotation expert. CRITICAL: Every material in materialsBOM MUST be a real product available on builders.co.za (Builders Warehouse). Do NOT include specialty items or proprietary accessories that Builders does not stock. Return only valid JSON.' },
          {
            role: 'user',
            content: `Generate a detailed maintenance quote:\nCategory: ${category}\nDescription: ${description}\nMaterials: ${materialsResp}\n${pricingCtx ? `Pricing: ${pricingCtx}` : ''}\n\nReturn JSON: {"laborHours":<num>,"laborCostPerHour":${laborRate},"complexity":<1-5>,"equipmentCost":<num>,"scopeOfWork":"<text>","estimatedDuration":"<text>","materialsBOM":[{"name":"<text>","qty":<num>,"unit":"<text>","estimated_price":<num>}]}`,
          },
        ],
      });

      const draft = JSON.parse(completion.choices[0]?.message?.content || '{}');
      const laborHours = parseFloat(draft.laborHours) || 4;
      const lrUsed = parseFloat(draft.laborCostPerHour) || laborRate;

      // Step 2: Look up real Builders.co.za prices for each BOM item
      const rawBom = draft.materialsBOM || [];
      const materialNames = rawBom.map(m => m.name || '');
      console.log(`[generate_rfq_quote] Looking up ${materialNames.length} items on Builders.co.za...`);

      let buildersResults = [];
      try {
        buildersResults = await buildersPriceLookupBatch(materialNames, 4);
        console.log(`[generate_rfq_quote] Builders lookup complete: ${buildersResults.filter(r => r && r.priceZar > 0).length}/${materialNames.length} priced`);
      } catch (e) {
        console.error('[generate_rfq_quote] Builders batch lookup error:', e.message);
      }

      // Step 3: Build BOM with real prices (Builders > Catalog > AI estimate fallback)
      const materialsMultiplier = 1.5;
      let matSubtotal = 0;
      const bom = [];
      for (let i = 0; i < rawBom.length; i++) {
        const m = rawBom[i];
        const qty = parseFloat(m.qty) || 1;
        const aiEstimate = parseFloat(m.estimated_price) || 0;
        const br = buildersResults[i];

        let unitPrice = aiEstimate;
        let matchedBy = 'ai_estimate';
        let buildersTitle = null;
        let buildersUrl = null;

        // Priority 1: Builders.co.za real price
        if (br && !br.blocked && br.priceZar > 0) {
          unitPrice = br.priceZar;
          matchedBy = br.source || 'builders_bff';
          buildersTitle = br.title || null;
          buildersUrl = br.url || null;
        }
        // Priority 2: Firestore materialsCatalog fallback
        else {
          const catalogResult = await lookupMaterialsCatalog(firestore, m.name);
          if (catalogResult && catalogResult.price > 0) {
            unitPrice = catalogResult.price;
            matchedBy = catalogResult.source;
          }
          // Priority 3: AI estimate (already set as default)
        }

        const lineBase = qty * unitPrice;
        matSubtotal += lineBase;

        const bomItem = { name: m.name, qty, unit: m.unit || 'each', unit_price: unitPrice, line_base: lineBase, matched_by: matchedBy };
        if (buildersTitle) bomItem.builders_title = buildersTitle;
        if (buildersUrl) bomItem.builders_url = buildersUrl;
        bom.push(bomItem);
      }

      // Step 4: Apply learning factor from historical admin corrections
      const learningFactor = await getLearningFactor(firestore, categoryId, category);
      console.log(`[generate_rfq_quote] Learning factor for ${category}: ${learningFactor.toFixed(3)}`);

      const laborCost = laborHours * lrUsed * learningFactor;
      const artisanBuys = materialsResp === 'artisan';
      const matWithMarkup = matSubtotal * materialsMultiplier * learningFactor;
      const matForTotals = artisanBuys ? matWithMarkup : 0;
      const eqCost = (parseFloat(draft.equipmentCost) || 0) * learningFactor;
      const subtotal = laborCost + matForTotals + eqCost;
      const contingency = subtotal * 0.15;
      const grandTotal = subtotal + contingency;

      const buildersCount = bom.filter(b => b.matched_by && b.matched_by.startsWith('builders')).length;
      const catalogCount = bom.filter(b => b.matched_by && b.matched_by.startsWith('catalog')).length;
      const aiCount = bom.filter(b => b.matched_by === 'ai_estimate').length;

      const r2 = (v) => Math.round(v * 100) / 100;
      const aiQuote = {
        laborHours, laborCostPerHour: lrUsed, laborCost: r2(laborCost),
        complexity: draft.complexity || 3,
        materialsBOM: bom, materialsMultiplier,
        materials_subtotal: r2(matSubtotal), materials_with_markup: r2(matWithMarkup),
        materials_responsibility: materialsResp,
        equipmentCost: r2(eqCost), subtotal: r2(subtotal),
        contingency: r2(contingency), grand_total: r2(grandTotal),
        scope_of_work: draft.scopeOfWork || description,
        estimated_duration: draft.estimatedDuration || 'TBD',
        learning_factor: r2(learningFactor),
        pricing_sources: { builders: buildersCount, catalog: catalogCount, ai_estimate: aiCount },
        breakdown: [
          { description: `Labour (${laborHours}hrs @ R${lrUsed}/hr${learningFactor !== 1 ? ` × ${learningFactor.toFixed(2)} adj` : ''})`, cost: laborCost.toFixed(2) },
          ...(artisanBuys && bom.length > 0 ? [{ description: `Materials & Supplies (${buildersCount} Builders-priced, ${catalogCount} catalog, ${aiCount} estimated)`, cost: matWithMarkup.toFixed(2) }] : []),
          ...(eqCost > 0 ? [{ description: 'Equipment & Tools', cost: eqCost.toFixed(2) }] : []),
          { description: 'Contingency (15%)', cost: contingency.toFixed(2) },
        ],
        disclaimer: 'Quote uses real-time Builders.co.za pricing where available. Final costs may vary based on actual site conditions.',
        generated_at: now, source: 'backend_ai_builders',
      };

      // Save to Firestore
      await bookingRef.update({
        ai_quote: aiQuote,
        quoted_price: grandTotal.toString(),
        quote_details: aiQuote.scope_of_work,
        rfq_status: 'pending_client_response',
        total_price: grandTotal.toString(),
        cost: grandTotal.toString(),
        updated_at: now,
      });

      console.log(`[generate_rfq_quote] Quote saved: R${grandTotal.toFixed(2)} (${buildersCount}/${bom.length} Builders-priced, LF=${learningFactor.toFixed(2)})`);
      return { ok: true, status: 200, data: { ai_quote: aiQuote, grand_total: grandTotal, rfq_no: String(data.rfq_no || '').trim() } };
    } catch (e) {
      console.error('[generate_rfq_quote] AI error:', e.message);
      return { ok: false, status: 500, error: 'ai_generation_failed', detail: e.message };
    }
  }

  // ── Accept RFQ Quote ──
  if (action === 'accept_rfq_quote') {
    const data = await loadBooking();
    if (!data) return { ok: false, status: 404, error: 'booking_not_found' };
    if (!data.ai_quote && !data.quoted_price) return { ok: false, status: 400, error: 'no_quote_available' };

    const price = data.quoted_price || (data.ai_quote ? String(data.ai_quote.grand_total) : '0');
    const priceNum = parseFloat(price) || 0;

    await bookingRef.update({
      rfq_status: 'accepted_converted',
      status: 'pending_artisan_acceptance',
      accepted_at: now,
      accepted_via: payload.source || 'voice',
      updated_at: now,
    });

    // Mirror to tasksManagement
    try {
      await firestore.collection('tasksManagement').doc(bookingId).set({
        id: bookingId,
        order_no: data.order_no || data.rfq_no || bookingId,
        user_id: data.user_id || '',
        category_name: data.category_name || '',
        description: data.description || data.problem_description || '',
        status: 'pending_artisan_acceptance',
        artisan_confirmed: 'pending',
        cost: priceNum.toFixed(2),
        source: 'voice_rfq',
        is_rfq: 'yes',
        rfq_status: 'accepted_converted',
        accepted_at: now,
        accepted_via: 'voice',
      }, { merge: true });
    } catch (e) { console.warn('[voice] tasksManagement mirror failed:', e.message); }

    // Auto-dispatch: route directly to artisans when conditions met
    const materialsResp = (data.materials_responsibility || '').toString().trim().toLowerCase();
    const clientBuysMaterials = materialsResp === 'client';
    const underThreshold = priceNum > 0 && priceNum < 12000;
    let autoDispatched = false;

    if (clientBuysMaterials || underThreshold) {
      const autoReason = clientBuysMaterials ? 'client_buys_materials' : 'under_12k';
      const cat = (data.category || data.category_name || '').toLowerCase().replace(/\s+/g, '_');
      try {
        let artisanSnap;
        try {
          artisanSnap = await firestore.collection('serviceProvider').where('status', '==', 'publish').limit(200).get();
          if (artisanSnap.empty) artisanSnap = await firestore.collection('serviceProvider').where('status', '==', 'approved').limit(200).get();
          if (artisanSnap.empty) artisanSnap = await firestore.collection('serviceProvider').limit(200).get();
        } catch (qErr) {
          console.warn('[lk] artisan query fallback:', qErr.message);
          artisanSnap = await firestore.collection('serviceProvider').limit(200).get();
        }
        const matchedArtisans = [];
        for (const artDoc of artisanSnap.docs) {
          const ad = artDoc.data() || {};
          const st = (ad.status || '').toString().toLowerCase();
          if (st && st !== 'publish' && st !== 'published' && st !== 'approved' && st !== 'approve') continue;
          if (ad.is_suspended === true) continue;
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

          await bookingRef.update({
            rfq_status: 'pending_artisan_acceptance',
            status: 'pending_artisan_acceptance',
            rfq_submitted_to: 'artisan',
            rfq_assigned_artisan_ids: artisanIds,
            rfq_assigned_artisan_names: artisanNames,
            rfq_auto_assigned: true,
            rfq_auto_assign_reason: autoReason,
            rfq_artisan_rejection_count: 0,
            rfq_artisan_rejections: [],
            artisan_name: matchedArtisans[0].name,
          });

          await firestore.collection('tasksManagement').doc(bookingId).update({
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
                notification: { title: '🔔 New RFQ Job Available', body: `RFQ ${data.rfq_no || bookingId} — R${priceNum.toFixed(2)}. Tap to view and accept.` },
                data: { type: 'rfq_accepted', booking_id: bookingId },
                android: { notification: { channelId: 'order_request_channel', sound: 'sound' } },
              });
            } catch (fcmErr) { console.warn(`[voice] FCM to artisan ${art.id} failed:`, fcmErr.message); }
          }
          autoDispatched = true;
          console.log(`[voice] Auto-dispatched RFQ ${bookingId} to ${artisanIds.length} artisans (${autoReason})`);
        }
      } catch (e) { console.warn('[voice] auto-dispatch failed:', e.message); }
    }

    if (!autoDispatched) {
      await writeAdminNotification({
        title: 'RFQ Quote Accepted — Assign Artisan',
        message: `Customer accepted RFQ ${data.rfq_no || bookingId} (R${priceNum.toFixed(2)}) via voice. Please assign an artisan.`,
        data: { type: 'rfq_accepted', bookingId },
      });
    }

    return { ok: true, status: 200, data: { accepted: true, price, rfq_no: String(data.rfq_no || '').trim(), auto_dispatched: autoDispatched } };
  }

  // ── Reject / Negotiate RFQ Quote ──
  if (action === 'reject_rfq_quote') {
    const data = await loadBooking();
    if (!data) return { ok: false, status: 404, error: 'booking_not_found' };

    const reason = String(payload.reason || 'Customer wants negotiation').trim();
    await bookingRef.update({
      rfq_status: 'under_negotiation',
      negotiation_reason: reason,
      negotiation_at: now,
      negotiation_via: payload.source || 'voice',
      updated_at: now,
    });

    await writeAdminNotification({
      title: 'RFQ Quote Negotiation',
      message: `Customer wants to negotiate RFQ ${data.rfq_no || bookingId}. Reason: ${reason}`,
      data: { type: 'rfq_negotiation', bookingId },
    });

    return { ok: true, status: 200, data: { negotiation: true, rfq_no: String(data.rfq_no || '').trim() } };
  }

  const bookingData = await loadBooking();
  if (!bookingData) return { ok: false, status: 404, error: 'booking_not_found' };

  const userId = String(bookingData.user_id || '').trim();
  const artisanId = String(bookingData.service_provider_id || '').trim();
  const tmId = String(bookingData.tasks_management_id || '').trim();

  if (action === 'cancel_booking') {
    if (!(actorRole === 'client' && userId === actorUid)) {
      return { ok: false, status: 403, error: 'forbidden' };
    }
    const status = String(bookingData.status || '').trim().toLowerCase();
    if (status === 'cancelled' || status === 'canceled' || status === 'closed') {
      return { ok: true, status: 200, data: { already: true } };
    }

    const reason = String(payload.reason || payload.cancel_reason || payload.additional_notes || 'client_cancelled').trim();
    await firestore.runTransaction(async (tx) => {
      const freshSnap = await tx.get(bookingRef);
      if (!freshSnap.exists) throw new Error('booking_not_found');
      const fresh = freshSnap.data() || {};
      const freshStatus = String(fresh.status || '').trim().toLowerCase();
      if (freshStatus === 'cancelled' || freshStatus === 'canceled' || freshStatus === 'closed') return;

      tx.set(
        bookingRef,
        {
          status: 'cancelled',
          cancelled_by_client: 'yes',
          cancel_reason: reason,
          cancelled_by_client_at: now,
          updated_at: now,
        },
        { merge: true }
      );

      if (tmId) {
        tx.set(
          firestore.collection('tasksManagement').doc(tmId),
          {
            status: 'closed',
            closed_date: now,
            closed_reason: 'client_cancelled',
            updated_at: now,
          },
          { merge: true }
        );
      }

      await refundWalletForBookingTx(tx, bookingId, fresh, `client_cancelled:${reason}`);
    });

    return { ok: true, status: 200, data: { cancelled: true } };
  }

  if (action === 'reschedule_booking') {
    if (!((actorRole === 'client' && userId === actorUid) || actorRole === 'admin')) {
      return { ok: false, status: 403, error: 'forbidden' };
    }
    const date = String(payload.scheduled_date || payload.scheduledDate || '').trim();
    const time = String(payload.scheduled_time || payload.scheduledTime || '').trim();
    if (!date || !time) return { ok: false, status: 400, error: 'missing_date_time' };

    const prevDate = String(bookingData.scheduled_date || '').trim();
    const prevTime = String(bookingData.scheduled_time || '').trim();
    const requestedBy = actorRole;

    await bookingRef.set(
      {
        scheduled_date: date,
        scheduled_time: time,
        rescheduled: 'yes',
        rescheduled_at: now,
        rescheduled_by: requestedBy,
        rescheduled_reason: 'voice_assistant',
        previous_scheduled_date: prevDate,
        previous_scheduled_time: prevTime,
        updated_at: now,
      },
      { merge: true }
    );

    if (tmId) {
      await firestore
        .collection('tasksManagement')
        .doc(tmId)
        .set({ scheduled_date: date, scheduled_time: time, updated_at: now }, { merge: true });
    }

    return { ok: true, status: 200, data: { rescheduled: true } };
  }

  if (action === 'mark_booking_in_progress') {
    if (!(actorRole === 'artisan' && artisanId === actorUid)) {
      return { ok: false, status: 403, error: 'forbidden' };
    }

    await bookingRef.set(
      {
        status: 'in_progress',
        in_progress_at: now,
        updated_at: now,
      },
      { merge: true }
    );

    if (tmId) {
      await firestore.collection('tasksManagement').doc(tmId).set(
        {
          status: 'progress',
          accept: '1',
          updated_at: now,
        },
        { merge: true }
      );
    }

    return { ok: true, status: 200, data: { in_progress: true } };
  }

  if (action === 'request_reassignment' || action === 'artisan_cancel_and_reassign' || action === 'reassign_booking') {
    const isOwnerClient = actorRole === 'client' && userId === actorUid;
    const isAssignedArtisan = actorRole === 'artisan' && artisanId === actorUid;
    const isAdmin = actorRole === 'admin';
    if (!(isOwnerClient || isAssignedArtisan || isAdmin)) {
      return { ok: false, status: 403, error: 'forbidden' };
    }

    const reason = String(payload.reason || payload.cancel_reason || payload.additional_notes || 'reassignment_requested').trim();

    // Attempt automatic reassignment first (server-controlled).
    const isServiceOnCurrentLocation =
      String(bookingData.is_service_on_current_location ?? bookingData.isServiceOnCurrentLocation ?? 'no')
        .trim()
        .toLowerCase() === 'yes';
    let clientLat = '0';
    let clientLng = '0';
    if (isServiceOnCurrentLocation) {
      try {
        const uSnap = await firestore.collection('users').doc(userId).get();
        if (uSnap.exists) {
          const ud = uSnap.data() || {};
          clientLat = String(ud.lat ?? '0');
          clientLng = String(ud.lng ?? '0');
        }
      } catch (e) { console.warn('\u26a0\ufe0f user geo lookup for reassign:', e.message);
        // ignore
      }
    } else {
      clientLat = String(bookingData.other_lat ?? bookingData.user_lat ?? '0');
      clientLng = String(bookingData.other_lng ?? bookingData.user_lng ?? '0');
    }

    const taskId = String(bookingData.task_id || '').trim();
    const scheduledDate = String(bookingData.scheduled_date || '').trim();
    const scheduledTime = String(bookingData.scheduled_time || '').trim();
    const categoryId = String(bookingData.category_id || bookingData.categoryId || '').trim() || null;
    const categoryName = String(bookingData.category_name || bookingData.categoryName || '').trim() || null;

    const newArtisanId = await findAvailableArtisanByLocation({
      taskId,
      scheduledDate,
      scheduledTime,
      userLat: clientLat,
      userLng: clientLng,
      excludeArtisanId: artisanId || null,
      categoryId,
      categoryName,
      bookingId,
    });

    if (!newArtisanId) {
      // Fallback: escalate to admin.
      await bookingRef.set(
        {
          status: 'pending_assignment',
          is_rfq: 'no',
          order_type: 'order',
          service_provider_id: 'admin',
          artisan_confirmed: 'pending',
          reassignment_requested: 'yes',
          reassignment_reason: reason,
          reassignment_requested_at: now,
          updated_at: now,
        },
        { merge: true }
      );

      if (tmId) {
        await firestore.collection('tasksManagement').doc(tmId).set(
          {
            status: 'closed',
            closed_date: now,
            closed_reason: 'reassignment_requested',
            updated_at: now,
          },
          { merge: true }
        );
      }

      // Best-effort notify user via notifications collection.
      await writePersonalNotification({
        userId,
        userType: 'user',
        title: 'Booking reassignment in progress',
        message: 'We are assigning a new artisan. You will be notified shortly.',
        data: { booking_id: bookingId, status: 'pending_assignment' },
      });

      return { ok: true, status: 200, data: { reassignment: 'admin_required' } };
    }

    // Auto-assigned to a new artisan.
    const prevTmId = tmId;
    const prevReassignRaw = String(bookingData.reassigned_count ?? bookingData.reassignedCount ?? '0').trim();
    const prevReassign = Number.parseInt(prevReassignRaw, 10);
    const reassignCount = Number.isFinite(prevReassign) ? prevReassign + 1 : 1;

    await bookingRef.set(
      {
        service_provider_id: newArtisanId,
        artisan_confirmed: 'pending',
        reassigned_count: String(reassignCount),
        reassignment_requested: 'yes',
        reassignment_reason: reason,
        reassignment_requested_at: now,
        status: 'pending',
        updated_at: now,
      },
      { merge: true }
    );

    if (prevTmId) {
      await firestore.collection('tasksManagement').doc(prevTmId).set(
        {
          status: 'closed',
          closed_date: now,
          closed_reason: 'reassigned',
          updated_at: now,
        },
        { merge: true }
      );
    }

    const newTmId = await createTasksManagementRequestForFutureBooking({
      bookingIdLocal: bookingId,
      bookingDataLocal: { ...bookingData, service_provider_id: newArtisanId },
      artisanIdLocal: newArtisanId,
    });

    // Notify new artisan + user.
    const providerDoc = await getServiceProviderDocByAnyId(newArtisanId);
    await writePersonalNotificationForProviderDoc(
      providerDoc,
      'New booking assigned',
      `New booking assigned for ${scheduledDate || 'the scheduled date'} at ${scheduledTime || 'the scheduled time'}.`,
      { booking_id: bookingId, tasks_management_id: newTmId || null, is_reassignment: true, type: 'new_booking' }
    );

    await writePersonalNotification({
      userId,
      userType: 'user',
      title: 'Booking reassigned',
      message: 'Your booking has been reassigned to another nearby artisan who will confirm shortly.',
      data: { booking_id: bookingId, service_provider_id: newArtisanId, tasks_management_id: newTmId || null },
    });

    return {
      ok: true,
      status: 200,
      data: {
        reassignment: 'auto_assigned',
        booking_id: bookingId,
        new_artisan_id: newArtisanId,
        tasks_management_id: newTmId || null,
      },
    };
  }

  // ── New Tier A: get_transaction_history ──────────────────────────
  if (action === 'get_transaction_history') {
    try {
      const limit = Math.min(Math.max(Number(payload.limit) || 20, 1), 50);
      const snap1 = await firestore.collection('transactionLogs')
        .where('transaction_by', '==', actorUid)
        .limit(limit)
        .get();
      const snap2 = await firestore.collection('transactionLogs')
        .where('user_id', '==', actorUid)
        .limit(limit)
        .get();
      const seen = new Set();
      const items = [];
      for (const doc of [...snap1.docs, ...snap2.docs]) {
        if (seen.has(doc.id)) continue;
        seen.add(doc.id);
        const d = doc.data() || {};
        items.push({
          id: doc.id,
          amount: d.amount || '0',
          type: d.type || '',
          subtype: d.subtype || '',
          direction: d.direction || '',
          status: d.status || '',
          transaction_at: d.transaction_at || '',
          booking_id: d.booking_id || '',
          task_name: d.task_name || '',
        });
      }
      items.sort((a, b) => (b.transaction_at || '').localeCompare(a.transaction_at || ''));
      return { ok: true, status: 200, data: { transactions: items.slice(0, limit) } };
    } catch (e) {
      return { ok: false, status: 500, error: e.message || 'failed' };
    }
  }

  // ── New Tier A: get_deposit_requests ────────────────────────────
  if (action === 'get_deposit_requests') {
    try {
      const limit = Math.min(Math.max(Number(payload.limit) || 20, 1), 50);
      const snap = await firestore.collection('requests')
        .where('requestBy', '==', actorUid)
        .limit(limit)
        .get();
      const items = snap.docs.map((doc) => {
        const d = doc.data() || {};
        return {
          id: doc.id,
          amount: d.amount || '0',
          status: d.status || 'pending',
          created_at: d.createdAt || d.created_at || '',
          proof_url: d.image || d.proof_url || '',
        };
      });
      return { ok: true, status: 200, data: { deposits: items } };
    } catch (e) {
      return { ok: false, status: 500, error: e.message || 'failed' };
    }
  }

  // ── New Tier A: get_service_categories ──────────────────────────
  if (action === 'get_service_categories') {
    try {
      const snap = await firestore.collection('tasksCategories').limit(50).get();
      const cats = snap.docs.map((doc) => {
        const d = doc.data() || {};
        return {
          id: doc.id,
          name: d.name || d.category_name || d.title || doc.id,
          description: d.description || '',
          status: d.status || 'published',
        };
      }).filter(c => {
        const s = String(c.status).toLowerCase();
        return !s || s === 'publish' || s === 'published' || s === 'approved';
      });
      return { ok: true, status: 200, data: { categories: cats } };
    } catch (e) {
      return { ok: false, status: 500, error: e.message || 'failed' };
    }
  }

  // ── New Tier A: get_notifications ──────────────────────────────
  if (action === 'get_notifications') {
    try {
      const limit = Math.min(Math.max(Number(payload.limit) || 15, 1), 30);
      // Try user-specific notifications collection
      const snap = await firestore.collection('users').doc(actorUid)
        .collection('notifications')
        .orderBy('created_at', 'desc')
        .limit(limit)
        .get();
      const items = snap.docs.map((doc) => {
        const d = doc.data() || {};
        return {
          id: doc.id,
          title: d.title || '',
          message: d.message || d.body || '',
          read: d.read || false,
          created_at: d.created_at || '',
        };
      });
      return { ok: true, status: 200, data: { notifications: items, count: items.length } };
    } catch (e) {
      // Notifications subcollection may not exist — return empty
      return { ok: true, status: 200, data: { notifications: [], count: 0 } };
    }
  }

  // ── New Tier A: get_scheduled_bookings ─────────────────────────
  if (action === 'get_scheduled_bookings') {
    try {
      const snap = await firestore.collection('futureBookings')
        .where('user_id', '==', actorUid)
        .limit(30)
        .get();
      const upcoming = [];
      const nowMs = Date.now();
      for (const doc of snap.docs) {
        const d = doc.data() || {};
        const status = String(d.status || '').toLowerCase();
        if (status === 'cancelled' || status === 'done' || status === 'completed') continue;
        const scheduledDate = d.scheduled_date || d.scheduledDate || '';
        const scheduledTime = d.scheduled_time || d.scheduledTime || '';
        upcoming.push({
          booking_id: doc.id,
          task_name: d.task_name || d.taskName || '',
          status: d.status || '',
          scheduled_date: scheduledDate,
          scheduled_time: scheduledTime,
          artisan_id: d.service_provider_id || '',
          order_no: d.order_no || '',
        });
      }
      // Sort by scheduled_date ascending
      upcoming.sort((a, b) => (a.scheduled_date || '').localeCompare(b.scheduled_date || ''));
      return { ok: true, status: 200, data: { bookings: upcoming } };
    } catch (e) {
      return { ok: false, status: 500, error: e.message || 'failed' };
    }
  }

  // ── New Tier A: get_artisan_info ───────────────────────────────
  if (action === 'get_artisan_info') {
    const artisanIdInput = String(payload.artisan_id || payload.service_provider_id || '').trim();
    if (!artisanIdInput) return { ok: false, status: 400, error: 'artisan_id required' };
    try {
      const doc = await getServiceProviderDocByAnyId(artisanIdInput);
      if (!doc) return { ok: false, status: 404, error: 'artisan_not_found' };
      const d = doc.data() || {};
      return {
        ok: true,
        status: 200,
        data: {
          id: doc.id,
          name: d.name || d.displayName || d.full_name || '',
          phone: d.phone || d.phoneNumber || '',
          rating: d.rating || d.averageRating || null,
          reviews_count: d.reviews_count || d.reviewsCount || 0,
          skills: d.skills || d.services || [],
          location: d.location || d.address || '',
          active: d.isActive ?? d.active ?? true,
        },
      };
    } catch (e) {
      return { ok: false, status: 500, error: e.message || 'failed' };
    }
  }

  // ── New Tier B: submit_rating ──────────────────────────────────
  if (action === 'submit_rating') {
    const targetBookingId = String(payload.booking_id || bookingId || '').trim();
    if (!targetBookingId) return { ok: false, status: 400, error: 'booking_id required' };

    const rating = Number(payload.rating);
    if (!Number.isFinite(rating) || rating < 1 || rating > 5) {
      return { ok: false, status: 400, error: 'rating must be 1-5' };
    }

    const review = String(payload.review || payload.comment || '').trim();

    try {
      const bRef = firestore.collection('futureBookings').doc(targetBookingId);
      const bSnap = await bRef.get();
      if (!bSnap.exists) return { ok: false, status: 404, error: 'booking_not_found' };
      const bData = bSnap.data() || {};

      if (String(bData.user_id || '').trim() !== actorUid) {
        return { ok: false, status: 403, error: 'only booking owner can rate' };
      }

      const artisanToRate = String(bData.service_provider_id || '').trim();
      if (!artisanToRate) return { ok: false, status: 400, error: 'no artisan assigned' };

      // Save rating on booking
      await bRef.set({
        rating: rating,
        review: review,
        rated_at: now,
        updated_at: now,
      }, { merge: true });

      // Save review in reviews subcollection on artisan
      try {
        const providerDoc = await getServiceProviderDocByAnyId(artisanToRate);
        if (providerDoc) {
          await firestore.collection('serviceProvider').doc(providerDoc.id)
            .collection('reviews')
            .doc(targetBookingId)
            .set({
              booking_id: targetBookingId,
              user_id: actorUid,
              rating: rating,
              review: review,
              created_at: now,
            });
        }
      } catch (e) { console.warn('\u26a0\ufe0f review write best-effort:', e.message); }

      return { ok: true, status: 200, data: { rated: true, booking_id: targetBookingId, rating } };
    } catch (e) {
      return { ok: false, status: 500, error: e.message || 'failed' };
    }
  }

  // ── New Tier B: submit_complaint ───────────────────────────────
  if (action === 'submit_complaint') {
    const subject = String(payload.subject || payload.title || 'Complaint').trim();
    const description = String(payload.description || payload.message || '').trim();
    if (!description) return { ok: false, status: 400, error: 'description required' };

    const relatedBookingId = String(payload.booking_id || bookingId || '').trim();

    try {
      const complaintId = randomId('complaint-');
      await firestore.collection('complaints').doc(complaintId).set({
        id: complaintId,
        user_id: actorUid,
        subject,
        description,
        booking_id: relatedBookingId || null,
        status: 'open',
        created_at: now,
        updated_at: now,
      });

      // Notify admin
      await writeAdminNotification({
        title: 'New complaint',
        message: `Complaint from user: ${subject}`,
        data: { complaint_id: complaintId, user_id: actorUid },
      });

      return { ok: true, status: 200, data: { complaint_id: complaintId, status: 'open' } };
    } catch (e) {
      return { ok: false, status: 500, error: e.message || 'failed' };
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // PHASE 4 — Admin Automation Tools (Tier B, admin-only)
  // ═══════════════════════════════════════════════════════════════════════════

  if (action === 'admin_bulk_reassign') {
    if (actorRole !== 'admin') return { ok: false, status: 403, error: 'admin_only' };
    const bookingIds = Array.isArray(payload.booking_ids) ? payload.booking_ids : [];
    const newArtisanId = String(payload.new_artisan_id || '').trim();
    const reason = String(payload.reason || 'Admin bulk reassignment').trim();
    if (!bookingIds.length || !newArtisanId) {
      return { ok: false, status: 400, error: 'missing_booking_ids_or_new_artisan_id' };
    }
    if (bookingIds.length > 20) {
      return { ok: false, status: 400, error: 'max_20_bookings_per_bulk_reassign' };
    }
    const results = [];
    for (const bid of bookingIds) {
      const id = String(bid).trim();
      if (!id) continue;
      try {
        const bRef = firestore.collection('futureBookings').doc(id);
        const bSnap = await bRef.get();
        if (!bSnap.exists) { results.push({ booking_id: id, ok: false, error: 'not_found' }); continue; }
        await bRef.update({
          service_provider_id: newArtisanId,
          reassigned_at: now,
          reassigned_by: actorUid,
          reassignment_reason: reason,
        });
        results.push({ booking_id: id, ok: true });
      } catch (e) {
        results.push({ booking_id: id, ok: false, error: e.message });
      }
    }
    return { ok: true, status: 200, data: { reassigned: results.filter(r => r.ok).length, total: bookingIds.length, results } };
  }

  if (action === 'admin_close_stale_cases') {
    if (actorRole !== 'admin') return { ok: false, status: 403, error: 'admin_only' };
    const maxAgeHours = Number(payload.max_age_hours) || 48;
    const cutoff = new Date(Date.now() - maxAgeHours * 3600 * 1000).toISOString();
    try {
      const snap = await firestore.collection('assistant_cases')
        .where('state', 'in', ['open', 'in_progress'])
        .where('created_at', '<', cutoff)
        .limit(50)
        .get();
      let closed = 0;
      for (const doc of snap.docs) {
        await doc.ref.update({
          state: 'resolved',
          resolved_at: now,
          resolved_by: actorUid,
          resolution_note: `Auto-closed: stale for ${maxAgeHours}+ hours`,
        });
        closed++;
      }
      return { ok: true, status: 200, data: { closed, checked: snap.size } };
    } catch (e) {
      return { ok: false, status: 500, error: e.message };
    }
  }

  if (action === 'admin_broadcast_notification') {
    if (actorRole !== 'admin') return { ok: false, status: 403, error: 'admin_only' };
    const title = String(payload.title || '').trim();
    const body = String(payload.body || '').trim();
    const targetRole = String(payload.target_role || 'all').trim();
    if (!title || !body) return { ok: false, status: 400, error: 'missing_title_or_body' };
    if (title.length > 100 || body.length > 500) return { ok: false, status: 400, error: 'title_max_100_body_max_500' };
    try {
      const notifId = randomId('broadcast-');
      await firestore.collection('admin_broadcasts').doc(notifId).set({
        id: notifId,
        title, body,
        target_role: targetRole,
        sent_by: actorUid,
        sent_at: now,
        status: 'pending',
      });
      return { ok: true, status: 200, data: { broadcast_id: notifId, target_role: targetRole } };
    } catch (e) {
      return { ok: false, status: 500, error: e.message };
    }
  }

  if (action === 'admin_flag_user') {
    if (actorRole !== 'admin') return { ok: false, status: 403, error: 'admin_only' };
    const targetUid = String(payload.user_id || payload.uid || '').trim();
    const flagReason = String(payload.reason || '').trim();
    const flagType = String(payload.flag_type || 'warning').trim();
    if (!targetUid) return { ok: false, status: 400, error: 'missing_user_id' };
    if (!flagReason) return { ok: false, status: 400, error: 'missing_reason' };
    if (!['warning', 'suspend', 'ban'].includes(flagType)) {
      return { ok: false, status: 400, error: 'flag_type_must_be_warning_suspend_or_ban' };
    }
    try {
      const flagId = randomId('flag-');
      await firestore.collection('user_flags').doc(flagId).set({
        id: flagId,
        user_id: targetUid,
        flag_type: flagType,
        reason: flagReason,
        flagged_by: actorUid,
        flagged_at: now,
        status: 'active',
      });
      if (flagType === 'suspend' || flagType === 'ban') {
        await firestore.collection('users').doc(targetUid).update({
          account_status: flagType === 'ban' ? 'banned' : 'suspended',
          account_status_reason: flagReason,
          account_status_updated_at: now,
          account_status_updated_by: actorUid,
        });
      }
      return { ok: true, status: 200, data: { flag_id: flagId, flag_type: flagType, user_id: targetUid } };
    } catch (e) {
      return { ok: false, status: 500, error: e.message };
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // PHASE 5.1 — Finance Read-Only Tools (Tier A)
  // ═══════════════════════════════════════════════════════════════════════════

  if (action === 'get_finance_summary') {
    if (actorRole !== 'admin') return { ok: false, status: 403, error: 'admin_only' };
    const period = String(payload.period || 'today').trim().toLowerCase();
    try {
      let startDate;
      const nowDate = new Date();
      if (period === 'today') {
        startDate = new Date(nowDate.getFullYear(), nowDate.getMonth(), nowDate.getDate());
      } else if (period === 'week') {
        startDate = new Date(Date.now() - 7 * 86400000);
      } else if (period === 'month') {
        startDate = new Date(Date.now() - 30 * 86400000);
      } else {
        startDate = new Date(Date.now() - 86400000);
      }
      const snap = await firestore.collection('transactionLogs')
        .where('transaction_at', '>=', startDate.toISOString())
        .orderBy('transaction_at', 'desc')
        .limit(1000)
        .get();
      let totalIn = 0, totalOut = 0, refunds = 0, fees = 0, count = 0;
      for (const d of snap.docs) {
        const tx = d.data() || {};
        const amt = toNumber(tx.amount) || 0;
        const dir = String(tx.direction || '').trim().toLowerCase();
        const type = String(tx.transaction_type || tx.type || '').trim().toLowerCase();
        if (dir === 'in') totalIn += amt;
        if (dir === 'out') totalOut += amt;
        if (type.includes('refund')) refunds += amt;
        if (type.includes('fee') || type.includes('commission')) fees += amt;
        count++;
      }
      return {
        ok: true, status: 200, data: {
          period, transaction_count: count,
          total_in: Number(totalIn.toFixed(2)),
          total_out: Number(totalOut.toFixed(2)),
          net: Number((totalIn - totalOut).toFixed(2)),
          refunds: Number(refunds.toFixed(2)),
          fees_commissions: Number(fees.toFixed(2)),
        }
      };
    } catch (e) {
      return { ok: false, status: 500, error: e.message };
    }
  }

  if (action === 'get_daily_revenue') {
    if (actorRole !== 'admin') return { ok: false, status: 403, error: 'admin_only' };
    const days = Math.min(30, Math.max(1, Number(payload.days) || 7));
    try {
      const startDate = new Date(Date.now() - days * 86400000).toISOString();
      const snap = await firestore.collection('transactionLogs')
        .where('transaction_at', '>=', startDate)
        .where('direction', '==', 'in')
        .orderBy('transaction_at', 'desc')
        .limit(2000)
        .get();
      const byDay = {};
      for (const d of snap.docs) {
        const tx = d.data() || {};
        const dateStr = String(tx.transaction_at || '').slice(0, 10);
        if (!dateStr) continue;
        byDay[dateStr] = (byDay[dateStr] || 0) + (toNumber(tx.amount) || 0);
      }
      return { ok: true, status: 200, data: { days, revenue_by_day: byDay } };
    } catch (e) {
      return { ok: false, status: 500, error: e.message };
    }
  }

  if (action === 'get_failed_payments') {
    if (actorRole !== 'admin') return { ok: false, status: 403, error: 'admin_only' };
    const limit = Math.min(100, Math.max(1, Number(payload.limit) || 20));
    try {
      const snap = await firestore.collection('transactionLogs')
        .where('status', 'in', ['failed', 'error', 'declined', 'cancelled'])
        .orderBy('transaction_at', 'desc')
        .limit(limit)
        .get();
      const failures = snap.docs.map(d => {
        const tx = d.data() || {};
        return {
          id: d.id,
          amount: String(tx.amount || ''),
          status: String(tx.status || ''),
          type: String(tx.transaction_type || tx.type || ''),
          user_id: String(tx.user_id || tx.client_id || ''),
          booking_id: String(tx.booking_id || ''),
          error_reason: String(tx.error_reason || tx.failure_reason || ''),
          transaction_at: String(tx.transaction_at || ''),
        };
      });
      return { ok: true, status: 200, data: { count: failures.length, failures } };
    } catch (e) {
      return { ok: false, status: 500, error: e.message };
    }
  }

  if (action === 'get_refund_history') {
    if (actorRole !== 'admin') return { ok: false, status: 403, error: 'admin_only' };
    const limit = Math.min(100, Math.max(1, Number(payload.limit) || 20));
    try {
      const snap = await firestore.collection('finance_requests')
        .where('type', '==', 'refund')
        .orderBy('created_at', 'desc')
        .limit(limit)
        .get();
      const refunds = snap.docs.map(d => {
        const r = d.data() || {};
        return {
          id: d.id, amount: String(r.amount || ''),
          status: String(r.status || ''), reason: String(r.reason || ''),
          user_id: String(r.target_user_id || ''), booking_id: String(r.booking_id || ''),
          requested_by: String(r.requested_by || ''), approved_by: String(r.approved_by || ''),
          created_at: String(r.created_at || ''), resolved_at: String(r.resolved_at || ''),
        };
      });
      return { ok: true, status: 200, data: { count: refunds.length, refunds } };
    } catch (e) {
      return { ok: false, status: 500, error: e.message };
    }
  }

  if (action === 'get_payout_status') {
    if (actorRole !== 'admin') return { ok: false, status: 403, error: 'admin_only' };
    const targetId = String(payload.user_id || payload.artisan_id || payload.partner_id || '').trim();
    try {
      let q = firestore.collection('finance_requests').where('type', '==', 'payout').orderBy('created_at', 'desc').limit(20);
      if (targetId) q = firestore.collection('finance_requests').where('type', '==', 'payout').where('target_user_id', '==', targetId).orderBy('created_at', 'desc').limit(20);
      const snap = await q.get();
      const payouts = snap.docs.map(d => {
        const p = d.data() || {};
        return {
          id: d.id, amount: String(p.amount || ''), status: String(p.status || ''),
          target_user_id: String(p.target_user_id || ''), method: String(p.method || ''),
          created_at: String(p.created_at || ''), resolved_at: String(p.resolved_at || ''),
        };
      });
      return { ok: true, status: 200, data: { count: payouts.length, payouts } };
    } catch (e) {
      return { ok: false, status: 500, error: e.message };
    }
  }

  if (action === 'get_fraud_alerts') {
    if (actorRole !== 'admin') return { ok: false, status: 403, error: 'admin_only' };
    const limit = Math.min(100, Math.max(1, Number(payload.limit) || 20));
    try {
      const snap = await firestore.collection('fraud_alerts')
        .where('status', '==', 'open')
        .orderBy('created_at', 'desc')
        .limit(limit)
        .get();
      const alerts = snap.docs.map(d => {
        const a = d.data() || {};
        return {
          id: d.id, alert_type: String(a.alert_type || ''),
          severity: String(a.severity || ''), description: String(a.description || ''),
          user_id: String(a.user_id || ''), amount: String(a.amount || ''),
          created_at: String(a.created_at || ''), status: String(a.status || ''),
        };
      });
      return { ok: true, status: 200, data: { count: alerts.length, alerts } };
    } catch (e) {
      return { ok: false, status: 500, error: e.message };
    }
  }

  return { ok: false, status: 400, error: 'unknown_action' };
}

// Phase 3 handlers (handleGetMessages, handleSendMessageToArtisan, handleSendMessageToAdmin,
// handleGetCaseStatus, handleCreateCase, handleUpdateCase) have been inlined into
// executeBookingAction() above for correct access to scoped helpers (now, writeAdminNotification,
// writePersonalNotification, writePersonalNotificationForProviderDoc, getServiceProviderDocByAnyId).

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
  } catch (e) { console.warn('\u26a0\ufe0f SDK version require:', e.message);
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
    } catch (e) { console.warn('\u26a0\ufe0f SDK version fallback require:', e.message);
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
  res.json({ 
    status: 'ok', 
    message: 'Livekit Token Server is running',
    timestamp: new Date().toISOString(),
    sdkVersion: getSdkVersion(),
    firebase: {
      configured: (() => {
        initFirebaseIfPossible();
        return !firebaseInitError;
      })(),
    },
    livekit: {
      wsUrl: wsUrl || null,
      httpUrl: httpUrl || null,
      agentName: getAgentName(),
      apiKeyConfigured: !!apiKey,
      apiSecretConfigured: !!apiSecret,
    },
  });
});

// ── Public pricing test endpoint (dev only) ──
app.get('/api/test-pricing', async (req, res) => {
  // Public pricing endpoint — used by voice agent for service/pricing lookups.
  try {
    const firestore = (() => { initFirebaseIfPossible(); if (firebaseInitError) return null; return admin.firestore(); })();
    if (!firestore) return res.status(500).json({ error: 'firebase_not_configured' });

    const q = String(req.query.q || req.query.query || '').trim().toLowerCase();

    // Synonym/related-terms expansion (same as authenticated endpoint)
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

    let expandedQ = q;
    if (q) {
      for (const [key, synonyms] of Object.entries(SYNONYMS)) {
        if (q.includes(key)) {
          expandedQ += ' ' + synonyms.join(' ');
        }
        for (const syn of synonyms) {
          if (syn.length >= 3 && q.includes(syn) && !expandedQ.includes(key)) {
            expandedQ += ' ' + key + ' ' + synonyms.join(' ');
            break;
          }
        }
      }
    }

    const searchTokens = expandedQ
      .replace(/[^a-z0-9\s]/g, ' ')
      .split(/\s+/)
      .filter(t => t.length >= 2);
    const uniqueTokens = [...new Set(searchTokens)];

    // Load categories
    const catSnap = await firestore.collection('categories').get();
    const categoryMap = {};
    const categoryList = [];
    for (const doc of catSnap.docs) {
      const d = doc.data() || {};
      const name = String(d.name || '').trim();
      const id = String(d.id || doc.id).trim();
      if (name) {
        categoryMap[id] = name;
        categoryMap[doc.id] = name;
        categoryList.push({ docId: doc.id, id, name, status: d.status || null });
      }
    }

    // Load tasks
    let taskDocs = [];
    const taskSnap = await firestore.collection('tasks').limit(200).get();
    taskDocs = taskSnap.docs;

    const services = [];
    const allServices = [];
    for (const doc of taskDocs) {
      const d = doc.data() || {};
      const name = String(d.name || d.title || d.task_name || d.taskName || '').trim();
      if (!name) continue;

      const costRaw = d.cost ?? d.price ?? d.amount ?? d.unit_price;
      const cost = (() => {
        if (costRaw == null) return null;
        const n = Number.parseFloat(String(costRaw).replace(/[^0-9.\-]/g, ''));
        return Number.isFinite(n) ? n : null;
      })();

      const catId = String(d.categoryId || d.category_id || d.subCategoryId || d.sub_category_id || d.subcategoryId || d.subcategory_id || '').trim();
      const catName = categoryMap[catId] || '';

      const entry = {
        task_id: doc.id,
        name,
        cost,
        cost_formatted: cost != null && cost > 0 ? `R${cost.toFixed(2)}` : 'Quote on request',
        category_id: catId,
        category_name: catName,
        status: d.status || null,
      };

      allServices.push(entry);

      if (uniqueTokens.length > 0) {
        const combined = `${name} ${catName}`.toLowerCase();
        let matches = false;
        for (const token of uniqueTokens) {
          if (combined.includes(token)) { matches = true; break; }
        }
        if (!matches) continue;
      }

      services.push(entry);
    }

    const finalServices = services.length > 0 ? services : allServices;
    finalServices.sort((a, b) => (a.category_name || '').localeCompare(b.category_name || '') || (a.name || '').localeCompare(b.name || ''));

    res.json({
      ok: true,
      categories_count: categoryList.length,
      tasks_count: taskDocs.length,
      matched: finalServices.length,
      filtered: services.length > 0,
      query: q || 'all',
      expanded: expandedQ !== q ? expandedQ : undefined,
      categories: categoryList.slice(0, 20),
      services: finalServices.slice(0, 30),
      message: services.length > 0
        ? `Found ${services.length} service(s) matching "${q}".`
        : allServices.length > 0
          ? `No exact match for "${q}", showing all ${allServices.length} available services.`
          : 'No services found.',
    });
  } catch (e) {
    res.status(500).json({ error: String(e) });
  }
});

/**
 * Start a voice session (recommended for mobile)
 * POST /api/voice/start
 * Body: { roomName?: string, participantName?: string, metadata?: string }
 * Returns: { roomName, participantName, token, url }
 */
app.post('/api/voice/start', assistantLimiter, async (req, res) => {
  try {
    const env = validateLiveKitEnv(res);
    if (!env) return;

    const requireAppCheck = isEnvTruthy('APP_CHECK_REQUIRED');
    const requireSessionBinding = isEnvTruthy('ASSISTANT_SESSION_BINDING_REQUIRED');
    const voiceSessionTtlMinutes = parseIntEnv('VOICE_SESSION_TTL_MINUTES', 60);

    if (requireSessionBinding) {
      initFirebaseIfPossible();
      if (firebaseInitError) {
        return res.status(503).json({
          error: 'Firebase Admin not configured',
          message: 'Voice session binding requires Firebase Admin + Firestore',
          request_id: req.requestId || null,
        });
      }
    }

    const appCheck = await verifyFirebaseAppCheck(req, res, { required: requireAppCheck });
    if (requireAppCheck && !appCheck) return;

    const agentName = getAgentName();
    const httpUrl = getLiveKitHttpUrl();

    const roomName = req.body.roomName || `square15-voice-${Date.now()}`;

    // Bind the LiveKit identity to the authenticated Firebase user when possible.
    // If session binding is required, we must have auth + Firestore so we can validate actions.
    let participantName = req.body.participantName || `user-${Date.now()}`;
    let sessionId = randomId('vs-');

    const sessionNonce = crypto.randomBytes(24).toString('hex');
    const expiresAt = new Date(Date.now() + voiceSessionTtlMinutes * 60_000).toISOString();

    // Extract idToken BEFORE the try block so it's accessible in the metadata enrichment below
    const idToken = getBearerToken(req);

    try {
      initFirebaseIfPossible();
      if (!firebaseInitError) {
        const firestore = admin.firestore();
        if (!idToken) {
          if (requireSessionBinding) {
            return res.status(401).json({
              error: 'Unauthorized',
              message: 'Voice start requires Authorization when session binding is enabled',
              request_id: req.requestId || null,
            });
          }
        } else {
          const decoded = await admin.auth().verifyIdToken(idToken);
          const uid = decoded.uid;
          const role = await resolveRole({ firestore, uid, decodedToken: decoded });
          const safeRole = role === 'admin' || role === 'artisan' ? role : 'client';
          participantName = `${safeRole}-${uid}-${Date.now()}`;

          await firestore.collection('assistant_voice_sessions').doc(sessionId).set({
            id: sessionId,
            uid,
            role: safeRole,
            room_name: roomName,
            participant_name: participantName,
            session_nonce: sessionNonce,
            expires_at: expiresAt,
            created_at: nowIso(),
            request_id: req.requestId || null,
            client_ip: getClientIp(req),
            user_agent: String(req.headers['user-agent'] || ''),
            app_check: (appCheck && appCheck.ok && appCheck.decoded)
              ? {
                  app_id: appCheck.decoded.appId || null,
                  token_consumed: true,
                }
              : {
                  token_consumed: false,
                },
          });
        }
      }
    } catch (e) { console.warn('\u26a0\ufe0f app-check verification:', e.message);
      // Best-effort only
    }
    const metadata = typeof req.body.metadata === 'string' ? req.body.metadata : '';

    // ── Enrich participant metadata with Firebase credentials ──
    // The agent worker reads firebase_token from the participant metadata
    // to initialize its backend API client. This eliminates race conditions
    // from in-band credential delivery via data channel / setMetadata.
    let enrichedMetadata = metadata;
    try {
      const parsed = metadata ? JSON.parse(metadata) : {};
      if (idToken) {
        parsed.firebase_token = idToken;
      }
      parsed.voice_session_id = sessionId;
      parsed.voice_session_nonce = sessionNonce;
      enrichedMetadata = JSON.stringify(parsed);
    } catch (e) { console.warn('\u26a0\ufe0f metadata JSON parse:', e.message);
      // If metadata isn't valid JSON, create a fresh object
      enrichedMetadata = JSON.stringify({
        voice_session_id: sessionId,
        voice_session_nonce: sessionNonce,
      });
    }

    // 1) Generate access token (server-side) with 15-minute TTL
    const at = new AccessToken(env.apiKey, env.apiSecret, {
      identity: participantName,
      name: participantName,
      metadata: enrichedMetadata,
      ttl: '15m',
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
      sessionId,
      // sessionNonce kept server-side only for security
      sessionExpiresAt: expiresAt,
      request_id: req.requestId || null,
    });
  } catch (error) {
    console.error('❌ Error starting voice session:', error);
    res.status(500).json({
      error: 'Voice session start failed',
      message: error && error.message ? error.message : 'Unknown error',
      request_id: req.requestId || null,
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
 * Secure assistant action execution
 * POST /api/action/execute
 * Headers: Authorization: Bearer <Firebase ID Token>
 * Optional: Idempotency-Key: <string>
 * Body: { action: string, payload: object, context?: { session_id?: string, room_name?: string } }
 */
app.post('/api/action/execute', assistantLimiter, async (req, res) => {
  const startedAt = nowIso();
  const idempotencyKey = getIdempotencyKey(req);
  const action = normalizeAction(req.body && req.body.action);
  const payload = (req.body && typeof req.body.payload === 'object' && req.body.payload) || {};
  const context = (req.body && typeof req.body.context === 'object' && req.body.context) || {};

  const requireAppCheck = isEnvTruthy('APP_CHECK_REQUIRED');
  const requireSessionBinding = isEnvTruthy('ASSISTANT_SESSION_BINDING_REQUIRED');
  const proposeConfirmRequired = isEnvTruthy('PROPOSE_CONFIRM_REQUIRED');

  const tier = actionTier(action);
  if (!tier) {
    return res.status(400).json({
      error: 'unknown_action',
      message: 'Unknown or unsupported action',
      idempotencyKey,
      request_id: req.requestId || null,
    });
  }

  // Financial controls: Tier C must never execute via direct endpoint.
  if (tierRank(tier) >= tierRank('C')) {
    return res.status(403).json({
      error: 'tier_c_blocked',
      message: 'This action requires step-up authorization and/or admin approval',
      idempotencyKey,
      request_id: req.requestId || null,
    });
  }

  // When enabled, require server-side propose->confirm for Tier B+.
  if (proposeConfirmRequired && tierRank(tier) >= tierRank('B')) {
    return res.status(409).json({
      error: 'proposal_required',
      message: 'Use /api/action/propose then /api/action/confirm for this action',
      idempotencyKey,
      request_id: req.requestId || null,
    });
  }

  const firestore = requireFirebase(res);
  if (!firestore) return;

  const appCheck = await verifyFirebaseAppCheck(req, res, { required: requireAppCheck });
  if (requireAppCheck && !appCheck) return;

  const decoded = await verifyFirebaseAuth(req, res);
  if (!decoded) return;

  const actorUid = decoded.uid;
  const actorRole = await resolveRole({ firestore, uid: actorUid, decodedToken: decoded });

  const sessionValidation = await enforceAssistantSessionBinding({
    firestore,
    req,
    actorUid,
    action,
    context,
    required: requireSessionBinding,
  });
  if (!sessionValidation.ok) {
    return res.status(sessionValidation.status).json({
      error: sessionValidation.error,
      message: sessionValidation.message,
      idempotencyKey,
      request_id: req.requestId || null,
    });
  }

  // Idempotency/audit doc prevents double execution.
  const auditRef = firestore.collection('assistant_action_audit').doc(idempotencyKey);
  const existing = await auditRef.get();
  if (existing.exists) {
    const data = existing.data() || {};
    if (data.status === 'success') {
      return res.json({
        success: true,
        idempotencyKey,
        action,
        reused: true,
        result: data.result || null,
        request_id: req.requestId || null,
      });
    }
    if (data.status === 'started') {
      return res.status(409).json({
        error: 'duplicate_in_flight',
        message: 'This action is already being processed',
        idempotencyKey,
        request_id: req.requestId || null,
      });
    }
  }

  const auditBase = {
    id: idempotencyKey,
    created_at: startedAt,
    updated_at: startedAt,
    status: 'started',
    action,
    request_id: req.requestId || null,
    actor_uid: actorUid,
    actor_role: actorRole,
    booking_id: normalizeBookingId(payload) || null,
    context: {
      session_id: context.session_id || null,
      session_nonce: context.session_nonce || context.sessionNonce || null,
      room_name: context.room_name || null,
      client_ip: getClientIp(req),
    },
    payload: payload,
    app_check: (appCheck && appCheck.ok && appCheck.decoded)
      ? {
          app_id: appCheck.decoded.appId || null,
          enforced: requireAppCheck,
        }
      : {
          enforced: requireAppCheck,
        },
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
        request_id: req.requestId || null,
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
      },
    });

    return res.json({
      ok: true,
      success: true,
      idempotencyKey,
      action,
      result: result.data || null,
      data: result.data || null,
      request_id: req.requestId || null,
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
      request_id: req.requestId || null,
    });
  }
});

/**
 * Phase 1: propose an assistant action (server-side)
 * POST /api/action/propose
 * Headers: Authorization: Bearer <Firebase ID Token>
 * Optional: X-Firebase-AppCheck
 * Body: { action: string, payload: object, context?: { session_id?: string, session_nonce?: string, room_name?: string } }
 */
app.post('/api/action/propose', assistantLimiter, async (req, res) => {
  const startedAt = nowIso();
  const action = normalizeAction(req.body && req.body.action);
  const payload = (req.body && typeof req.body.payload === 'object' && req.body.payload) || {};
  const context = (req.body && typeof req.body.context === 'object' && req.body.context) || {};

  const requireAppCheck = isEnvTruthy('APP_CHECK_REQUIRED');
  const requireSessionBinding = isEnvTruthy('ASSISTANT_SESSION_BINDING_REQUIRED');
  const proposalTtlMinutes = parseIntEnv('PROPOSAL_TTL_MINUTES', 10);

  const tier = actionTier(action);
  if (!tier) {
    return res.status(400).json({
      error: 'unknown_action',
      message: 'Unknown or unsupported action',
      request_id: req.requestId || null,
    });
  }

  if (tierRank(tier) >= tierRank('C')) {
    return res.status(403).json({
      error: 'tier_c_blocked',
      message: 'This action requires step-up authorization and/or admin approval',
      request_id: req.requestId || null,
    });
  }

  const firestore = requireFirebase(res);
  if (!firestore) return;

  const appCheck = await verifyFirebaseAppCheck(req, res, { required: requireAppCheck });
  if (requireAppCheck && !appCheck) return;

  const decoded = await verifyFirebaseAuth(req, res);
  if (!decoded) return;

  const actorUid = decoded.uid;
  const actorRole = await resolveRole({ firestore, uid: actorUid, decodedToken: decoded });

  const sessionValidation = await enforceAssistantSessionBinding({
    firestore,
    req,
    actorUid,
    action,
    context,
    required: requireSessionBinding,
  });
  if (!sessionValidation.ok) {
    return res.status(sessionValidation.status).json({
      error: sessionValidation.error,
      message: sessionValidation.message,
      request_id: req.requestId || null,
    });
  }

  const proposalId = randomId('prop-');
  const expiresAt = new Date(Date.now() + proposalTtlMinutes * 60_000).toISOString();

  const bookingId = normalizeBookingId(payload) || null;
  const summary = `Proposed ${action}${bookingId ? ` (booking_id=${bookingId})` : ''}`;

  const proposalDoc = {
    id: proposalId,
    created_at: startedAt,
    updated_at: startedAt,
    expires_at: expiresAt,
    status: 'proposed',
    request_id: req.requestId || null,
    action,
    tier,
    actor_uid: actorUid,
    actor_role: actorRole,
    booking_id: bookingId,
    context: {
      session_id: context.session_id || null,
      session_nonce: context.session_nonce || context.sessionNonce || null,
      room_name: context.room_name || null,
      client_ip: getClientIp(req),
    },
    payload,
    summary,
    app_check: (appCheck && appCheck.ok && appCheck.decoded)
      ? { app_id: appCheck.decoded.appId || null, enforced: requireAppCheck }
      : { enforced: requireAppCheck },
  };

  try {
    await firestore.collection('assistant_action_proposals').doc(proposalId).set(proposalDoc);
  } catch (e) {
    return res.status(500).json({
      error: 'internal_error',
      message: 'Failed to create proposal',
      request_id: req.requestId || null,
    });
  }

  return res.json({
    success: true,
    proposalId,
    action,
    tier,
    summary,
    expiresAt,
    request_id: req.requestId || null,
  });
});

/**
 * Phase 1: confirm a proposed action (server-side)
 * POST /api/action/confirm
 * Headers: Authorization: Bearer <Firebase ID Token>
 * Optional: Idempotency-Key
 * Optional: X-Firebase-AppCheck
 * Body: { proposalId: string }
 */
app.post('/api/action/confirm', assistantLimiter, async (req, res) => {
  const startedAt = nowIso();
  const proposalId = String((req.body && (req.body.proposalId || req.body.proposal_id)) || '').trim();

  if (!proposalId) {
    return res.status(400).json({
      error: 'invalid_request',
      message: 'Missing proposalId',
      request_id: req.requestId || null,
    });
  }

  const requireAppCheck = isEnvTruthy('APP_CHECK_REQUIRED');
  const requireSessionBinding = isEnvTruthy('ASSISTANT_SESSION_BINDING_REQUIRED');

  const firestore = requireFirebase(res);
  if (!firestore) return;

  const appCheck = await verifyFirebaseAppCheck(req, res, { required: requireAppCheck });
  if (requireAppCheck && !appCheck) return;

  const decoded = await verifyFirebaseAuth(req, res);
  if (!decoded) return;

  const actorUid = decoded.uid;
  const actorRole = await resolveRole({ firestore, uid: actorUid, decodedToken: decoded });

  const proposalRef = firestore.collection('assistant_action_proposals').doc(proposalId);
  const proposalSnap = await proposalRef.get();
  if (!proposalSnap.exists) {
    return res.status(404).json({
      error: 'not_found',
      message: 'Proposal not found',
      request_id: req.requestId || null,
    });
  }

  const proposal = proposalSnap.data() || {};
  if (String(proposal.actor_uid || '').trim() !== actorUid) {
    return res.status(403).json({
      error: 'forbidden',
      message: 'This proposal does not belong to the current user',
      request_id: req.requestId || null,
    });
  }

  const status = String(proposal.status || '').trim().toLowerCase();
  if (status === 'confirmed' || status === 'success') {
    // Idempotent: if we have an audit record, return it.
    const auditId = String(proposal.audit_id || proposalId).trim();
    try {
      const auditSnap = await firestore.collection('assistant_action_audit').doc(auditId).get();
      const audit = auditSnap.exists ? (auditSnap.data() || {}) : null;
      if (audit && audit.status === 'success') {
        return res.json({
          success: true,
          reused: true,
          proposalId,
          idempotencyKey: auditId,
          action: String(proposal.action || ''),
          result: audit.result || null,
          request_id: req.requestId || null,
        });
      }
    } catch (e) { console.warn('\u26a0\ufe0f idempotency check:', e.message);
      // fall through
    }
  }

  if (status && status !== 'proposed') {
    return res.status(409).json({
      error: 'invalid_state',
      message: `Proposal is not confirmable (status=${status})`,
      request_id: req.requestId || null,
    });
  }

  const exp = String(proposal.expires_at || '').trim();
  if (exp) {
    const expMs = Date.parse(exp);
    if (Number.isFinite(expMs) && Date.now() > expMs) {
      await proposalRef.set({ status: 'expired', updated_at: nowIso() }, { merge: true });
      return res.status(409).json({
        error: 'proposal_expired',
        message: 'Proposal expired',
        request_id: req.requestId || null,
      });
    }
  }

  const action = normalizeAction(proposal.action);
  const tier = actionTier(action);
  if (!tier) {
    return res.status(400).json({
      error: 'unknown_action',
      message: 'Unknown or unsupported action',
      request_id: req.requestId || null,
    });
  }

  if (tierRank(tier) >= tierRank('C')) {
    return res.status(403).json({
      error: 'tier_c_blocked',
      message: 'This action requires step-up authorization and/or admin approval',
      request_id: req.requestId || null,
    });
  }

  const payload = (proposal.payload && typeof proposal.payload === 'object') ? proposal.payload : {};
  const context = (proposal.context && typeof proposal.context === 'object') ? proposal.context : {};

  const sessionValidation = await enforceAssistantSessionBinding({
    firestore,
    req,
    actorUid,
    action,
    context,
    required: requireSessionBinding,
  });
  if (!sessionValidation.ok) {
    return res.status(sessionValidation.status).json({
      error: sessionValidation.error,
      message: sessionValidation.message,
      request_id: req.requestId || null,
    });
  }

  const idempotencyKey = getIdempotencyKeyOr(req, proposalId);

  // Prevent double execution with audit doc keyed by idempotency key.
  const auditRef = firestore.collection('assistant_action_audit').doc(idempotencyKey);
  const existing = await auditRef.get();
  if (existing.exists) {
    const data = existing.data() || {};
    if (data.status === 'success') {
      return res.json({
        success: true,
        reused: true,
        proposalId,
        idempotencyKey,
        action,
        result: data.result || null,
        request_id: req.requestId || null,
      });
    }
    if (data.status === 'started') {
      return res.status(409).json({
        error: 'duplicate_in_flight',
        message: 'This confirmation is already being processed',
        proposalId,
        idempotencyKey,
        request_id: req.requestId || null,
      });
    }
  }

  await proposalRef.set({ status: 'confirming', updated_at: startedAt, audit_id: idempotencyKey }, { merge: true });

  const auditBase = {
    id: idempotencyKey,
    created_at: startedAt,
    updated_at: startedAt,
    status: 'started',
    request_id: req.requestId || null,
    proposal_id: proposalId,
    action,
    actor_uid: actorUid,
    actor_role: actorRole,
    booking_id: normalizeBookingId(payload) || normalizeBookingId(proposal) || null,
    context: {
      session_id: context.session_id || null,
      session_nonce: context.session_nonce || context.sessionNonce || null,
      room_name: context.room_name || null,
      client_ip: getClientIp(req),
    },
    payload,
    app_check: (appCheck && appCheck.ok && appCheck.decoded)
      ? { app_id: appCheck.decoded.appId || null, enforced: requireAppCheck }
      : { enforced: requireAppCheck },
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
          completed_at: nowIso(),
          error: result.error,
          http_status: result.status,
        },
      });
      await proposalRef.set({ status: 'error', updated_at: nowIso(), error: result.error }, { merge: true });
      return res.status(result.status).json({
        error: result.error,
        message: 'Action failed',
        proposalId,
        idempotencyKey,
        request_id: req.requestId || null,
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
      },
    });

    await proposalRef.set({ status: 'confirmed', updated_at: nowIso(), confirmed_at: nowIso() }, { merge: true });

    return res.json({
      ok: true,
      success: true,
      proposalId,
      idempotencyKey,
      action,
      result: result.data || null,
      data: result.data || null,
      request_id: req.requestId || null,
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
    await proposalRef.set({ status: 'error', updated_at: nowIso(), error: 'exception' }, { merge: true });
    return res.status(500).json({
      error: 'internal_error',
      message: 'Action confirmation failed',
      proposalId,
      idempotencyKey,
      request_id: req.requestId || null,
    });
  }
});

/**
 * Admin-only: recent assistant audit logs
 * GET /api/admin/assistant-audit/recent?limit=50
 */
app.get('/api/admin/assistant-audit/recent', adminLimiter, async (req, res) => {
  const firestore = requireFirebase(res);
  if (!firestore) return;
  const decoded = await verifyFirebaseAuth(req, res);
  if (!decoded) return;

  const role = await resolveRole({ firestore, uid: decoded.uid, decodedToken: decoded });
  if (role !== 'admin') {
    return res.status(403).json({ error: 'forbidden', message: 'Admin only' });
  }

  const limitRaw = Number.parseInt(String(req.query.limit || '50'), 10);
  const limit = Number.isFinite(limitRaw) ? Math.max(1, Math.min(200, limitRaw)) : 50;

  try {
    const snap = await firestore
      .collection('assistant_action_audit')
      .orderBy('created_at', 'desc')
      .limit(limit)
      .get();
    const items = snap.docs.map((d) => ({ id: d.id, ...(d.data() || {}) }));
    return res.json({ success: true, items });
  } catch (e) {
    return res.status(500).json({
      error: 'internal_error',
      message: 'Failed to load audit logs',
      request_id: req.requestId || null,
    });
  }
});

/**
 * Admin-only: audit logs by request id (trace lookup)
 * GET /api/admin/audits/by-request/:requestId
 */
app.get('/api/admin/audits/by-request/:requestId', adminLimiter, async (req, res) => {
  const firestore = requireFirebase(res);
  if (!firestore) return;
  const decoded = await verifyFirebaseAuth(req, res);
  if (!decoded) return;

  const role = await resolveRole({ firestore, uid: decoded.uid, decodedToken: decoded });
  if (role !== 'admin') {
    return res.status(403).json({ error: 'forbidden', message: 'Admin only', request_id: req.requestId || null });
  }

  const requestId = String(req.params.requestId || '').trim();
  if (!requestId) {
    return res.status(400).json({ error: 'invalid_request', message: 'Missing requestId', request_id: req.requestId || null });
  }

  try {
    const snap = await firestore
      .collection('assistant_action_audit')
      .where('request_id', '==', requestId)
      .limit(200)
      .get();
    const items = snap.docs.map((d) => ({ id: d.id, ...(d.data() || {}) }));
    return res.json({ success: true, requestId, items });
  } catch (e) {
    return res.status(500).json({
      error: 'internal_error',
      message: 'Failed to query audit logs by request id',
      request_id: req.requestId || null,
    });
  }
});

/**
 * Admin-only: jobs by request id (trace lookup)
 * GET /api/admin/jobs/by-request/:requestId
 * Note: this backend currently runs actions inline; this endpoint returns an empty list unless you later add a jobs collection.
 */
app.get('/api/admin/jobs/by-request/:requestId', adminLimiter, async (req, res) => {
  const firestore = requireFirebase(res);
  if (!firestore) return;
  const decoded = await verifyFirebaseAuth(req, res);
  if (!decoded) return;

  const role = await resolveRole({ firestore, uid: decoded.uid, decodedToken: decoded });
  if (role !== 'admin') {
    return res.status(403).json({ error: 'forbidden', message: 'Admin only', request_id: req.requestId || null });
  }

  const requestId = String(req.params.requestId || '').trim();
  if (!requestId) {
    return res.status(400).json({ error: 'invalid_request', message: 'Missing requestId', request_id: req.requestId || null });
  }

  // Best-effort: if the collection exists in your project later, this will start returning results.
  try {
    const snap = await firestore
      .collection('assistant_action_jobs')
      .where('request_id', '==', requestId)
      .limit(200)
      .get();
    const items = snap.docs.map((d) => ({ id: d.id, ...(d.data() || {}) }));
    return res.json({ success: true, requestId, items });
  } catch (e) { console.warn('\u26a0\ufe0f action jobs query:', e.message);
    return res.json({ success: true, requestId, items: [] });
  }
});

/**
 * Admin-only: lightweight finance snapshot from recent transaction logs.
 * GET /api/admin/finance/summary?limit=200
 */
app.get('/api/admin/finance/summary', adminLimiter, async (req, res) => {
  const firestore = requireFirebase(res);
  if (!firestore) return;
  const decoded = await verifyFirebaseAuth(req, res);
  if (!decoded) return;

  const role = await resolveRole({ firestore, uid: decoded.uid, decodedToken: decoded });
  if (role !== 'admin') {
    return res.status(403).json({ error: 'forbidden', message: 'Admin only' });
  }

  const limitRaw = Number.parseInt(String(req.query.limit || '200'), 10);
  const limit = Number.isFinite(limitRaw) ? Math.max(1, Math.min(500, limitRaw)) : 200;

  function toNum(v) {
    if (v == null) return 0;
    if (typeof v === 'number') return v;
    const cleaned = String(v).trim().replace(/[^0-9.\-]/g, '');
    const n = Number.parseFloat(cleaned);
    return Number.isFinite(n) ? n : 0;
  }

  try {
    const snap = await firestore
      .collection('transactionLogs')
      .orderBy('transaction_at', 'desc')
      .limit(limit)
      .get();

    let totalIn = 0;
    let totalOut = 0;
    let profitTotal = 0;
    let count = 0;

    for (const d of snap.docs) {
      const data = d.data() || {};
      const amount = toNum(data.amount);
      const dir = String(data.direction || '').trim().toLowerCase();
      if (dir === 'in') totalIn += amount;
      if (dir === 'out') totalOut += amount;
      profitTotal += toNum(data.profit);
      count += 1;
    }

    return res.json({
      success: true,
      sample_size: count,
      total_in: Number(totalIn.toFixed(2)),
      total_out: Number(totalOut.toFixed(2)),
      profit_total: Number(profitTotal.toFixed(2)),
      note:
        'This is computed from a recent sample of transactionLogs. For full-period reporting, use a dedicated analytics pipeline or aggregation jobs.',
    });
  } catch (e) {
    return res.status(500).json({
      error: 'internal_error',
      message: 'Failed to load finance summary',
      request_id: req.requestId || null,
    });
  }
});

/**
 * Admin-only: debug identity mapping for an assigned artisan.
 * GET /api/admin/debug/reassignment-recipients?bookingId=<id>
 */
app.get('/api/admin/debug/reassignment-recipients', async (req, res) => {
  const firestore = requireFirebase(res);
  if (!firestore) return;
  const decoded = await verifyFirebaseAuth(req, res);
  if (!decoded) return;

  const role = await resolveRole({ firestore, uid: decoded.uid, decodedToken: decoded });
  if (role !== 'admin') {
    return res.status(403).json({ error: 'forbidden', message: 'Admin only' });
  }

  const bookingId = String(req.query.bookingId || req.query.booking_id || '').trim();
  if (!bookingId) {
    return res.status(400).json({ error: 'missing_booking_id', message: 'Provide bookingId query param' });
  }

  try {
    const snap = await firestore.collection('futureBookings').doc(bookingId).get();
    if (!snap.exists) return res.status(404).json({ error: 'booking_not_found' });
    const data = snap.data() || {};
    const providerKey = String(data.service_provider_id || '').trim();

    // Re-use same lookup strategy as actions.
    let providerDoc = null;
    try {
      const direct = await firestore.collection('serviceProvider').doc(providerKey).get();
      if (direct.exists) providerDoc = direct;
    } catch (e) { console.warn('\u26a0\ufe0f provider doc direct fetch:', e.message);
      providerDoc = null;
    }
    if (!providerDoc) {
      // fall back to a few common fields
      for (const f of ['user_id', 'uid', 'userId', 'provider_id']) {
        try {
          const qs = await firestore.collection('serviceProvider').where(f, '==', providerKey).limit(1).get();
          if (!qs.empty) {
            providerDoc = qs.docs[0];
            break;
          }
        } catch (e) { console.warn('\u26a0\ufe0f provider doc field query:', e.message);
          // ignore
        }
      }
    }

    const providerDocId = providerDoc && providerDoc.exists ? String(providerDoc.id || '').trim() : '';
    const pd = providerDoc && providerDoc.exists ? providerDoc.data() || {} : {};
    const primaryUid = String(pd.user_id || pd.uid || pd.userId || pd.user_uid || pd.auth_uid || '').trim();

    const recipientIds = [];
    const seen = new Set();
    for (const id of [primaryUid, providerDocId, String(pd.user_id || '').trim(), String(pd.uid || '').trim(), String(pd.userId || '').trim(), String(pd.provider_id || '').trim()]) {
      const v = String(id || '').trim();
      if (!v || seen.has(v)) continue;
      seen.add(v);
      recipientIds.push(v);
    }

    return res.json({
      success: true,
      booking_id: bookingId,
      booking_service_provider_id: providerKey || null,
      provider_doc_found: !!(providerDoc && providerDoc.exists),
      provider_doc_id: providerDocId || null,
      provider_primary_uid: primaryUid || null,
      provider_fields: {
        user_id: String(pd.user_id || '').trim() || null,
        uid: String(pd.uid || '').trim() || null,
        userId: String(pd.userId || '').trim() || null,
        provider_id: String(pd.provider_id || '').trim() || null,
      },
      notification_recipient_ids: recipientIds,
      note:
        "The mobile app notification screen queries notifications where user_id == FirebaseAuth uid. Ensure provider_primary_uid matches the artisan's auth uid to guarantee delivery.",
    });
  } catch (e) {
    return res.status(500).json({ error: 'internal_error', message: 'Debug lookup failed' });
  }
});

/**
 * Admin-only: fix serviceProvider identity mapping so notifications reach the artisan FirebaseAuth uid.
 * POST /api/admin/fix/service-provider-uid-mapping
 * Body: { bookingId?: string, providerDocId?: string, providerId?: string, targetUid: string, reason?: string }
 */
app.post('/api/admin/fix/service-provider-uid-mapping', async (req, res) => {
  const firestore = requireFirebase(res);
  if (!firestore) return;
  const decoded = await verifyFirebaseAuth(req, res);
  if (!decoded) return;

  const role = await resolveRole({ firestore, uid: decoded.uid, decodedToken: decoded });
  if (role !== 'admin') {
    return res.status(403).json({ error: 'forbidden', message: 'Admin only' });
  }

  const body = (req.body && typeof req.body === 'object' && req.body) || {};
  const bookingId = String(body.bookingId || body.booking_id || '').trim();
  const providerDocIdInput = String(body.providerDocId || body.provider_doc_id || body.providerDocID || '').trim();
  const providerId = String(body.providerId || body.provider_id || '').trim();
  const targetUid = String(body.targetUid || body.target_uid || body.uid || '').trim();
  const reason = String(body.reason || 'admin_fix_mapping').trim();

  if (!targetUid) {
    return res.status(400).json({ error: 'missing_target_uid', message: 'Provide targetUid' });
  }
  if (!bookingId && !providerDocIdInput && !providerId) {
    return res.status(400).json({
      error: 'missing_locator',
      message: 'Provide bookingId or providerDocId or providerId',
    });
  }

  // Validate that this uid exists in Firebase Auth.
  try {
    await admin.auth().getUser(targetUid);
  } catch (e) {
    return res.status(400).json({
      error: 'invalid_target_uid',
      message: 'targetUid not found in Firebase Auth',
    });
  }

  async function resolveProviderDoc(key) {
    const k = String(key || '').trim();
    if (!k) return null;
    try {
      const direct = await firestore.collection('serviceProvider').doc(k).get();
      if (direct.exists) return direct;
    } catch (e) { console.warn('\u26a0\ufe0f resolveProviderDoc direct fetch:', e.message);
      // ignore
    }
    for (const f of ['user_id', 'uid', 'userId', 'provider_id']) {
      try {
        const qs = await firestore.collection('serviceProvider').where(f, '==', k).limit(1).get();
        if (!qs.empty) return qs.docs[0];
      } catch (e) { console.warn('\u26a0\ufe0f resolveProviderDoc field query:', e.message);
        // ignore
      }
    }
    return null;
  }

  let providerDoc = null;
  let derivedProviderKey = providerId || providerDocIdInput;
  if (!providerDoc && providerDocIdInput) {
    providerDoc = await resolveProviderDoc(providerDocIdInput);
  }

  if (!providerDoc && bookingId) {
    const snap = await firestore.collection('futureBookings').doc(bookingId).get();
    if (!snap.exists) {
      return res.status(404).json({ error: 'booking_not_found', message: 'Booking not found' });
    }
    const bookingData = snap.data() || {};
    derivedProviderKey = String(bookingData.service_provider_id || '').trim();
    providerDoc = await resolveProviderDoc(derivedProviderKey);
  }

  if (!providerDoc && providerId) {
    providerDoc = await resolveProviderDoc(providerId);
  }

  if (!providerDoc || !providerDoc.exists) {
    return res.status(404).json({
      error: 'provider_not_found',
      message: 'Could not resolve serviceProvider document',
      providerKey: derivedProviderKey || null,
    });
  }

  const providerRef = firestore.collection('serviceProvider').doc(providerDoc.id);
  const before = providerDoc.data() || {};
  const prev = {
    user_id: String(before.user_id || '').trim() || null,
    uid: String(before.uid || '').trim() || null,
    userId: String(before.userId || '').trim() || null,
    provider_id: String(before.provider_id || '').trim() || null,
  };

  const patch = {
    user_id: targetUid,
    uid: targetUid,
    userId: targetUid,
    mapping_fixed_at: nowIso(),
    mapping_fixed_by: decoded.uid,
    mapping_fixed_reason: reason,
    mapping_prev: prev,
  };

  // Write an audit record for traceability.
  try {
    await firestore.collection('assistant_action_audit').doc(randomId('mapfix-')).set({
      id: randomId('mapfix-'),
      created_at: nowIso(),
      updated_at: nowIso(),
      status: 'success',
      action: 'admin_fix_service_provider_uid_mapping',
      actor_uid: decoded.uid,
      actor_role: role,
      booking_id: bookingId || null,
      payload: {
        provider_doc_id: providerDoc.id,
        provider_key: derivedProviderKey || null,
        target_uid: targetUid,
        reason,
        prev,
      },
    });
  } catch (e) { console.warn('\u26a0\ufe0f admin action audit write:', e.message);
    // best-effort
  }

  await providerRef.set(patch, { merge: true });

  // Optional: verify the users/{uid} role looks like an artisan.
  let userRoleHint = null;
  try {
    const userSnap = await firestore.collection('users').doc(targetUid).get();
    if (userSnap.exists) {
      const ud = userSnap.data() || {};
      const v = ud.role || ud.user_role || ud.userType || ud.user_type || ud.type || ud.account_type;
      const r = String(v || '').trim().toLowerCase();
      userRoleHint = r || null;
    }
  } catch (e) { console.warn('\u26a0\ufe0f user role hint lookup:', e.message);
    // ignore
  }

  return res.json({
    success: true,
    provider_doc_id: providerDoc.id,
    provider_key: derivedProviderKey || null,
    target_uid: targetUid,
    previous: prev,
    user_role_hint: userRoleHint,
    note:
      "If the app's artisan account uses FirebaseAuth uid for notification queries, setting serviceProvider.user_id/uid/userId to that uid ensures notifications appear.",
  });
});

// ── Server-side FCM Notification Endpoint ──
// Replaces client-side admin SDK usage — clients call this instead of loading firebase-adminsdk.json
app.post('/api/notifications/send', authMiddleware, assistantLimiter, async (req, res) => {
  try {
    initFirebaseIfPossible();
    if (firebaseInitError) {
      return res.status(503).json({ error: 'Firebase not configured on backend' });
    }
    const { token, title, body, data, userId, userType, bookingId, type } = req.body;

    if (!token || !title || !body) {
      return res.status(400).json({ error: 'Missing required fields: token, title, body' });
    }

    // Determine notification channel based on type
    const notifType = (data && data.type) ? String(data.type) : (type || '');
    const ORDER_REQUEST_TYPES = new Set([
      'Order Request', 'order_request', 'rfq_broadcast', 'rfq_assignment',
      'rfq_amended', 'rfq_assigned', 'rfq_updated',
      'future_booking', 'booking_request', 'new_booking',
      'wallet_topup', 'wallet_credit',
      'chat_message', 'case_reply',
    ]);
    const channelId = ORDER_REQUEST_TYPES.has(notifType)
      ? 'order_request_channel'
      : 'high_importance_channel';

    // Send FCM via Admin SDK (server-side — no private key exposed to clients)
    const message = {
      token: String(token).trim(),
      notification: { title: String(title), body: String(body) },
      data: data && typeof data === 'object' ? Object.fromEntries(
        Object.entries(data).map(([k, v]) => [String(k), String(v)])
      ) : {},
      android: {
        priority: 'high',
        notification: { channelId },
      },
      apns: { headers: { 'apns-priority': '10' } },
    };

    const result = await admin.messaging().send(message);
    console.log(`✅ FCM sent via backend: ${result}`);

    // Optionally store in-app notification doc
    if (userId) {
      const firestore = admin.firestore();
      await firestore.collection('notifications').add({
        user_id: userId,
        user_type: userType || 'user',
        title: String(title),
        message: String(body),
        ...(bookingId ? { booking_id: bookingId } : {}),
        type: type || 'general',
        read: false,
        view: false,
        created_at: new Date().toISOString(),
      });
    }

    res.json({ ok: true, success: true, messageId: result });
  } catch (error) {
    console.error('❌ FCM send error:', error);
    res.status(500).json({ error: 'Failed to send notification' });
  }
});

// ── Server-side PayFast Payment Initiation ──
// Replaces client-side hardcoded merchant credentials
app.post('/api/payment/initiate', authMiddleware, assistantLimiter, async (req, res) => {
  try {
    const merchantId = env('PAYFAST_MERCHANT_ID');
    const merchantKey = env('PAYFAST_MERCHANT_KEY');
    const payfastUrl = env('PAYFAST_URL') || 'https://www.payfast.co.za/eng/process';

    if (!merchantId || !merchantKey) {
      return res.status(503).json({ error: 'Payment credentials not configured on server' });
    }

    const { amount, item_name, return_url, cancel_url, notify_url, custom_str1 } = req.body;

    if (!amount || !item_name) {
      return res.status(400).json({ error: 'Missing required fields: amount, item_name' });
    }

    const paymentData = {
      merchant_id: merchantId,
      merchant_key: merchantKey,
      amount: String(amount),
      item_name: String(item_name),
      ...(return_url ? { return_url } : {}),
      ...(cancel_url ? { cancel_url } : {}),
      ...(notify_url ? { notify_url } : {}),
      ...(custom_str1 ? { custom_str1 } : {}),
    };

    res.json({
      ok: true,
      payfast_url: payfastUrl,
      payment_data: paymentData,
    });
  } catch (error) {
    console.error('❌ Payment initiation error:', error);
    res.status(500).json({ error: 'Payment initiation failed' });
  }
});

// ── PayFast ITN (Instant Transaction Notification) Webhook ──
// Server-side payment verification — PayFast posts here after payment
app.post('/api/payment/itn', async (req, res) => {
  try {
    const data = req.body;
    console.log('📥 PayFast ITN received:', JSON.stringify(data));

    // 1. Verify signature
    const merchantKey = env('PAYFAST_MERCHANT_KEY');
    if (!merchantKey) {
      console.error('❌ ITN: PAYFAST_MERCHANT_KEY not configured');
      return res.status(503).send('Server misconfigured');
    }

    const receivedSignature = data.signature;
    if (!receivedSignature) {
      console.error('❌ ITN: No signature in payload');
      return res.status(400).send('Missing signature');
    }

    // Build param string for signature verification (exclude signature itself)
    const paramString = Object.keys(data)
      .filter(key => key !== 'signature')
      .sort()
      .map(key => `${key}=${encodeURIComponent(String(data[key] || '')).replace(/%20/g, '+')}`)
      .join('&');

    const passphrase = env('PAYFAST_PASSPHRASE') || merchantKey;
    const expectedSignature = crypto
      .createHash('md5')
      .update(paramString + `&passphrase=${encodeURIComponent(passphrase)}`)
      .digest('hex');

    if (receivedSignature !== expectedSignature) {
      console.error('❌ ITN: Signature mismatch');
      return res.status(403).send('Invalid signature');
    }

    // 2. Extract payment info
    const paymentStatus = String(data.payment_status || '');
    const pfPaymentId = String(data.pf_payment_id || '');
    const amountGross = String(data.amount_gross || '0');
    const customStr1 = String(data.custom_str1 || ''); // tasksManagement ID
    const itemName = String(data.item_name || '');

    console.log(`✅ ITN verified: status=${paymentStatus}, pfId=${pfPaymentId}, amount=R${amountGross}, taskId=${customStr1}`);

    // 3. Update Firestore
    const now = new Date().toISOString();

    if (customStr1) {
      // Update tasksManagement if we have a task ID
      const taskRef = admin.firestore().collection('tasksManagement').doc(customStr1);
      const taskSnap = await taskRef.get();

      if (taskSnap.exists) {
        const updateData = {
          payfast_payment_id: pfPaymentId,
          payfast_itn_status: paymentStatus,
          payfast_itn_amount: amountGross,
          payfast_itn_received_at: now,
          updated_at: now,
        };

        if (paymentStatus === 'COMPLETE') {
          updateData.payment_status = 'paid';
          updateData.payment_verified = true;
          updateData.payment_verified_at = now;
          updateData.payment_verified_via = 'payfast_itn';
        } else if (paymentStatus === 'CANCELLED') {
          updateData.payment_status = 'cancelled';
        } else if (paymentStatus === 'FAILED') {
          updateData.payment_status = 'failed';
        }

        await taskRef.update(updateData);
        console.log(`📝 Updated tasksManagement/${customStr1}: payment_status=${updateData.payment_status || paymentStatus}`);
      }

      // Create/update transaction log
      const txRef = admin.firestore().collection('transactionLogs');
      const existingTx = await txRef
        .where('payfast_payment_id', '==', pfPaymentId)
        .limit(1)
        .get();

      if (existingTx.empty) {
        const taskData = taskSnap.exists ? taskSnap.data() : {};
        const txId = crypto.randomUUID();
        await txRef.doc(txId).set({
          id: txId,
          amount: amountGross,
          transaction_at: now,
          status: paymentStatus === 'COMPLETE' ? 'success' : paymentStatus.toLowerCase(),
          user_id: taskData.user_id || taskData.userId || '',
          type: 'payfast',
          subtype: 'payment',
          direction: 'in',
          cash_movement: true,
          schema_version: 2,
          tasks_management_id: customStr1,
          payfast_payment_id: pfPaymentId,
          payfast_itn_status: paymentStatus,
          verified_via: 'payfast_itn',
          item_name: itemName,
        });
        console.log(`📝 Created transactionLog for ITN: ${txId}`);
      } else {
        // Update existing transaction log
        const existingDoc = existingTx.docs[0];
        await existingDoc.ref.update({
          payfast_itn_status: paymentStatus,
          payfast_itn_received_at: now,
          status: paymentStatus === 'COMPLETE' ? 'success' : paymentStatus.toLowerCase(),
          verified_via: 'payfast_itn',
        });
        console.log(`📝 Updated existing transactionLog: ${existingDoc.id}`);
      }
    }

    // PayFast expects a 200 OK response
    res.status(200).send('OK');
  } catch (error) {
    console.error('❌ PayFast ITN error:', error);
    res.status(200).send('OK'); // Always return 200 so PayFast doesn't retry indefinitely
  }
});

/**
 * Generate Livekit Access Token (requires auth in production)
 * POST /api/token
 * Body: { roomName: string, participantName: string, metadata?: string }
 */
app.post('/api/token', authMiddleware, async (req, res) => {
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

    // Create access token with 15-minute TTL
    const at = new AccessToken(
      env.apiKey,
      env.apiSecret,
      {
        identity: participantName,
        name: participantName,
        metadata: metadata || '',
        ttl: '15m',
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
app.post('/api/create-room', authMiddleware, async (req, res) => {
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
app.post('/api/dispatch-agent', authMiddleware, async (req, res) => {
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

// Error handling middleware
app.use((err, req, res, next) => {
  console.error('❌ Server error:', err);
  res.status(500).json({
    error: 'Internal server error',
    message: process.env.NODE_ENV !== 'production' ? err.message : 'An unexpected error occurred'
  });
});

/**
 * Bootstrap admin custom claims.
 * POST /api/admin/bootstrap-claims
 * Body: { "uid": "<firebaseAuthUid>" }
 * Header: x-bootstrap-key: <matches ADMIN_BOOTSTRAP_KEY env var>
 *
 * Sets { role: 'admin' } custom claim on the user so resolveRole() grants
 * admin access for backend endpoints.
 */
app.post('/api/admin/bootstrap-claims', async (req, res) => {
  const firestore = requireFirebase(res);
  if (!firestore) return;

  const bootstrapKey = (process.env.ADMIN_BOOTSTRAP_KEY || '').trim();
  const providedKey = (req.headers['x-bootstrap-key'] || '').trim();

  if (!bootstrapKey) {
    return res.status(500).json({ error: 'ADMIN_BOOTSTRAP_KEY not configured on server' });
  }
  if (!providedKey || providedKey !== bootstrapKey) {
    return res.status(403).json({ error: 'Invalid bootstrap key' });
  }

  const uid = String(req.body?.uid || '').trim();
  if (!uid) {
    return res.status(400).json({ error: 'Missing uid in request body' });
  }

  try {
    const admin = require('firebase-admin');
    await admin.auth().setCustomUserClaims(uid, { role: 'admin' });
    console.log(`✅ Admin custom claims set for UID: ${uid}`);
    return res.json({ success: true, uid, message: 'Admin claims set. User must re-login for claims to take effect.' });
  } catch (e) {
    console.error('❌ Failed to set admin claims:', e);
    return res.status(500).json({ error: 'Failed to set claims', message: e.message });
  }
});

// ═══════════════════════════════════════════════════════════════════════════════
// PHASE 5.2 — Secure Finance Approval Pipeline (Tier C)
// Money NEVER moves without: auth → fraud check → request doc → admin approval
// ═══════════════════════════════════════════════════════════════════════════════

// ── Fraud Detection Engine ──────────────────────────────────────────────────
async function runFraudChecks({ firestore, type, amount, targetUserId, requestedBy, bookingId }) {
  const alerts = [];
  const amountNum = typeof amount === 'number' ? amount : Number.parseFloat(String(amount).replace(/[^0-9.\-]/g, ''));

  // Rule 1: Amount exceeds daily limit per type
  const DAILY_LIMITS = { refund: 10000, wallet_adjustment: 5000, payout: 50000, fee_override: 2000 };
  const dailyLimit = DAILY_LIMITS[type] || 5000;
  if (amountNum > dailyLimit) {
    alerts.push({ rule: 'amount_exceeds_daily_limit', severity: 'high', detail: `R${amountNum} exceeds R${dailyLimit} limit for ${type}` });
  }

  // Rule 2: Velocity check — max 5 finance requests per user per hour
  try {
    const oneHourAgo = new Date(Date.now() - 3600000).toISOString();
    const recentSnap = await firestore.collection('finance_requests')
      .where('requested_by', '==', requestedBy)
      .where('created_at', '>', oneHourAgo)
      .limit(10)
      .get();
    if (recentSnap.size >= 5) {
      alerts.push({ rule: 'velocity_exceeded', severity: 'high', detail: `${recentSnap.size} requests in last hour from same admin` });
    }
  } catch (e) { console.warn('\u26a0\ufe0f fraud velocity check:', e.message); }

  // Rule 3: Self-dealing — admin requesting funds to themselves
  if (targetUserId === requestedBy) {
    alerts.push({ rule: 'self_dealing', severity: 'critical', detail: 'Admin requesting financial action to own account' });
  }

  // Rule 4: Duplicate refund — same booking refunded within 24 hours
  if (type === 'refund' && bookingId) {
    try {
      const oneDayAgo = new Date(Date.now() - 86400000).toISOString();
      const dupSnap = await firestore.collection('finance_requests')
        .where('type', '==', 'refund')
        .where('booking_id', '==', bookingId)
        .where('created_at', '>', oneDayAgo)
        .limit(1)
        .get();
      if (!dupSnap.empty) {
        alerts.push({ rule: 'duplicate_refund', severity: 'high', detail: `Booking ${bookingId} already has a recent refund request` });
      }
    } catch (e) { console.warn('\u26a0\ufe0f fraud duplicate refund check:', e.message); }
  }

  // Rule 5: Flagged user target
  if (targetUserId) {
    try {
      const flagSnap = await firestore.collection('user_flags')
        .where('user_id', '==', targetUserId)
        .where('status', '==', 'active')
        .limit(1)
        .get();
      if (!flagSnap.empty) {
        const flag = flagSnap.docs[0].data() || {};
        alerts.push({ rule: 'flagged_user', severity: 'medium', detail: `Target user is flagged: ${flag.flag_type} - ${flag.reason || ''}` });
      }
    } catch (e) { console.warn('\u26a0\ufe0f fraud flagged user check:', e.message); }
  }

  // Rule 6: Unusual amount (suspiciously round or very large)
  if (amountNum > 0 && amountNum === Math.round(amountNum) && amountNum >= 1000 && amountNum % 1000 === 0) {
    alerts.push({ rule: 'round_amount_pattern', severity: 'low', detail: `Suspiciously round amount: R${amountNum}` });
  }

  const blocked = alerts.some(a => a.severity === 'critical');
  const requiresReview = alerts.some(a => a.severity === 'high' || a.severity === 'critical');

  return { alerts, blocked, requiresReview, score: alerts.length };
}

// ── Create Finance Request (admin-only, creates approval doc) ────────────────
app.post('/api/finance/request', adminLimiter, async (req, res) => {
  const firestore = requireFirebase(res);
  if (!firestore) return;
  const decoded = await verifyFirebaseAuth(req, res);
  if (!decoded) return;
  const role = await resolveRole({ firestore, uid: decoded.uid, decodedToken: decoded });
  if (role !== 'admin') {
    return res.status(403).json({ error: 'forbidden', message: 'Admin only' });
  }

  const type = String(req.body.type || '').trim().toLowerCase();
  const amountRaw = req.body.amount;
  const targetUserId = String(req.body.target_user_id || '').trim();
  const bookingIdParam = String(req.body.booking_id || '').trim();
  const reason = String(req.body.reason || '').trim();
  const method = String(req.body.method || '').trim();
  const notes = String(req.body.notes || '').trim();

  // Validation
  const validTypes = ['refund', 'wallet_adjustment', 'payout', 'fee_override'];
  if (!validTypes.includes(type)) {
    return res.status(400).json({ error: 'invalid_type', message: `Type must be one of: ${validTypes.join(', ')}` });
  }
  const amount = Number.parseFloat(String(amountRaw).replace(/[^0-9.\-]/g, ''));
  if (!Number.isFinite(amount) || amount <= 0) {
    return res.status(400).json({ error: 'invalid_amount', message: 'Amount must be a positive number' });
  }
  if (amount > 100000) {
    return res.status(400).json({ error: 'amount_too_large', message: 'Maximum single request is R100,000' });
  }
  if (!targetUserId) {
    return res.status(400).json({ error: 'missing_target_user_id' });
  }
  if (!reason || reason.length < 5) {
    return res.status(400).json({ error: 'missing_reason', message: 'Reason must be at least 5 characters' });
  }

  // Verify target user exists
  try {
    const userSnap = await firestore.collection('users').doc(targetUserId).get();
    if (!userSnap.exists) {
      return res.status(404).json({ error: 'target_user_not_found' });
    }
  } catch (e) { console.warn('\u26a0\ufe0f target user exists check:', e.message); }

  // Run fraud detection
  const fraud = await runFraudChecks({
    firestore, type, amount, targetUserId,
    requestedBy: decoded.uid, bookingId: bookingIdParam,
  });

  // Block critical fraud alerts immediately
  if (fraud.blocked) {
    const alertId = randomId('fraud-');
    await firestore.collection('fraud_alerts').doc(alertId).set({
      id: alertId, alert_type: 'blocked_request', severity: 'critical',
      description: `Blocked ${type} request: ${fraud.alerts.map(a => a.detail).join('; ')}`,
      user_id: decoded.uid, target_user_id: targetUserId,
      amount: amount.toFixed(2), booking_id: bookingIdParam,
      alerts: fraud.alerts, created_at: nowIso(), status: 'open',
    });
    return res.status(403).json({
      error: 'fraud_blocked',
      message: 'This request was blocked by fraud detection and flagged for review',
      alerts: fraud.alerts.filter(a => a.severity === 'critical'),
    });
  }

  // Create the finance request document
  const requestId = randomId('fin-');
  const finReq = {
    id: requestId,
    type,
    amount: Number(amount.toFixed(2)),
    target_user_id: targetUserId,
    booking_id: bookingIdParam || null,
    reason,
    method: method || null,
    notes: notes || null,
    requested_by: decoded.uid,
    status: fraud.requiresReview ? 'flagged_for_review' : 'pending_approval',
    fraud_score: fraud.score,
    fraud_alerts: fraud.alerts,
    requires_secondary_approval: fraud.requiresReview || amount > 5000,
    approvals: [],
    rejections: [],
    created_at: nowIso(),
    resolved_at: null,
    executed_at: null,
  };

  await firestore.collection('finance_requests').doc(requestId).set(finReq);

  // If flagged, also create a fraud alert
  if (fraud.requiresReview) {
    const alertId = randomId('fraud-');
    await firestore.collection('fraud_alerts').doc(alertId).set({
      id: alertId, alert_type: 'flagged_request', severity: 'high',
      description: `Flagged ${type} for R${amount.toFixed(2)}: ${fraud.alerts.map(a => a.detail).join('; ')}`,
      user_id: decoded.uid, target_user_id: targetUserId,
      amount: amount.toFixed(2), finance_request_id: requestId,
      alerts: fraud.alerts, created_at: nowIso(), status: 'open',
    });
  }

  // Audit trail
  await writeAudit({
    firestore,
    auditId: randomId('audit-'),
    audit: {
      action: `finance_request_${type}`,
      actor_uid: decoded.uid,
      actor_role: role,
      status: 'request_created',
      payload: { request_id: requestId, type, amount, target_user_id: targetUserId, reason },
      context: { fraud_score: fraud.score, blocked: fraud.blocked },
      created_at: nowIso(),
    },
  });

  return res.json({
    success: true,
    request_id: requestId,
    status: finReq.status,
    fraud_score: fraud.score,
    fraud_alerts: fraud.alerts.length > 0 ? fraud.alerts : undefined,
    message: fraud.requiresReview
      ? 'Request created but flagged for additional review due to fraud checks'
      : 'Request created and pending admin approval',
  });
});

// ── Approve Finance Request (admin-only, requires different admin than requester) ──
app.post('/api/finance/approve', adminLimiter, async (req, res) => {
  const firestore = requireFirebase(res);
  if (!firestore) return;
  const decoded = await verifyFirebaseAuth(req, res);
  if (!decoded) return;
  const role = await resolveRole({ firestore, uid: decoded.uid, decodedToken: decoded });
  if (role !== 'admin') {
    return res.status(403).json({ error: 'forbidden', message: 'Admin only' });
  }

  const requestId = String(req.body.request_id || '').trim();
  if (!requestId) return res.status(400).json({ error: 'missing_request_id' });

  const reqSnap = await firestore.collection('finance_requests').doc(requestId).get();
  if (!reqSnap.exists) return res.status(404).json({ error: 'request_not_found' });

  const finReq = reqSnap.data() || {};

  // Security: Cannot approve own request (separation of duties)
  if (finReq.requested_by === decoded.uid) {
    return res.status(403).json({
      error: 'self_approval_forbidden',
      message: 'You cannot approve your own finance request. Another admin must approve it.',
    });
  }

  // Check status — only pending or flagged can be approved
  if (!['pending_approval', 'flagged_for_review'].includes(finReq.status)) {
    return res.status(409).json({
      error: 'invalid_status',
      message: `Request is already ${finReq.status}, cannot approve`,
    });
  }

  // Check if secondary approval is needed and hasn't been met
  const approvals = Array.isArray(finReq.approvals) ? finReq.approvals : [];
  const alreadyApproved = approvals.some(a => a.uid === decoded.uid);
  if (alreadyApproved) {
    return res.status(409).json({ error: 'already_approved', message: 'You have already approved this request' });
  }

  approvals.push({ uid: decoded.uid, approved_at: nowIso() });

  const needsTwo = finReq.requires_secondary_approval || (finReq.amount > 5000);
  if (needsTwo && approvals.length < 2) {
    await reqSnap.ref.update({ approvals, status: 'awaiting_second_approval', updated_at: nowIso() });
    return res.json({
      success: true, request_id: requestId,
      status: 'awaiting_second_approval',
      message: 'First approval recorded. A second admin must also approve this request.',
      approvals_count: approvals.length,
    });
  }

  // ── Execute the financial operation ──────────────────────────────────
  const now = nowIso();
  let executionResult = null;
  const amount = Number(finReq.amount) || 0;
  const targetUserId = String(finReq.target_user_id || '').trim();

  try {
    if (finReq.type === 'refund' || finReq.type === 'wallet_adjustment') {
      // Credit/debit the user's wallet balance (atomic transaction to prevent race conditions)
      const userRef = firestore.collection('users').doc(targetUserId);
      const direction = finReq.type === 'refund' ? 'credit' : (amount >= 0 ? 'credit' : 'debit');
      const txId = randomId('tx-');

      const { previousBalance, newBalance } = await firestore.runTransaction(async (tx) => {
        const userSnap = await tx.get(userRef);
        if (!userSnap.exists) throw new Error('Target user not found');

        const userData = userSnap.data() || {};
        const currentBalance = Number.parseFloat(String(userData.balance || '0').replace(/[^0-9.\-]/g, '')) || 0;
        const updatedBalance = direction === 'credit' ? currentBalance + Math.abs(amount) : currentBalance - Math.abs(amount);

        if (updatedBalance < 0 && direction === 'debit') {
          throw new Error(`Insufficient balance: current R${currentBalance.toFixed(2)}, requested debit R${Math.abs(amount).toFixed(2)}`);
        }

        tx.update(userRef, { balance: updatedBalance.toFixed(2) });

        // Write transaction log inside the same transaction
        const txRef = firestore.collection('transactionLogs').doc(txId);
        tx.set(txRef, {
          id: txId,
          transaction_type: finReq.type,
          amount: amount.toFixed(2),
          direction: direction === 'credit' ? 'in' : 'out',
          status: 'success',
          user_id: targetUserId,
          booking_id: finReq.booking_id || null,
          finance_request_id: requestId,
          previous_balance: currentBalance.toFixed(2),
          new_balance: updatedBalance.toFixed(2),
          reason: finReq.reason,
          executed_by: decoded.uid,
          approved_by: approvals.map(a => a.uid),
          transaction_at: now,
          created_at: now,
        });

        return { previousBalance: currentBalance, newBalance: updatedBalance };
      });

      executionResult = {
        type: finReq.type, amount: amount.toFixed(2),
        previous_balance: previousBalance.toFixed(2),
        new_balance: newBalance.toFixed(2),
        transaction_id: txId,
      };
    } else if (finReq.type === 'payout') {
      // Payouts create a pending payout record (actual transfer handled externally)
      const payoutId = randomId('payout-');
      await firestore.collection('payout_records').doc(payoutId).set({
        id: payoutId,
        target_user_id: targetUserId,
        amount: amount.toFixed(2),
        method: finReq.method || 'eft',
        status: 'pending_transfer',
        finance_request_id: requestId,
        reason: finReq.reason,
        approved_by: approvals.map(a => a.uid),
        created_at: now,
      });

      // Deduct from user balance
      const userRef = firestore.collection('users').doc(targetUserId);
      const userSnap = await userRef.get();
      if (userSnap.exists) {
        const bal = Number.parseFloat(String((userSnap.data() || {}).balance || '0').replace(/[^0-9.\-]/g, '')) || 0;
        if (bal < amount) {
          throw new Error(`Insufficient balance for payout: R${bal.toFixed(2)} < R${amount.toFixed(2)}`);
        }
        await userRef.update({ balance: (bal - amount).toFixed(2) });
      }

      const txId = randomId('tx-');
      await firestore.collection('transactionLogs').doc(txId).set({
        id: txId, transaction_type: 'payout', amount: amount.toFixed(2),
        direction: 'out', status: 'pending_transfer', user_id: targetUserId,
        finance_request_id: requestId, payout_id: payoutId,
        reason: finReq.reason, executed_by: decoded.uid,
        approved_by: approvals.map(a => a.uid), transaction_at: now, created_at: now,
      });

      executionResult = { type: 'payout', payout_id: payoutId, amount: amount.toFixed(2), status: 'pending_transfer' };
    } else if (finReq.type === 'fee_override') {
      // Fee overrides update the booking's fee/commission fields
      const bId = String(finReq.booking_id || '').trim();
      if (!bId) throw new Error('Fee override requires a booking_id');
      const bRef = firestore.collection('futureBookings').doc(bId);
      const bSnap = await bRef.get();
      if (!bSnap.exists) throw new Error('Booking not found');
      await bRef.update({
        fee_override: amount.toFixed(2),
        fee_override_reason: finReq.reason,
        fee_override_by: decoded.uid,
        fee_override_at: now,
      });
      executionResult = { type: 'fee_override', booking_id: bId, new_fee: amount.toFixed(2) };
    }

    // Mark request as executed
    await reqSnap.ref.update({
      status: 'executed',
      approvals,
      executed_at: now,
      executed_by: decoded.uid,
      execution_result: executionResult,
      updated_at: now,
    });

    // Audit trail
    await writeAudit({
      firestore, auditId: randomId('audit-'),
      audit: {
        action: `finance_executed_${finReq.type}`,
        actor_uid: decoded.uid, actor_role: role,
        status: 'executed',
        payload: { request_id: requestId, type: finReq.type, amount, target_user_id: targetUserId },
        context: { approvals: approvals.length, execution_result: executionResult },
        created_at: now,
      },
    });

    return res.json({
      success: true, request_id: requestId,
      status: 'executed', execution_result: executionResult,
    });
  } catch (execErr) {
    await reqSnap.ref.update({
      status: 'execution_failed',
      execution_error: execErr.message,
      updated_at: nowIso(),
    });
    return res.status(500).json({
      error: 'execution_failed',
      message: execErr.message,
      request_id: requestId,
    });
  }
});

// ── Reject Finance Request (admin-only) ──────────────────────────────────────
app.post('/api/finance/reject', adminLimiter, async (req, res) => {
  const firestore = requireFirebase(res);
  if (!firestore) return;
  const decoded = await verifyFirebaseAuth(req, res);
  if (!decoded) return;
  const role = await resolveRole({ firestore, uid: decoded.uid, decodedToken: decoded });
  if (role !== 'admin') {
    return res.status(403).json({ error: 'forbidden', message: 'Admin only' });
  }

  const requestId = String(req.body.request_id || '').trim();
  const rejectReason = String(req.body.reason || '').trim();
  if (!requestId) return res.status(400).json({ error: 'missing_request_id' });
  if (!rejectReason) return res.status(400).json({ error: 'missing_reason' });

  const reqSnap = await firestore.collection('finance_requests').doc(requestId).get();
  if (!reqSnap.exists) return res.status(404).json({ error: 'request_not_found' });

  const finReq = reqSnap.data() || {};
  if (['executed', 'rejected'].includes(finReq.status)) {
    return res.status(409).json({ error: 'invalid_status', message: `Request is already ${finReq.status}` });
  }

  await reqSnap.ref.update({
    status: 'rejected',
    rejected_by: decoded.uid,
    rejection_reason: rejectReason,
    resolved_at: nowIso(),
    updated_at: nowIso(),
  });

  await writeAudit({
    firestore, auditId: randomId('audit-'),
    audit: {
      action: `finance_rejected_${finReq.type}`,
      actor_uid: decoded.uid, actor_role: role,
      status: 'rejected',
      payload: { request_id: requestId, type: finReq.type, amount: finReq.amount, rejection_reason: rejectReason },
      created_at: nowIso(),
    },
  });

  return res.json({ success: true, request_id: requestId, status: 'rejected' });
});

// ── List Finance Requests (admin-only) ───────────────────────────────────────
app.get('/api/finance/requests', adminLimiter, async (req, res) => {
  const firestore = requireFirebase(res);
  if (!firestore) return;
  const decoded = await verifyFirebaseAuth(req, res);
  if (!decoded) return;
  const role = await resolveRole({ firestore, uid: decoded.uid, decodedToken: decoded });
  if (role !== 'admin') {
    return res.status(403).json({ error: 'forbidden', message: 'Admin only' });
  }

  const status = String(req.query.status || '').trim();
  const type = String(req.query.type || '').trim();
  const limitRaw = Number.parseInt(String(req.query.limit || '50'), 10);
  const limit = Math.max(1, Math.min(200, limitRaw));

  let q = firestore.collection('finance_requests').orderBy('created_at', 'desc').limit(limit);
  if (status) q = firestore.collection('finance_requests').where('status', '==', status).orderBy('created_at', 'desc').limit(limit);

  try {
    const snap = await q.get();
    const items = snap.docs.map(d => {
      const r = d.data() || {};
      return {
        id: d.id, type: r.type, amount: r.amount, status: r.status,
        target_user_id: r.target_user_id, booking_id: r.booking_id,
        reason: r.reason, requested_by: r.requested_by, method: r.method,
        fraud_score: r.fraud_score, fraud_alerts: r.fraud_alerts,
        requires_secondary_approval: r.requires_secondary_approval,
        approvals: r.approvals, created_at: r.created_at,
        executed_at: r.executed_at, resolved_at: r.resolved_at,
      };
    });
    return res.json({ success: true, count: items.length, items });
  } catch (e) {
    return res.status(500).json({ error: 'internal_error', message: e.message });
  }
});

// ── Fraud Alerts Dashboard (admin-only) ──────────────────────────────────────
app.get('/api/finance/fraud-alerts', adminLimiter, async (req, res) => {
  const firestore = requireFirebase(res);
  if (!firestore) return;
  const decoded = await verifyFirebaseAuth(req, res);
  if (!decoded) return;
  const role = await resolveRole({ firestore, uid: decoded.uid, decodedToken: decoded });
  if (role !== 'admin') {
    return res.status(403).json({ error: 'forbidden', message: 'Admin only' });
  }

  const status = String(req.query.status || 'open').trim();
  const limitRaw = Number.parseInt(String(req.query.limit || '50'), 10);
  const limit = Math.max(1, Math.min(200, limitRaw));

  try {
    let snap;
    try {
      snap = await firestore.collection('fraud_alerts')
        .where('status', '==', status)
        .orderBy('created_at', 'desc')
        .limit(limit)
        .get();
    } catch (indexErr) {
      // Composite index may not exist yet — fall back to status-only query
      console.warn('[fraud-alerts] Index query failed, falling back:', indexErr.message);
      snap = await firestore.collection('fraud_alerts')
        .where('status', '==', status)
        .limit(limit)
        .get();
    }
    const items = snap.docs.map(d => ({ id: d.id, ...d.data() }));
    return res.json({ success: true, count: items.length, items });
  } catch (e) {
    return res.status(500).json({ error: 'internal_error', message: e.message });
  }
});

// ── Dismiss Fraud Alert (admin-only) ─────────────────────────────────────────
app.post('/api/finance/fraud-alerts/dismiss', adminLimiter, async (req, res) => {
  const firestore = requireFirebase(res);
  if (!firestore) return;
  const decoded = await verifyFirebaseAuth(req, res);
  if (!decoded) return;
  const role = await resolveRole({ firestore, uid: decoded.uid, decodedToken: decoded });
  if (role !== 'admin') {
    return res.status(403).json({ error: 'forbidden', message: 'Admin only' });
  }

  const alertId = String(req.body.alert_id || '').trim();
  const dismissReason = String(req.body.reason || '').trim();
  if (!alertId) return res.status(400).json({ error: 'missing_alert_id' });
  if (!dismissReason) return res.status(400).json({ error: 'missing_reason' });

  try {
    await firestore.collection('fraud_alerts').doc(alertId).update({
      status: 'dismissed',
      dismissed_by: decoded.uid,
      dismiss_reason: dismissReason,
      dismissed_at: nowIso(),
    });
    return res.json({ success: true, alert_id: alertId, status: 'dismissed' });
  } catch (e) {
    return res.status(500).json({ error: 'internal_error', message: e.message });
  }
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
  process.on('unhandledRejection', (reason, promise) => {
    console.error('\u274c Unhandled Rejection:', reason);
  });
  process.on('uncaughtException', (error) => {
    console.error('\u274c Uncaught Exception:', error);
    process.exit(1);
  });

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
