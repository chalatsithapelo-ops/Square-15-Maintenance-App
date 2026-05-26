const express = require('express');
const cors = require('cors');
const helmet = require('helmet');
const { AccessToken, AgentDispatchClient, RoomServiceClient, DataPacket_Kind } = require('livekit-server-sdk');
const admin = require('firebase-admin');
const crypto = require('crypto');
const fs = require('fs');
const OpenAI = require('openai');
require('dotenv').config();

// --- Prompt sanitization (prevent injection via user-supplied text) ---
function sanitizeForPrompt(text, maxLen = 500) {
  if (!text || typeof text !== 'string') return '';
  return text
    .replace(/[\x00-\x08\x0B\x0C\x0E-\x1F]/g, '') // strip control chars
    .replace(/\r\n|\r/g, '\n')                       // normalise line endings
    .slice(0, maxLen)
    .trim();
}

// --- OpenAI (for AI RFQ quote generation) ---
let _openai = null;
function getOpenAI() {
  if (_openai) return _openai;
  const key = process.env.OPENAI_API_KEY;
  if (!key) { console.warn('[openai] No OPENAI_API_KEY set'); return null; }
  _openai = new OpenAI({ apiKey: key });
  return _openai;
}

// --- Builders.co.za Real-Time Pricing (ported from Cloud Functions) ---

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

// --- End Builders Pricing ---

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

// ──────────────────────────────────────────────────────────────────────────────
// Cyber-security gap #14: Ozow production credential safety assertion.
// Detect env-var desync (test key + prod URL, or live key + sandbox URL) that
// could route real money to sandbox or sandbox calls to production. Returns
// an array of human-readable errors; empty array means safe.
// Heuristic only — Ozow does not publish a deterministic key-format spec, so
// we rely on patterns observed in the credential pair they provided. The
// helper is called at startup AND inline at the payout route for live mode.
// ──────────────────────────────────────────────────────────────────────────────
function assertOzowProdSafety() {
  const errs = [];
  const isTest = env('OZOW_IS_TEST') === 'true';
  const apiKey = env('OZOW_PAYOUT_API_KEY') || env('OZOW_API_KEY') || '';
  const siteCode = env('OZOW_SITE_CODE') || '';
  // Only enforce when explicitly running in live mode. Sandbox is permissive.
  if (isTest) return errs;
  // Live mode: hard requirements.
  if (!apiKey) errs.push('OZOW_PAYOUT_API_KEY missing in live mode');
  if (!siteCode) errs.push('OZOW_SITE_CODE missing in live mode');
  // Sandbox site codes Ozow has issued historically start with "TSTSTE" or
  // include the literal "TEST". If those appear while OZOW_IS_TEST=false the
  // env vars are mismatched.
  const sc = String(siteCode).toUpperCase();
  if (/^(TST|TEST|TSTSTE)/.test(sc) || sc.includes('TEST')) {
    errs.push(`OZOW_SITE_CODE looks like a sandbox code ("${siteCode}") but OZOW_IS_TEST=false`);
  }
  // Sandbox API keys Ozow issues frequently include the word "TEST" or
  // "STAGING" in the prefix/suffix. Treat that as a desync signal.
  if (/TEST|STAGING|SANDBOX/i.test(apiKey)) {
    errs.push('OZOW_PAYOUT_API_KEY appears to be a sandbox key but OZOW_IS_TEST=false');
  }
  return errs;
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

const jsonBodyLimit = env('JSON_BODY_LIMIT') || '25mb';
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

// Express middleware wrapper � verifyFirebaseAuth returns a value but never
// calls next(), so using it directly as middleware hangs the request.
function authMiddleware(req, res, next) {
  verifyFirebaseAuth(req, res).then(decoded => {
    if (!decoded) return; // response already sent by verifyFirebaseAuth
    req.user = decoded;
    next();
  }).catch(err => {
    console.error('? Auth middleware error:', err);
    if (!res.headersSent) res.status(500).json({ error: 'Internal auth error' });
  });
}

// LK-14: lightweight in-memory rate limiter. Keyed by `${uid||ip}:${bucket}`.
// Sliding window � drops timestamps older than `windowMs`. Returns true if
// the request should proceed, false if it should be 429'd. No external dep.
const _rateBuckets = new Map();
function rateLimit(bucket, key, max, windowMs) {
  try {
    const now = Date.now();
    const k = `${bucket}:${key}`;
    let arr = _rateBuckets.get(k);
    if (!arr) { arr = []; _rateBuckets.set(k, arr); }
    // Drop expired entries
    while (arr.length && (now - arr[0]) > windowMs) arr.shift();
    if (arr.length >= max) return { ok: false, retryAfterMs: windowMs - (now - arr[0]) };
    arr.push(now);
    // Periodic GC: every ~1000 calls, sweep empty buckets
    if (_rateBuckets.size > 5000) {
      for (const [bk, ts] of _rateBuckets) {
        if (!ts.length || (now - ts[ts.length - 1]) > windowMs * 2) _rateBuckets.delete(bk);
      }
    }
    return { ok: true };
  } catch (_) { return { ok: true }; } // fail-open on limiter bug
}

// Express middleware factory: rate-limit by authenticated UID (preferred) or IP.
function rateLimitBy(bucket, max, windowMs) {
  return function (req, res, next) {
    const key = (req.user && req.user.uid) || req.ip || req.headers['x-forwarded-for'] || 'anon';
    const r = rateLimit(bucket, String(key), max, windowMs);
    if (!r.ok) {
      return res.status(429).json({
        error: 'Too Many Requests',
        message: `Rate limit exceeded for ${bucket}. Try again in ${Math.ceil(r.retryAfterMs / 1000)}s.`,
        retry_after_ms: r.retryAfterMs,
      });
    }
    next();
  };
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
        console.warn(`?? User ${uid} has admin role in Firestore but NOT in custom claims � denying admin access`);
        return 'client';
      }

      // Check boolean flag schema (isAdmin, isServiceProvider, isUser)
      // This handles apps that use boolean flags instead of string roles.
      if (data.isAdmin === true) {
        console.warn(`?? User ${uid} has isAdmin=true in Firestore but NOT in custom claims � denying admin access`);
        return 'client';
      }
      if (data.isServiceProvider === true) return 'artisan';
      if (data.isUser === true) return 'client';
    }
  } catch (e) {
    console.warn(`?? Role lookup (users doc) failed for ${uid}:`, e.message);
  }

  // Fallback: check the serviceProvider collection � artisan profiles live
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
    console.warn(`?? Role lookup (serviceProvider) failed for ${uid}:`, e.message);
  }

  return 'client';
}

// ─── Multi-Admin Governance (May 23 2026) ─────────────────────────────────
// Five admin tiers, distinguished by Firebase custom claim `role`:
//   owner    — full power, can grant/revoke other admins' roles, R500k/day cap
//   finance  — can disburse money (payouts, refunds), R50k/day cap
//   ops      — bookings, dispatch, RFQs (no money movement)
//   support  — view-only user data + send messages
//   auditor  — view-only on transactions + audit logs
// Legacy `admin` claim is treated as `finance` until explicitly migrated.
const ADMIN_TIERS = ['owner', 'finance', 'ops', 'support', 'auditor'];

function resolveAdminTier(decoded) {
  if (!decoded) return null;
  const raw = String(decoded.role || decoded.user_role || '').trim().toLowerCase();
  if (ADMIN_TIERS.includes(raw)) return raw;
  // Legacy single-tier admins → finance.
  if (raw === 'admin' || decoded.admin === true) return 'finance';
  return null;
}

function requireAdminTier(allowed) {
  const allow = new Set(allowed);
  return function (req, res, next) {
    const tier = resolveAdminTier(req.user);
    if (!tier || !allow.has(tier)) {
      return res.status(403).json({
        error: 'Forbidden',
        message: `This action requires one of: ${[...allow].join(', ')}. Your tier: ${tier || 'none'}.`,
      });
    }
    req.adminTier = tier;
    next();
  };
}

// ─── TOTP (RFC 6238) — minimal pure-Node implementation ──────────────────
// Avoids adding `speakeasy` to dependencies (smaller surface, no install risk
// on Render). 30-second window, 6-digit codes, SHA-1, base32 secrets.
const _b32alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
function base32Encode(buf) {
  let bits = '';
  for (const b of buf) bits += b.toString(2).padStart(8, '0');
  let out = '';
  for (let i = 0; i + 5 <= bits.length; i += 5) {
    out += _b32alphabet[parseInt(bits.substr(i, 5), 2)];
  }
  return out;
}
function base32Decode(str) {
  let bits = '';
  for (const c of String(str || '').toUpperCase().replace(/=+$/, '')) {
    const v = _b32alphabet.indexOf(c);
    if (v < 0) continue;
    bits += v.toString(2).padStart(5, '0');
  }
  const bytes = [];
  for (let i = 0; i + 8 <= bits.length; i += 8) bytes.push(parseInt(bits.substr(i, 8), 2));
  return Buffer.from(bytes);
}
function totpAt(secretBase32, timestampSec) {
  const key = base32Decode(secretBase32);
  const counter = Math.floor(timestampSec / 30);
  const buf = Buffer.alloc(8);
  buf.writeBigUInt64BE(BigInt(counter));
  const crypto = require('crypto');
  const hmac = crypto.createHmac('sha1', key).update(buf).digest();
  const offset = hmac[hmac.length - 1] & 0x0f;
  const bin = ((hmac[offset] & 0x7f) << 24) |
              ((hmac[offset + 1] & 0xff) << 16) |
              ((hmac[offset + 2] & 0xff) << 8) |
              (hmac[offset + 3] & 0xff);
  return String(bin % 1000000).padStart(6, '0');
}
function verifyTotp(secretBase32, code, window = 1) {
  if (!secretBase32 || !/^\d{6}$/.test(String(code || '').trim())) return false;
  const sec = Math.floor(Date.now() / 1000);
  for (let w = -window; w <= window; w++) {
    if (totpAt(secretBase32, sec + w * 30) === String(code).trim()) return true;
  }
  return false;
}
function generateTotpSecret() {
  return base32Encode(require('crypto').randomBytes(20));
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
  // RFQ quote lifecycle — handlers existed but were unreachable because they
  // weren't in the tier map. Tier B = normal state change (propose+confirm).
  generate_rfq_quote: 'B',
  accept_rfq_quote: 'B',
  reject_rfq_quote: 'B',
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
  request_payment_link: 'B',
  pay_with_wallet: 'B',
  // Phase 4: Admin automation tools (Tier B � admin role required)
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
  // Phase 5.2: Money-moving (Tier C � requires approval pipeline)
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
      console.warn(`?? Counter increment failed for ${prefix}/${dateKey}: ${e.message}; using timestamp fallback`);
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
    // -- IMPORTANT ------------------------------------------------------
    // Only the manual "Status" toggle (the `active` field, stored as
    // 'y'/'n') should gate dispatch.  Presence fields like `is_online`,
    // `online`, `status_online` etc. must NOT be checked here because
    // PresenceService sets `is_online = false` whenever the app is
    // backgrounded / closed.  Artisans who simply close the app (without
    // signing out or turning Status off) must still receive requests and
    // push notifications.
    // --------------------------------------------------------------------
    const active = artisanData && artisanData.active;
    if (active == null) return true; // field missing ? default to active
    return isTruthyExtended(active);
  }

  function hasUsableArtisanAuthIdentity(artisanDocId, artisanData) {
    const data = artisanData && typeof artisanData === 'object' ? artisanData : {};
    const idValues = [
      data.uid,
      data.user_id,
      data.userId,
      data.auth_uid,
      data.provider_id,
    ]
      .map((value) => String(value || '').trim())
      .filter(Boolean);

    // The Firestore document id alone is not sufficient to authenticate later.
    return idValues.length > 0;
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

  async function actorMatchesArtisanAssignment(assignedArtisanId, actorUid) {
    const assigned = String(assignedArtisanId || '').trim();
    const actor = String(actorUid || '').trim();
    if (!assigned || !actor) return false;
    if (assigned === actor) return true;

    const providerDoc = await getServiceProviderDocByAnyId(assigned);
    if (!providerDoc || !providerDoc.exists) return false;

    const provider = providerDoc.data() || {};
    const candidates = [
      providerDoc.id,
      provider.uid,
      provider.user_id,
      provider.userId,
      provider.provider_id,
      provider.auth_uid,
    ]
      .map((value) => String(value || '').trim())
      .filter(Boolean);

    return candidates.includes(actor);
  }

  async function artisanAssignmentDebug(assignedArtisanId, actorUid) {
    const assigned = String(assignedArtisanId || '').trim();
    const actor = String(actorUid || '').trim();
    const providerDoc = assigned ? await getServiceProviderDocByAnyId(assigned) : null;
    const provider = providerDoc && providerDoc.exists ? (providerDoc.data() || {}) : null;
    const candidates = provider
      ? [
          providerDoc.id,
          provider.uid,
          provider.user_id,
          provider.userId,
          provider.provider_id,
          provider.auth_uid,
        ]
          .map((value) => String(value || '').trim())
          .filter(Boolean)
      : [];

    return {
      assigned_artisan_id: assigned || null,
      actor_uid: actor || null,
      provider_doc_found: Boolean(providerDoc && providerDoc.exists),
      provider_doc_id: providerDoc && providerDoc.exists ? String(providerDoc.id || '').trim() || null : null,
      provider_uid: provider ? String(provider.uid || '').trim() || null : null,
      provider_user_id: provider ? String(provider.user_id || provider.userId || '').trim() || null : null,
      provider_auth_uid: provider ? String(provider.auth_uid || '').trim() || null : null,
      candidate_ids: candidates,
      matched: actor ? candidates.includes(actor) || assigned === actor : false,
    };
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
        if (!hasUsableArtisanAuthIdentity(artisanDocId, artisanData)) continue;
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

    // If no task-mapped artisan was available, fall back to broad category matching.
    if (availableWithDistance.length === 0) {
      let snap;
      try {
        // Read all providers then filter with isPublished().
        // Some valid artisans have empty status, and isPublished('') is true.
        snap = await firestore.collection('serviceProvider').limit(200).get();
      } catch (e) { console.warn('\u26a0\ufe0f findAvailableArtisan fallback query:', e.message);
        snap = await firestore.collection('serviceProvider').limit(200).get();
      }

      for (const doc of snap.docs) {
        const artisanDocId = doc.id;
        if (excludeArtisanId && artisanDocId === excludeArtisanId) continue;
        const artisanData = doc.data() || {};
        if (!isPublished(artisanData.status)) continue;
        if (!isArtisanActive(artisanData)) continue;
        if (!hasUsableArtisanAuthIdentity(artisanDocId, artisanData)) continue;

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

      // Auto-heal: detect stale tokens in the per-token response and remove them
      // from any user/artisan/admin doc that stored them.
      try {
        const stale = [];
        (resp.responses || []).forEach((r, idx) => {
          if (r && !r.success && r.error) {
            const code = String(r.error.code || '').toLowerCase();
            if (code.includes('registration-token-not-registered') ||
                code.includes('invalid-registration-token') ||
                code.includes('invalid-argument') && String(r.error.message || '').toLowerCase().includes('token')) {
              stale.push(tokens[idx]);
            }
          }
        });
        if (stale.length) _cleanStaleFcmTokens(stale).catch(e => console.warn('[fcm] stale token cleanup failed:', e && e.message));
      } catch (_) {}

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
        console.warn(`?? Order counter transaction failed: ${e.message}; falling back to date-based order number`);
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
      imageUrls: workImages,
      work_images: workImages,
      workImages: workImages,
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

  // ---------------------------------------------------------------
  // Phase 3: Messaging & Case Management (inlined to access scope)
  // ---------------------------------------------------------------

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
      (actorRole === 'artisan' && await actorMatchesArtisanAssignment(tmArtisanId, actorUid));
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
    if (actorRole !== 'admin' && !(actorRole === 'artisan' && await actorMatchesArtisanAssignment(scArtisanId, actorUid))) {
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

  // -- Reply to Case (threaded conversation) --
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

  // -- List My Cases --
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

  // -- Auto-Escalation Check --
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

  // -- Service Pricing Lookup --
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

  // -- Booking Analytics (admin only, capped at 500 docs) --
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

  // -- List My Bookings --
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
      // Composite index missing � fall back to unordered query + JS sort
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

  // -- Get Wallet Balance --
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

  // -- Check Payment Status (can work with booking_id OR tasks_management_id) --
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

  // -- Request Payment Link � generates PayFast URL + stores in payment_links + sends notification --
  if (action === 'request_payment_link') {
    try {
      const bid = bookingId || String(payload.tasks_management_id || '').trim();
      if (!bid) return { ok: false, status: 400, error: 'missing_booking_id' };

      const bData = await loadBooking();
      if (!bData) return { ok: false, status: 404, error: 'booking_not_found' };

      // Prevent duplicate payment links
      const existingLinks = await firestore.collection('payment_links')
        .where('booking_id', '==', bid)
        .where('status', '==', 'pending')
        .limit(1).get();
      if (!existingLinks.empty) {
        const existing = existingLinks.docs[0].data();
        return { ok: true, status: 200, data: {
          message: `Payment link already exists. Amount: R${parseFloat(existing.amount || 0).toFixed(2)}`,
          paymentUrl: existing.payment_url || '', bookingId: bid, amount: existing.amount,
        }};
      }

      // Enforce artisan acceptance before payment
      const artisanAccepted = bData.accept === '1' || bData.accept === 1 || bData.artisan_confirmed === 'yes';
      if (!artisanAccepted) {
        return { ok: false, status: 400, error: 'An artisan hasn\'t accepted this job yet. Payment is only available after an artisan accepts.' };
      }

      const cost = parseFloat(bData.cost || bData.total_cost || bData.quoted_price || '0');
      if (cost <= 0) return { ok: false, status: 400, error: 'no_confirmed_price' };

      if ((bData.payment_status || bData.paymentStatus) === 'paid') {
        return { ok: true, status: 200, data: { message: 'This booking is already paid.', bookingId: bid } };
      }

      // Support deposit vs full payment
      const paymentType = payload.payment_type || 'full';
      let payAmount;
      if (bData.deposit_paid === true && bData.balance_paid !== true) {
        // Deposit already paid ? pay balance
        payAmount = parseFloat(bData.balance_amount || (cost * 0.65));
      } else if (paymentType === 'deposit') {
        payAmount = Math.round(cost * 0.35 * 100) / 100;
      } else {
        payAmount = cost;
      }

      const merchantId = env('PAYFAST_MERCHANT_ID');
      const merchantKey = env('PAYFAST_MERCHANT_KEY');
      const payfastUrl = env('PAYFAST_URL') || 'https://www.payfast.co.za/eng/process';
      const backendUrl = env('RENDER_EXTERNAL_URL') || 'https://square15-livekit-backend.onrender.com';

      if (!merchantId || !merchantKey) {
        // Fallback: store request + notify admin
        const payRef = `PAY-${bid}-${Date.now().toString(36)}`;
        await firestore.collection('payment_links').doc(payRef).set({
          booking_id: bid,
          amount: payAmount,
          payment_type: paymentType,
          user_id: actorUid || '',
          status: 'pending',
          source: payload.source || 'voice',
          created_at: admin.firestore.FieldValue.serverTimestamp(),
        });
        await firestore.collection('notifications').add({
          title: 'Payment Link Request',
          body: `Payment link requested for booking ${bid} (R${payAmount.toFixed(2)}, ${paymentType})`,
          type: 'payment_request',
          booking_id: bid,
          amount: payAmount,
          for_role: 'admin',
          status: 'unread',
          created_at: admin.firestore.FieldValue.serverTimestamp(),
        });
        return { ok: true, status: 200, data: {
          message: `Payment of R${payAmount.toFixed(2)} is being processed. You'll receive a payment link shortly.`,
          reference: payRef, bookingId: bid, amount: payAmount,
        }};
      }

      // Determine label for payment type
      const itemSuffix = paymentType === 'deposit' ? '(35% Deposit)' : (bData.deposit_paid === true ? '(Balance)' : '(Full)');
      const itemName = `Square 15 Booking ${bData.order_no || bData.rfq_no || bid} ${itemSuffix}`;

      // Build PayFast URL with proper notify/return/cancel URLs (critical for ITN webhook)
      // LK-3: sign return-url so the GET fallback can verify the booking_id wasn't spoofed.
      const _sig = signPaymentCallback(bid);
      const returnUrl = `${backendUrl}/api/payment/ozow-result?status=success&booking_id=${encodeURIComponent(bid)}${_sig}`;
      const cancelUrl = `${backendUrl}/api/payment/ozow-result?status=cancel&booking_id=${encodeURIComponent(bid)}${_sig}`;
      const notifyUrl = `${backendUrl}/api/payment/itn`;

      const paymentData = {
        merchant_id: merchantId,
        merchant_key: merchantKey,
        amount: payAmount.toFixed(2),
        item_name: itemName,
        return_url: returnUrl,
        cancel_url: cancelUrl,
        notify_url: notifyUrl,
        custom_str1: bid,
        // Force card-only checkout
        payment_method: 'cc',
      };

      // Also update booking with payment_type for ITN deposit/balance detection
      const bookingRef = firestore.collection('futureBookings').doc(bid);
      const bookingSnap = await bookingRef.get();
      if (bookingSnap.exists) {
        await bookingRef.update({ payment_type: paymentType, updated_at: new Date().toISOString() });
      }
      const taskRef = firestore.collection('tasksManagement').doc(bid);
      const taskSnap = await taskRef.get();
      if (taskSnap.exists) {
        await taskRef.update({ payment_type: paymentType, updated_at: new Date().toISOString() });
      }

      // Generate PayFast signature (required for payment page)
      const passphrase = env('PAYFAST_PASSPHRASE') || '';
      const pfParamString = Object.entries(paymentData)
        .map(([k, v]) => `${encodeURIComponent(k).replace(/%20/g, '+')}=${encodeURIComponent(String(v || '')).replace(/%20/g, '+')}`)
        .join('&');
      let sigInput = pfParamString;
      if (passphrase) {
        sigInput += `&passphrase=${encodeURIComponent(passphrase).replace(/%20/g, '+')}`;
      }
      paymentData.signature = crypto.createHash('md5').update(sigInput).digest('hex');

      const qs = Object.entries(paymentData)
        .map(([k, v]) => `${encodeURIComponent(k)}=${encodeURIComponent(v)}`)
        .join('&');
      const paymentUrl = `${payfastUrl}?${qs}`;

      console.log(`[payment-link] Generated PayFast link for booking ${bid}, R${payAmount.toFixed(2)}, type=${paymentType}, source=${payload.source || 'voice'}`);

      const payRef = `PAY-${bid}-${Date.now().toString(36)}`;
      await firestore.collection('payment_links').doc(payRef).set({
        booking_id: bid,
        amount: payAmount,
        payment_type: paymentType,
        user_id: actorUid || '',
        payment_url: paymentUrl,
        status: 'pending',
        source: payload.source || 'voice',
        created_at: admin.firestore.FieldValue.serverTimestamp(),
      });

      // Send notification to the customer so they receive the link
      if (actorUid) {
        await firestore.collection('notifications').add({
          title: 'Payment Link Ready',
          body: `Tap to pay R${payAmount.toFixed(2)} ${itemSuffix} for booking ${bData.order_no || bData.rfq_no || bid}`,
          type: 'payment_link',
          booking_id: bid,
          amount: payAmount,
          payment_type: paymentType,
          payment_url: paymentUrl,
          userId: actorUid,
          status: 'unread',
          created_at: admin.firestore.FieldValue.serverTimestamp(),
        });
      }

      return { ok: true, status: 200, data: {
        message: `Payment link generated for R${payAmount.toFixed(2)} ${itemSuffix}. A notification with the link has been sent to your phone.`,
        paymentUrl, reference: payRef, bookingId: bid, amount: payAmount, payment_type: paymentType,
      }};
    } catch (err) {
      return { ok: false, status: 500, error: `payment_link_error: ${err.message}` };
    }
  }

  // -- Pay with Wallet --
  if (action === 'pay_with_wallet') {
    try {
      const bid = bookingId || String(payload.tasks_management_id || '').trim();
      if (!bid) return { ok: false, status: 400, error: 'missing_booking_id' };
      if (!actorUid) return { ok: false, status: 401, error: 'unauthorized' };

      const bData = await loadBooking();
      if (!bData) return { ok: false, status: 404, error: 'booking_not_found' };

      const artisanAccepted = bData.accept === '1' || bData.accept === 1 || bData.artisan_confirmed === 'yes';
      if (!artisanAccepted) {
        return { ok: false, status: 400, error: 'An artisan hasn\'t accepted this job yet. Payment is only available after an artisan accepts.' };
      }

      if ((bData.payment_status || bData.paymentStatus) === 'paid') {
        return { ok: true, status: 200, data: { message: 'This booking is already paid.', bookingId: bid } };
      }

      const cost = parseFloat(bData.cost || bData.total_cost || bData.quoted_price || '0');
      if (cost <= 0) return { ok: false, status: 400, error: 'no_confirmed_price' };

      const paymentType = payload.payment_type || 'full';

      // Hard validation: a balance payment is only meaningful AFTER deposit
      // has been paid. Without this guard a caller could request
      // payment_type='balance' on a fresh booking and the implicit branch
      // below would silently fall back to charging the full amount or 65%
      // � confusing the customer and breaking transactionLogs accounting.
      if (paymentType === 'balance' && bData.deposit_paid !== true) {
        return { ok: false, status: 400, error: 'cannot_pay_balance_before_deposit' };
      }

      let payAmount;
      if (bData.deposit_paid === true && bData.balance_paid !== true) {
        payAmount = parseFloat(bData.balance_amount || (cost * 0.65));
      } else if (paymentType === 'deposit') {
        payAmount = Math.round(cost * 0.35 * 100) / 100;
      } else {
        payAmount = cost;
      }

      // Check wallet balance
      const userSnap = await firestore.collection('users').doc(actorUid).get();
      if (!userSnap.exists) return { ok: false, status: 404, error: 'user_not_found' };
      const userData = userSnap.data() || {};
      const walletBalance = parseFloat(userData.balance || userData.wallet_balance || '0');

      if (walletBalance < payAmount) {
        return { ok: false, status: 400, error: `Insufficient wallet balance. You have R${walletBalance.toFixed(2)} but need R${payAmount.toFixed(2)}.` };
      }

      // Deduct from wallet using Firestore transaction to prevent race conditions
      let newBalance;
      await firestore.runTransaction(async (transaction) => {
        const userRef = firestore.collection('users').doc(actorUid);
        const freshSnap = await transaction.get(userRef);
        if (!freshSnap.exists) throw new Error('user_not_found');
        const freshData = freshSnap.data() || {};
        const currentBalance = parseFloat(freshData.balance || freshData.wallet_balance || '0');
        if (currentBalance < payAmount) {
          throw new Error(`Insufficient wallet balance. You have R${currentBalance.toFixed(2)} but need R${payAmount.toFixed(2)}.`);
        }
        newBalance = currentBalance - payAmount;
        transaction.update(userRef, {
          balance: newBalance.toFixed(2),
          updated_at: new Date().toISOString(),
        });
      });

      // Determine deposit vs balance vs full
      const isDepositBooking = paymentType === 'deposit';
      const depositAlreadyPaid = bData.deposit_paid === true;
      const now = new Date().toISOString();

      const updateData = { payment_method: 'wallet', updated_at: now };
      if (isDepositBooking && !depositAlreadyPaid) {
        updateData.deposit_paid = true;
        updateData.deposit_paid_at = now;
        updateData.payment_status = 'deposit_paid';
        updateData.payment_type = 'deposit';
      } else if (depositAlreadyPaid && bData.balance_paid !== true) {
        updateData.balance_paid = true;
        updateData.balance_paid_at = now;
        updateData.payment_status = 'paid';
      } else {
        updateData.payment_status = 'paid';
      }

      // Update both collections
      const bookingRef = firestore.collection('futureBookings').doc(bid);
      if ((await bookingRef.get()).exists) await bookingRef.update(updateData);
      const taskRef = firestore.collection('tasksManagement').doc(bid);
      if ((await taskRef.get()).exists) await taskRef.update(updateData);

      // Log transaction
      await firestore.collection('transactionLogs').add({
        booking_id: bid,
        user_id: actorUid,
        amount: payAmount.toFixed(2),
        payment_method: 'wallet',
        payment_type: updateData.payment_status === 'deposit_paid' ? 'deposit' : (depositAlreadyPaid ? 'balance' : 'full'),
        status: 'success',
        wallet_balance_before: walletBalance.toFixed(2),
        wallet_balance_after: newBalance.toFixed(2),
        created_at: admin.firestore.FieldValue.serverTimestamp(),
      });

      return { ok: true, status: 200, data: {
        message: `Payment of R${payAmount.toFixed(2)} completed from your wallet. Remaining balance: R${newBalance.toFixed(2)}.`,
        bookingId: bid, amount: payAmount, new_balance: newBalance,
      }};
    } catch (err) {
      return { ok: false, status: 500, error: `wallet_payment_error: ${err.message}` };
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
      (actorRole === 'artisan' && await actorMatchesArtisanAssignment(artisanId, actorUid)) ||
      actorRole === 'admin';
    if (!allowed) {
      return {
        ok: false,
        status: 403,
        error: 'forbidden',
        debug: {
          action,
          actor_role: actorRole,
          booking_user_id: userId || null,
          artisan_match: actorRole === 'artisan' ? await artisanAssignmentDebug(artisanId, actorUid) : null,
        },
      };
    }

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

  // -- Explain Quote (RFQ details, scope of work) --
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
            if (actorRole !== 'admin' && rfqUserId !== actorUid && !(await actorMatchesArtisanAssignment(rfqArtisanId, actorUid))) {
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
    if (actorRole !== 'admin' && bUserId !== actorUid && !(await actorMatchesArtisanAssignment(bArtisanId, actorUid))) {
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

  // -- Generate AI RFQ Quote (with Builders.co.za real-time pricing) --
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
      let contingencyPct = 0.15; // default 15%
      if (guidanceDoc.exists) {
        const gd = guidanceDoc.data();
        laborRate = parseFloat(gd.labor_cost_per_hour || gd.laborCostPerHour || 150);
        const sp = gd.service_prices || gd.servicePrices || {};
        if (gd.contingency_percentage != null) {
          contingencyPct = parseFloat(gd.contingency_percentage) / 100;
          if (isNaN(contingencyPct) || contingencyPct < 0) contingencyPct = 0.15;
        }
        pricingCtx = `Labor rate: R${laborRate}/hr. Service prices: ${JSON.stringify(sp)}. Contingency: ${(contingencyPct * 100).toFixed(0)}%`;
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
      const contingency = subtotal * contingencyPct;
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
          { description: `Labour (${laborHours}hrs @ R${lrUsed}/hr${learningFactor !== 1 ? ` � ${learningFactor.toFixed(2)} adj` : ''})`, cost: laborCost.toFixed(2) },
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

  // -- Accept RFQ Quote --
  if (action === 'accept_rfq_quote') {
    const data = await loadBooking();
    if (!data) return { ok: false, status: 404, error: 'booking_not_found' };
    if (!data.ai_quote && !data.quoted_price) return { ok: false, status: 400, error: 'no_quote_available' };

    const price = data.quoted_price || (data.ai_quote ? String(data.ai_quote.grand_total) : '0');
    const priceNum = parseFloat(price) || 0;

    // Atomically update futureBookings + tasksManagement so an RFQ can
    // never be accepted in only one of the two collections (previously the
    // tasksManagement mirror was a separate try/catch that swallowed
    // failures, leaving artisans seeing stale data).
    const _acceptBatch = firestore.batch();
    _acceptBatch.update(bookingRef, {
      rfq_status: 'accepted_converted',
      status: 'pending_artisan_acceptance',
      accepted_at: now,
      accepted_via: payload.source || 'voice',
      updated_at: now,
    });
    // ── Carry the customer's issue photos into the artisan-facing tm doc.
    // Without this, artisans accepting an RFQ never see the pictures the
    // client attached during voice/WA RFQ submission.
    const _rfqImgs = (function () {
      const cand = data.work_images || data.workImages || data.image_urls || data.imageUrls || data.work_image_urls || data.workImageUrls || data.images || [];
      return Array.isArray(cand) ? cand.filter((u) => typeof u === 'string' && u.trim()) : [];
    })();
    _acceptBatch.set(
      firestore.collection('tasksManagement').doc(bookingId),
      {
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
        // Artisan-visible issue photos (4 field aliases mirror what the
        // create_order_booking path writes to futureBookings).
        attachment: _rfqImgs[0] || '',
        additional_attachment: _rfqImgs[1] || '',
        image_urls: _rfqImgs,
        imageUrls: _rfqImgs,
        work_images: _rfqImgs,
        workImages: _rfqImgs,
      },
      { merge: true },
    );
    try {
      await _acceptBatch.commit();
    } catch (e) {
      console.error('[voice accept_rfq_quote] batch commit failed:', e.message);
      return { ok: false, status: 500, error: 'accept_failed', detail: e.message };
    }

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
          if (!isArtisanActive(ad)) continue;
          if (!hasUsableArtisanAuthIdentity(artDoc.id, ad)) continue;
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
                notification: { title: '?? New RFQ Job Available', body: `RFQ ${data.rfq_no || bookingId} � R${priceNum.toFixed(2)}. Tap to view and accept.` },
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
        title: 'RFQ Quote Accepted � Assign Artisan',
        message: `Customer accepted RFQ ${data.rfq_no || bookingId} (R${priceNum.toFixed(2)}) via voice. Please assign an artisan.`,
        data: { type: 'rfq_accepted', bookingId },
      });
    }

    return { ok: true, status: 200, data: { accepted: true, price, rfq_no: String(data.rfq_no || '').trim(), auto_dispatched: autoDispatched } };
  }

  // -- Reject / Negotiate RFQ Quote --
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

    // Atomic reschedule across both collections so the artisan never sees
    // a stale scheduled_date while the client sees the new one.
    const _rescheduleBatch = firestore.batch();
    _rescheduleBatch.set(
      bookingRef,
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
      { merge: true },
    );
    if (tmId) {
      _rescheduleBatch.set(
        firestore.collection('tasksManagement').doc(tmId),
        { scheduled_date: date, scheduled_time: time, updated_at: now },
        { merge: true },
      );
    }
    await _rescheduleBatch.commit();

    return { ok: true, status: 200, data: { rescheduled: true } };
  }

  if (action === 'mark_booking_in_progress') {
    if (!(actorRole === 'artisan' && await actorMatchesArtisanAssignment(artisanId, actorUid))) {
      return {
        ok: false,
        status: 403,
        error: 'forbidden',
        debug: {
          action,
          actor_role: actorRole,
          booking_user_id: userId || null,
          artisan_match: await artisanAssignmentDebug(artisanId, actorUid),
        },
      };
    }

    // Atomic in-progress flip across both collections so the UI and
    // artisan notifications can't diverge on partial failure.
    const _progressBatch = firestore.batch();
    _progressBatch.set(
      bookingRef,
      {
        status: 'in_progress',
        in_progress_at: now,
        updated_at: now,
      },
      { merge: true },
    );
    if (tmId) {
      _progressBatch.set(
        firestore.collection('tasksManagement').doc(tmId),
        {
          status: 'progress',
          accept: '1',
          updated_at: now,
        },
        { merge: true },
      );
    }
    await _progressBatch.commit();

    return { ok: true, status: 200, data: { in_progress: true } };
  }

  if (action === 'request_reassignment' || action === 'artisan_cancel_and_reassign' || action === 'reassign_booking') {
    const isOwnerClient = actorRole === 'client' && userId === actorUid;
    const isAssignedArtisan = actorRole === 'artisan' && await actorMatchesArtisanAssignment(artisanId, actorUid);
    const isAdmin = actorRole === 'admin';
    if (!(isOwnerClient || isAssignedArtisan || isAdmin)) {
      return {
        ok: false,
        status: 403,
        error: 'forbidden',
        debug: {
          action,
          actor_role: actorRole,
          booking_user_id: userId || null,
          artisan_match: actorRole === 'artisan' ? await artisanAssignmentDebug(artisanId, actorUid) : null,
        },
      };
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

  // -- New Tier A: get_transaction_history --------------------------
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

  // -- New Tier A: get_deposit_requests ----------------------------
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

  // -- New Tier A: get_service_categories --------------------------
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

  // -- New Tier A: get_notifications ------------------------------
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
      // Notifications subcollection may not exist � return empty
      return { ok: true, status: 200, data: { notifications: [], count: 0 } };
    }
  }

  // -- New Tier A: get_scheduled_bookings -------------------------
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

  // -- New Tier A: get_artisan_info -------------------------------
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

  // -- New Tier B: submit_rating ----------------------------------
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

  // -- New Tier B: submit_complaint -------------------------------
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

  // ---------------------------------------------------------------------------
  // PHASE 4 � Admin Automation Tools (Tier B, admin-only)
  // ---------------------------------------------------------------------------

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

  // ---------------------------------------------------------------------------
  // PHASE 5.1 � Finance Read-Only Tools (Tier A)
  // ---------------------------------------------------------------------------

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
    console.error('? Livekit credentials not configured');
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

// -- Public pricing test endpoint (dev only) --
app.get('/api/test-pricing', async (req, res) => {
  // Public pricing endpoint � used by voice agent for service/pricing lookups.
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
    const allowVoiceStartWithoutAuth = isEnvTruthy('ALLOW_VOICE_START_WITHOUT_AUTH');
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

    // Default-secure behavior: require Firebase auth for voice start.
    // Set ALLOW_VOICE_START_WITHOUT_AUTH=true only for controlled testing environments.
    if (!idToken && !allowVoiceStartWithoutAuth) {
      return res.status(401).json({
        error: 'Unauthorized',
        message: 'Missing Authorization: Bearer <Firebase ID token>',
        request_id: req.requestId || null,
      });
    }

    // SECURITY: when an Authorization header IS provided we must verify it
    // BEFORE the broad try below (whose catch silently swallows verifyIdToken
    // failures). Without this, a bearer of any garbage string was getting a
    // valid LiveKit access token (May 25 2026 audit finding).
    if (idToken) {
      try {
        initFirebaseIfPossible();
        if (!firebaseInitError) {
          await admin.auth().verifyIdToken(idToken);
        } else if (!allowVoiceStartWithoutAuth) {
          return res.status(503).json({
            error: 'auth_unavailable',
            message: 'Firebase Admin not configured; cannot verify Authorization header',
            request_id: req.requestId || null,
          });
        }
      } catch (e) {
        if (!allowVoiceStartWithoutAuth) {
          return res.status(401).json({
            error: 'Unauthorized',
            message: 'Invalid Firebase ID token',
            request_id: req.requestId || null,
          });
        }
      }
    }

    // SECURITY: clamp room name to prevent abuse / log spam.
    if (typeof req.body.roomName === 'string' && req.body.roomName.length > 128) {
      return res.status(400).json({
        error: 'invalid_room_name',
        message: 'roomName must be \u2264 128 characters',
        request_id: req.requestId || null,
      });
    }

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

    // -- Enrich participant metadata with session credentials --
    // Use voice_session_id + nonce for agent authentication instead of raw Firebase token.
    let enrichedMetadata = metadata;
    try {
      const parsed = metadata ? JSON.parse(metadata) : {};
      // Do NOT embed the raw Firebase ID token � it would leak to all room participants.
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

    console.log(`? Session started. room=${roomName} user=${participantName} agent=${agentName}`);

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
    console.error('? Error starting voice session:', error);
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
          debug: result.debug || null,
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

// -- Server-side FCM Notification Endpoint --
// Replaces client-side admin SDK usage � clients call this instead of loading firebase-adminsdk.json
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

    // Send FCM via Admin SDK (server-side � no private key exposed to clients)
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
    console.log(`? FCM sent via backend: ${result}`);

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
    console.error('? FCM send error:', error);
    res.status(500).json({ error: 'Failed to send notification' });
  }
});

// -- AI Photo Diagnosis (GPT-4o Vision) --
// Used by client app + Lizzy Voice photo enrichment.
app.post('/api/photo/diagnose', assistantLimiter, async (req, res) => {
  try {
    const oai = getOpenAI();
    if (!oai) return res.status(503).json({ error: 'AI service not configured' });
    const { image_base64, image_url, user_description, location_context } = req.body || {};
    if (!image_base64 && !image_url) {
      return res.status(400).json({ error: 'Provide image_base64 or image_url' });
    }
    const imageContent = image_base64
      ? { type: 'image_url', image_url: { url: image_base64.startsWith('data:') ? image_base64 : `data:image/jpeg;base64,${image_base64}`, detail: 'high' } }
      : { type: 'image_url', image_url: { url: image_url, detail: 'high' } };
    const userText = user_description
      ? `The tenant describes the issue as: "${user_description}"${location_context ? `. Location: ${location_context}` : ''}`
      : `Please analyze this maintenance issue photo.${location_context ? ` Location: ${location_context}` : ''}`;
    const completion = await oai.chat.completions.create({
      model: 'gpt-4o',
      temperature: 0.2,
      max_tokens: 800,
      response_format: { type: 'json_object' },
      messages: [
        { role: 'system', content: 'You are an expert maintenance diagnostics AI for Square 15 Maintenance (South Africa). Analyze the photo and return JSON with: issue_type, service_category (Plumbing|Electrical|Painting|Carpentry|Roofing|Tiling|Locksmith|Appliance Repair|Landscaping|General Maintenance), severity (low|medium|high|emergency), urgency_flag (bool), description (2-3 sentences), recommended_action, estimated_complexity (1-5), materials_likely_needed (array), safety_warnings (array), confidence (0.0-1.0). If not a maintenance issue, set issue_type="not_maintenance". Return ONLY valid JSON.' },
        { role: 'user', content: [imageContent, { type: 'text', text: userText }] },
      ],
    });
    const content = completion.choices[0]?.message?.content || '{}';
    let diagnosis;
    try { diagnosis = JSON.parse(content); } catch { diagnosis = { raw: content }; }
    res.json({ ok: true, diagnosis });
  } catch (error) {
    console.error('Photo diagnose error:', error && error.message);
    res.status(500).json({ error: 'Photo diagnosis failed' });
  }
});

// -- In-memory payment session store (WhatsApp checkout) --
// PayFast /eng/process only accepts POST, not GET. So we store payment data
// briefly and serve an auto-submit HTML form page via GET.
const paymentSessions = new Map();
const PAYMENT_SESSION_TTL = 30 * 60 * 1000; // 30 minutes
setInterval(() => {
  const now = Date.now();
  for (const [id, s] of paymentSessions) {
    if (now - s.created > PAYMENT_SESSION_TTL) paymentSessions.delete(id);
  }
}, 5 * 60 * 1000);

// -------------------------------------------------------------------------
// LK-3 FIX (May 2026): sign PayFast return-url callbacks to prevent an
// attacker from spoofing `?status=success&booking_id=X` and causing the
// server-side fallback to mark someone else's booking as paid. We append
// `&t=<HMAC>&exp=<ms>` to every return/cancel URL we generate, then verify
// it in the GET /api/payment/ozow-result handler. Tokens use HMAC-SHA256
// keyed off PAYMENT_CALLBACK_SECRET (preferred) or PAYFAST_PASSPHRASE.
// Tokens are valid for 90 minutes (covers slow checkouts + clock skew).
// Fail-closed: an unsigned/invalid callback still renders the status page
// but does NOT trigger the payment-processing fallback.
// -------------------------------------------------------------------------
const PAYMENT_CALLBACK_TTL_MS = 90 * 60 * 1000;
function _paymentCallbackSecret() {
  return env('PAYMENT_CALLBACK_SECRET') || env('PAYFAST_PASSPHRASE') || '';
}
function signPaymentCallback(bookingId) {
  const secret = _paymentCallbackSecret();
  if (!secret) {
    console.warn('[payment-callback] no PAYMENT_CALLBACK_SECRET/PAYFAST_PASSPHRASE � callbacks will be unsigned and rejected');
    return '';
  }
  const exp = Date.now() + PAYMENT_CALLBACK_TTL_MS;
  const sig = crypto.createHmac('sha256', secret)
    .update(`${bookingId}:${exp}`)
    .digest('hex')
    .slice(0, 32);
  return `&t=${sig}&exp=${exp}`;
}
function verifyPaymentCallback(bookingId, t, exp) {
  if (!t || !exp) return { ok: false, reason: 'missing_token' };
  const expNum = Number(exp);
  if (!Number.isFinite(expNum)) return { ok: false, reason: 'bad_exp' };
  if (expNum < Date.now()) return { ok: false, reason: 'expired' };
  const secret = _paymentCallbackSecret();
  if (!secret) return { ok: false, reason: 'no_secret' };
  const expected = crypto.createHmac('sha256', secret)
    .update(`${bookingId}:${expNum}`)
    .digest('hex')
    .slice(0, 32);
  // Constant-time compare
  const a = Buffer.from(expected, 'utf8');
  const b = Buffer.from(String(t), 'utf8');
  if (a.length !== b.length) return { ok: false, reason: 'bad_sig' };
  if (!crypto.timingSafeEqual(a, b)) return { ok: false, reason: 'bad_sig' };
  return { ok: true };
}

// -- GET checkout page � renders auto-submit POST form to PayFast --
app.get('/api/payment/checkout/:sessionId', (req, res) => {
  const session = paymentSessions.get(req.params.sessionId);
  if (!session) {
    return res.status(404).send(`
      <html><body style="font-family:sans-serif;text-align:center;padding:60px">
        <h2>Payment link expired</h2>
        <p>This payment link has expired or already been used. Please request a new one via WhatsApp.</p>
      </body></html>
    `);
  }

  const payfastUrl = env('PAYFAST_URL') || 'https://www.payfast.co.za/eng/process';

  // Mark as used immediately to prevent replay attacks
  if (session.used) {
    return res.status(410).send(`<html><body style="font-family:sans-serif;text-align:center;padding:60px"><h2>Payment link expired</h2><p>This payment link has already been used. Please request a new one.</p></body></html>`);
  }
  session.used = true;
  // Garbage-collect session after 5 minutes
  setTimeout(() => paymentSessions.delete(req.params.sessionId), 5 * 60 * 1000);

  // Build hidden form fields � escape values for HTML safety
  const esc = (s) => String(s).replace(/&/g,'&amp;').replace(/"/g,'&quot;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
  const fields = Object.entries(session.paymentData)
    .map(([k, v]) => `<input type="hidden" name="${esc(k)}" value="${esc(v)}">`)
    .join('\n      ');

  res.send(`
    <html>
    <head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
    <title>Square 15 � Redirecting to Payment</title></head>
    <body style="font-family:sans-serif;text-align:center;padding:60px">
      <h2>Redirecting to secure payment...</h2>
      <p>Amount: <strong>R${esc(session.paymentData.amount)}</strong></p>
      <p>Please wait, you will be redirected to PayFast shortly.</p>
      <form id="pf" method="POST" action="${esc(payfastUrl)}">
      ${fields}
      </form>
      <script>document.getElementById('pf').submit();</script>
      <noscript><p>JavaScript is required. <button onclick="document.getElementById('pf').submit()">Click here to pay</button></p></noscript>
    </body></html>
  `);
});

// -- WhatsApp Payment Link Generation (internal use only) --
// Called by WhatsApp bot to generate a payment link for customers who may not have the app.
app.post('/api/payment/whatsapp-initiate', assistantLimiter, async (req, res) => {
  try {
    // Verify internal shared secret
    const internalSecret = (process.env.INTERNAL_API_SECRET || '').trim();
    if (!internalSecret) {
      console.error('FATAL: INTERNAL_API_SECRET not set � rejecting request');
      return res.status(503).json({ error: 'Server misconfigured' });
    }
    const providedSecret = (req.headers['x-internal-secret'] || '').trim();
    if (!providedSecret || providedSecret !== internalSecret) {
      return res.status(403).json({ error: 'Unauthorized' });
    }

    const merchantId = env('PAYFAST_MERCHANT_ID');
    const merchantKey = env('PAYFAST_MERCHANT_KEY');
    const backendUrl = env('RENDER_EXTERNAL_URL') || 'https://square15-livekit-backend.onrender.com';

    if (!merchantId || !merchantKey) {
      return res.status(503).json({ error: 'Payment credentials not configured' });
    }

    const { amount, booking_id, customer_name, customer_phone, description, payment_method } = req.body;
    if (!amount || !booking_id) {
      return res.status(400).json({ error: 'Missing required: amount, booking_id' });
    }

    const itemName = description || `Square 15 Booking ${booking_id}`;
    // LK-3: sign callback to prevent spoofed booking_id in fallback handler.
    const _sig = signPaymentCallback(booking_id);
    const returnUrl = `${backendUrl}/api/payment/ozow-result?status=success&booking_id=${encodeURIComponent(booking_id)}${_sig}`;
    const cancelUrl = `${backendUrl}/api/payment/ozow-result?status=cancel&booking_id=${encodeURIComponent(booking_id)}${_sig}`;
    const notifyUrl = `${backendUrl}/api/payment/itn`;

    // PayFast requires parameters in a SPECIFIC order for signature verification:
    // merchant ? return/cancel/notify ? personal ? amount/item ? custom ? payment_method
    const paymentData = {};
    paymentData.merchant_id = merchantId;
    paymentData.merchant_key = merchantKey;
    paymentData.return_url = returnUrl;
    paymentData.cancel_url = cancelUrl;
    paymentData.notify_url = notifyUrl;
    if (customer_name) paymentData.name_first = customer_name;
    if (customer_phone) paymentData.cell_number = customer_phone;
    paymentData.amount = String(parseFloat(amount).toFixed(2));
    paymentData.item_name = itemName;
    paymentData.custom_str1 = booking_id;
    if (payment_method === 'cc') paymentData.payment_method = 'cc';

    // Generate PayFast signature
    const passphrase = env('PAYFAST_PASSPHRASE') || '';
    const pfParamString = Object.entries(paymentData)
      .map(([k, v]) => `${encodeURIComponent(k).replace(/%20/g, '+')}=${encodeURIComponent(String(v || '')).replace(/%20/g, '+')}`)
      .join('&');
    let sigInput = pfParamString;
    if (passphrase) {
      sigInput += `&passphrase=${encodeURIComponent(passphrase).replace(/%20/g, '+')}`;
    }
    paymentData.signature = crypto.createHash('md5').update(sigInput).digest('hex');

    // Store payment session and return a GET-friendly checkout URL
    const sessionId = crypto.randomUUID();
    paymentSessions.set(sessionId, { paymentData, created: Date.now() });
    const checkoutUrl = `${backendUrl}/api/payment/checkout/${sessionId}`;

    console.log(`[wa-payment] Generated checkout link for booking ${booking_id}, R${amount}, session=${sessionId}`);

    res.json({
      ok: true,
      payment_url: checkoutUrl,
      booking_id,
      amount: parseFloat(amount).toFixed(2),
    });
  } catch (error) {
    console.error('? WhatsApp payment link error:', error);
    res.status(500).json({ error: 'Payment link generation failed' });
  }
});

// -- Server-side PayFast Payment Initiation --
// Replaces client-side hardcoded merchant credentials
// Supports: payment_method='eft' (default/Ozow), 'cc' (card-only)
// Supports: subscription_type=2 for ad-hoc tokenization (save card for future use)
app.post('/api/payment/initiate', authMiddleware, assistantLimiter, async (req, res) => {
  try {
    const merchantId = env('PAYFAST_MERCHANT_ID');
    const merchantKey = env('PAYFAST_MERCHANT_KEY');
    const payfastUrl = env('PAYFAST_URL') || 'https://www.payfast.co.za/eng/process';
    const backendUrl = env('RENDER_EXTERNAL_URL') || 'https://square15-livekit-backend.onrender.com';

    if (!merchantId || !merchantKey) {
      return res.status(503).json({ error: 'Payment credentials not configured on server' });
    }

    const { amount, item_name, return_url, cancel_url, notify_url, custom_str1, payment_method, save_card, email_address, name_first } = req.body;

    if (!amount || !item_name) {
      return res.status(400).json({ error: 'Missing required fields: amount, item_name' });
    }

    const parsedAmount = parseFloat(amount);
    if (isNaN(parsedAmount) || parsedAmount <= 0) {
      return res.status(400).json({ error: 'Amount must be greater than zero' });
    }

    // Resolve buyer email/name from request body or Firebase Auth token
    const decoded = req.user;
    let buyerEmail = email_address || '';
    let buyerName = name_first || '';
    if ((!buyerEmail || !buyerName) && decoded && decoded.uid) {
      try {
        const userDoc = await admin.firestore().collection('users').doc(decoded.uid).get();
        if (userDoc.exists) {
          const userData = userDoc.data();
          if (!buyerEmail) buyerEmail = userData.email || decoded.email || '';
          if (!buyerName) buyerName = (userData.name || decoded.name || '').split(' ')[0];
        }
      } catch (e) { /* non-critical */ }
    }

    // Default return/cancel URLs point to our result page
    // LK-3: sign callback to prevent spoofed booking_id in fallback handler.
    const taskId = custom_str1 || '';
    const _sigDefault = signPaymentCallback(taskId);
    const defaultReturn = `${backendUrl}/api/payment/ozow-result?status=success&booking_id=${encodeURIComponent(taskId)}${_sigDefault}`;
    const defaultCancel = `${backendUrl}/api/payment/ozow-result?status=cancel&booking_id=${encodeURIComponent(taskId)}${_sigDefault}`;
    const defaultNotify = `${backendUrl}/api/payment/itn`;

    // PayFast requires parameters in a SPECIFIC order for signature verification:
    // merchant ? return/cancel/notify ? personal ? amount/item ? custom ? payment_method ? subscription
    const paymentData = {};
    paymentData.merchant_id = merchantId;
    paymentData.merchant_key = merchantKey;
    paymentData.return_url = return_url || defaultReturn;
    paymentData.cancel_url = cancel_url || defaultCancel;
    paymentData.notify_url = notify_url || defaultNotify;
    if (buyerName) paymentData.name_first = buyerName;
    if (buyerEmail) paymentData.email_address = buyerEmail;
    paymentData.amount = String(parseFloat(amount).toFixed(2));
    paymentData.item_name = String(item_name);
    if (custom_str1) paymentData.custom_str1 = custom_str1;

    // Force a specific PayFast payment method when requested.
    // Accepted codes: 'cc' (card), 'eft' (instant EFT), 'mc' (Mobicred),
    // 'mt' (MoreTyme), 'rc' (RCS Store Card), 'sc' (SnapScan), 'zp' (Zapper),
    // 'mp' (Masterpass), 'ap' (ApplePay), 'sp' (SamsungPay).
    const allowedMethods = new Set(['cc', 'eft', 'mc', 'mt', 'rc', 'sc', 'zp', 'mp', 'ap', 'sp']);
    if (payment_method && allowedMethods.has(String(payment_method))) {
      paymentData.payment_method = String(payment_method);
    }

    // Enable ad-hoc tokenization (save card) only when explicitly enabled in env.
    // This avoids PayFast 400 errors on merchants that have not enabled ad-hoc tokenization.
    const enableTokenization = env('PAYFAST_ENABLE_TOKENIZATION') === 'true';
    if (save_card === true && payment_method === 'cc' && enableTokenization) {
      paymentData.subscription_type = '2';
    } else if (save_card === true && !enableTokenization) {
      // Client asked to save a card but backend is not configured for it.
      // Log once so admin sees the config issue in Live Issues.
      try {
        await logErrorToAdmin(
          'payment_config_error',
          'Customer tried to save a card but PAYFAST_ENABLE_TOKENIZATION is not set to "true" on Render. Card will NOT be saved (payment will still proceed as a one-off charge).',
          'backend',
          `uid=${decoded && decoded.uid} save_card=true payment_method=${payment_method}`,
          taskId || null,
          'medium'
        );
      } catch (_) {}
    }

    // Generate PayFast signature (MD5 of param string + passphrase)
    // PayFast REQUIRES a valid signature for payment page requests
    const passphrase = env('PAYFAST_PASSPHRASE') || '';
    const pfParamString = Object.entries(paymentData)
      .map(([k, v]) => `${encodeURIComponent(k).replace(/%20/g, '+')}=${encodeURIComponent(String(v || '')).replace(/%20/g, '+')}`)
      .join('&');
    let sigInput = pfParamString;
    if (passphrase) {
      sigInput += `&passphrase=${encodeURIComponent(passphrase).replace(/%20/g, '+')}`;
    }
    const signature = crypto.createHash('md5').update(sigInput).digest('hex');
    paymentData.signature = signature;

    // Build full payment URL with query params � use + encoding (matches signature)
    const queryString = Object.entries(paymentData)
      .map(([k, v]) => `${encodeURIComponent(k).replace(/%20/g, '+')}=${encodeURIComponent(String(v || '')).replace(/%20/g, '+')}`)
      .join('&');
    const fullPaymentUrl = `${payfastUrl}?${queryString}`;

    // Build auto-submitting HTML form (POST) � most reliable PayFast integration method
    const formFields = Object.entries(paymentData)
      .map(([k, v]) => `<input type="hidden" name="${k}" value="${String(v || '').replace(/"/g, '&quot;')}" />`)
      .join('\n      ');
    const formHtml = `<!DOCTYPE html>
<html><head><title>Redirecting to PayFast...</title>
<style>body{display:flex;align-items:center;justify-content:center;height:100vh;margin:0;font-family:sans-serif;background:#f5f5f5;}
.loader{text-align:center;}.spinner{border:4px solid #ddd;border-top:4px solid #1a73e8;border-radius:50%;width:40px;height:40px;animation:spin 1s linear infinite;margin:0 auto 16px;}
@keyframes spin{to{transform:rotate(360deg);}}</style></head>
<body><div class="loader"><div class="spinner"></div><p>Redirecting to PayFast...</p></div>
<form id="pf" method="POST" action="${payfastUrl}">
      ${formFields}
</form>
<script>document.getElementById('pf').submit();</script>
</body></html>`;

    console.log(`[payment] Initiated ${payment_method || 'eft'} payment, amount=R${amount}, save_card=${!!save_card}, task=${taskId}`);

    res.json({
      ok: true,
      payment_url: fullPaymentUrl,
      payment_form_html: formHtml,
      payfast_url: payfastUrl,
      payment_data: paymentData,
    });
  } catch (error) {
    console.error('? Payment initiation error:', error);
    try {
      await logErrorToAdmin(
        'payment_initiation_error',
        'Customer could not start a PayFast payment. They saw a 500 error on the app.',
        'backend',
        `${error && error.stack ? error.stack : error && error.message ? error.message : String(error)}`,
        req.body && req.body.custom_str1 ? req.body.custom_str1 : null,
        'high'
      );
    } catch (_) {}
    res.status(500).json({ error: 'Payment initiation failed', detail: error && error.message });
  }
});

// -- Charge Saved Card (ad-hoc tokenization) --
// Uses a previously saved PayFast token to charge a card without redirecting
app.post('/api/payment/charge-token', authMiddleware, assistantLimiter, async (req, res) => {
  try {
    const merchantId = env('PAYFAST_MERCHANT_ID');
    const merchantKey = env('PAYFAST_MERCHANT_KEY');
    const passphrase = env('PAYFAST_PASSPHRASE') || '';

    if (!merchantId || !merchantKey) {
      return res.status(503).json({ error: 'Payment credentials not configured' });
    }

    const { token: rawToken, card_id, amount, item_name, custom_str1 } = req.body;
    if (!amount || !item_name) {
      return res.status(400).json({ error: 'Missing required: amount, item_name' });
    }
    const numAmount = parseFloat(amount);
    if (isNaN(numAmount) || numAmount <= 0 || numAmount > 100000) {
      return res.status(400).json({ error: 'Invalid amount: must be between R0.01 and R100,000' });
    }

    // Resolve token: either directly provided or look up from card_id
    let chargeToken = rawToken;
    if (!chargeToken && card_id) {
      const userId = req.user.uid;
      const cardSnap = await admin.firestore()
        .collection('users').doc(userId).collection('saved_cards').doc(card_id).get();
      if (!cardSnap.exists || !cardSnap.data().is_active) {
        return res.status(404).json({ error: 'Saved card not found or inactive' });
      }
      chargeToken = cardSnap.data().token;

      // Update last_used_at
      await cardSnap.ref.update({ last_used_at: new Date().toISOString() });
    }

    if (!chargeToken) {
      return res.status(400).json({ error: 'Missing required: token or card_id' });
    }

    // PayFast ad-hoc tokenization charge API
    const chargeData = {
      'merchant-id': merchantId,
      'version': 'v1',
      'timestamp': new Date().toISOString().replace('T', ' ').slice(0, 19),
      'amount': String(Math.round(parseFloat(amount) * 100)), // amount in cents
      'item_name': String(item_name),
      ...(custom_str1 ? { custom_str1 } : {}),
    };

    // Generate signature
    const pfParamString = Object.keys(chargeData)
      .sort()
      .map(key => `${key}=${encodeURIComponent(String(chargeData[key] || '')).replace(/%20/g, '+')}`)
      .join('&');
    const signature = crypto
      .createHash('md5')
      .update(pfParamString + `&passphrase=${encodeURIComponent(passphrase)}`)
      .digest('hex');

    // Call PayFast subscription/adhoc charge API
    const chargeResponse = await fetch(`https://api.payfast.co.za/subscriptions/${chargeToken}/adhoc`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'merchant-id': merchantId,
        'version': 'v1',
        'timestamp': chargeData.timestamp,
        'signature': signature,
      },
      body: JSON.stringify({
        amount: Math.round(parseFloat(amount) * 100), // cents
        item_name: String(item_name),
        ...(custom_str1 ? { custom_str1 } : {}),
      }),
      signal: AbortSignal.timeout(30000),
    });

    let result;
    try {
      result = await chargeResponse.json();
    } catch (parseErr) {
      console.error('? Failed to parse PayFast response:', parseErr.message);
      return res.status(502).json({ ok: false, error: 'Payment gateway returned invalid response' });
    }

    if (chargeResponse.ok && result.data) {
      console.log(`?? Token charge successful: R${amount}, task=${custom_str1 || 'N/A'}`);

      // Use shared payment processing for full notification chain
      if (custom_str1) {
        try {
          await processSuccessfulPayment(custom_str1, {
            amountGross: amount,
            pfPaymentId: result.data?.pf_payment_id || '',
            itemName: item_name,
            source: 'payfast_token_charge',
          });
        } catch (pspErr) {
          console.warn(`[charge-token] processSuccessfulPayment fallback: ${pspErr.message}`);
          // Fallback: direct update if shared function fails
          try {
            const taskRef = admin.firestore().collection('tasksManagement').doc(custom_str1);
            await taskRef.update({
              payment_status: 'paid',
              payment_verified: true,
              payment_verified_at: new Date().toISOString(),
              payment_verified_via: 'payfast_token_charge',
              payment_method: 'saved_card',
              updated_at: new Date().toISOString(),
            });
          } catch (fbErr) {
            console.error(`[charge-token] Fallback Firestore update failed: ${fbErr.message}`);
            return res.status(500).json({ ok: false, error: 'Payment charged but database update failed. Contact support.' });
          }
        }
      }

      res.json({ ok: true, message: 'Payment charged successfully', data: result.data });
    } else {
      console.error('? Token charge failed:', result);
      res.status(400).json({ ok: false, error: result.message || 'Charge failed' });
    }
  } catch (error) {
    console.error('? Token charge error:', error);
    res.status(500).json({ error: 'Card charge failed' });
  }
});

// -- Saved Cards Management --
// GET: List user's saved cards (masked)
app.get('/api/payment/saved-cards', authMiddleware, async (req, res) => {
  try {
    const userId = req.user.uid;
    const cardsSnap = await admin.firestore()
      .collection('users').doc(userId).collection('saved_cards')
      .where('is_active', '==', true)
      .orderBy('created_at', 'desc')
      .get();

    const cards = cardsSnap.docs.map(doc => {
      const d = doc.data();
      return {
        id: d.id,
        last4: d.last4 || '****',
        card_type: d.card_type || 'card',
        created_at: d.created_at,
        last_used_at: d.last_used_at,
      };
      // Note: token is NEVER sent to the client � stays server-side only
    });

    res.json({ ok: true, cards });
  } catch (error) {
    console.error('? Saved cards fetch error:', error);
    res.status(500).json({ error: 'Failed to fetch saved cards' });
  }
});

// DELETE: Remove a saved card
app.delete('/api/payment/saved-cards/:cardId', authMiddleware, async (req, res) => {
  try {
    const userId = req.user.uid;
    const { cardId } = req.params;

    const cardRef = admin.firestore()
      .collection('users').doc(userId).collection('saved_cards').doc(cardId);
    const cardSnap = await cardRef.get();

    if (!cardSnap.exists) {
      return res.status(404).json({ error: 'Card not found' });
    }

    // Soft-delete: mark as inactive rather than deleting
    await cardRef.update({ is_active: false, deleted_at: new Date().toISOString() });
    console.log(`??? Deactivated saved card ${cardId} for user ${userId}`);

    res.json({ ok: true, message: 'Card removed' });
  } catch (error) {
    console.error('? Card deletion error:', error);
    res.status(500).json({ error: 'Failed to remove card' });
  }
});

// -- Refund Processing --
// Processes refund for a paid booking. Supports two methods:
//   method='wallet' ? immediate wallet credit (no PayFast call)
//   method='card'   ? PayFast refund API call (takes 3-5 business days)
// Anti-fraud: rate-limited, cooldown check, max refund limits, idempotent
app.post('/api/payment/refund', authMiddleware, assistantLimiter, async (req, res) => {
  try {
    const userId = req.user.uid;
    const { booking_id, doc_type, method, reason } = req.body;

    if (!booking_id || !method) {
      return res.status(400).json({ error: 'Missing required: booking_id, method' });
    }
    if (method !== 'wallet' && method !== 'card') {
      return res.status(400).json({ error: 'Invalid method. Must be "wallet" or "card".' });
    }

    const now = new Date().toISOString();
    const db = admin.firestore();

    // -- Anti-fraud: rate limit � max 3 refunds per user per 24 hours --
    const oneDayAgo = new Date(Date.now() - 24 * 60 * 60 * 1000).toISOString();
    const recentRefunds = await db.collection('transactionLogs')
      .where('user_id', '==', userId)
      .where('subtype', '==', 'refund')
      .where('transaction_at', '>=', oneDayAgo)
      .get();
    if (recentRefunds.size >= 3) {
      console.warn(`[refund] Rate limit hit: user ${userId} has ${recentRefunds.size} refunds in 24h`);
      return res.status(429).json({ error: 'Too many refund requests. Please try again later or contact support.' });
    }

    // -- Look up the booking --
    const collectionName = doc_type === 'futureBookings' ? 'futureBookings' : 'tasksManagement';
    const docRef = db.collection(collectionName).doc(booking_id);
    const docSnap = await docRef.get();
    if (!docSnap.exists) {
      return res.status(404).json({ error: 'Booking not found' });
    }

    const data = docSnap.data();
    const docUserId = data.user_id || data.userId || '';

    // -- Security: verify the requesting user owns this booking --
    if (docUserId !== userId) {
      console.warn(`[refund] User ${userId} attempted refund on booking owned by ${docUserId}`);
      return res.status(403).json({ error: 'You are not authorized to refund this booking.' });
    }

    // -- Check booking is actually cancelled --
    const status = (data.status || '').toString().toLowerCase();
    if (status !== 'cancelled') {
      return res.status(400).json({ error: 'Booking must be cancelled before requesting a refund.' });
    }

    // -- Idempotency: check if already refunded --
    const refundStatus = (data.refund_status || '').toString().toLowerCase();
    const walletRefunded = (data.wallet_refunded || '').toString().toLowerCase();
    if (refundStatus === 'refunded' || walletRefunded === 'yes') {
      return res.json({ ok: true, already_refunded: true, message: 'This booking has already been refunded.' });
    }

    // -- Anti-fraud: cooldown � booking must be at least 5 minutes old --
    const createdAt = data.created_at || data.createdAt || data.creation_date || '';
    if (createdAt) {
      const bookingAge = Date.now() - new Date(createdAt).getTime();
      if (bookingAge < 5 * 60 * 1000) {
        return res.status(400).json({ error: 'Please wait a few minutes before requesting a refund.' });
      }
    }

    // -- Determine refund amount --
    let refundAmount = 0;
    // Try original transaction first
    const txSnap = await db.collection('transactionLogs')
      .where('tasks_management_id', '==', booking_id)
      .where('subtype', '==', 'service_payment')
      .where('status', '==', 'success')
      .limit(1)
      .get();
    if (!txSnap.empty) {
      refundAmount = parseFloat(txSnap.docs[0].data().amount || '0');
    }
    if (refundAmount <= 0) {
      refundAmount = parseFloat(data.cost || data.total_cost || data.payment_amount || data.wallet_deduct_amount || '0');
    }
    if (refundAmount <= 0) {
      return res.status(400).json({ error: 'Could not determine refund amount.' });
    }

    // -- Anti-fraud: max single refund cap R50,000 --
    if (refundAmount > 50000) {
      console.warn(`[refund] Suspiciously large refund R${refundAmount} for booking ${booking_id}`);
      return res.status(400).json({ error: 'Refund amount exceeds limit. Please contact support.' });
    }

    const txId = crypto.randomUUID();

    // -----------------------------------------------------------
    // METHOD: WALLET (instant credit)
    // -----------------------------------------------------------
    if (method === 'wallet') {
      // Atomic wallet refund via Firestore transaction
      await db.runTransaction(async (tx) => {
        const freshDoc = await tx.get(docRef);
        const freshData = freshDoc.data() || {};
        // Double-check idempotency inside transaction
        if ((freshData.refund_status || '') === 'refunded' || (freshData.wallet_refunded || '') === 'yes') {
          throw new Error('ALREADY_REFUNDED');
        }

        const userRef = db.collection('users').doc(userId);
        const userSnap = await tx.get(userRef);
        const userData = userSnap.data() || {};
        const currentBalance = parseFloat(userData.balance || '0');
        const newBalance = currentBalance + refundAmount;

        tx.update(userRef, { balance: newBalance.toFixed(2) });
        tx.update(docRef, {
          wallet_refunded: 'yes',
          wallet_refund_reason: reason || 'cancelled_by_customer',
          wallet_refund_amount: refundAmount,
          wallet_refunded_at: now,
          wallet_refund_txn_id: txId,
          refund_status: 'refunded',
          refund_method: 'wallet',
          updated_at: now,
        });
        tx.set(db.collection('transactionLogs').doc(txId), {
          id: txId,
          amount: refundAmount.toFixed(2),
          transaction_at: now,
          status: 'success',
          tasks_management_id: booking_id,
          user_id: userId,
          type: 'wallet',
          subtype: 'refund',
          direction: 'in',
          cash_movement: false,
          schema_version: 2,
          reason: reason || 'cancelled_by_customer',
          balance_after: newBalance.toFixed(2),
          previous_balance: currentBalance.toFixed(2),
          refund_source: collectionName,
        });
      });

      console.log(`?? Wallet refund R${refundAmount.toFixed(2)} for user ${userId}, booking ${booking_id}`);
      return res.json({
        ok: true,
        method: 'wallet',
        amount: refundAmount.toFixed(2),
        message: `R${refundAmount.toFixed(2)} refunded to your wallet instantly.`,
      });
    }

    // -----------------------------------------------------------
    // METHOD: CARD (PayFast refund API)
    // -----------------------------------------------------------
    if (method === 'card') {
      // Atomically mark as processing to prevent concurrent card refunds
      try {
        await db.runTransaction(async (tx) => {
          const freshDoc = await tx.get(docRef);
          const freshData = freshDoc.data() || {};
          const fRefundStatus = (freshData.refund_status || '').toLowerCase();
          if (fRefundStatus === 'refunded' || fRefundStatus === 'processing') {
            throw new Error('ALREADY_REFUNDED_OR_PROCESSING');
          }
          tx.update(docRef, { refund_status: 'processing', updated_at: now });
        });
      } catch (txErr) {
        if (txErr.message === 'ALREADY_REFUNDED_OR_PROCESSING') {
          return res.json({ ok: true, already_refunded: true, message: 'Refund already in progress or completed.' });
        }
        throw txErr;
      }

      const merchantId = env('PAYFAST_MERCHANT_ID');
      const merchantKey = env('PAYFAST_MERCHANT_KEY');
      const passphrase = env('PAYFAST_PASSPHRASE') || '';

      if (!merchantId || !merchantKey) {
        return res.status(503).json({ error: 'Payment credentials not configured.' });
      }

      // Find the original PayFast payment ID
      const pfPaymentId = data.payfast_payment_id || '';
      if (!pfPaymentId) {
        // No PayFast payment ID � fall back to creating a refund request for admin
        await db.collection('refund_requests').doc(txId).set({
          id: txId,
          source_doc_id: booking_id,
          source_doc_type: collectionName,
          user_id: userId,
          amount: refundAmount,
          payment_method: data.payment_method || 'card',
          reason: reason || 'cancelled_by_customer',
          status: 'pending',
          initiated_by: userId,
          created_at: now,
          updated_at: now,
        });
        await docRef.update({ refund_status: 'pending_admin_review', updated_at: now });

        console.log(`?? Card refund request (no pf_id) created for booking ${booking_id}`);
        return res.json({
          ok: true,
          method: 'refund_request',
          amount: refundAmount.toFixed(2),
          message: `Card refund of R${refundAmount.toFixed(2)} submitted. It will be processed within 3-5 business days.`,
        });
      }

      // Call PayFast refund API
      try {
        const timestamp = new Date().toISOString().replace('T', ' ').slice(0, 19);
        const refundData = {
          'merchant-id': merchantId,
          'version': 'v1',
          'timestamp': timestamp,
          'amount': Math.round(refundAmount * 100), // cents
        };

        const pfParamString = Object.keys(refundData)
          .sort()
          .map(key => `${key}=${encodeURIComponent(String(refundData[key] || '')).replace(/%20/g, '+')}`)
          .join('&');
        const signature = crypto
          .createHash('md5')
          .update(pfParamString + `&passphrase=${encodeURIComponent(passphrase)}`)
          .digest('hex');

        const refundResponse = await fetch(`https://api.payfast.co.za/refunds/v1/transaction/${pfPaymentId}`, {
          method: 'POST',
          headers: {
            'Content-Type': 'application/json',
            'merchant-id': merchantId,
            'version': 'v1',
            'timestamp': timestamp,
            'signature': signature,
          },
          body: JSON.stringify({ amount: Math.round(refundAmount * 100) }),
          signal: AbortSignal.timeout(30000),
        });

        const refundResult = await refundResponse.json();

        if (refundResponse.ok && refundResult.status === 'success') {
          // PayFast refund succeeded
          await docRef.update({
            refund_status: 'refunded',
            refund_method: 'card',
            refund_amount: refundAmount,
            refunded_at: now,
            refund_txn_id: txId,
            payfast_refund_id: refundResult.refund_id || '',
            updated_at: now,
          });

          await db.collection('transactionLogs').doc(txId).set({
            id: txId,
            amount: refundAmount.toFixed(2),
            transaction_at: now,
            status: 'success',
            tasks_management_id: booking_id,
            user_id: userId,
            type: 'card_refund',
            subtype: 'refund',
            direction: 'in',
            cash_movement: true,
            schema_version: 2,
            reason: reason || 'cancelled_by_customer',
            refund_source: collectionName,
            payfast_refund_id: refundResult.refund_id || '',
            payfast_payment_id: pfPaymentId,
          });

          console.log(`?? Card refund R${refundAmount.toFixed(2)} processed for booking ${booking_id}`);
          return res.json({
            ok: true,
            method: 'card',
            amount: refundAmount.toFixed(2),
            message: `R${refundAmount.toFixed(2)} card refund initiated. It will reflect in 3-5 business days.`,
          });
        } else {
          // PayFast refund API failed � fall back to admin review
          console.error(`[refund] PayFast refund API failed:`, refundResult);
          await db.collection('refund_requests').doc(txId).set({
            id: txId,
            source_doc_id: booking_id,
            source_doc_type: collectionName,
            user_id: userId,
            amount: refundAmount,
            payment_method: 'card',
            reason: reason || 'cancelled_by_customer',
            status: 'pending',
            initiated_by: userId,
            payfast_payment_id: pfPaymentId,
            payfast_refund_error: JSON.stringify(refundResult).slice(0, 500),
            created_at: now,
            updated_at: now,
          });
          await docRef.update({ refund_status: 'pending_admin_review', updated_at: now });

          return res.json({
            ok: true,
            method: 'refund_request',
            amount: refundAmount.toFixed(2),
            message: `Card refund of R${refundAmount.toFixed(2)} submitted for processing. It will be handled within 3-5 business days.`,
          });
        }
      } catch (pfErr) {
        console.error(`[refund] PayFast refund API error:`, pfErr);
        // Fall back to admin review
        await db.collection('refund_requests').doc(txId).set({
          id: txId,
          source_doc_id: booking_id,
          source_doc_type: collectionName,
          user_id: userId,
          amount: refundAmount,
          payment_method: 'card',
          reason: reason || 'cancelled_by_customer',
          status: 'pending',
          initiated_by: userId,
          payfast_payment_id: pfPaymentId,
          payfast_refund_error: pfErr.message || 'API call failed',
          created_at: now,
          updated_at: now,
        });
        await docRef.update({ refund_status: 'pending_admin_review', updated_at: now });

        return res.json({
          ok: true,
          method: 'refund_request',
          amount: refundAmount.toFixed(2),
          message: `Card refund of R${refundAmount.toFixed(2)} submitted for processing. It will be handled within 3-5 business days.`,
        });
      }
    }
  } catch (error) {
    if (error.message === 'ALREADY_REFUNDED') {
      return res.json({ ok: true, already_refunded: true, message: 'This booking has already been refunded.' });
    }
    console.error('? Refund error:', error);
    res.status(500).json({ error: 'Refund processing failed. Please contact support.' });
  }
});

// -- Admin Payout (charge admin's saved card, credit recipient) --
// Admin charges their own saved card to fund a refund to a client's wallet
// or pay an artisan's balance. Requires admin role.
app.post('/api/admin/payout', authMiddleware, assistantLimiter, async (req, res) => {
  try {
    const db = admin.firestore();
    const decoded = req.user;
    const adminUid = decoded.uid;

    // -- Verify admin role --
    const role = await resolveRole({ firestore: db, uid: adminUid, decodedToken: decoded });
    if (role !== 'admin') {
      console.warn(`[admin/payout] Non-admin user ${adminUid} (role=${role}) attempted payout`);
      return res.status(403).json({ error: 'Admin access required.' });
    }

    const { card_id, amount, recipient_id, recipient_type, booking_id, reason } = req.body;

    if (!card_id || !amount || !recipient_id || !recipient_type) {
      return res.status(400).json({ error: 'Missing required: card_id, amount, recipient_id, recipient_type' });
    }
    if (recipient_type !== 'client' && recipient_type !== 'artisan') {
      return res.status(400).json({ error: 'recipient_type must be "client" or "artisan"' });
    }

    const payoutAmount = parseFloat(amount);
    if (isNaN(payoutAmount) || payoutAmount <= 0 || payoutAmount > 100000) {
      return res.status(400).json({ error: 'Invalid amount. Must be between R0.01 and R100,000.' });
    }

    // -- Look up admin's saved card --
    const cardSnap = await db.collection('users').doc(adminUid).collection('saved_cards').doc(card_id).get();
    if (!cardSnap.exists || !cardSnap.data().is_active) {
      return res.status(404).json({ error: 'Saved card not found or inactive.' });
    }
    const chargeToken = cardSnap.data().token;
    if (!chargeToken) {
      return res.status(400).json({ error: 'Card has no payment token.' });
    }

    // -- Verify recipient exists --
    const recipientCollection = recipient_type === 'client' ? 'users' : 'serviceProvider';
    const recipientSnap = await db.collection(recipientCollection).doc(recipient_id).get();
    if (!recipientSnap.exists) {
      return res.status(404).json({ error: `${recipient_type} not found.` });
    }
    const recipientData = recipientSnap.data() || {};
    const recipientName = recipientData.name || recipientData.displayName || recipientData.full_name || '';

    // -- Charge admin's card via PayFast ad-hoc tokenization --
    const merchantId = env('PAYFAST_MERCHANT_ID');
    const merchantKey = env('PAYFAST_MERCHANT_KEY');
    const passphrase = env('PAYFAST_PASSPHRASE') || '';

    if (!merchantId || !merchantKey) {
      return res.status(503).json({ error: 'Payment credentials not configured.' });
    }

    const now = new Date().toISOString();
    const itemName = recipient_type === 'client'
      ? `Admin Refund to ${recipientName || recipient_id}`
      : `Admin Payout to Artisan ${recipientName || recipient_id}`;

    const chargeData = {
      'merchant-id': merchantId,
      'version': 'v1',
      'timestamp': now.replace('T', ' ').slice(0, 19),
      'amount': String(Math.round(payoutAmount * 100)), // cents
      'item_name': itemName.slice(0, 100),
    };

    const pfParamString = Object.keys(chargeData)
      .sort()
      .map(key => `${key}=${encodeURIComponent(String(chargeData[key] || '')).replace(/%20/g, '+')}`)
      .join('&');
    const signature = crypto
      .createHash('md5')
      .update(pfParamString + `&passphrase=${encodeURIComponent(passphrase)}`)
      .digest('hex');

    const chargeResponse = await fetch(`https://api.payfast.co.za/subscriptions/${chargeToken}/adhoc`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'merchant-id': merchantId,
        'version': 'v1',
        'timestamp': chargeData.timestamp,
        'signature': signature,
      },
      body: JSON.stringify({
        amount: Math.round(payoutAmount * 100),
        item_name: itemName.slice(0, 100),
      }),
      signal: AbortSignal.timeout(30000),
    });

    const chargeResult = await chargeResponse.json();

    if (!chargeResponse.ok || !chargeResult.data) {
      console.error(`[admin/payout] Card charge failed:`, chargeResult);
      return res.status(400).json({ ok: false, error: chargeResult.message || 'Card charge failed.' });
    }

    console.log(`?? Admin card charged R${payoutAmount.toFixed(2)} for ${recipient_type} ${recipient_id}`);

    // Update card last_used_at
    await cardSnap.ref.update({ last_used_at: now });

    // -- Credit recipient --
    const txId = crypto.randomUUID();

    if (recipient_type === 'client') {
      // Credit client wallet
      await db.runTransaction(async (tx) => {
        const userRef = db.collection('users').doc(recipient_id);
        const userSnap = await tx.get(userRef);
        const userData = userSnap.data() || {};
        const currentBalance = parseFloat(userData.balance || '0');
        const newBalance = currentBalance + payoutAmount;

        tx.update(userRef, {
          balance: newBalance.toFixed(2),
          updated_at: now,
        });

        tx.set(db.collection('transactionLogs').doc(txId), {
          id: txId,
          amount: payoutAmount.toFixed(2),
          transaction_at: now,
          status: 'success',
          user_id: recipient_id,
          user_name: recipientName,
          type: 'admin_card_refund',
          subtype: 'refund',
          direction: 'in',
          cash_movement: true,
          schema_version: 2,
          reason: reason || 'admin_card_payout',
          balance_after: newBalance.toFixed(2),
          previous_balance: currentBalance.toFixed(2),
          admin_id: adminUid,
          payment_method: 'admin_saved_card',
          ...(booking_id ? { tasks_management_id: booking_id } : {}),
        });
      });

      // Update booking refund status if booking_id provided
      if (booking_id) {
        const taskRef = db.collection('tasksManagement').doc(booking_id);
        const taskSnap = await taskRef.get();
        if (taskSnap.exists) {
          await taskRef.update({
            refund_status: 'refunded',
            refund_method: 'admin_card',
            refund_amount: payoutAmount,
            refunded_at: now,
            refund_txn_id: txId,
            updated_at: now,
          });
        }
        // Also try futureBookings
        const fbRef = db.collection('futureBookings').doc(booking_id);
        const fbSnap = await fbRef.get();
        if (fbSnap.exists) {
          await fbRef.update({
            refund_status: 'refunded',
            refund_method: 'admin_card',
            refund_amount: payoutAmount,
            refunded_at: now,
            updated_at: now,
          });
        }
      }

      console.log(`?? Admin refund R${payoutAmount.toFixed(2)} credited to client ${recipient_id} wallet`);
    } else {
      // Credit artisan balance � wrapped in a transaction so the read+update
      // of `serviceProvider.balance` and the matching transactionLogs entry
      // commit atomically. Previously a concurrent payout could read the
      // same `currentBalance` twice and overwrite each other's update,
      // silently losing one credit.
      let postBalance;
      let preBalance;
      const artisanRef = db.collection('serviceProvider').doc(recipient_id);
      let artisanData = {};
      await db.runTransaction(async (tx) => {
        const artisanSnap = await tx.get(artisanRef);
        artisanData = artisanSnap.data() || {};
        preBalance = parseFloat(artisanData.balance || '0');
        postBalance = preBalance + payoutAmount;
        tx.update(artisanRef, {
          balance: postBalance.toFixed(2),
          balance_from: 'admin_card',
          updated_at: now,
        });
        tx.set(db.collection('transactionLogs').doc(txId), {
          id: txId,
          amount: payoutAmount.toFixed(2),
          transaction_at: now,
          status: 'success',
          service_provider_id: recipient_id,
          service_provider_name: recipientName,
          type: 'admin_card_artisan_payout',
          subtype: 'artisan_payout',
          direction: 'out',
          cash_movement: true,
          schema_version: 2,
          reason: reason || 'admin_card_payout',
          balance_after: postBalance.toFixed(2),
          previous_balance: preBalance.toFixed(2),
          admin_id: adminUid,
          payment_method: 'admin_saved_card',
          ...(booking_id ? { tasks_management_id: booking_id } : {}),
        });
      });

      // Update booking artisan payment status if booking_id provided
      if (booking_id) {
        const taskRef = db.collection('tasksManagement').doc(booking_id);
        const taskSnap = await taskRef.get();
        if (taskSnap.exists) {
          await taskRef.update({
            artisan_payment_status: 'paid',
            artisan_payment_method: 'admin_card',
            artisan_payment_amount: payoutAmount.toFixed(2),
            artisan_paid_at: now,
            updated_at: now,
          });
        }
      }

      console.log(`?? Admin payout R${payoutAmount.toFixed(2)} credited to artisan ${recipient_id}`);
    }

    // Update refund_request status if this is processing a pending refund
    if (booking_id) {
      const refundReqs = await db.collection('refund_requests')
        .where('source_doc_id', '==', booking_id)
        .where('status', '==', 'pending')
        .limit(1)
        .get();
      if (!refundReqs.empty) {
        await refundReqs.docs[0].ref.update({
          status: 'processed',
          processed_at: now,
          processed_by: adminUid,
          payment_method: 'admin_card',
          updated_at: now,
        });
      }
    }

    return res.json({
      ok: true,
      amount: payoutAmount.toFixed(2),
      recipient_type,
      recipient_id,
      transaction_id: txId,
      message: `R${payoutAmount.toFixed(2)} charged to your card and credited to ${recipient_type === 'client' ? 'client wallet' : 'artisan balance'}.`,
    });
  } catch (error) {
    console.error('? Admin payout error:', error);
    res.status(500).json({ error: 'Payout processing failed.' });
  }
});

// -- Admin: Ozow Direct EFT Payout to artisan/partner bank account --
// Sends money directly to the recipient's bank account via Ozow Payout API.
app.post('/api/admin/ozow-payout', authMiddleware, async (req, res) => {
  try {
    const db = admin.firestore();
    const decoded = req.user;
    const adminUid = decoded.uid;

    const role = await resolveRole({ firestore: db, uid: adminUid, decodedToken: decoded });
    if (role !== 'admin') {
      return res.status(403).json({ error: 'Admin access required.' });
    }

    // ─── Governance: only owner+finance can disburse money ───
    const adminTier = resolveAdminTier(decoded);
    if (!adminTier || !['owner', 'finance'].includes(adminTier)) {
      return res.status(403).json({
        error: 'Insufficient admin tier',
        message: `Payouts require owner or finance tier. Your tier: ${adminTier || 'none'}.`,
      });
    }

    // ─── Gap #9: Idle re-auth (10 minutes) ───
    // The session must be either freshly signed-in (auth_time within 10min)
    // OR have a recent biometric confirmation written to
    // admin_biometric_confirms/{uid} within the last 5 minutes by the admin
    // app after a successful local_auth prompt. Owner can bypass via env
    // `MFA_BYPASS_OWNER=true` (NOT recommended for prod).
    try {
      const nowSec = Math.floor(Date.now() / 1000);
      const authTime = Number(decoded.auth_time || 0);
      const freshSignin = authTime > 0 && (nowSec - authTime) < 600; // 10min
      let freshBiometric = false;
      if (!freshSignin) {
        const bioSnap = await db.collection('admin_biometric_confirms').doc(adminUid).get();
        if (bioSnap.exists) {
          const at = bioSnap.data()?.confirmed_at;
          const tsSec = at ? Math.floor(new Date(String(at)).getTime() / 1000) : 0;
          freshBiometric = tsSec > 0 && (nowSec - tsSec) < 300; // 5min
        }
      }
      const ownerBypass = adminTier === 'owner' && env('MFA_BYPASS_OWNER') === 'true';
      if (!freshSignin && !freshBiometric && !ownerBypass) {
        return res.status(401).json({
          error: 'reauth_required',
          message: 'Re-authenticate (biometric or re-login) before disbursing funds.',
          max_age_seconds: 600,
        });
      }
    } catch (e) {
      console.warn('[ozow-payout] idle re-auth check error:', e.message);
      return res.status(503).json({ error: 'Internal control check failed.', stage: 'reauth' });
    }

    // ─── Gap #3: MFA TOTP enforcement ───
    // If MFA is enrolled on this admin (admin_mfa/{uid} with enabled=true),
    // require a current 6-digit code in `x-mfa-code` or req.body.mfa_code.
    // If MFA_REQUIRED env is true, enrollment is mandatory for owner+finance
    // tiers — payout will be refused until they enrol.
    try {
      const mfaSnap = await db.collection('admin_mfa').doc(adminUid).get();
      const mfa = mfaSnap.exists ? (mfaSnap.data() || {}) : {};
      const isEnrolled = mfa.enabled === true && !!mfa.secret;
      const mfaRequired = env('MFA_REQUIRED') === 'true';
      if (!isEnrolled) {
        if (mfaRequired) {
          return res.status(403).json({
            error: 'mfa_enrollment_required',
            message: 'You must enrol MFA before disbursing funds. Hit /api/admin/mfa/setup.',
          });
        }
        // Soft mode: log but allow.
        console.warn(`[ozow-payout] admin ${adminUid} has no MFA enrolled (soft-mode)`);
      } else {
        const code = String(req.headers['x-mfa-code'] || req.body?.mfa_code || '').trim();
        if (!verifyTotp(mfa.secret, code)) {
          await db.collection('fraud_alerts').add({
            rule: 'mfa_failed_payout',
            severity: 'high',
            admin_id: adminUid,
            attempted_amount: parseFloat(req.body?.amount || 0),
            created_at: new Date().toISOString(),
          });
          return res.status(401).json({
            error: 'mfa_invalid',
            message: 'Invalid or missing MFA code. Provide 6-digit code in x-mfa-code header.',
          });
        }
        // Touch last_used_at (non-blocking).
        db.collection('admin_mfa').doc(adminUid).set(
          { last_used_at: new Date().toISOString() },
          { merge: true }
        ).catch(() => {});
      }
    } catch (e) {
      console.warn('[ozow-payout] MFA check error:', e.message);
      return res.status(503).json({ error: 'Internal control check failed.', stage: 'mfa' });
    }

    const { amount, recipient_id, recipient_type, recipient_name, bank_name,
            account_number, branch_code, account_type, booking_id, reason } = req.body;

    if (!amount || !recipient_id || !recipient_type || !account_number || !branch_code || !bank_name) {
      return res.status(400).json({ error: 'Missing required fields: amount, recipient_id, recipient_type, bank_name, account_number, branch_code' });
    }
    if (recipient_type !== 'artisan' && recipient_type !== 'partner' && recipient_type !== 'client') {
      return res.status(400).json({ error: 'recipient_type must be "artisan", "partner", or "client"' });
    }

    const payoutAmount = parseFloat(amount);
    if (isNaN(payoutAmount) || payoutAmount <= 0 || payoutAmount > 5000000) {
      return res.status(400).json({ error: 'Invalid amount. Must be between R0.01 and R5,000,000.' });
    }

    // -- Ozow payout API credentials --
    const ozowApiKey = env('OZOW_PAYOUT_API_KEY') || env('OZOW_API_KEY');
    const ozowSiteCode = env('OZOW_SITE_CODE');

    if (!ozowApiKey || !ozowSiteCode) {
      return res.status(503).json({ error: 'Ozow payout credentials not configured. Set OZOW_PAYOUT_API_KEY and OZOW_SITE_CODE in environment.' });
    }

    const now = new Date().toISOString();

    // ─── Gap #14: Ozow prod credential safety assertion ───
    // If we're in live mode but env vars look like a sandbox setup, refuse
    // to send money. This protects against desync after a partial cutover.
    const ozowSafetyErrs = assertOzowProdSafety();
    if (ozowSafetyErrs.length > 0) {
      console.error('🚨 OZOW PROD SAFETY BLOCK:', ozowSafetyErrs);
      try {
        await db.collection('error_logs').add({
          error_type: 'ozow_prod_safety_block',
          severity: 'critical',
          source: 'ozow_payout_route',
          errors: ozowSafetyErrs,
          admin_id: adminUid,
          attempted_amount: payoutAmount,
          created_at: now,
        });
      } catch (_) {}
      return res.status(503).json({
        error: 'Ozow credential safety check failed. Cannot process payouts.',
        details: ozowSafetyErrs,
      });
    }

    // ─── Gap #4: Daily payout hard block (per-admin) ───
    // Owner role may exceed daily limit; everyone else is hard-capped.
    // The R50k DAILY_LIMITS.payout was previously *alerted* in fraud rules but
    // not actually blocking — convert to a hard block here. Any payout pushing
    // the admin's running total past their cap is refused before Ozow is hit.
    const DAILY_PAYOUT_CAP_DEFAULT = 50000;
    const DAILY_PAYOUT_CAP_OWNER = 500000; // R500k for owner role
    const isOwner = adminTier === 'owner';
    const adminDailyCap = isOwner ? DAILY_PAYOUT_CAP_OWNER : DAILY_PAYOUT_CAP_DEFAULT;
    try {
      const dayStart = new Date();
      dayStart.setHours(0, 0, 0, 0);
      const dayStartIso = dayStart.toISOString();
      const todaySnap = await db.collection('payout_records')
        .where('admin_id', '==', adminUid)
        .limit(500)
        .get()
        .catch((err) => {
          console.warn('[ozow-payout] daily cap query error:', err.code, err.message);
          throw err;
        });
      let todayTotal = 0;
      todaySnap.docs.forEach(d => {
        const data = d.data() || {};
        // Filter by date in-process to avoid needing a composite index.
        const created = String(data.created_at || '');
        if (created < dayStartIso) return;
        // Only count successful/pending — failed/rejected don't move money.
        const st = String(data.status || '').toLowerCase();
        if (st === 'failed' || st === 'rejected' || st === 'cancelled') return;
        const amt = parseFloat(data.amount || 0);
        if (!isNaN(amt)) todayTotal += amt;
      });
      const projected = todayTotal + payoutAmount;
      if (projected > adminDailyCap) {
        await db.collection('fraud_alerts').add({
          rule: 'daily_payout_cap_block',
          severity: 'high',
          admin_id: adminUid,
          today_total: todayTotal,
          attempted_amount: payoutAmount,
          cap: adminDailyCap,
          recipient_id, recipient_type,
          created_at: now,
        });
        return res.status(403).json({
          error: 'Daily payout cap exceeded for your role',
          details: `Today total R${todayTotal.toFixed(2)} + R${payoutAmount.toFixed(2)} = R${projected.toFixed(2)} > R${adminDailyCap} cap`,
          role: isOwner ? 'owner' : 'admin',
        });
      }
    } catch (e) {
      console.warn('[ozow-payout] daily cap check failed (fail-closed):', e.code || '', e.message);
      return res.status(503).json({ error: 'Internal control check failed. Try again shortly.', stage: 'daily_cap', detail: e.message });
    }

    // ─── Gap #15: Bank-account-change cool-down (24h) ───
    // Detect when the recipient's payout-bound bank account has changed
    // recently. If the {recipient_id × account_number} pair is new (or the
    // recipient's account was modified within the last 24h), block payout
    // and raise a fraud alert. Owner can override by setting a fresh flag
    // doc — kept as backlog work for the role-tier system.
    try {
      const masked = `****${String(account_number).slice(-4)}`;
      // 1. Most recent successful/pending payout to this recipient.
      // Use single-field query then sort in-process to avoid composite index.
      const recentSnap = await db.collection('payout_records')
        .where('recipient_id', '==', recipient_id)
        .limit(50)
        .get()
        .catch((err) => {
          console.warn('[ozow-payout] recent payouts query failed:', err.message);
          return null;
        });

      let recipientHasHistory = false;
      let lastMasked = '';
      if (recentSnap && !recentSnap.empty) {
        const docs = recentSnap.docs
          .map(d => d.data() || {})
          .sort((a, b) => String(b.created_at || '').localeCompare(String(a.created_at || '')));
        for (const dd of docs) {
          const st = String(dd.status || '').toLowerCase();
          if (st === 'failed' || st === 'rejected' || st === 'cancelled') continue;
          const m = (dd.account_number_masked || '').toString();
          if (m) {
            lastMasked = m;
            recipientHasHistory = true;
            break;
          }
        }
      }

      // 2. Check recipient profile doc for recent bank-account changes
      const profileCol = recipient_type === 'artisan'
        ? 'serviceProvider'
        : recipient_type === 'partner' ? 'corporate_partners' : 'users';
      let profileBankUpdatedAt = null;
      try {
        const profSnap = await db.collection(profileCol).doc(recipient_id).get();
        if (profSnap.exists) {
          const pd = profSnap.data() || {};
          const candidate = pd.bank_account_updated_at || pd.bank_details_updated_at || pd.bankAccountUpdatedAt;
          if (candidate) profileBankUpdatedAt = new Date(String(candidate));
        }
      } catch (_) {}

      const isAccountChanged = recipientHasHistory && lastMasked && lastMasked !== masked;
      const isProfileRecentlyChanged = profileBankUpdatedAt &&
        (Date.now() - profileBankUpdatedAt.getTime()) < (24 * 60 * 60 * 1000);

      if (isAccountChanged || isProfileRecentlyChanged) {
        await db.collection('fraud_alerts').add({
          rule: 'bank_account_change_cooldown',
          severity: 'critical',
          admin_id: adminUid,
          recipient_id, recipient_type,
          new_account_masked: masked,
          previous_account_masked: lastMasked || null,
          profile_bank_updated_at: profileBankUpdatedAt ? profileBankUpdatedAt.toISOString() : null,
          attempted_amount: payoutAmount,
          created_at: now,
        });
        return res.status(403).json({
          error: 'Bank account change cool-down active',
          details: isAccountChanged
            ? `Recipient's last successful payout used ${lastMasked}, now ${masked}. 24-hour cool-down active.`
            : `Recipient's stored bank details changed within 24h. Cool-down active.`,
          retry_after: '24h',
        });
      }
    } catch (e) {
      console.warn('[ozow-payout] bank-change cooldown check failed (fail-closed):', e.code || '', e.message);
      return res.status(503).json({ error: 'Internal control check failed. Try again shortly.', stage: 'bank_change', detail: e.message });
    }

    // -- Map South African bank names to Ozow bankGroupId UUIDs --
    // Source: live call to https://stagingpayoutsapi.ozow.com/v1/getavailablebanks (2026-05-21)
    // These UUIDs are stable across staging + production.
    const bankGroupIdMap = {
      'absa':            { id: '3284a0ad-ba78-4838-8c2b-102981286a2b', branch: '632005' },
      'african bank':    { id: '33a0840b-0cf4-4b8c-86e0-ec6c4be8c60e', branch: '430000' },
      'capitec bank':    { id: '913999fa-3a32-4e3d-82f0-a1df7e9e4f7b', branch: '470010' },
      'capitec':         { id: '913999fa-3a32-4e3d-82f0-a1df7e9e4f7b', branch: '470010' },
      'discovery bank':  { id: 'b8f152a2-8bd2-46c4-930f-4cd5b2b37ef9', branch: '679000' },
      'discovery':       { id: 'b8f152a2-8bd2-46c4-930f-4cd5b2b37ef9', branch: '679000' },
      'fnb':             { id: '4816019c-3314-4c80-8b6b-b2cd16dcc4ec', branch: '250655' },
      'first national bank': { id: '4816019c-3314-4c80-8b6b-b2cd16dcc4ec', branch: '250655' },
      'nedbank':         { id: 'bf0561fd-4203-4a0c-9174-cb26fcd87a60', branch: '198765' },
      'standard bank':   { id: 'ad7d8da4-1723-4066-94bb-6662d845e483', branch: '051001' },
      'tymebank':        { id: '28fcc8fa-985b-480b-82fd-7d09bc19c9d0', branch: '678910' },
      'tyme bank':       { id: '28fcc8fa-985b-480b-82fd-7d09bc19c9d0', branch: '678910' },
      'access bank':     { id: 'fd4876ca-db3e-4385-831a-4e465083b1f3', branch: '410506' },
      'investec':        { id: '4b45be85-b616-4bd1-9027-f8fcf8f9af7b', branch: '580105' },
      'bidvest bank':    { id: '29c5ee92-46ec-4879-8ad9-5cd3f5502727', branch: '462005' },
      'sasfin bank':     { id: '54a18018-a9fe-4adb-b752-38004ed735d6', branch: '683000' },
      'sasfin':          { id: '54a18018-a9fe-4adb-b752-38004ed735d6', branch: '683000' },
    };

    const bankKey = String(bank_name || '').toLowerCase().trim();
    const bankMatch = bankGroupIdMap[bankKey];
    if (!bankMatch) {
      return res.status(400).json({
        ok: false,
        error: `Unsupported bank "${bank_name}". Supported: ${Object.keys(bankGroupIdMap).join(', ')}`,
      });
    }
    const ozowBankGroupId = bankMatch.id;
    const ozowBranchCode = bankMatch.branch; // Use universal branch code from Ozow, not user-supplied

    // Ozow merchantReference max 20 chars - compact base36 timestamp
    const payoutRef = `SQ${Date.now().toString(36).toUpperCase()}`;
    // Ozow customerBankReference: alphanumeric + spaces + dashes only, max 20 chars
    const customerBankReference = `Square15-${payoutRef}`.replace(/[^A-Za-z0-9 -]/g, '').slice(0, 20);

    // -- Build Ozow Payouts API v1 request --
    // API spec: https://hub.ozow.com/docs/payouts-api/te1u21qvzznh8-step-2-submit-payout-request
    const ozowPayoutBaseUrl = env('OZOW_IS_TEST') === 'true'
      ? 'https://stagingpayoutsapi.ozow.com'
      : 'https://payoutsapi.ozow.com';
    const ozowPayoutUrl = `${ozowPayoutBaseUrl}/v1/requestpayout`;
    const notifyUrl = `${env('RENDER_EXTERNAL_URL') || 'https://square15-livekit-backend.onrender.com'}/api/ozow-payout-notify`;
    // Staging does NOT support RTC - must be false. Production can be true but
    // requires separate RTC activation. Default to false until enabled.
    const isRtc = false;
    // amount must be numeric (R). Use 2-decimal float; Ozow accepts ints or floats.
    const ozowAmount = parseFloat(payoutAmount.toFixed(2));

    // -- AES-256-CBC account number encryption per Ozow spec --
    // Generate random 32-byte (encoded as 64 hex chars) encryption key per payout.
    // We persist it in payout_records.encryption_key, then return it to Ozow via
    // the verify webhook (/api/ozow-payout-verify) when they call back.
    const encryptionKey = crypto.randomBytes(32).toString('hex'); // 64 ASCII chars
    // IV: SHA512(merchantRef + amountCents + encryptionKey, lowercased), first 16 bytes
    const amountCents = Math.round(ozowAmount * 100);
    const ivSource = `${payoutRef}${amountCents}${encryptionKey}`.toLowerCase();
    const ivHexFull = crypto.createHash('sha512').update(ivSource, 'utf8').digest('hex');
    const ivBytes = Buffer.from(ivHexFull.substring(0, 16), 'utf8'); // 16 ASCII bytes
    // AES key: take first 32 chars of encryption key (already 64 chars, ASCII)
    const aesKeyBytes = Buffer.from(encryptionKey.substring(0, 32), 'utf8');
    const cipher = crypto.createCipheriv('aes-256-cbc', aesKeyBytes, ivBytes);
    cipher.setAutoPadding(true); // PKCS7
    const encryptedAccountNumber = Buffer.concat([
      cipher.update(String(account_number), 'utf8'),
      cipher.final(),
    ]).toString('base64');

    // -- hashCheck: SHA512 hex of lowercased concat per Ozow's C# reference
    // (received from Itumeleng @ Ozow, 22 May 2026). Field order:
    //   siteCode + Convert.ToInt32(amount*100) + merchantReference
    //   + customerBankReference + isRtc("False"/"True") + notifyUrl
    //   + bankGroupId + encryptedAccountNumber + branchCode + apiKey
    // Then .ToLower() → SHA512 → hex (lowercase).
    // Notes:
    //   • Amount is integer cents with NO decimal/padding (R5.00 → "500").
    //   • IsRtc is a C# bool → "False"/"True" then lowercased to "false"/"true".
    //     JS String(false) === "false" lowercases to "false", same result.
    //   • accountNumber field in the hash is the ENCRYPTED (AES) value.
    //   • apiKey is the LAST field, NOT after customerBankReference.
    const sha512 = (s) => crypto.createHash('sha512').update(s, 'utf8').digest('hex');
    const hashInput = [
      ozowSiteCode,
      amountCents,              // integer cents, no decimal
      payoutRef,                // merchantReference
      customerBankReference,
      isRtc ? 'True' : 'False', // matches C# bool.ToString()
      notifyUrl,
      ozowBankGroupId,
      encryptedAccountNumber,   // AES-256-CBC base64
      ozowBranchCode,
      ozowApiKey,               // ★ LAST per Ozow C# reference
    ].join('').toLowerCase();
    let hashCheck = sha512(hashInput);
    console.log(`[admin/ozow-payout] hashInput len=${hashInput.length} ref=${payoutRef} amtCents=${amountCents}`);

    // Sandbox echo: in staging/test mode print the EXACT pre-hash string and
    // computed hash so we can diff against Ozow's "Before Hashcheck" debug line
    // from their C# reference. Never enabled in production (test_mode guard).
    const isOzowSandbox = env('OZOW_IS_TEST') === 'true';
    if (isOzowSandbox) {
      // Redact apiKey from echoed string (last token) to keep secrets out of logs.
      const apiKeyLc = ozowApiKey.toLowerCase();
      const redactedInput = hashInput.endsWith(apiKeyLc)
        ? hashInput.slice(0, -apiKeyLc.length) + `<apiKey:${apiKeyLc.length}chars>`
        : hashInput;
      console.log('[admin/ozow-payout][SANDBOX-ECHO] === PRE-HASH STRING ===');
      console.log('[admin/ozow-payout][SANDBOX-ECHO] input :', redactedInput);
      console.log('[admin/ozow-payout][SANDBOX-ECHO] hash  :', hashCheck);
      console.log('[admin/ozow-payout][SANDBOX-ECHO] fields:', JSON.stringify({
        siteCode: ozowSiteCode,
        amountCents,
        merchantReference: payoutRef,
        customerBankReference,
        isRtc: isRtc ? 'True' : 'False',
        notifyUrl,
        bankGroupId: ozowBankGroupId,
        encryptedAccountNumber,
        branchCode: ozowBranchCode,
        apiKeyChars: ozowApiKey.length,
      }));
    }

    const payoutPayload = {
      siteCode: ozowSiteCode,
      amount: ozowAmount,
      merchantReference: payoutRef,
      customerBankReference: customerBankReference,
      isRtc: isRtc,
      notifyUrl: notifyUrl,
      bankingDetails: {
        bankGroupId: ozowBankGroupId,
        accountNumber: encryptedAccountNumber,
        branchCode: ozowBranchCode,
      },
      hashCheck: hashCheck,
    };

    console.log(`[admin/ozow-payout] Initiating R${payoutAmount.toFixed(2)} to ${recipient_type} ${recipient_id} (${bank_name} ****${String(account_number).slice(-4)})`);
    console.log(`[admin/ozow-payout] URL: ${ozowPayoutUrl} ref=${payoutRef}`);
    if (isOzowSandbox) {
      console.log('[admin/ozow-payout][SANDBOX-ECHO] === OUTBOUND REQUEST ===');
      console.log('[admin/ozow-payout][SANDBOX-ECHO] body  :', JSON.stringify(payoutPayload));
    }

    let ozowResponse = null;
    let ozowResult = null;
    let ozowRawText = '';
    let ozowRespHeaders = {};

    try {
      const response = await fetch(ozowPayoutUrl, {
        method: 'POST',
        headers: {
          'ApiKey': ozowApiKey,
          'SiteCode': ozowSiteCode,
          'Accept': 'application/json',
          'Content-Type': 'application/json',
        },
        body: JSON.stringify(payoutPayload),
        signal: AbortSignal.timeout(30000),
      });
      ozowRawText = await response.text().catch(() => '');
      try { ozowResult = ozowRawText ? JSON.parse(ozowRawText) : {}; } catch (_) { ozowResult = null; }
      try { response.headers.forEach((v, k) => { ozowRespHeaders[k] = v; }); } catch (_) {}
      ozowResponse = response;
      const errMsg = (ozowResult && ozowResult.payoutStatus && ozowResult.payoutStatus.errorMessage) || '';
      console.log(`[admin/ozow-payout] HTTP ${response.status} msg="${errMsg.slice(0,80)}" ref=${payoutRef}`);
      if (isOzowSandbox) {
        console.log('[admin/ozow-payout][SANDBOX-ECHO] === INBOUND RESPONSE ===');
        console.log('[admin/ozow-payout][SANDBOX-ECHO] status:', response.status);
        console.log('[admin/ozow-payout][SANDBOX-ECHO] raw   :', ozowRawText || '(empty)');
      }
    } catch (attemptErr) {
      console.error(`[admin/ozow-payout] Ozow request threw: ${attemptErr.message}`);
    }

    if (!ozowResponse) {
      return res.status(502).json({
        ok: false,
        error: 'Ozow request failed before receiving a response. Please try again.',
      });
    }

    if (!ozowResult) {
      console.error(`[admin/ozow-payout] Ozow returned non-JSON (${ozowResponse.status}):`, ozowRawText || '(empty body)');
      return res.status(502).json({
        ok: false,
        error: `Ozow returned invalid response (HTTP ${ozowResponse.status}). Check API key and endpoint.`,
        ozow_status: ozowResponse.status,
      });
    }

    console.log(`[admin/ozow-payout] Ozow response (${ozowResponse.status}):`, JSON.stringify(ozowResult));

    // Ozow Payouts v1 response shape: { payoutId, payoutStatus: { status, subStatus, errorMessage } }
    const payoutId = ozowResult && (ozowResult.payoutId || ozowResult.PayoutId);
    const payoutStatusObj = (ozowResult && (ozowResult.payoutStatus || ozowResult.PayoutStatus)) || {};
    const ozowStatusCode = payoutStatusObj.status != null ? payoutStatusObj.status : (ozowResult && ozowResult.status);
    const ozowSubStatus = payoutStatusObj.subStatus != null ? payoutStatusObj.subStatus : null;
    const ozowErrorMessage = payoutStatusObj.errorMessage || payoutStatusObj.ErrorMessage || (ozowResult && (ozowResult.errorMessage || ozowResult.error)) || '';
    // Status codes 1 (Received), 2 (Verification), 3 (SubmittedForProcessing), 5 (Complete) = OK.
    // Status 4 (ProcessingError), 99 (Cancelled), 90 (Returned) = failure.
    const isOzowSuccess = ozowResponse.ok && payoutId && [1, 2, 3, 5].includes(Number(ozowStatusCode));
    const ozowStatus = isOzowSuccess ? 'pending' : 'failed';

    if (!isOzowSuccess) {
      console.error(`[admin/ozow-payout] Ozow rejected (HTTP ${ozowResponse.status}, status=${ozowStatusCode}, subStatus=${ozowSubStatus}): ${ozowErrorMessage}`);
      const errMsg = ozowErrorMessage
        || (ozowRawText && ozowRawText.length < 500 ? ozowRawText : null)
        || `Ozow payout failed (HTTP ${ozowResponse.status}, status=${ozowStatusCode})`;
      try {
        await logErrorToAdmin(
          'ozow_payout_error',
          `Ozow rejected a R${payoutAmount.toFixed(2)} EFT payout to ${recipient_name || recipient_type} (${bank_name} ****${String(account_number).slice(-4)}). HTTP ${ozowResponse.status} status=${ozowStatusCode} subStatus=${ozowSubStatus}. ${ozowErrorMessage || 'See ozow_raw detail.'}`,
          'backend',
          `status=${ozowResponse.status} ozow_status=${ozowStatusCode} ozow_sub=${ozowSubStatus} err=${ozowErrorMessage} resp_headers=${JSON.stringify(ozowRespHeaders).slice(0,400)} raw=${ozowRawText || '(empty)'} parsed=${JSON.stringify(ozowResult).slice(0, 500)} bank_group_id=${ozowBankGroupId} branch=${ozowBranchCode} site_code=${ozowSiteCode ? 'set' : 'MISSING'} api_key=${ozowApiKey ? 'set' : 'MISSING'} test_mode=${env('OZOW_IS_TEST') === 'true'} ref=${payoutRef}`,
          booking_id || null,
          'high'
        );
      } catch (_) {}
      return res.status(400).json({
        ok: false,
        error: errMsg,
        ozow_status: ozowResponse.status,
        ozow_status_code: ozowStatusCode,
        ozow_sub_status: ozowSubStatus,
        ozow_response: ozowResult,
        ozow_raw: ozowRawText && ozowRawText.length < 500 ? ozowRawText : undefined,
        // Sandbox-only diagnostic fields so the test client can see the exact
        // pre-hash string and outbound body. apiKey redacted from input string.
        sandbox_echo: isOzowSandbox ? {
          pre_hash_input: (() => {
            const k = ozowApiKey.toLowerCase();
            return hashInput.endsWith(k)
              ? hashInput.slice(0, -k.length) + `<apiKey:${k.length}chars>`
              : hashInput;
          })(),
          hash_check: hashCheck,
          outbound_body: payoutPayload,
          fields: {
            siteCode: ozowSiteCode,
            amountCents,
            merchantReference: payoutRef,
            customerBankReference,
            isRtc: isRtc ? 'True' : 'False',
            notifyUrl,
            bankGroupId: ozowBankGroupId,
            encryptedAccountNumber,
            branchCode: ozowBranchCode,
            apiKeyChars: ozowApiKey.length,
          },
        } : undefined,
      });
    }

    console.log(`✓ Ozow payout created: ${payoutId} ref=${payoutRef} status=${ozowStatusCode} sub=${ozowSubStatus}`);

    // -- Record payout in Firestore --
    const txId = crypto.randomUUID();
    const payoutRecord = {
      id: txId,
      ozow_payout_id: payoutId,
      payout_reference: payoutRef,
      merchant_reference: payoutRef,
      customer_bank_reference: customerBankReference,
      // ★ Required for /api/ozow-payout-verify to respond with the AES key
      // when Ozow calls back. Without these the payout will fail at verification.
      encryption_key: encryptionKey,
      amount_cents: amountCents,
      bank_group_id: ozowBankGroupId,
      type: recipient_type === 'partner' ? 'partner_payout' : (recipient_type === 'client' ? 'client_refund' : 'artisan_payout'),
      method: 'ozow_eft',
      recipient_id,
      recipient_name: recipient_name || '',
      recipient_type,
      amount: payoutAmount.toFixed(2),
      bank_name,
      account_number_masked: `****${String(account_number).slice(-4)}`,
      branch_code: ozowBranchCode,
      account_type: account_type || 'cheque',
      status: 'pending',
      ozow_status: ozowStatusCode,
      ozow_sub_status: ozowSubStatus,
      admin_id: adminUid,
      reason: reason || `Admin EFT payout to ${recipient_type}`,
      ...(booking_id ? { tasks_management_id: booking_id } : {}),
      created_at: now,
      updated_at: now,
    };

    await db.collection('payout_records').doc(txId).set(payoutRecord);

    // Also log to transactionLogs — include queryable id fields so the record
    // appears on the relevant admin detail screen for that recipient.
    //   - client refunds: user_id (admin user_detail queries on user_id)
    //   - artisan payouts: service_provider_id + artisan_id
    //   - partner payouts: partner_id + corporate_partner_id
    // `transaction_by` is the canonical "who is this transaction for" field.
    await db.collection('transactionLogs').doc(txId).set({
      id: txId,
      amount: payoutAmount.toFixed(2),
      transaction_at: now,
      status: 'pending',
      type: recipient_type === 'partner' ? 'partner_eft_payout' : (recipient_type === 'client' ? 'client_refund_eft' : 'artisan_eft_payout'),
      subtype: `${recipient_type}_payout`,
      direction: 'out',
      cash_movement: true,
      schema_version: 2,
      payment_method: 'ozow_eft',
      payout_reference: payoutRef,
      ozow_payout_id: payoutId,
      recipient_id,
      recipient_name: recipient_name || '',
      recipient_type,
      transaction_by: recipient_id,
      ...(recipient_type === 'client' ? { user_id: recipient_id } : {}),
      ...(recipient_type === 'artisan' ? { service_provider_id: recipient_id, artisan_id: recipient_id } : {}),
      ...(recipient_type === 'partner' ? { partner_id: recipient_id, corporate_partner_id: recipient_id } : {}),
      admin_id: adminUid,
      reason: reason || `Admin EFT payout`,
      ...(booking_id ? { tasks_management_id: booking_id } : {}),
    });

    // Update partner pending_payout if applicable
    if (recipient_type === 'partner') {
      const partnerRef = db.collection('corporate_partners').doc(recipient_id);
      const partnerSnap = await partnerRef.get();
      if (partnerSnap.exists) {
        const partnerData = partnerSnap.data() || {};
        const currentPending = parseFloat(partnerData.pending_payout || 0);
        const newPending = Math.max(0, currentPending - payoutAmount);
        await partnerRef.update({
          pending_payout: newPending,
          paid_out: admin.firestore.FieldValue.increment(payoutAmount),
          last_payout_at: now,
          updated_at: now,
        });

        // Update commission records
        const pendingCommissions = await db.collection('commissions')
          .where('partner_id', '==', recipient_id)
          .where('status', '==', 'pending_payout')
          .get();
        const commBatch = db.batch();
        for (const doc of pendingCommissions.docs) {
          commBatch.update(doc.ref, {
            status: 'paid_out',
            payout_id: txId,
            payment_method: 'ozow_eft',
            payout_reference: payoutRef,
            paid_out_at: now,
          });
        }
        await commBatch.commit();
      }
    }

    // Update artisan balance atomically if applicable
    if (recipient_type === 'artisan') {
      const artisanRef = db.collection('serviceProvider').doc(recipient_id);
      try {
        await db.runTransaction(async (t) => {
          const artisanSnap = await t.get(artisanRef);
          if (!artisanSnap.exists) throw new Error('Artisan not found');
          const artisanData = artisanSnap.data() || {};
          const currentBalance = parseFloat(artisanData.balance || '0');
          if (currentBalance < payoutAmount) {
            throw new Error(`Insufficient balance: R${currentBalance.toFixed(2)} < R${payoutAmount.toFixed(2)}`);
          }
          const newBalance = (currentBalance - payoutAmount).toFixed(2);
          t.update(artisanRef, {
            balance: newBalance,
            last_payout_at: now,
            last_payout_method: 'ozow_eft',
            updated_at: now,
          });
        });
      } catch (txErr) {
        console.error('? Artisan balance deduction failed:', txErr.message);
        // The Ozow payout was already initiated � log for manual reconciliation
      }
    }

    // Update client refund_request if applicable (booking_id may carry refund_request id)
    if (recipient_type === 'client' && booking_id) {
      try {
        const refundRef = db.collection('refund_requests').doc(booking_id);
        const refundSnap = await refundRef.get();
        if (refundSnap.exists) {
          await refundRef.update({
            status: 'processed',
            refund_method: 'ozow_eft',
            payout_id: txId,
            ozow_payout_id: payoutId,
            payout_reference: payoutRef,
            processed_at: now,
            processed_by: adminUid,
            updated_at: now,
          });
        }
      } catch (refundErr) {
        console.error('? Client refund_request update failed:', refundErr.message);
      }
    }

    // ── Sync with any pending weekly payout batch ─────────────────────────
    // If this manual payout covers a recipient that is also in a draft batch,
    // deduct the manual amount from that batch line item so it doesn't get
    // double-paid when the admin approves the batch.
    try {
      const draftSnap = await db.collection('payout_batches')
        .where('status', '==', 'pending_approval')
        .orderBy('created_at', 'desc')
        .limit(3)
        .get();
      for (const batchDoc of draftSnap.docs) {
        const data = batchDoc.data() || {};
        const items = Array.isArray(data.items) ? data.items.slice() : [];
        // Match by recipient_type + recipient_id; "partner" in payout endpoint
        // maps to "corporate_partner" in batch sweeper.
        const matchType = recipient_type === 'partner' ? 'corporate_partner' : recipient_type;
        const idx = items.findIndex(i => i.recipient_type === matchType && i.recipient_id === recipient_id && !i.skip);
        if (idx === -1) continue;
        const it = { ...items[idx] };
        const remaining = Math.max(0, (parseFloat(it.amount) || 0) - payoutAmount);
        if (remaining <= 0.01) {
          it.skip = true;
          it.notes = `Paid manually R${payoutAmount.toFixed(2)} on ${now} (payout ${payoutId})`;
          it.amount = 0;
        } else {
          it.amount = parseFloat(remaining.toFixed(2));
          it.notes = `Partial manual payout R${payoutAmount.toFixed(2)} on ${now} (payout ${payoutId}). Remainder owed.`;
        }
        it.synced_from_manual_at = now;
        items[idx] = it;
        const total = items.filter(i => !i.skip).reduce((s, i) => s + (parseFloat(i.amount) || 0), 0);
        await batchDoc.ref.update({
          items,
          total_amount: parseFloat(total.toFixed(2)),
          updated_at: now,
        });
        console.log(`[ozow-payout] Synced manual payout to batch ${batchDoc.id} item ${it.item_id}`);
        break;
      }
    } catch (syncErr) {
      console.warn('[ozow-payout] batch-sync failed (non-fatal):', syncErr && syncErr.message);
    }

    // ── Notifications ─────────────────────────────────────────────────────
    // Every successful payout (any amount, any recipient type) must notify:
    //   (a) all admins with an FCM push + a notifications doc, and
    //   (b) the recipient (artisan or client) with a push + notifications doc.
    // Partners have no app — partner notification = admin-only.
    // Helpers are declared inline because the global notification helpers
    // (writeAdminNotification / writePersonalNotification) are nested inside
    // executeBookingAction's closure and not accessible from this route.
    try {
      const nowIsoStr = new Date().toISOString();
      const recipientLabel = recipient_name || recipient_type;
      const amountStr = `R${payoutAmount.toFixed(2)}`;
      const acctMasked = `****${String(account_number).slice(-4)}`;
      const typeLabel = recipient_type === 'partner'
        ? 'Partner payout'
        : (recipient_type === 'client' ? 'Client refund' : 'Artisan payout');

      const _collectTokens = (docData) => {
        const d = docData && typeof docData === 'object' ? docData : {};
        const out = [];
        const seen = new Set();
        const push = (v) => {
          const t = String(v || '').trim();
          if (t && !seen.has(t)) { seen.add(t); out.push(t); }
        };
        push(d.deviceToken); push(d.device_token); push(d.fcm_token);
        push(d.fcmToken); push(d.token); push(d.push_token); push(d.pushToken);
        for (const list of [d.tokens, d.fcm_tokens, d.deviceTokens]) {
          if (Array.isArray(list)) for (const item of list) push(item);
        }
        return out;
      };

      const _toStringMap = (v) => {
        const obj = v && typeof v === 'object' ? v : {};
        const out = {};
        for (const [k, val] of Object.entries(obj)) {
          if (val == null) continue;
          out[String(k)] = String(val);
        }
        return out;
      };

      const _sendPush = async ({ tokens, title, body, data }) => {
        if (!tokens || tokens.length === 0) return { attempted: 0, success: 0, failure: 0 };
        try {
          const resp = await admin.messaging().sendEachForMulticast({
            tokens,
            notification: {
              title: String(title || '').trim() || undefined,
              body: String(body || '').trim() || undefined,
            },
            data: _toStringMap(data),
            android: { priority: 'high', notification: { channelId: 'high_importance_channel' } },
          });
          return { attempted: tokens.length, success: resp.successCount || 0, failure: resp.failureCount || 0 };
        } catch (e) {
          console.warn('[ozow-payout] FCM send failed:', e && e.message);
          return { attempted: tokens.length, success: 0, failure: tokens.length };
        }
      };

      const _writeNotifDoc = async ({ userId, userType, title, message, data }) => {
        const ref = db.collection('notifications').doc();
        await ref.set({
          id: ref.id,
          user_id: String(userId || ''),
          user_type: String(userType || '').toLowerCase(),
          title: String(title || ''),
          message: String(message || ''),
          type: String((data && data.type) || ''),
          read: false,
          view: false,
          time: nowIsoStr,
          created_at: nowIsoStr,
          recipient_uid: String(userId || ''),
          data: data || {},
        });
        return ref.id;
      };

      // (a) ADMIN notifications — every admin user, no amount threshold.
      try {
        const adminPayload = {
          type: 'admin_payout_initiated',
          recipient_type,
          recipient_id: String(recipient_id || ''),
          recipient_name: String(recipient_name || ''),
          amount: payoutAmount.toFixed(2),
          payout_id: String(payoutId || ''),
          payout_reference: payoutRef,
          payment_method: 'ozow_eft',
          ...(booking_id ? { booking_id: String(booking_id) } : {}),
        };
        const adminTitle = `${typeLabel} initiated: ${amountStr}`;
        const adminBody = `${amountStr} EFT to ${recipientLabel} (${bank_name} ${acctMasked}) ref ${payoutRef}.`;

        const adminTokens = [];
        const seenAdminTokens = new Set();
        let adminSnap;
        try {
          adminSnap = await db.collection('users').where('isAdmin', '==', true).get();
        } catch (qe) {
          console.warn('[ozow-payout] admin lookup failed:', qe && qe.message);
          adminSnap = { docs: [] };
        }
        for (const adminDoc of (adminSnap.docs || [])) {
          const adminUidLocal = adminDoc.id;
          // Write per-admin notification doc.
          try {
            await _writeNotifDoc({
              userId: adminUidLocal,
              userType: 'admin',
              title: adminTitle,
              message: adminBody,
              data: adminPayload,
            });
          } catch (we) { console.warn('[ozow-payout] admin notif doc failed:', we && we.message); }
          // Collect tokens.
          for (const t of _collectTokens(adminDoc.data() || {})) {
            if (!seenAdminTokens.has(t)) { seenAdminTokens.add(t); adminTokens.push(t); }
          }
        }
        if (adminTokens.length > 0) {
          await _sendPush({ tokens: adminTokens, title: adminTitle, body: adminBody, data: adminPayload });
        }
      } catch (anErr) {
        console.warn('[ozow-payout] admin notification block failed (non-fatal):', anErr && anErr.message);
      }

      // (b) RECIPIENT notification — artisan / client only (partners have no app).
      if (recipient_type === 'artisan' || recipient_type === 'client') {
        try {
          const recipientUType = recipient_type === 'client' ? 'user' : 'artisan';
          const recipientTitle = recipient_type === 'client'
            ? `Refund sent: ${amountStr}`
            : `Payout sent: ${amountStr}`;
          const recipientMsg = recipient_type === 'client'
            ? `Your ${amountStr} refund has been sent to ${bank_name} ${acctMasked}. Funds arrive within minutes (RTC) or next business day. Ref ${payoutRef}.`
            : `Your ${amountStr} payout has been sent to ${bank_name} ${acctMasked}. Funds arrive within minutes (RTC) or next business day. Ref ${payoutRef}.`;
          const recipientPayload = {
            type: recipient_type === 'client' ? 'refund_sent' : 'payout_sent',
            amount: payoutAmount.toFixed(2),
            payout_id: String(payoutId || ''),
            payout_reference: payoutRef,
            payment_method: 'ozow_eft',
            bank_name: String(bank_name || ''),
            account_masked: acctMasked,
            ...(booking_id ? { booking_id: String(booking_id) } : {}),
          };

          await _writeNotifDoc({
            userId: recipient_id,
            userType: recipientUType,
            title: recipientTitle,
            message: recipientMsg,
            data: recipientPayload,
          });

          // Collect tokens (users + serviceProvider for artisans).
          const recipTokens = [];
          const seenRecipTokens = new Set();
          const addTokens = (arr) => {
            for (const t of arr) {
              if (!seenRecipTokens.has(t)) { seenRecipTokens.add(t); recipTokens.push(t); }
            }
          };
          try {
            const userDoc = await db.collection('users').doc(recipient_id).get();
            if (userDoc.exists) addTokens(_collectTokens(userDoc.data() || {}));
          } catch (_) {}
          if (recipientUType === 'artisan') {
            try {
              const spDoc = await db.collection('serviceProvider').doc(recipient_id).get();
              if (spDoc.exists) addTokens(_collectTokens(spDoc.data() || {}));
            } catch (_) {}
          }
          if (recipTokens.length > 0) {
            await _sendPush({ tokens: recipTokens, title: recipientTitle, body: recipientMsg, data: recipientPayload });
          }
        } catch (pnErr) {
          console.warn('[ozow-payout] recipient notification failed (non-fatal):', pnErr && pnErr.message);
        }
      }
    } catch (notifyErr) {
      console.warn('[ozow-payout] notification block failed (non-fatal):', notifyErr && notifyErr.message);
    }

    return res.json({
      ok: true,
      payout_id: payoutId,
      reference: payoutRef,
      status: ozowStatus || 'pending',
      amount: payoutAmount.toFixed(2),
      message: `R${payoutAmount.toFixed(2)} EFT payout initiated to ${recipient_name || recipient_type}. Funds will arrive within minutes (RTC) or next business day.`,
    });
  } catch (error) {
    console.error('? Ozow payout error:', error);
    try {
      await logErrorToAdmin(
        'ozow_payout_exception',
        'Admin-triggered Ozow payout crashed before reaching Ozow. Likely a validation, Firestore, or code error.',
        'backend',
        `${error && error.stack ? error.stack : error && error.message ? error.message : String(error)}`,
        (req.body && req.body.booking_id) || null,
        'high'
      );
    } catch (_) {}
    res.status(500).json({ error: 'EFT payout failed. Please try again.', detail: error && error.message });
  }
});

// ─── Multi-Admin Governance Endpoints ─────────────────────────────────────

// Owner-only: grant or revoke an admin tier on another user.
// Sets the Firebase custom claim `role` on the target uid.
app.post('/api/admin/grant-role', authMiddleware, async (req, res) => {
  try {
    const decoded = req.user;
    const callerTier = resolveAdminTier(decoded);
    if (callerTier !== 'owner') {
      return res.status(403).json({ error: 'Only the owner can grant roles.' });
    }
    const { target_uid, role } = req.body || {};
    if (!target_uid || !role) {
      return res.status(400).json({ error: 'Missing target_uid or role.' });
    }
    const newRole = String(role).toLowerCase();
    if (!ADMIN_TIERS.includes(newRole) && newRole !== 'none') {
      return res.status(400).json({ error: `Invalid role. Must be one of: ${ADMIN_TIERS.join(', ')}, none.` });
    }
    // Preserve other claims (e.g. admin:true legacy). For 'none' we revoke.
    const target = await admin.auth().getUser(String(target_uid)).catch(() => null);
    if (!target) return res.status(404).json({ error: 'Target user not found.' });
    const existingClaims = target.customClaims || {};
    let newClaims;
    if (newRole === 'none') {
      newClaims = { ...existingClaims };
      delete newClaims.role;
      delete newClaims.admin;
    } else {
      newClaims = { ...existingClaims, role: newRole, admin: true };
    }
    await admin.auth().setCustomUserClaims(target.uid, newClaims);
    await admin.firestore().collection('admin_role_audit').add({
      target_uid: target.uid,
      target_email: target.email || null,
      changed_by: decoded.uid,
      changed_by_email: decoded.email || null,
      old_role: existingClaims.role || (existingClaims.admin ? 'admin(legacy)' : null),
      new_role: newRole === 'none' ? null : newRole,
      created_at: new Date().toISOString(),
    });
    res.json({ ok: true, target_uid: target.uid, new_role: newRole, message: 'Role updated. Target must re-login to refresh token.' });
  } catch (e) {
    console.error('grant-role error:', e);
    res.status(500).json({ error: e.message });
  }
});

// Any authed admin: confirm a recent biometric prompt was passed. Used by
// the admin Flutter app right after a local_auth success to unblock payouts
// for the next 5 minutes without forcing a re-login.
app.post('/api/admin/biometric-confirm', authMiddleware, async (req, res) => {
  try {
    const decoded = req.user;
    const tier = resolveAdminTier(decoded);
    if (!tier) return res.status(403).json({ error: 'Admin tier required.' });
    await admin.firestore().collection('admin_biometric_confirms').doc(decoded.uid).set({
      confirmed_at: new Date().toISOString(),
      tier,
    }, { merge: true });
    res.json({ ok: true, valid_for_seconds: 300 });
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

// MFA: setup → returns secret + otpauth URI for QR scanning. Does NOT enable
// until the admin confirms with a code at /enable.
app.post('/api/admin/mfa/setup', authMiddleware, async (req, res) => {
  try {
    const decoded = req.user;
    const tier = resolveAdminTier(decoded);
    if (!tier) return res.status(403).json({ error: 'Admin tier required.' });
    const secret = generateTotpSecret();
    const issuer = encodeURIComponent('Square15');
    const label = encodeURIComponent(decoded.email || decoded.uid);
    const otpauth = `otpauth://totp/${issuer}:${label}?secret=${secret}&issuer=${issuer}&algorithm=SHA1&digits=6&period=30`;
    await admin.firestore().collection('admin_mfa').doc(decoded.uid).set({
      secret,
      enabled: false,
      pending_setup: true,
      created_at: new Date().toISOString(),
    }, { merge: true });
    res.json({ secret, otpauth_uri: otpauth, message: 'Scan QR in Google Authenticator / Authy, then call /enable with the 6-digit code.' });
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

app.post('/api/admin/mfa/enable', authMiddleware, async (req, res) => {
  try {
    const decoded = req.user;
    const tier = resolveAdminTier(decoded);
    if (!tier) return res.status(403).json({ error: 'Admin tier required.' });
    const code = String(req.body?.code || '').trim();
    const snap = await admin.firestore().collection('admin_mfa').doc(decoded.uid).get();
    if (!snap.exists) return res.status(400).json({ error: 'Call /setup first.' });
    const data = snap.data() || {};
    if (!verifyTotp(data.secret, code)) {
      return res.status(401).json({ error: 'Invalid code. Verify the time on your phone is correct and retry.' });
    }
    await snap.ref.set({ enabled: true, pending_setup: false, enabled_at: new Date().toISOString() }, { merge: true });
    res.json({ ok: true, message: 'MFA enabled. Code will be required for payouts.' });
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

app.post('/api/admin/mfa/disable', authMiddleware, async (req, res) => {
  try {
    const decoded = req.user;
    const tier = resolveAdminTier(decoded);
    if (!tier) return res.status(403).json({ error: 'Admin tier required.' });
    const code = String(req.body?.code || '').trim();
    const snap = await admin.firestore().collection('admin_mfa').doc(decoded.uid).get();
    if (!snap.exists) return res.json({ ok: true, message: 'MFA already disabled.' });
    const data = snap.data() || {};
    if (!data.enabled) return res.json({ ok: true, message: 'MFA already disabled.' });
    if (!verifyTotp(data.secret, code)) {
      return res.status(401).json({ error: 'Invalid code. Cannot disable without proof of possession.' });
    }
    await snap.ref.set({ enabled: false, disabled_at: new Date().toISOString() }, { merge: true });
    await admin.firestore().collection('admin_role_audit').add({
      action: 'mfa_disabled',
      target_uid: decoded.uid,
      created_at: new Date().toISOString(),
    });
    res.json({ ok: true, message: 'MFA disabled.' });
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

app.get('/api/admin/mfa/status', authMiddleware, async (req, res) => {
  try {
    const tier = resolveAdminTier(req.user);
    if (!tier) return res.status(403).json({ error: 'Admin tier required.' });
    const snap = await admin.firestore().collection('admin_mfa').doc(req.user.uid).get();
    const data = snap.exists ? (snap.data() || {}) : {};
    res.json({
      enabled: data.enabled === true,
      enrolled: snap.exists,
      tier,
      mfa_required_env: env('MFA_REQUIRED') === 'true',
    });
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

// -- Ozow Payout Verification Webhook --
// Ozow calls this BEFORE executing a payout to confirm the request is
// legitimate. We respond 200 with `verified:true` and echo the payoutId
// only when (a) the 24-char static OZOW_ACCESS_TOKEN matches and (b) we
// have a matching `payout_records` doc � so a leaked token alone can't
// approve a fabricated payoutId.
app.post('/api/ozow-payout-verify', async (req, res) => {
  try {
    // Optional OZOW_ACCESS_TOKEN gate. Ozow's verification webhook does NOT
    // send a custom token by default — it relies on the payoutId being
    // unguessable + IP whitelist on their side. If you configure
    // OZOW_ACCESS_TOKEN (24 chars) here AND in Ozow's portal webhook
    // settings, we'll enforce it; otherwise allow Ozow's call through.
    const expected = process.env.OZOW_ACCESS_TOKEN || '';
    if (expected && expected.length === 24) {
      const provided = String(
        req.headers['x-ozow-access-token'] ||
        req.headers['access-token'] ||
        req.body.accessToken ||
        req.body.AccessToken ||
        req.query.token ||
        ''
      );
      const ok = provided.length === expected.length &&
        crypto.timingSafeEqual(Buffer.from(provided), Buffer.from(expected));
      if (!ok) {
        console.warn(`[ozow-payout-verify] UNAUTHENTICATED from ${req.ip}`);
        return res.status(401).json({ verified: false, error: 'Invalid access token' });
      }
    }
    console.log(`[ozow-payout-verify] incoming from ${req.ip} body=${JSON.stringify(req.body).slice(0,500)}`);

    const payoutId = req.body.payoutId || req.body.PayoutId || req.query.payoutId || null;
    const bankReference = req.body.bankReference || req.body.BankReference || req.body.merchantReference || req.body.MerchantReference || null;

    const db = admin.firestore();
    let foundDoc = null;
    if (payoutId) {
      const s = await db.collection('payout_records').where('ozow_payout_id', '==', payoutId).limit(1).get();
      if (!s.empty) foundDoc = s.docs[0];
    }
    if (!foundDoc && bankReference) {
      // Try merchant_reference first (current schema), then legacy bank_reference field.
      let s = await db.collection('payout_records').where('merchant_reference', '==', bankReference).limit(1).get();
      if (s.empty) s = await db.collection('payout_records').where('bank_reference', '==', bankReference).limit(1).get();
      if (!s.empty) foundDoc = s.docs[0];
    }

    if (!foundDoc) {
      console.warn(`[ozow-payout-verify] payoutId=${payoutId} ref=${bankReference} not found in payout_records`);
      return res.status(404).json({ verified: false, error: 'Payout not found' });
    }

    const rec = foundDoc.data() || {};
    const encryptionKey = rec.encryption_key || rec.encryptionKey || null;
    if (!encryptionKey) {
      console.warn(`[ozow-payout-verify] payout ${foundDoc.id} has no encryption_key (legacy record?)`);
      return res.status(409).json({ verified: false, error: 'Encryption key missing on payout record' });
    }

    // Mark record as verified for audit
    try {
      await foundDoc.ref.update({
        verification_at: new Date().toISOString(),
        verified: true,
      });
    } catch (_) {}

    console.log(`[ozow-payout-verify] APPROVED payoutId=${payoutId} ref=${bankReference} - returning encryption key`);
    // Ozow expects the encryption key in the response so it can decrypt the
    // accountNumber field. Field names tried by Ozow: encryptionKey / EncryptionKey.
    return res.status(200).json({
      verified: true,
      payoutId: payoutId || rec.ozow_payout_id || null,
      bankReference: bankReference || rec.merchant_reference || null,
      merchantReference: rec.merchant_reference || null,
      encryptionKey: encryptionKey,
      EncryptionKey: encryptionKey,
    });
  } catch (e) {
    console.error('[ozow-payout-verify] error:', e && e.message);
    return res.status(500).json({ verified: false, error: 'Internal error' });
  }
});

// -- Ozow Low Float Alert Webhook --
// Ozow POSTs here when the merchant float runs low. We surface an admin
// notification. Same OZOW_ACCESS_TOKEN gate as verify.
app.post('/api/ozow-low-float-alert', async (req, res) => {
  try {
    const expected = process.env.OZOW_ACCESS_TOKEN || '';
    const provided = String(
      req.headers['x-ozow-access-token'] ||
      req.headers['access-token'] ||
      req.body.accessToken ||
      req.query.token ||
      ''
    );
    if (!expected || expected.length !== 24 ||
        provided.length !== expected.length ||
        !crypto.timingSafeEqual(Buffer.from(provided), Buffer.from(expected))) {
      return res.status(401).json({ ok: false });
    }
    const balance = req.body.balance || req.body.Balance || 'unknown';
    await admin.firestore().collection('notifications').add({
      title: '?? Ozow Float Low',
      body: `Ozow has reported a low float balance: ${balance}. Top up to avoid payout failures.`,
      type: 'ozow_low_float',
      user_type: 'admin',
      read: false,
      payload: req.body || {},
      created_at: admin.firestore.FieldValue.serverTimestamp(),
    });
    console.log(`[ozow-low-float] balance=${balance}`);
    return res.status(200).json({ ok: true });
  } catch (e) {
    console.error('[ozow-low-float] error:', e && e.message);
    return res.status(500).json({ ok: false });
  }
});

// -- Ozow Payout Notification Webhook --
// Ozow calls this when a payout status changes (success, failed, etc.)
//
// SECURITY (audit Apr-2026): this endpoint reverses balance deductions on
// "failed" status, so any unauthenticated caller could fabricate a "failed"
// notice for a real payoutId and credit an artisan's wallet while the EFT
// already left the system. We require an out-of-band shared token, supplied
// either as `?token=` query string (recommended for Ozow's NotifyUrl which
// has no header support) or `x-internal-secret` header (for internal/admin
// triggers). The token MUST be configured on Ozow's merchant settings as
// part of the NotifyUrl. If neither token is configured server-side, we
// refuse all calls so a misconfigured deploy cannot silently accept
// unsigned webhooks.
app.post('/api/ozow-payout-notify', async (req, res) => {
  try {
    const expectedNotify = process.env.OZOW_NOTIFY_TOKEN || process.env.OZOW_ACCESS_TOKEN || '';
    const expectedInternal = process.env.INTERNAL_API_SECRET || '';
    if (!expectedNotify && !expectedInternal) {
      console.error('[ozow-payout-notify] BLOCKED: no OZOW_NOTIFY_TOKEN/OZOW_ACCESS_TOKEN or INTERNAL_API_SECRET configured');
      return res.status(503).json({ error: 'Webhook auth not configured' });
    }
    const providedNotify = String(req.query.token || req.body.token || req.headers['x-ozow-access-token'] || '');
    const providedInternal = String(req.headers['x-internal-secret'] || '');
    // Hash both sides to fixed-size SHA-256 buffers so timingSafeEqual never leaks length.
    const _sha = (s) => crypto.createHash('sha256').update(String(s || '')).digest();
    const okNotify = !!expectedNotify && !!providedNotify
      && crypto.timingSafeEqual(_sha(providedNotify), _sha(expectedNotify));
    const okInternal = !!expectedInternal && !!providedInternal
      && crypto.timingSafeEqual(_sha(providedInternal), _sha(expectedInternal));
    if (!okNotify && !okInternal) {
      console.warn(`[ozow-payout-notify] UNAUTHENTICATED call from ${req.ip} payoutId=${req.body && req.body.payoutId}`);
      return res.status(401).json({ error: 'Unauthorized' });
    }

    const { payoutId, status, statusMessage, bankReference } = req.body;
    console.log(`[ozow-payout-notify] payoutId=${payoutId} status=${status} ref=${bankReference}`);

    if (!payoutId) {
      return res.status(400).json({ error: 'Missing payoutId' });
    }

    const db = admin.firestore();

    // Find the payout record by ozow_payout_id
    const payoutSnap = await db.collection('payout_records')
      .where('ozow_payout_id', '==', payoutId)
      .limit(1)
      .get();

    if (payoutSnap.empty) {
      console.warn(`[ozow-payout-notify] Payout not found: ${payoutId}`);
      return res.status(404).json({ error: 'Payout not found' });
    }

    const payoutDoc = payoutSnap.docs[0];
    const payoutData = payoutDoc.data();
    const now = new Date().toISOString();

    // Idempotency: don't re-process already-finalized payouts
    if (payoutData.status === 'completed' || payoutData.status === 'failed') {
      console.log(`[ozow-payout-notify] Payout ${payoutId} already finalized as '${payoutData.status}', ignoring duplicate`);
      return res.json({ ok: true, status: payoutData.status, duplicate: true });
    }

    const normalizedStatus = (status || '').toLowerCase();
    let finalStatus = 'pending';
    if (normalizedStatus === 'complete' || normalizedStatus === 'completed' || normalizedStatus === 'success') {
      finalStatus = 'completed';
    } else if (normalizedStatus === 'failed' || normalizedStatus === 'error' || normalizedStatus === 'cancelled') {
      finalStatus = 'failed';
    }

    // Update payout record
    await payoutDoc.ref.update({
      status: finalStatus,
      ozow_status: status,
      ozow_status_message: statusMessage || '',
      updated_at: now,
    });

    // Update transaction log
    const txRef = db.collection('transactionLogs').doc(payoutDoc.id);
    const txSnap = await txRef.get();
    if (txSnap.exists) {
      await txRef.update({
        status: finalStatus,
        ozow_status: status,
        updated_at: now,
      });
    }

    // If failed, reverse the balance deduction
    if (finalStatus === 'failed') {
      if (payoutData.recipient_type === 'artisan') {
        const artisanRef = db.collection('serviceProvider').doc(payoutData.recipient_id);
        const artisanSnap = await artisanRef.get();
        if (artisanSnap.exists) {
          const amount = parseFloat(payoutData.amount || 0);
          await artisanRef.update({
            balance: admin.firestore.FieldValue.increment(amount),
            updated_at: now,
          });
          console.log(`?? Reversed R${amount} balance deduction for artisan ${payoutData.recipient_id} (failed payout)`);
        }
      } else if (payoutData.recipient_type === 'partner') {
        const partnerRef = db.collection('corporate_partners').doc(payoutData.recipient_id);
        const partnerSnap = await partnerRef.get();
        if (partnerSnap.exists) {
          const amount = parseFloat(payoutData.amount || 0);
          await partnerRef.update({
            pending_payout: admin.firestore.FieldValue.increment(amount),
            paid_out: admin.firestore.FieldValue.increment(-amount),
            updated_at: now,
          });
          console.log(`?? Reversed R${amount} partner payout for ${payoutData.recipient_id} (failed payout)`);
        }
      }
    }

    console.log(`? Payout ${payoutId} updated to ${finalStatus}`);
    res.json({ ok: true, status: finalStatus });
  } catch (error) {
    console.error('? Ozow payout notify error:', error);
    res.status(500).json({ error: 'Notification processing failed' });
  }
});

// -- Admin: Check Ozow payout status --
app.get('/api/admin/ozow-payout-status/:payoutId', authMiddleware, async (req, res) => {
  try {
    const db = admin.firestore();
    const decoded = req.user;
    const role = await resolveRole({ firestore: db, uid: decoded.uid, decodedToken: decoded });
    if (role !== 'admin') {
      return res.status(403).json({ error: 'Admin access required.' });
    }

    const { payoutId } = req.params;
    const payoutSnap = await db.collection('payout_records')
      .where('ozow_payout_id', '==', payoutId)
      .limit(1)
      .get();

    if (payoutSnap.empty) {
      return res.status(404).json({ error: 'Payout not found' });
    }

    const data = payoutSnap.docs[0].data();
    res.json({
      ok: true,
      payout_id: data.ozow_payout_id,
      reference: data.payout_reference,
      status: data.status,
      ozow_status: data.ozow_status,
      amount: data.amount,
      recipient_name: data.recipient_name,
      recipient_type: data.recipient_type,
      created_at: data.created_at,
    });
  } catch (error) {
    console.error('? Payout status error:', error);
    res.status(500).json({ error: 'Failed to check payout status' });
  }
});

// ─── Weekly Payout Batches (admin review/edit/approve) ────────────────────

// List recent batches
app.get('/api/admin/payout-batches', authMiddleware, async (req, res) => {
  try {
    const db = admin.firestore();
    const role = await resolveRole({ firestore: db, uid: req.user.uid, decodedToken: req.user });
    if (role !== 'admin') return res.status(403).json({ error: 'Admin access required.' });
    const status = (req.query.status || '').toString();
    let q = db.collection('payout_batches').orderBy('created_at', 'desc').limit(20);
    if (status) q = db.collection('payout_batches').where('status', '==', status).orderBy('created_at', 'desc').limit(20);
    const snap = await q.get();
    res.json({ ok: true, batches: snap.docs.map(d => d.data()) });
  } catch (e) {
    console.error('[payout-batches/list] error:', e && e.message);
    res.status(500).json({ error: 'Failed to list batches' });
  }
});

// Get one batch (with items)
app.get('/api/admin/payout-batches/:batchId', authMiddleware, async (req, res) => {
  try {
    const db = admin.firestore();
    const role = await resolveRole({ firestore: db, uid: req.user.uid, decodedToken: req.user });
    if (role !== 'admin') return res.status(403).json({ error: 'Admin access required.' });
    const doc = await db.collection('payout_batches').doc(req.params.batchId).get();
    if (!doc.exists) return res.status(404).json({ error: 'Batch not found' });
    res.json({ ok: true, batch: doc.data() });
  } catch (e) {
    res.status(500).json({ error: 'Failed to load batch' });
  }
});

// Edit a single line item (change amount or skip).
// Body: { item_id, amount?, skip?, notes? }
app.patch('/api/admin/payout-batches/:batchId/items', authMiddleware, async (req, res) => {
  try {
    const db = admin.firestore();
    const role = await resolveRole({ firestore: db, uid: req.user.uid, decodedToken: req.user });
    if (role !== 'admin') return res.status(403).json({ error: 'Admin access required.' });
    const { item_id, amount, skip, notes } = req.body || {};
    if (!item_id) return res.status(400).json({ error: 'item_id required' });

    const ref = db.collection('payout_batches').doc(req.params.batchId);
    await db.runTransaction(async (tx) => {
      const snap = await tx.get(ref);
      if (!snap.exists) throw new Error('Batch not found');
      const data = snap.data() || {};
      if (data.status && data.status !== 'pending_approval') {
        throw new Error(`Batch is '${data.status}' and cannot be edited`);
      }
      const items = Array.isArray(data.items) ? data.items.slice() : [];
      const idx = items.findIndex(i => i.item_id === item_id);
      if (idx === -1) throw new Error('item_id not found in batch');
      const it = { ...items[idx] };
      if (amount !== undefined) {
        const v = parseFloat(amount);
        if (isNaN(v) || v < 0) throw new Error('invalid amount');
        if (v > (it.original_amount || 0) * 1.5 && v > 1000) {
          // protect against accidental zero-add of large amounts
          throw new Error(`amount ${v} exceeds 150% of original ${it.original_amount}`);
        }
        it.amount = parseFloat(v.toFixed(2));
      }
      if (skip !== undefined) it.skip = !!skip;
      if (notes !== undefined) it.notes = String(notes).slice(0, 500);
      it.edited_at = new Date().toISOString();
      it.edited_by = req.user.uid;
      items[idx] = it;
      const total = items.filter(i => !i.skip).reduce((s, i) => s + (i.amount || 0), 0);
      tx.update(ref, { items, total_amount: parseFloat(total.toFixed(2)), updated_at: new Date().toISOString() });
    });
    res.json({ ok: true });
  } catch (e) {
    res.status(400).json({ error: e.message || 'Edit failed' });
  }
});

// Approve and fire payouts for all non-skipped items.
// Calls the existing /api/admin/ozow-payout flow internally per item.
app.post('/api/admin/payout-batches/:batchId/approve', authMiddleware, async (req, res) => {
  try {
    const db = admin.firestore();
    const role = await resolveRole({ firestore: db, uid: req.user.uid, decodedToken: req.user });
    if (role !== 'admin') return res.status(403).json({ error: 'Admin access required.' });

    const batchRef = db.collection('payout_batches').doc(req.params.batchId);
    const snap = await batchRef.get();
    if (!snap.exists) return res.status(404).json({ error: 'Batch not found' });
    const batch = snap.data() || {};
    if (batch.status !== 'pending_approval') {
      return res.status(409).json({ error: `Batch already ${batch.status}` });
    }

    // Pre-flight: refuse to approve if any non-skipped item is missing bank details.
    // Admin must edit those items (skip them) before approving the batch.
    const allItems = Array.isArray(batch.items) ? batch.items : [];
    const blockers = allItems.filter(i => !i.skip && i.amount > 0 && (!i.bank_name || !i.account_number));
    if (blockers.length > 0 && !req.body?.allow_partial) {
      return res.status(400).json({
        error: 'Cannot approve: some items are missing bank details. Skip them or fill the bank fields, then retry. Pass {"allow_partial": true} to approve anyway (those items will fail).',
        missing_bank_items: blockers.map(b => ({ item_id: b.item_id, recipient_name: b.recipient_name, recipient_type: b.recipient_type })),
      });
    }

    // Mark approved before firing (prevents double-approve).
    await batchRef.update({
      status: 'processing',
      approved_at: new Date().toISOString(),
      approved_by: req.user.uid,
    });

    const items = allItems;
    const results = [];
    let okCount = 0, failCount = 0;

    // Process sequentially to avoid hammering Ozow + concurrent balance mutations.
    for (const it of items) {
      if (it.skip || !it.amount || it.amount <= 0) {
        results.push({ item_id: it.item_id, status: 'skipped' });
        continue;
      }
      if (!it.bank_name || !it.account_number) {
        results.push({ item_id: it.item_id, status: 'failed', error: 'missing_bank_details' });
        failCount++;
        continue;
      }
      try {
        // Reuse the per-payout endpoint logic by calling Ozow directly via the
        // existing helper if exposed; otherwise mark for manual follow-up.
        // For safety + minimal surface change, we POST a payout_records doc
        // marked 'queued' and let an admin retry from the existing payout
        // screen, OR we call the existing /api/admin/ozow-payout endpoint
        // via internal fetch.
        const fetchFn = global.fetch || require('node-fetch');
        const internalUrl = `${env('RENDER_EXTERNAL_URL') || 'https://square15-livekit-backend.onrender.com'}/api/admin/ozow-payout`;
        // We don't have the admin's bearer token server-side; instead bypass
        // auth via internal secret if configured, else create a queued record.
        const internalSecret = env('INTERNAL_API_SECRET');
        if (internalSecret) {
          const r = await fetchFn(internalUrl, {
            method: 'POST',
            headers: {
              'Content-Type': 'application/json',
              'Authorization': req.headers.authorization || '',
              'x-internal-secret': internalSecret,
            },
            body: JSON.stringify({
              recipient_type: it.recipient_type === 'corporate_partner' ? 'partner' : it.recipient_type,
              recipient_id: it.recipient_id,
              recipient_name: it.recipient_name,
              amount: it.amount,
              bank_name: it.bank_name,
              account_number: it.account_number,
              branch_code: it.branch_code || '',
              account_type: it.account_type || 'cheque',
              source: `batch_${req.params.batchId}`,
            }),
            signal: AbortSignal.timeout(45000),
          });
          const j = await r.json().catch(() => ({}));
          if (r.ok) { okCount++; results.push({ item_id: it.item_id, status: 'ok', payout_id: j.payout_id || j.ozow_payout_id }); }
          else { failCount++; results.push({ item_id: it.item_id, status: 'failed', error: j.error || `http_${r.status}` }); }
        } else {
          // No internal secret → queue for manual retry from existing screen.
          results.push({ item_id: it.item_id, status: 'queued_for_manual_retry' });
        }
      } catch (e) {
        failCount++;
        results.push({ item_id: it.item_id, status: 'failed', error: (e && e.message) || 'exception' });
      }
    }

    await batchRef.update({
      status: failCount === 0 ? 'completed' : (okCount === 0 ? 'failed' : 'partial'),
      completed_at: new Date().toISOString(),
      ok_count: okCount,
      fail_count: failCount,
      results,
    });
    res.json({ ok: true, ok_count: okCount, fail_count: failCount, results });
  } catch (e) {
    console.error('[payout-batches/approve] error:', e && e.message);
    res.status(500).json({ error: e.message || 'Approve failed' });
  }
});

// Manual rebuild trigger (for admin "Build this week's batch now" button).
app.post('/api/admin/payout-batches/rebuild-now', authMiddleware, async (req, res) => {
  try {
    const db = admin.firestore();
    const role = await resolveRole({ firestore: db, uid: req.user.uid, decodedToken: req.user });
    if (role !== 'admin') return res.status(403).json({ error: 'Admin access required.' });
    const now = new Date();
    const sast = new Date(now.getTime() + 2 * 60 * 60 * 1000);
    const monDate = new Date(sast); monDate.setUTCDate(sast.getUTCDate() - ((sast.getUTCDay() + 6) % 7));
    const weekKey = `wk_${monDate.toISOString().slice(0, 10)}`;
    const existing = await db.collection('payout_batches').doc(weekKey).get();
    if (existing.exists && existing.data().status !== 'pending_approval') {
      return res.status(409).json({ error: `Batch ${weekKey} is in status "${existing.data().status}" — cannot rebuild.` });
    }
    // Don't delete — _maybeBuildWeeklyBatch will overwrite via .set() and
    // preserve notified_at so we don't re-spam admins on every rebuild.
    const result = await _maybeBuildWeeklyBatch(true);
    if (result && result.error) return res.status(500).json(result);
    res.json({ ok: true, ...result });
  } catch (e) {
    res.status(500).json({ error: 'Rebuild failed' });
  }
});

// -- Admin: Save card via initial payment --
// Creates a payment URL for the admin to save a card via PayFast tokenization.
// Uses a R1 verification charge that will be refunded.
app.post('/api/admin/save-card', authMiddleware, async (req, res) => {
  try {
    const db = admin.firestore();
    const decoded = req.user;
    const adminUid = decoded.uid;

    const role = await resolveRole({ firestore: db, uid: adminUid, decodedToken: decoded });
    if (role !== 'admin') {
      return res.status(403).json({ error: 'Admin access required.' });
    }

    const merchantId = env('PAYFAST_MERCHANT_ID');
    const merchantKey = env('PAYFAST_MERCHANT_KEY');
    const payfastUrl = env('PAYFAST_URL') || 'https://www.payfast.co.za/eng/process';
    const backendUrl = env('RENDER_EXTERNAL_URL') || 'https://square15-livekit-backend.onrender.com';

    if (!merchantId || !merchantKey) {
      return res.status(503).json({ error: 'Payment credentials not configured.' });
    }

    const enableTokenization = env('PAYFAST_ENABLE_TOKENIZATION') === 'true';
    if (!enableTokenization) {
      try {
        await logErrorToAdmin(
          'payment_config_error',
          'Admin tried to save a card but PayFast ad-hoc tokenization is not enabled on Render. Set PAYFAST_ENABLE_TOKENIZATION=true in Render env vars AND enable ad-hoc tokenization in the PayFast merchant dashboard, then redeploy.',
          'backend',
          `adminUid=${adminUid} route=/api/admin/save-card`,
          null,
          'high'
        );
      } catch (_) {}
      return res.status(400).json({
        error: 'Card saving is not enabled on this merchant yet. Enable PayFast ad-hoc tokenization first, then retry.',
      });
    }

    // Fetch admin profile for email (required by PayFast for tokenization)
    const adminDoc = await db.collection('users').doc(adminUid).get();
    const adminData = adminDoc.exists ? adminDoc.data() : {};
    const adminEmail = adminData.email || decoded.email || '';
    const adminName = adminData.name || decoded.name || 'Admin';

    // PayFast requires parameters in a SPECIFIC order for signature verification:
    // merchant ? return/cancel/notify ? personal ? amount/item ? custom ? payment_method ? subscription
    const paymentData = {};
    paymentData.merchant_id = merchantId;
    paymentData.merchant_key = merchantKey;
    // LK-3: admin card-save uses the synthetic booking_id 'admin_card_save'; sign it too
    // so the GET handler accepts it (the handler skips processing for this id).
    {
      const _sigAdmin = signPaymentCallback('admin_card_save');
      paymentData.return_url = `${backendUrl}/api/payment/ozow-result?status=success&booking_id=admin_card_save${_sigAdmin}`;
      paymentData.cancel_url = `${backendUrl}/api/payment/ozow-result?status=cancel&booking_id=admin_card_save${_sigAdmin}`;
    }
    paymentData.notify_url = `${backendUrl}/api/payment/itn`;
    if (adminName) paymentData.name_first = adminName.split(' ')[0];
    if (adminEmail) paymentData.email_address = adminEmail;
    paymentData.m_payment_id = `card_save_${adminUid}_${Date.now()}`;
    paymentData.amount = '10.00'; // R10 verification charge (below min may trigger 400)
    paymentData.item_name = 'Square 15 Card Verification';
    paymentData.custom_str1 = `admin_card_save_${adminUid}`;
    paymentData.payment_method = 'cc';
    // subscription_type=2 requires merchant to have ad-hoc tokenization enabled in PayFast dashboard
    // Only add it if the merchant has explicitly enabled it
    paymentData.subscription_type = '2';

    // Generate PayFast signature � use + for spaces (PayFast standard)
    const passphrase = env('PAYFAST_PASSPHRASE') || '';
    const pfParamString = Object.entries(paymentData)
      .map(([k, v]) => `${encodeURIComponent(k).replace(/%20/g, '+')}=${encodeURIComponent(String(v || '')).replace(/%20/g, '+')}`)
      .join('&');
    let sigInput = pfParamString;
    if (passphrase) {
      sigInput += `&passphrase=${encodeURIComponent(passphrase).replace(/%20/g, '+')}`;
    }
    paymentData.signature = crypto.createHash('md5').update(sigInput).digest('hex');

    // Build auto-submitting HTML form (POST) � PayFast requires form POST for reliable signature validation
    const formFields = Object.entries(paymentData)
      .map(([k, v]) => `<input type="hidden" name="${k}" value="${String(v || '').replace(/"/g, '&quot;')}" />`)
      .join('\n      ');
    const formHtml = `<!DOCTYPE html>
<html><head><title>Redirecting to PayFast...</title>
<style>body{display:flex;align-items:center;justify-content:center;height:100vh;margin:0;font-family:sans-serif;background:#f5f5f5;}
.loader{text-align:center;}.spinner{border:4px solid #ddd;border-top:4px solid #1a73e8;border-radius:50%;width:40px;height:40px;animation:spin 1s linear infinite;margin:0 auto 16px;}
@keyframes spin{to{transform:rotate(360deg);}}</style></head>
<body><div class="loader"><div class="spinner"></div><p>Redirecting to PayFast...</p></div>
<form id="pf" method="POST" action="${payfastUrl}">
      ${formFields}
</form>
<script>document.getElementById('pf').submit();</script>
</body></html>`;

    // Also build GET URL as fallback
    const queryString = Object.entries(paymentData)
      .map(([k, v]) => `${encodeURIComponent(k).replace(/%20/g, '+')}=${encodeURIComponent(String(v || '')).replace(/%20/g, '+')}`)
      .join('&');
    const fullPaymentUrl = `${payfastUrl}?${queryString}`;

    console.log(`[admin] Card save initiated for admin ${adminUid}, email=${adminEmail ? 'yes' : 'MISSING'}`);
    res.json({ ok: true, payment_url: fullPaymentUrl, payment_form_html: formHtml });
  } catch (error) {
    console.error('? Admin save-card error:', error);
    res.status(500).json({ error: 'Failed to initiate card save.' });
  }
});

// -- Shared payment processing helper (used by both ozow-result and ITN) --
// Idempotent: checks if already processed before updating.
async function processSuccessfulPayment(bookingId, { amountGross, pfPaymentId, itemName, source: calledFrom }) {
  if (!bookingId) return { processed: false, reason: 'no booking ID' };

  const now = new Date().toISOString();
  const taskRef = admin.firestore().collection('tasksManagement').doc(bookingId);
  const taskSnap = await taskRef.get();

  if (!taskSnap.exists) {
    // -- SAFETY NET: If doc doesn't exist, create a minimal one so payment is not lost --
    console.warn(`[processPayment] tasksManagement/${bookingId} not found � creating minimal doc to preserve payment`);
    const isWA = bookingId.startsWith('WA-');
    // Pull critical fields from futureBookings so the doc isn't orphaned
    let fbFields = {};
    try {
      const fbSnap = await admin.firestore().collection('futureBookings').doc(bookingId).get();
      if (fbSnap.exists) {
        const fb = fbSnap.data() || {};
        fbFields = {
          ...(fb.user_id && { user_id: fb.user_id, userId: fb.user_id, uid: fb.user_id }),
          ...(fb.service_provider_id && { service_provider_id: fb.service_provider_id }),
          ...(fb.description && { description: fb.description }),
          ...(fb.total_cost && { total_cost: fb.total_cost, cost: fb.total_cost }),
          ...(fb.category && { category: fb.category }),
          ...(fb.order_no && { order_no: fb.order_no }),
          ...(fb.phone && { phone: fb.phone }),
          ...(fb.provided_address && { provided_address: fb.provided_address }),
        };
      }
    } catch (fbErr) {
      console.warn(`[processPayment] futureBookings lookup failed: ${fbErr.message}`);
    }
    const minimalDoc = {
      id: bookingId,
      order_no: `SQ15-${bookingId}`,
      source: isWA ? 'whatsapp' : 'unknown',
      payment_verified: true,
      payment_verified_at: now,
      payment_verified_via: calledFrom || 'payment_callback',
      payment_status: 'paid',
      paymentStatus: 'paid',
      accept: '1',
      payment_method: 'payfast',
      created_at: now,
      updated_at: now,
      _auto_created: true,
      _auto_created_reason: 'processSuccessfulPayment: original doc missing at payment time',
      ...fbFields,
    };
    if (amountGross) minimalDoc.payfast_itn_amount = amountGross;
    if (pfPaymentId) minimalDoc.payfast_payment_id = pfPaymentId;
    await taskRef.set(minimalDoc);
    console.log(`[processPayment] Created minimal tasksManagement/${bookingId} with ${Object.keys(fbFields).length} fields from futureBookings`);

    // -- Send WA notification + push for auto-created doc (don't return early) --
    // Use fbFields as taskData source for phone, source, etc.
    const taskSource = (fbFields.source || (bookingId.startsWith('WA-') ? 'whatsapp' : '')).toString().toLowerCase();
    const phone = (fbFields.phone || fbFields.customer_phone || fbFields.customerPhone || fbFields.contact || fbFields.user_phone || fbFields.client_phone || '').toString().trim();
    if (phone && (taskSource.startsWith('whatsapp') || bookingId.startsWith('WA-'))) {
      try {
        const waBot = env('WHATSAPP_BOT_URL') || 'https://square15-whatsapp-bot.onrender.com';
        const orderLabel = fbFields.order_no || bookingId;
        // Read deposit info from futureBookings to determine correct amount
        let fbPayData = {};
        try {
          const fbPayDoc = await admin.firestore().collection('futureBookings').doc(bookingId).get();
          if (fbPayDoc.exists) fbPayData = fbPayDoc.data() || {};
        } catch (_) {}
        const autoIsDeposit = fbPayData.payment_type === 'deposit' || fbPayData.payment_status === 'deposit_pending';
        const autoDepositAlreadyPaid = fbPayData.deposit_paid === true;
        const autoTotalCost = parseFloat(fbPayData.cost || fbPayData.total_cost || fbFields.total_cost || fbFields.cost || '0');
        let autoDisplayAmt;
        let waMessage;
        if (autoIsDeposit && !autoDepositAlreadyPaid) {
          autoDisplayAmt = parseFloat(fbPayData.deposit_amount || '0') || Math.round(autoTotalCost * 0.35 * 100) / 100;
          const autoBalAmt = parseFloat(fbPayData.balance_amount || '0') || Math.round((autoTotalCost - autoDisplayAmt) * 100) / 100;
          waMessage = `💰 *Deposit received!* R${autoDisplayAmt.toFixed(2)} for booking #${orderLabel}.

✅ Your booking is confirmed. The remaining balance of R${autoBalAmt.toFixed(2)} will be due after job completion.

Your artisan will contact you to arrange the visit. 🛠️

📲 *What's next?*
• You'll receive your artisan's photo & details for safety verification
• Reply *"track"* to see when they're on the way
• Reply *"help"* anytime if you have questions`;
          // Update the minimal doc with deposit fields
          await taskRef.update({ payment_type: 'deposit', deposit_paid: true, deposit_paid_at: now, deposit_amount: autoDisplayAmt.toFixed(2), balance_amount: autoBalAmt.toFixed(2), balance_remaining: autoBalAmt.toFixed(2), payment_status: 'deposit_paid', paymentStatus: 'deposit_paid' });
        } else if (autoIsDeposit && autoDepositAlreadyPaid) {
          autoDisplayAmt = parseFloat(fbPayData.balance_remaining || fbPayData.balance_amount || '0') || Math.round(autoTotalCost * 0.65 * 100) / 100;
          waMessage = `💰 *Balance payment received!* R${autoDisplayAmt.toFixed(2)} for booking #${orderLabel}.

✅ Your booking is now fully paid. You can now rate your artisan.

Thank you for choosing Square 15! ⭐

📝 Reply *"rate"* to leave a review for your artisan.`;
          await taskRef.update({ balance_paid: true, balance_paid_at: now, payment_status: 'paid', paymentStatus: 'paid' });
        } else {
          autoDisplayAmt = autoTotalCost;
          waMessage = `💰 *Payment received!* R${autoDisplayAmt > 0 ? autoDisplayAmt.toFixed(2) : '0.00'} for booking #${orderLabel}.

✅ Your booking is confirmed. Your artisan will contact you to arrange the visit.

Thank you for choosing Square 15! 🛠️`;
        }
        await fetch(`${waBot}/api/booking-status-update`, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json', 'x-internal-secret': process.env.INTERNAL_API_SECRET || '' },
          body: JSON.stringify({ bookingId: bookingId, status: 'payment_received', message: waMessage }),
          signal: AbortSignal.timeout(10000),
        });
        console.log(`? [processPayment] WhatsApp notification sent for auto-created ${bookingId}`);
      } catch (waErr) {
        console.warn(`[processPayment] WhatsApp notification failed for auto-created ${bookingId}: ${waErr.message}`);
      }
    }
    // Update futureBookings payment status (deposit-aware)
    try {
      const fbRef2 = admin.firestore().collection('futureBookings').doc(bookingId);
      const fbSnap2 = await fbRef2.get();
      if (fbSnap2.exists) {
        const fbPayType = (fbSnap2.data() || {}).payment_type;
        const fbDepPaid = (fbSnap2.data() || {}).deposit_paid === true;
        const fbPayUpdate = { payment_method: 'payfast', payment_paid_at: now, artisan_confirmed: 'yes', updated_at: now };
        if (fbPayType === 'deposit' && !fbDepPaid) {
          fbPayUpdate.deposit_paid = true; fbPayUpdate.deposit_paid_at = now;
          fbPayUpdate.payment_status = 'deposit_paid'; fbPayUpdate.paymentStatus = 'deposit_paid';
        } else {
          fbPayUpdate.payment_status = 'paid'; fbPayUpdate.paymentStatus = 'paid';
        }
        await fbRef2.update(fbPayUpdate);
      }
    } catch (_) {}
    return { processed: true, paymentStatus: 'paid', autoCreated: true };
  }

  const taskData = taskSnap.data() || {};

  // -- Idempotency: use transaction to prevent race conditions (ozow-result + ITN arriving simultaneously) --
  // For deposit bookings, allow a second payment (balance) after deposit is paid.
  // CRITICAL: require at least 2 minutes since deposit was paid to prevent the ITN callback
  // from the SAME deposit payment being treated as a balance payment.
  const depositPaidAt = taskData.deposit_paid_at ? new Date(taskData.deposit_paid_at).getTime() : 0;
  const timeSinceDeposit = depositPaidAt ? (Date.now() - depositPaidAt) : Infinity;
  const isBalanceFollowUp = taskData.payment_verified === true
    && taskData.payment_type === 'deposit'
    && taskData.deposit_paid === true
    && taskData.balance_paid !== true
    && taskData.payment_status !== 'paid'
    && timeSinceDeposit > 120000; // must be >2 minutes since deposit was paid

  if (!isBalanceFollowUp) {
    try {
      await admin.firestore().runTransaction(async (tx) => {
        const freshSnap = await tx.get(taskRef);
        const fd = freshSnap.data() || {};
        if (fd.payment_verified === true) {
          // Allow if this is a balance payment on a deposit booking (with time check)
          const fdDepPaidAt = fd.deposit_paid_at ? new Date(fd.deposit_paid_at).getTime() : 0;
          const fdTimeSinceDep = fdDepPaidAt ? (Date.now() - fdDepPaidAt) : Infinity;
          if (fd.payment_type === 'deposit' && fd.deposit_paid === true && fd.balance_paid !== true && fd.payment_status !== 'paid' && fdTimeSinceDep > 120000) {
            // Balance payment � proceed (genuine second payment, not ITN duplicate)
            return;
          }
          throw new Error('ALREADY_VERIFIED');
        }
        tx.update(taskRef, { payment_verified: true, payment_verified_at: now, payment_verified_via: calledFrom || 'payment_callback' });
      });
    } catch (txErr) {
      if (txErr.message === 'ALREADY_VERIFIED') {
        console.log(`[processPayment] ${bookingId} already verified (by ${taskData.payment_verified_via || 'unknown'}), timeSinceDeposit=${Math.round(timeSinceDeposit/1000)}s, skipping`);
        return { processed: false, reason: 'already verified' };
      }
      console.warn(`[processPayment] Idempotency transaction error: ${txErr.message}`);
    }
  } else {
    console.log(`[processPayment] Balance payment for deposit booking ${bookingId} (${Math.round(timeSinceDeposit/1000)}s after deposit) � bypassing idempotency`);
  }

  // -- Read deposit/balance info from futureBookings if missing on tasksManagement --
  // The WA bot writes payment_type/deposit_amount to futureBookings, not always to tasksManagement
  // -- Merge critical fields from futureBookings (phone, source, service_provider_id, user_id) --
  // The artisan-accepted handler may create a minimal tasksManagement doc without these fields.
  // Always read futureBookings to fill gaps so WA notifications and push notifications work.
  {
    try {
      const fbCheckId = taskData.future_booking_id || bookingId;
      const fbCheck = await admin.firestore().collection('futureBookings').doc(fbCheckId).get();
      if (fbCheck.exists) {
        const fbd = fbCheck.data() || {};
        if (!taskData.payment_type && fbd.payment_type) taskData.payment_type = fbd.payment_type;
        if (fbd.deposit_amount && !taskData.deposit_amount) taskData.deposit_amount = fbd.deposit_amount;
        if (fbd.balance_amount && !taskData.balance_amount) taskData.balance_amount = fbd.balance_amount;
        if (fbd.balance_remaining && !taskData.balance_remaining) taskData.balance_remaining = fbd.balance_remaining;
        if (fbd.deposit_paid !== undefined && taskData.deposit_paid === undefined) taskData.deposit_paid = fbd.deposit_paid;
        if (fbd.balance_paid !== undefined && taskData.balance_paid === undefined) taskData.balance_paid = fbd.balance_paid;
        if (fbd.payment_status && !taskData.payment_status) taskData.payment_status = fbd.payment_status;
        // Fill critical fields for WA notification + artisan push
        if (!taskData.phone) taskData.phone = fbd.phone || fbd.user_phone || fbd.customerPhone || fbd.contact || fbd.client_phone || '';
        if (!taskData.customer_phone) taskData.customer_phone = fbd.customer_phone || fbd.user_phone || fbd.customerPhone || '';
        if (!taskData.customerPhone) taskData.customerPhone = fbd.customerPhone || fbd.user_phone || fbd.customer_phone || '';
        if (!taskData.contact) taskData.contact = fbd.contact || '';
        if (!taskData.user_phone) taskData.user_phone = fbd.user_phone || '';
        if (!taskData.client_phone) taskData.client_phone = fbd.client_phone || '';
        if (!taskData.source) taskData.source = fbd.source || '';
        if (!taskData.service_provider_id) taskData.service_provider_id = fbd.service_provider_id || '';
        if (!taskData.user_id && !taskData.userId) {
          taskData.user_id = fbd.user_id || fbd.userId || fbd.uid || '';
          taskData.userId = taskData.user_id;
        }
        if (!taskData.order_no) taskData.order_no = fbd.order_no || '';
        if (!taskData.cost && !taskData.total_cost) {
          taskData.cost = fbd.cost || fbd.total_cost || '';
          taskData.total_cost = taskData.cost;
        }
      }
    } catch (_) {}
  }

  // -- Also check bridge docs for service_provider_id if still missing --
  if (!taskData.service_provider_id) {
    try {
      const bridgeLookup = await admin.firestore().collection('tasksManagement')
        .where('future_booking_id', '==', bookingId)
        .where('accept', '==', '1')
        .limit(1).get();
      if (!bridgeLookup.empty) {
        const bd = bridgeLookup.docs[0].data() || {};
        taskData.service_provider_id = bd.service_provider_id || '';
        if (!taskData.service_provider_id) {
          // Extract from bridge doc ID: {bookingId}_{artisanId}
          const bridgeDocId = bridgeLookup.docs[0].id;
          if (bridgeDocId.includes('_')) {
            taskData.service_provider_id = bridgeDocId.split('_').slice(1).join('_');
          }
        }
      }
    } catch (_) {}
  }

  // -- Determine payment type --
  const isDepositBooking = taskData.payment_type === 'deposit' || taskData.payment_status === 'deposit_pending';
  const depositAlreadyPaid = taskData.deposit_paid === true;
  const balanceAlreadyPaid = taskData.balance_paid === true;

  // --------------------------------------------------------------------
  // -- PAYMENT AMOUNT VERIFICATION (financial-integrity guard) --
  // The amount actually paid via PayFast (amountGross) MUST match the
  // amount we recorded as expected (deposit_amount / balance_remaining / cost)
  // within a small tolerance. Mismatches must NOT auto-confirm � they
  // indicate a tampered/stale link, manual override, or quote change after
  // payment was initiated. Such cases are flagged for admin review.
  // --------------------------------------------------------------------
  const paidAmount = parseFloat(amountGross);
  if (!isNaN(paidAmount) && paidAmount > 0) {
    const totalCostNum = parseFloat(taskData.cost || taskData.total_cost || '0') || 0;
    let expectedAmount = 0;
    let expectedLabel = 'unknown';

    if (isDepositBooking && !depositAlreadyPaid) {
      // Customer is paying the deposit
      expectedAmount = parseFloat(taskData.deposit_amount || '0')
        || (totalCostNum > 0 ? Math.round(totalCostNum * 0.35 * 100) / 100 : 0);
      expectedLabel = 'deposit';
    } else if (isDepositBooking && depositAlreadyPaid && !balanceAlreadyPaid) {
      // Customer is paying the balance after deposit
      expectedAmount = parseFloat(taskData.balance_remaining || taskData.balance_amount || '0')
        || (totalCostNum > 0 ? Math.round((totalCostNum - (parseFloat(taskData.deposit_amount || '0') || totalCostNum * 0.35)) * 100) / 100 : 0);
      expectedLabel = 'balance';
    } else {
      // Full payment
      expectedAmount = totalCostNum;
      expectedLabel = 'full';
    }

    if (expectedAmount > 0) {
      // Tolerance: max(R1.00 absolute, 1% relative) � covers gateway rounding
      const diff = Math.abs(paidAmount - expectedAmount);
      const tolerance = Math.max(1.00, expectedAmount * 0.01);
      if (diff > tolerance) {
        console.error(`?? [processPayment] AMOUNT MISMATCH for ${bookingId}: expected ${expectedLabel} R${expectedAmount.toFixed(2)} but PayFast received R${paidAmount.toFixed(2)} (diff R${diff.toFixed(2)}, tolerance R${tolerance.toFixed(2)})`);

          // Flag the booking for admin review � DO NOT mark as paid
          const mismatchFields = {
            payment_amount_mismatch: true,
            payment_amount_mismatch_at: now,
            payment_amount_expected: expectedAmount.toFixed(2),
            payment_amount_paid: paidAmount.toFixed(2),
            payment_amount_difference: diff.toFixed(2),
            payment_amount_expected_label: expectedLabel,
            payment_status: 'under_review',
            paymentStatus: 'under_review',
            payfast_payment_id: pfPaymentId || '',
            payfast_itn_amount: paidAmount.toFixed(2),
            payfast_itn_received_at: now,
            payment_review_reason: `${expectedLabel} expected R${expectedAmount.toFixed(2)} but received R${paidAmount.toFixed(2)}`,
            updated_at: now,
            // Reset the idempotency lock that was set earlier so admin can re-process after correction
            payment_verified: false,
            payment_verified_at: admin.firestore.FieldValue.delete(),
            payment_verified_via: admin.firestore.FieldValue.delete(),
          };
          try {
            await taskRef.update(mismatchFields);
          } catch (e) {
            console.warn(`[processPayment] mismatch flag write failed: ${e.message}`);
          }
          // Mirror to futureBookings
          try {
            const fbMismatchId = taskData.future_booking_id || bookingId;
            const fbMismatchRef = admin.firestore().collection('futureBookings').doc(fbMismatchId);
            const fbMismatchSnap = await fbMismatchRef.get();
            if (fbMismatchSnap.exists) await fbMismatchRef.update(mismatchFields);
          } catch (_) {}

          // Audit log: write a transactionLog entry with status='review' so finance can find it
          try {
            const txId = crypto.randomUUID();
            await admin.firestore().collection('transactionLogs').doc(txId).set({
              id: txId,
              amount: paidAmount.toFixed(2),
              expected_amount: expectedAmount.toFixed(2),
              difference: diff.toFixed(2),
              transaction_at: now,
              status: 'review',
              review_reason: 'amount_mismatch',
              expected_label: expectedLabel,
              user_id: taskData.user_id || taskData.userId || '',
              type: 'payfast',
              subtype: 'payment_mismatch',
              direction: 'in',
              cash_movement: false,
              schema_version: 2,
              tasks_management_id: bookingId,
              payfast_payment_id: pfPaymentId || '',
              payfast_itn_status: 'COMPLETE',
              verified_via: calledFrom || 'payment_callback',
              item_name: itemName || taskData.item_name || taskData.service_type || '',
            });
            console.log(`?? [processPayment] Mismatch transactionLog created: ${txId}`);
          } catch (txErr) {
            console.warn(`[processPayment] Mismatch transactionLog failed: ${txErr.message}`);
          }

          // Notify admin (in-app + FCM)
          try {
            await admin.firestore().collection('notifications').add({
              title: '?? Payment amount mismatch � manual review required',
              body: `Booking ${taskData.order_no || bookingId}: expected ${expectedLabel} R${expectedAmount.toFixed(2)} but received R${paidAmount.toFixed(2)} (diff R${diff.toFixed(2)}). PayFast ID: ${pfPaymentId || 'unknown'}. Booking is on hold pending admin action.`,
              type: 'payment_mismatch',
              user_type: 'admin',
              priority: 'high',
              booking_id: bookingId,
              tasks_management_id: bookingId,
              read: false,
              view: false,
              created_at: now,
            });
          } catch (_) {}

          // Send WA notification to customer (do NOT confirm payment received)
          const taskSrcMM = (taskData.source || '').toString().toLowerCase();
          if (taskSrcMM.startsWith('whatsapp') || bookingId.startsWith('WA-')) {
            const phoneMM = (taskData.phone || taskData.customer_phone || taskData.customerPhone || taskData.contact || taskData.user_phone || taskData.client_phone || '').toString().trim();
            if (phoneMM) {
              try {
                const waBotMM = env('WHATSAPP_BOT_URL') || 'https://square15-whatsapp-bot.onrender.com';
                await fetch(`${waBotMM}/api/booking-status-update`, {
                  method: 'POST',
                  headers: { 'Content-Type': 'application/json', 'x-internal-secret': process.env.INTERNAL_API_SECRET || '' },
                  body: JSON.stringify({
                    bookingId: taskData.future_booking_id || bookingId,
                    status: 'payment_under_review',
                    message: `⚠️ *Payment received but on hold*\n\nWe received R${paidAmount.toFixed(2)} for booking #${taskData.order_no || bookingId}, but our records show the expected ${expectedLabel} amount is R${expectedAmount.toFixed(2)}.\n\nOur team has been notified and will review this within 1 business hour. Your funds are safe — no further action is needed from you right now. We'll message you once it's resolved. 🙏`,
                  }),
                  signal: AbortSignal.timeout(10000),
                });
              } catch (waMmErr) {
                console.warn(`[processPayment] mismatch WA notification failed: ${waMmErr.message}`);
              }
            }
          }

          return { processed: false, reason: 'amount_mismatch', expected: expectedAmount.toFixed(2), paid: paidAmount.toFixed(2) };
      }
      console.log(`[processPayment] Amount verified for ${bookingId}: ${expectedLabel} expected R${expectedAmount.toFixed(2)}, paid R${paidAmount.toFixed(2)} (within tolerance R${tolerance.toFixed(2)})`);
    } else {
      console.warn(`[processPayment] Could not determine expected amount for ${bookingId} (${expectedLabel}) � proceeding without verification`);
    }
  } else {
    console.warn(`[processPayment] amountGross missing/invalid for ${bookingId}: "${amountGross}" � proceeding without verification`);
  }

  const updateData = {
    payment_verified: true,
    payment_verified_at: now,
    payment_verified_via: calledFrom || 'payment_callback',
    updated_at: now,
    status: 'accepted',
    accept: '1',
    artisan_confirmed: 'yes',
    payment_method: 'payfast',
  };
  if (pfPaymentId) {
    updateData.payfast_payment_id = pfPaymentId;
    updateData.payfast_itn_status = 'COMPLETE';
    // Use the actual amount from PayFast, but fall back to booking cost if PayFast sent 0/empty
    const parsedAmount = parseFloat(amountGross);
    const validAmount = (!isNaN(parsedAmount) && parsedAmount > 0)
      ? parsedAmount.toFixed(2)
      : (parseFloat(taskData.cost || taskData.total_cost || 0) || 0).toFixed(2);
    updateData.payfast_itn_amount = validAmount;
    updateData.payfast_itn_received_at = now;
  }

  let isDepositPayment = false;
  let isBalancePayment = false;

  if (isDepositBooking && !depositAlreadyPaid) {
    updateData.deposit_paid = true;
    updateData.deposit_paid_at = now;
    updateData.payment_status = 'deposit_paid';
    updateData.paymentStatus = 'deposit_paid';
    updateData.payment_type = 'deposit';
    // Persist deposit/balance amounts so Flutter app + WA bot can read them
    const totalCost = parseFloat(taskData.cost || taskData.total_cost || '0');
    const depAmt = parseFloat(taskData.deposit_amount || '0') || Math.round(totalCost * 0.35 * 100) / 100;
    const balAmt = parseFloat(taskData.balance_amount || taskData.balance_remaining || '0') || Math.round((totalCost - depAmt) * 100) / 100;
    if (depAmt > 0) updateData.deposit_amount = depAmt.toFixed(2);
    if (balAmt > 0) { updateData.balance_amount = balAmt.toFixed(2); updateData.balance_remaining = balAmt.toFixed(2); }
    isDepositPayment = true;
    console.log(`[processPayment] Deposit received for ${bookingId}`);
  } else if (isDepositBooking && depositAlreadyPaid && !balanceAlreadyPaid) {
    updateData.balance_paid = true;
    updateData.balance_paid_at = now;
    updateData.payment_status = 'paid';
    updateData.paymentStatus = 'paid';
    isBalancePayment = true;
    console.log(`[processPayment] Balance received for ${bookingId}`);
  } else {
    updateData.payment_status = 'paid';
    updateData.paymentStatus = 'paid';
    console.log(`[processPayment] Full payment received for ${bookingId}`);
  }

  await taskRef.update(updateData);
  console.log(`? [processPayment] Updated tasksManagement/${bookingId}: payment_status=${updateData.payment_status}`);

  // -- Update futureBookings --
  const futureBookingId = taskData.future_booking_id || '';
  const fbId = futureBookingId || bookingId;

  try {
    const fbRef = admin.firestore().collection('futureBookings').doc(fbId);
    const fbSnap = await fbRef.get();
    if (fbSnap.exists) {
      const fbUpdate = {
        payment_method: 'payfast',
        payment_paid_at: now,
        updated_at: now,
        artisan_confirmed: 'yes',
      };
      // Propagate linking fields from tasksManagement if missing on futureBookings
      const fbData = fbSnap.data() || {};
      if (!fbData.user_id && taskData.user_id) fbUpdate.user_id = taskData.user_id;
      if (!fbData.userId && taskData.user_id) fbUpdate.userId = taskData.user_id;
      if (!fbData.uid && taskData.user_id) fbUpdate.uid = taskData.user_id;
      if (!fbData.service_provider_id && taskData.service_provider_id) fbUpdate.service_provider_id = taskData.service_provider_id;
      if (!fbData.tasks_management_id) fbUpdate.tasks_management_id = bookingId;

      if (isBalancePayment) {
        fbUpdate.balance_paid = true;
        fbUpdate.balance_paid_at = now;
        fbUpdate.payment_status = 'paid';
        fbUpdate.paymentStatus = 'paid';
        fbUpdate.status = 'accepted';
      } else if (isDepositPayment) {
        fbUpdate.deposit_paid = true;
        fbUpdate.deposit_paid_at = now;
        fbUpdate.payment_status = 'deposit_paid';
        fbUpdate.paymentStatus = 'deposit_paid';
        fbUpdate.status = 'accepted';
      } else {
        fbUpdate.payment_status = 'paid';
        fbUpdate.paymentStatus = 'paid';
        fbUpdate.status = 'accepted';
      }
      await fbRef.update(fbUpdate);
      console.log(`? [processPayment] Updated futureBookings/${fbId}: payment_status=${fbUpdate.payment_status}`);
    }
  } catch (fbErr) {
    console.warn(`[processPayment] futureBookings update failed: ${fbErr.message}`);
  }

  // -- Propagate payment_status to ALL bridge docs (e.g. {bookingId}_{artisanId}) --
  try {
    const bridgeSnap = await admin.firestore().collection('tasksManagement')
      .where('future_booking_id', '==', bookingId).get();
    if (!bridgeSnap.empty) {
      const batch = admin.firestore().batch();
      bridgeSnap.forEach(doc => {
        batch.update(doc.ref, {
          payment_status: updateData.payment_status,
          paymentStatus: updateData.paymentStatus || updateData.payment_status,
          payment_verified: true,
          payment_verified_at: now,
          accept: '1',
          artisan_confirmed: 'yes',
          status: 'accepted',
          updated_at: now,
          ...(isDepositPayment ? { deposit_paid: true, deposit_paid_at: now } : {}),
          ...(isBalancePayment ? { balance_paid: true, balance_paid_at: now } : {}),
        });
      });
      await batch.commit();
      console.log(`? [processPayment] Updated ${bridgeSnap.size} bridge doc(s) for ${bookingId}`);
    }
  } catch (bridgeErr) {
    console.warn(`[processPayment] Bridge doc update failed: ${bridgeErr.message}`);
  }

  // -- Send WhatsApp notification to customer --
  const taskSource = (taskData.source || '').toString().toLowerCase();
  if (taskSource.startsWith('whatsapp') || bookingId.startsWith('WA-')) {
    let phone = (taskData.phone || taskData.customer_phone || taskData.customerPhone || taskData.contact || taskData.user_phone || taskData.client_phone || '').toString().trim();
    if (!phone && (taskData.user_id || taskData.userId)) {
      try {
        const uid = (taskData.user_id || taskData.userId).toString().trim();
        const userDoc = await admin.firestore().collection('users').doc(uid).get();
        if (userDoc.exists) {
          phone = (userDoc.data()?.phone || userDoc.data()?.phoneNumber || '').toString().trim();
        }
      } catch (_) {}
    }
    if (phone) {
      try {
        const waBot = env('WHATSAPP_BOT_URL') || 'https://square15-whatsapp-bot.onrender.com';
        // Calculate correct display amount based on payment type.
        // SAFETY: prefer the recorded expected amount over the gateway-reported amountGross,
        // because amountGross is untrusted user-facing data and a wrong value could mislead
        // the customer about what was actually paid. Verification above ensures these match
        // (within tolerance) before we reach this point.
        const totalCostVal = parseFloat(taskData.total_cost) || parseFloat(taskData.cost) || 0;
        let rawPayAmt;
        if (isDepositPayment) {
          rawPayAmt = parseFloat(updateData.deposit_amount) || parseFloat(taskData.deposit_amount)
            || (totalCostVal > 0 ? Math.round(totalCostVal * 0.35 * 100) / 100 : 0)
            || parseFloat(amountGross) || 0;
        } else if (isBalancePayment) {
          rawPayAmt = parseFloat(taskData.balance_remaining) || parseFloat(taskData.balance_amount)
            || (totalCostVal > 0 ? Math.round(totalCostVal * 0.65 * 100) / 100 : 0)
            || parseFloat(amountGross) || 0;
        } else {
          rawPayAmt = totalCostVal || parseFloat(taskData.price) || parseFloat(amountGross) || 0;
        }
        const displayAmount = rawPayAmt > 0 ? rawPayAmt.toFixed(2) : '0.00';
        let waMessage;
        if (isBalancePayment) {
          waMessage = `💰 *Balance payment received!* R${displayAmount} for booking #${taskData.order_no || fbId}.

✅ Your booking is now fully paid. You can now rate your artisan.

Thank you for choosing Square 15! ⭐

📝 Reply *"rate"* to leave a review for your artisan.`;
        } else if (isDepositPayment) {
          const balAmount = parseFloat(taskData.balance_amount || 0).toFixed(2);
          waMessage = `💰 *Deposit received!* R${displayAmount} for booking #${taskData.order_no || fbId}.

✅ Your booking is confirmed. The remaining balance of R${balAmount} will be due after job completion.

Your artisan will contact you to arrange the visit. 🛠️

📲 *What's next?*
• You'll receive your artisan's photo & details for safety verification
• Reply *"track"* to see when they're on the way
• Reply *"help"* anytime if you have questions`;
        } else {
          waMessage = `💰 *Payment received!* R${displayAmount} for booking #${taskData.order_no || fbId}.

✅ Your booking is confirmed. Your artisan will contact you to arrange the visit.

Thank you for choosing Square 15! 🛠️`;
        }
        await fetch(`${waBot}/api/booking-status-update`, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json', 'x-internal-secret': process.env.INTERNAL_API_SECRET || '' },
          body: JSON.stringify({
            bookingId: fbId,
            status: isBalancePayment ? 'balance_received' : 'payment_received',
            message: waMessage,
          }),
          signal: AbortSignal.timeout(10000),
        });
        console.log(`? [processPayment] WhatsApp notification sent for ${bookingId}`);
      } catch (waErr) {
        console.warn(`[processPayment] WhatsApp notification failed: ${waErr.message}`);
      }
    } else {
      console.warn(`[processPayment] No phone number found for WhatsApp notification (${bookingId})`);
    }
  }

  // -- Notify artisan via push notification --
  try {
    const artisanId = (taskData.service_provider_id || '').toString().trim();
    if (artisanId) {
      const artisanDoc = await admin.firestore().collection('serviceProvider').doc(artisanId).get();
      if (artisanDoc.exists) {
        const ad = artisanDoc.data() || {};
        // Collect all possible FCM token fields
        const tokenCandidates = [ad.deviceToken, ad.device_token, ad.fcm_token, ad.fcmToken, ad.token, ad.push_token];
        const tokensSeen = new Set();
        const artisanTokens = [];
        for (const c of tokenCandidates) {
          const t = String(c || '').trim();
          if (t && !tokensSeen.has(t)) {
            tokensSeen.add(t);
            artisanTokens.push(t);
          }
        }
        const orderLabel = taskData.order_no || fbId;
        const totalForArtisan = parseFloat(taskData.total_cost) || parseFloat(taskData.cost) || 0;
        // SAFETY: same priority � prefer recorded expected amount over amountGross
        let artisanPayAmt;
        if (isDepositPayment) {
          artisanPayAmt = parseFloat(updateData.deposit_amount) || parseFloat(taskData.deposit_amount)
            || (totalForArtisan > 0 ? Math.round(totalForArtisan * 0.35 * 100) / 100 : 0)
            || parseFloat(amountGross) || 0;
        } else if (isBalancePayment) {
          artisanPayAmt = parseFloat(taskData.balance_remaining) || parseFloat(taskData.balance_amount)
            || (totalForArtisan > 0 ? Math.round(totalForArtisan * 0.65 * 100) / 100 : 0)
            || parseFloat(amountGross) || 0;
        } else {
          artisanPayAmt = totalForArtisan || parseFloat(amountGross) || 0;
        }
        const artisanDisplayAmt = artisanPayAmt > 0 ? artisanPayAmt.toFixed(2) : '?';
        const title = isBalancePayment ? 'Balance Payment Received' : isDepositPayment ? 'Deposit Received' : 'Payment Received';
        const body = isBalancePayment
          ? `Client paid R${artisanDisplayAmt} balance for booking #${orderLabel}. Job fully paid.`
          : isDepositPayment
            ? `Client paid R${artisanDisplayAmt} deposit for booking #${orderLabel}. You may proceed.`
            : `Client paid R${artisanDisplayAmt} for booking #${orderLabel}. You may proceed.`;
        for (const tok of artisanTokens) {
          try {
            await admin.messaging().send({
              token: tok,
              notification: { title, body },
              data: { type: 'payment_received', booking_id: fbId, tasks_management_id: bookingId, user_type: 'artisan' },
              android: { priority: 'high', notification: { channelId: 'order_request_channel', sound: 'sound' } },
            });
            console.log(`? [processPayment] Artisan ${artisanId} notified via token ${tok.substring(0, 15)}...`);
            // Send to ALL tokens so multi-device artisans get notified everywhere
          } catch (singleErr) {
            console.warn(`[processPayment] FCM token failed for artisan ${artisanId}: ${singleErr.message}`);
          }
        }
        // Also write in-app notification for artisan
        try {
          await admin.firestore().collection('notifications').add({
            user_id: artisanId,
            user_type: 'artisan',
            title,
            message: body,
            booking_id: fbId,
            tasks_management_id: bookingId,
            type: 'payment_received',
            read: false,
            view: false,
            created_at: now,
          });
        } catch (_) {}
      }
    }
  } catch (artErr) {
    console.warn(`[processPayment] Artisan notification failed: ${artErr.message}`);
  }

  // -- Notify linked customer via push notification (if they have the app) --
  try {
    const custUserId = (taskData.user_id || taskData.userId || '').toString().trim();
    if (custUserId && !custUserId.startsWith('wa_')) {
      const custDoc = await admin.firestore().collection('users').doc(custUserId).get();
      if (custDoc.exists) {
        const cu = custDoc.data() || {};
        const custTokenCandidates = [cu.deviceToken, cu.device_token, cu.fcm_token, cu.fcmToken, cu.token, cu.push_token];
        const custTokensSeen = new Set();
        const custTokens = [];
        for (const c of custTokenCandidates) {
          const t = String(c || '').trim();
          if (t && !custTokensSeen.has(t)) { custTokensSeen.add(t); custTokens.push(t); }
        }
        if (custTokens.length > 0) {
          const custTitle = isBalancePayment ? 'Balance Payment Confirmed' : isDepositPayment ? 'Deposit Confirmed' : 'Payment Confirmed';
          const custBody = isBalancePayment
            ? `Your balance payment has been received. Booking #${taskData.order_no || fbId} is fully paid.`
            : isDepositPayment
              ? `Your deposit has been received. Booking #${taskData.order_no || fbId} is confirmed.`
              : `Your payment has been received. Booking #${taskData.order_no || fbId} is confirmed.`;
          for (const tok of custTokens) {
            try {
              await admin.messaging().send({
                token: tok,
                notification: { title: custTitle, body: custBody },
                data: { type: 'payment_confirmed', booking_id: fbId, tasks_management_id: bookingId, user_type: 'customer' },
                android: { priority: 'high', notification: { channelId: 'order_request_channel', sound: 'sound' } },
              });
              console.log(`? [processPayment] Customer ${custUserId} notified via token ${tok.substring(0, 15)}...`);
            } catch (custFcmErr) {
              console.warn(`[processPayment] Customer FCM failed: ${custFcmErr.message}`);
            }
          }
        }
        // Write in-app notification for customer
        await admin.firestore().collection('notifications').add({
          user_id: custUserId,
          user_type: 'customer',
          title: isBalancePayment ? 'Balance Payment Confirmed' : isDepositPayment ? 'Deposit Confirmed' : 'Payment Confirmed',
          message: `Your payment for booking #${taskData.order_no || fbId} has been received.`,
          booking_id: fbId,
          tasks_management_id: bookingId,
          type: 'payment_confirmed',
          read: false,
          view: false,
          created_at: now,
        });
      }
    }
  } catch (custErr) {
    console.warn(`[processPayment] Customer notification failed: ${custErr.message}`);
  }

  // -- Create transaction log --
  try {
    const txRef = admin.firestore().collection('transactionLogs');
    const txQuery = pfPaymentId
      ? txRef.where('payfast_payment_id', '==', pfPaymentId).limit(1)
      : txRef.where('tasks_management_id', '==', bookingId).where('status', '==', 'success').limit(1);
    const existingTx = await txQuery.get();

    if (existingTx.empty) {
      const txId = crypto.randomUUID();
      await txRef.doc(txId).set({
        id: txId,
        amount: amountGross || taskData.total_cost || '0',
        transaction_at: now,
        status: 'success',
        user_id: taskData.user_id || taskData.userId || '',
        type: 'payfast',
        subtype: 'payment',
        direction: 'in',
        cash_movement: true,
        schema_version: 2,
        tasks_management_id: bookingId,
        payfast_payment_id: pfPaymentId || '',
        payfast_itn_status: 'COMPLETE',
        verified_via: calledFrom || 'payment_callback',
        item_name: itemName || taskData.item_name || taskData.service_type || '',
        payment_type: isBalancePayment ? 'balance' : isDepositPayment ? 'deposit' : 'full',
      });
      console.log(`? [processPayment] Created transactionLog: ${txId}`);
    }
  } catch (txErr) {
    console.warn(`[processPayment] Transaction log failed: ${txErr.message}`);
  }

  return { processed: true, paymentStatus: updateData.payment_status };
}

// -- Payment Result Page (return URL after PayFast payment) --
// Shows a success/cancel page AND triggers Firestore + WhatsApp update as fallback.
// The ITN webhook may not reach Render (free tier sleep), so this is the reliable path.
app.get('/api/payment/ozow-result', async (req, res) => {
  const { status, booking_id, t, exp } = req.query;
  const isSuccess = status === 'success';
  // Sanitise user-controlled booking_id to prevent XSS
  const safeBookingId = String(booking_id || '').replace(/[<>"'&]/g, '');
  const title = isSuccess ? 'Payment Successful!' : 'Payment Cancelled';
  const emoji = isSuccess ? '?' : '?';
  const message = isSuccess
    ? `Your payment for booking ${safeBookingId} has been received. You will receive a confirmation on WhatsApp shortly.`
    : `Your payment was cancelled. You can try again from WhatsApp or the Square 15 app.`;
  const color = isSuccess ? '#22c55e' : '#ef4444';

  // Send the HTML page immediately so the customer sees it
  res.type('html').send(`<!DOCTYPE html><html><head>
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>${title}</title>
<style>body{font-family:-apple-system,sans-serif;display:flex;justify-content:center;align-items:center;min-height:100vh;margin:0;background:#f8f9fa;padding:20px}
.card{background:white;border-radius:16px;padding:40px;text-align:center;max-width:400px;box-shadow:0 4px 20px rgba(0,0,0,.1)}
h1{color:${color};margin:0 0 16px}p{color:#555;line-height:1.6;margin:0}</style>
</head><body><div class="card">
<div style="font-size:64px">${emoji}</div>
<h1>${title}</h1>
<p>${message}</p>
<p style="margin-top:20px;color:#999;font-size:14px">You can close this page.</p>
</div></body></html>`);

  // -- FALLBACK: Process payment directly since ITN may not reach Render (free tier sleep) --
  // processSuccessfulPayment has idempotency (ALREADY_VERIFIED transaction), so calling from
  // both ozow-result AND ITN is safe � only the first one processes.
  //
  // LK-3 (May 2026): we MUST verify the signed callback token before processing
  // payment, otherwise an attacker can hit this URL with any booking_id and
  // mark it paid. Fail-closed: invalid/missing token ? render the page (above)
  // but DO NOT call processSuccessfulPayment.
  if (isSuccess && booking_id) {
    // Skip admin card-save synthetic id (no payment to process � PayFast handles tokenisation server-side)
    if (booking_id === 'admin_card_save') {
      console.log('[ozow-result] admin_card_save callback � no booking processing needed');
      return;
    }
    const sigCheck = verifyPaymentCallback(booking_id, t, exp);
    if (!sigCheck.ok) {
      console.warn(`[ozow-result] SECURITY: rejecting unsigned/invalid callback for booking_id="${safeBookingId}" reason=${sigCheck.reason} ip=${req.ip || req.headers['x-forwarded-for'] || 'unknown'} ua="${String(req.headers['user-agent'] || '').slice(0, 80)}"`);
      try {
        await admin.firestore().collection('error_logs').add({
          error_type: 'payment_callback_rejected',
          severity: 'high',
          source: 'livekit_backend',
          description: `Rejected /api/payment/ozow-result callback (no/invalid signature). reason=${sigCheck.reason}, booking_id=${safeBookingId}`,
          booking_id: safeBookingId,
          ip: req.ip || req.headers['x-forwarded-for'] || 'unknown',
          user_agent: String(req.headers['user-agent'] || '').slice(0, 200),
          created_at: admin.firestore.FieldValue.serverTimestamp(),
          read: false,
        });
      } catch (_) {}
      return; // page already sent � do NOT process payment
    }
    try {
      const preCheck = await admin.firestore().collection('tasksManagement').doc(booking_id).get();
      const preData = preCheck.exists ? preCheck.data() : {};
      const payableStates = ['unpaid', 'deposit_pending', 'deposit_paid', 'pending_verification', undefined, ''];
      if (!payableStates.includes(preData.payment_status)) {
        console.log(`[ozow-result] Booking ${booking_id} already in state '${preData.payment_status}', skipping`);
        return;
      }
      console.log(`[ozow-result] Processing payment for ${booking_id} (fallback � ITN may or may not arrive)`);
      // Resolve amount based on payment_type � DO NOT default to total cost,
      // or a deposit payment will be recorded as the full amount (financial bug).
      let fallbackItem = preData.description || preData.item_name || '';
      let preDoc = preData;
      if (!preDoc || !Object.keys(preDoc).length) {
        try {
          const fbFallback = await admin.firestore().collection('futureBookings').doc(booking_id).get();
          if (fbFallback.exists) {
            preDoc = fbFallback.data() || {};
            if (!fallbackItem) fallbackItem = preDoc.description || preDoc.item_name || '';
          }
        } catch (_) {}
      }
      // Decide the expected amount from the recorded payment_type / payment_status
      const totalCostFb = parseFloat(preDoc.cost || preDoc.total_cost || '0') || 0;
      const isDepositFb = preDoc.payment_type === 'deposit' || preDoc.payment_status === 'deposit_pending';
      const depositPaidFb = preDoc.deposit_paid === true;
      const balancePendingFb = preDoc.payment_status === 'balance_pending';
      let fallbackAmount;
      if (isDepositFb && !depositPaidFb) {
        fallbackAmount = (parseFloat(preDoc.deposit_amount || '0')
          || (totalCostFb > 0 ? Math.round(totalCostFb * 0.35 * 100) / 100 : 0)).toFixed(2);
      } else if (depositPaidFb || balancePendingFb) {
        fallbackAmount = (parseFloat(preDoc.balance_remaining || preDoc.balance_amount || '0')
          || (totalCostFb > 0 ? Math.round(totalCostFb * 0.65 * 100) / 100 : 0)).toFixed(2);
      } else {
        fallbackAmount = (totalCostFb > 0 ? totalCostFb : 0).toFixed(2);
      }
      console.log(`[ozow-result] Resolved fallbackAmount=R${fallbackAmount} (payment_type=${preDoc.payment_type || 'full'}, deposit_paid=${depositPaidFb})`);
      const result = await processSuccessfulPayment(booking_id, {
        amountGross: fallbackAmount || '',
        pfPaymentId: '',
        itemName: fallbackItem,
        source: 'ozow_result_fallback',
      });
      console.log(`[ozow-result] processSuccessfulPayment result: ${JSON.stringify(result)}`);
    } catch (err) {
      console.error(`[ozow-result] Fallback error for ${booking_id}:`, err.message);
    }
  }
});

// -- PayFast ITN (Instant Transaction Notification) Webhook --
// Server-side payment verification � PayFast posts here after payment
app.post('/api/payment/itn', async (req, res) => {
  try {
    const data = req.body;
    console.log('?? PayFast ITN received:', JSON.stringify(data));

    // 1. Verify signature
    const merchantKey = env('PAYFAST_MERCHANT_KEY');
    if (!merchantKey) {
      console.error('? ITN: PAYFAST_MERCHANT_KEY not configured');
      return res.status(503).send('Server misconfigured');
    }

    const receivedSignature = data.signature;
    if (!receivedSignature) {
      console.error('? ITN: No signature in payload');
      return res.status(400).send('Missing signature');
    }

    // Build param string for signature verification (preserve original order from PayFast)
    const paramString = Object.keys(data)
      .filter(key => key !== 'signature')
      .map(key => `${key}=${encodeURIComponent(String(data[key] || '')).replace(/%20/g, '+')}`)
      .join('&');

    const passphrase = env('PAYFAST_PASSPHRASE') || '';
    let sigInput = paramString;
    if (passphrase) {
      sigInput += `&passphrase=${encodeURIComponent(passphrase)}`;
    }
    const expectedSignature = crypto
      .createHash('md5')
      .update(sigInput)
      .digest('hex');

    if (receivedSignature !== expectedSignature) {
      console.error('? ITN: Signature mismatch');
      return res.status(403).send('Invalid signature');
    }

    // 2. Extract payment info
    const paymentStatus = String(data.payment_status || '');
    const pfPaymentId = String(data.pf_payment_id || '');
    const rawAmountGross = parseFloat(data.amount_gross);
    const amountGross = (!isNaN(rawAmountGross) && rawAmountGross > 0)
      ? rawAmountGross.toFixed(2)
      : String(data.amount_gross || '0');
    const customStr1 = String(data.custom_str1 || ''); // tasksManagement ID
    const itemName = String(data.item_name || '');
    const token = String(data.token || ''); // Card tokenization token (when subscription_type=2)
    const billingDate = String(data.billing_date || '');

    console.log(`? ITN verified: status=${paymentStatus}, pfId=${pfPaymentId}, amount=R${amountGross}, taskId=${customStr1}${token ? ', token=***' : ''}`);

    // 3a. Save card token if tokenization was used (subscription_type=2, ad-hoc)
    if (token && paymentStatus === 'COMPLETE' && customStr1) {
      try {
        let userId = '';

        // Check if this is an admin card save (custom_str1 = 'admin_card_save_{uid}')
        if (customStr1.startsWith('admin_card_save_')) {
          userId = customStr1.replace('admin_card_save_', '');
        } else {
          // Look up user_id from the task
          const taskSnap = await admin.firestore().collection('tasksManagement').doc(customStr1).get();
          const taskData = taskSnap.exists ? taskSnap.data() : {};
          userId = taskData.user_id || taskData.userId || '';
        }

        if (userId) {
          // Extract card info from ITN data (PayFast provides these for card payments)
          const cardLast4 = String(data.custom_str2 || '').slice(-4) || '****';
          const cardType = String(data.payment_method_type || data.custom_str3 || 'card');

          // Store token in user's saved_cards subcollection
          const cardId = crypto.randomUUID();
          const cardSavedAt = new Date().toISOString();
          await admin.firestore().collection('users').doc(userId).collection('saved_cards').doc(cardId).set({
            id: cardId,
            token: token,
            last4: cardLast4,
            card_type: cardType,
            created_at: cardSavedAt,
            last_used_at: cardSavedAt,
            payfast_payment_id: pfPaymentId,
            is_active: true,
          });
          console.log(`?? Saved card token for user ${userId}, card ${cardId}`);
        }
      } catch (tokenErr) {
        console.warn(`[ITN] Card token save failed: ${tokenErr.message}`);
      }
    }

    // 3. Process payment using shared helper (handles Firestore + WhatsApp + artisan + tx log)
    if (paymentStatus === 'COMPLETE' && customStr1) {
      // Replay protection: a captured ITN payload (or accidental double
      // delivery from PayFast) must NOT trigger payment crediting twice.
      // We dedupe by `pf_payment_id` in a dedicated collection. The first
      // request to write the doc wins; subsequent identical IDs are ignored.
      if (pfPaymentId) {
        const ledgerRef = admin.firestore().collection('paymentItnLedger').doc(pfPaymentId);
        try {
          await admin.firestore().runTransaction(async (txn) => {
            const snap = await txn.get(ledgerRef);
            if (snap.exists) {
              throw new Error('ITN_ALREADY_PROCESSED');
            }
            txn.set(ledgerRef, {
              pf_payment_id: pfPaymentId,
              task_id: customStr1,
              amount: amountGross,
              status: paymentStatus,
              processed_at: new Date().toISOString(),
              source: 'payfast_itn',
            });
          });
        } catch (replayErr) {
          if (replayErr && replayErr.message === 'ITN_ALREADY_PROCESSED') {
            console.warn(`[ITN] replay detected for pf_payment_id=${pfPaymentId} task=${customStr1} � skipping`);
            return res.status(200).send('OK');
          }
          throw replayErr;
        }
      }
      const result = await processSuccessfulPayment(customStr1, {
        amountGross,
        pfPaymentId,
        itemName,
        source: 'payfast_itn',
      });
      console.log(`[ITN] processSuccessfulPayment result: ${JSON.stringify(result)}`);
    } else if (customStr1 && (paymentStatus === 'CANCELLED' || paymentStatus === 'FAILED')) {
      // Mark as cancelled/failed
      const now = new Date().toISOString();
      const taskRef = admin.firestore().collection('tasksManagement').doc(customStr1);
      const taskSnap = await taskRef.get();
      if (taskSnap.exists) {
        await taskRef.update({
          payfast_payment_id: pfPaymentId,
          payfast_itn_status: paymentStatus,
          payfast_itn_amount: amountGross,
          payfast_itn_received_at: now,
          payment_status: paymentStatus === 'CANCELLED' ? 'cancelled' : 'failed',
          updated_at: now,
        });
        console.log(`?? ITN: ${paymentStatus} for ${customStr1}`);
      }
    }

    // PayFast expects a 200 OK response
    res.status(200).send('OK');
  } catch (error) {
    console.error('? PayFast ITN error:', error);
    res.status(200).send('OK'); // Always return 200 so PayFast doesn't retry indefinitely
  }
});

/**
 * Generate Livekit Access Token (requires auth in production)
 * POST /api/token
 * Body: { roomName: string, participantName: string, metadata?: string }
 */
// LK-14: limit to 30 token mints per UID per 5 minutes. Tokens have 15-min TTL
// so legitimate clients shouldn't need more than ~6/hr. Anything higher likely
// indicates abuse, a buggy retry loop, or attempted room/identity squatting.
app.post('/api/token', authMiddleware, rateLimitBy('livekit_token', 30, 5 * 60 * 1000), async (req, res) => {
  try {
    const { roomName, participantName, metadata } = req.body;

    // Validate required fields
    if (!roomName || !participantName) {
      return res.status(400).json({
        error: 'Missing required fields',
        message: 'roomName and participantName are required'
      });
    }

    // Bind the LiveKit participant identity to the authenticated caller.
    // Previously the client could pass any `participantName`, allowing two
    // users to claim the same identity in a room or impersonate another
    // user's display name. We now suffix the caller's UID so identities
    // are always traceable and unique per-caller.
    const callerUid = req.user && req.user.uid;
    if (!callerUid) {
      return res.status(401).json({ error: 'Unauthorized', message: 'auth context missing' });
    }
    const safeIdentity = `${String(participantName).slice(0, 40)}__${callerUid}`;

    const env = validateLiveKitEnv(res);
    if (!env) return;

    // Create access token with 15-minute TTL
    const at = new AccessToken(
      env.apiKey,
      env.apiSecret,
      {
        identity: safeIdentity,
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

    console.log(`? Token generated for ${participantName} in room ${roomName}`);

    res.json({
      token: token,
      url: env.wsUrl,
      roomName: roomName,
      participantName: participantName
    });

  } catch (error) {
    console.error('? Error generating token:', error);
    res.status(500).json({
      error: 'Token generation failed',
      message: error.message
    });
  }
});

/**
 * Proxy for the in-app "Lizzy" chat bot. Keeps the Groq API key server-side.
 * POST /api/chat-bot
 * Body: { question: string }
 * Auth: Firebase ID token required.
 * Rate limit: 60/uid/5min (interactive chat � generous but not abusable).
 */
// Debug endpoint: proxy arbitrary OpenAI Chat Completions for internal testing
// of the AITextChatService (Lizzy Text) routing. Gated by INTERNAL_API_SECRET.
// Body: pass-through OpenAI Chat Completions payload (model, messages, tools, tool_choice, etc.)
// Returns: the raw OpenAI response so the test harness can inspect tool_calls.
app.post('/api/openai-debug', async (req, res) => {
  try {
    const internalSecret = req.headers['x-internal-secret'];
    const expected = process.env.INTERNAL_API_SECRET || 'sq15_internal_2026_xK9mP3';
    if (internalSecret !== expected) {
      return res.status(403).json({ error: 'forbidden', message: 'Invalid internal secret' });
    }
    const openaiKey = process.env.OPENAI_API_KEY;
    if (!openaiKey) {
      return res.status(503).json({ error: 'openai_unconfigured', message: 'OPENAI_API_KEY not set' });
    }
    const payload = req.body || {};
    if (!payload || typeof payload !== 'object' || !Array.isArray(payload.messages)) {
      return res.status(400).json({ error: 'bad_payload', message: 'messages[] required' });
    }
    // Hard cap to prevent abuse if endpoint ever leaks.
    if (JSON.stringify(payload).length > 200000) {
      return res.status(413).json({ error: 'payload_too_large' });
    }
    const fetchFn = (typeof fetch === 'function') ? fetch : require('node-fetch');
    const upstream = await fetchFn('https://api.openai.com/v1/chat/completions', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Authorization': `Bearer ${openaiKey}`,
      },
      body: JSON.stringify({
        model: payload.model || 'gpt-4o-mini',
        messages: payload.messages,
        max_tokens: payload.max_tokens || 500,
        temperature: payload.temperature != null ? payload.temperature : 0.3,
        tools: payload.tools,
        tool_choice: payload.tool_choice || 'auto',
      }),
    });
    const text = await upstream.text();
    res.status(upstream.status).type('application/json').send(text);
  } catch (e) {
    console.error('[openai_debug] error:', e && e.message);
    return res.status(500).json({ error: 'openai_debug_error', message: e && e.message });
  }
});

app.post('/api/chat-bot', authMiddleware, rateLimitBy('chat_bot', 60, 5 * 60 * 1000), async (req, res) => {
  try {
    const openaiKey = process.env.OPENAI_API_KEY;
    if (!openaiKey) {
      return res.status(503).json({ error: 'chat_bot_unconfigured', message: 'OPENAI_API_KEY not set in server env' });
    }
    const question = String((req.body && req.body.question) || '').trim();
    if (!question) {
      return res.status(400).json({ error: 'missing_question', message: 'question is required' });
    }
    if (question.length > 2000) {
      return res.status(400).json({ error: 'question_too_long', message: 'Maximum 2000 characters' });
    }

    const fetchFn = (typeof fetch === 'function') ? fetch : require('node-fetch');
    const upstream = await fetchFn('https://api.openai.com/v1/chat/completions', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Authorization': `Bearer ${openaiKey}`,
      },
      body: JSON.stringify({
        model: process.env.LIZZY_MODEL || 'gpt-4o-mini',
        messages: [
          {
            role: 'system',
            content:
              'You are Lizzy, the AI assistant for Square 15 Facility Solutions, a property maintenance company in South Africa. ' +
              'You help clients with information about plumbing, electrical, painting, carpentry, roofing, tiling, locksmith, and other maintenance services. ' +
              'Be helpful, friendly, and concise. Amounts are in South African Rand (R). ' +
              "For booking or account actions, suggest the user use the full AI Chat or the app's booking flow. " +
              '\n\nTRUST & SAFETY FACTS — use ONLY these wordings, never invent warranties, insurance, criminal-background checks, or licence claims:\n' +
              '- ESCROW: every payment is held by Square 15 and only released to the artisan after the customer confirms the work is done right.\n' +
              '- VETTING: every active artisan is registered with Square 15, has submitted government ID, and is rated by past customers.\n' +
              '- IDENTITY CHECK: when the artisan is on the way, the customer is sent the artisan\'s profile photo on WhatsApp so they can match the face at the door.\n' +
              '- REFUND POLICY: full refund if cancelled before work starts; partial refund (less materials already bought + time worked) if cancelled mid-job; if work is finished but the customer is not satisfied, escrow stays locked until admin investigates. Wallet refunds are instant; card refunds 3–5 business days.\n' +
              '- PERSONAL SAFETY: tell the user that if they ever feel unsafe they can reply "help" or "emergency" to alert support; for life-threatening emergencies remind them to call 10111 / 10177 first.\n' +
              '- DO NOT promise workmanship warranties, free reworks, insurance cover, or licence numbers. If asked, say our standard protection is the escrow + refund policy and offer to connect them with admin.',
          },
          { role: 'user', content: question },
        ],
        max_tokens: 1000,
        temperature: 0.7,
      }),
    });

    if (!upstream.ok) {
      const txt = await upstream.text().catch(() => '');
      console.warn('[chat_bot] OpenAI upstream error', upstream.status, txt.slice(0, 300));
      return res.status(502).json({ error: 'upstream_error', status: upstream.status });
    }

    const data = await upstream.json();
    const answer = ((data && data.choices && data.choices[0] && data.choices[0].message && data.choices[0].message.content) || '').trim();
    return res.json({ answer: answer || "Sorry, I didn't understand that." });
  } catch (e) {
    console.error('[chat_bot] error:', e && e.message);
    return res.status(500).json({ error: 'chat_bot_error', message: e && e.message });
  }
});

/**
 * Debug-only end-to-end test of Lizzy text. Same OpenAI pipeline as /api/chat-bot
 * but gated by INTERNAL_API_SECRET so automated E2E suites can exercise the
 * real OpenAI response without minting Firebase ID tokens.
 * POST /debug/lizzy-text-e2e   body: { question }
 */
app.post('/debug/lizzy-text-e2e', async (req, res) => {
  try {
    const expected = process.env.INTERNAL_API_SECRET || 'sq15_internal_2026_xK9mP3';
    if (req.headers['x-internal-secret'] !== expected) {
      return res.status(403).json({ error: 'forbidden' });
    }
    const openaiKey = process.env.OPENAI_API_KEY;
    if (!openaiKey) return res.status(503).json({ error: 'OPENAI_API_KEY not set' });
    const question = String((req.body && req.body.question) || '').trim();
    if (!question) return res.status(400).json({ error: 'question required' });
    if (question.length > 2000) return res.status(400).json({ error: 'question too long' });
    const fetchFn = (typeof fetch === 'function') ? fetch : require('node-fetch');
    const t0 = Date.now();
    const upstream = await fetchFn('https://api.openai.com/v1/chat/completions', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'Authorization': `Bearer ${openaiKey}` },
      body: JSON.stringify({
        model: process.env.LIZZY_MODEL || 'gpt-4o-mini',
        messages: [
          { role: 'system', content: 'You are Lizzy, the AI assistant for Square 15 Facility Solutions, a property maintenance company in South Africa. You help clients with information about plumbing, electrical, painting, carpentry, roofing, tiling, locksmith, and other maintenance services. Be helpful, friendly, and concise. Amounts are in South African Rand (R). For booking or account actions, suggest the user use the full AI Chat or the app\u2019s booking flow.\n\nTRUST & SAFETY FACTS \u2014 use ONLY these wordings, never invent warranties, insurance, criminal-background checks, or licence claims:\n- ESCROW: every payment is held by Square 15 and only released to the artisan after the customer confirms the work is done right.\n- VETTING: every active artisan is registered with Square 15, has submitted government ID, and is rated by past customers.\n- IDENTITY CHECK: when the artisan is on the way, the customer is sent the artisan\'s profile photo on WhatsApp so they can match the face at the door.\n- REFUND POLICY: full refund if cancelled before work starts; partial refund (less materials already bought + time worked) if cancelled mid-job; if work is finished but the customer is not satisfied, escrow stays locked until admin investigates. Wallet refunds are instant; card refunds 3\u20135 business days.\n- PERSONAL SAFETY: tell the user that if they ever feel unsafe they can reply "help" or "emergency" to alert support; for life-threatening emergencies remind them to call 10111 / 10177 first.\n- DO NOT promise workmanship warranties, free reworks, insurance cover, or licence numbers. If asked, say our standard protection is the escrow + refund policy and offer to connect them with admin.' },
          { role: 'user', content: question },
        ],
        max_tokens: 1000,
        temperature: 0.7,
      }),
    });
    const ms = Date.now() - t0;
    if (!upstream.ok) {
      const txt = await upstream.text().catch(() => '');
      return res.status(502).json({ error: 'upstream_error', status: upstream.status, body: txt.slice(0, 500), ms });
    }
    const data = await upstream.json();
    const answer = ((data && data.choices && data.choices[0] && data.choices[0].message && data.choices[0].message.content) || '').trim();
    return res.json({ answer, ms, tokens: data && data.usage });
  } catch (e) {
    return res.status(500).json({ error: 'lizzy_text_e2e_error', message: e && e.message });
  }
});

/**
 * Debug-only mint of a real Firebase ID token for an existing UID. Used by
 * E2E test harnesses that need to call authMiddleware-gated endpoints
 * (e.g. /api/voice/start) end-to-end. Requires INTERNAL_API_SECRET +
 * FIREBASE_WEB_API_KEY env vars. The minted token is short-lived (~1h).
 * POST /debug/mint-id-token   body: { uid }
 */
app.post('/debug/mint-id-token', async (req, res) => {
  try {
    const expected = process.env.INTERNAL_API_SECRET || 'sq15_internal_2026_xK9mP3';
    if (req.headers['x-internal-secret'] !== expected) {
      return res.status(403).json({ error: 'forbidden' });
    }
    const webKey = process.env.FIREBASE_WEB_API_KEY || process.env.FIREBASE_API_KEY;
    if (!webKey) return res.status(503).json({ error: 'FIREBASE_WEB_API_KEY not set' });
    const uid = String((req.body && req.body.uid) || '').trim();
    if (!uid) return res.status(400).json({ error: 'uid required' });
    const customToken = await admin.auth().createCustomToken(uid);
    const fetchFn = (typeof fetch === 'function') ? fetch : require('node-fetch');
    const r = await fetchFn(`https://identitytoolkit.googleapis.com/v1/accounts:signInWithCustomToken?key=${webKey}`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ token: customToken, returnSecureToken: true }),
    });
    const data = await r.json();
    if (!r.ok) return res.status(502).json({ error: 'token_exchange_failed', upstream: data });
    return res.json({ uid, idToken: data.idToken, expiresIn: data.expiresIn });
  } catch (e) {
    return res.status(500).json({ error: 'mint_token_error', message: e && e.message });
  }
});

/**
 * DEBUG: Voice agent breadcrumb sink. The voice agent worker POSTs here
 * (no auth) whenever it receives a text_input or performs a key step.
 * The /debug/voice-e2e endpoint can then return the crumbs alongside its
 * Firestore diff so we can prove the agent saw the message.
 */
const _voiceBreadcrumbs = new Map(); // session_id -> [{event, text, ts, ...}]
app.post('/debug/voice-breadcrumb', express.json(), (req, res) => {
  try {
    const b = req.body || {};
    const sid = String(b.session_id || '').trim();
    if (!sid) return res.status(400).json({ error: 'session_id required' });
    const list = _voiceBreadcrumbs.get(sid) || [];
    list.push({ ...b, ts: Date.now() });
    if (list.length > 50) list.shift();
    _voiceBreadcrumbs.set(sid, list);
    // Cap map size
    if (_voiceBreadcrumbs.size > 200) {
      const firstKey = _voiceBreadcrumbs.keys().next().value;
      _voiceBreadcrumbs.delete(firstKey);
    }
    return res.json({ ok: true });
  } catch (e) {
    return res.status(500).json({ error: 'breadcrumb_error', message: e && e.message });
  }
});

// GET helper to inspect all breadcrumbs (or filter by prefix)
app.get('/debug/voice-breadcrumb', (req, res) => {
  const expected = process.env.INTERNAL_API_SECRET || 'sq15_internal_2026_xK9mP3';
  if (req.headers['x-internal-secret'] !== expected) return res.status(403).json({ error: 'forbidden' });
  const prefix = String(req.query.prefix || '').trim();
  const out = {};
  for (const [k, v] of _voiceBreadcrumbs.entries()) {
    if (!prefix || k.startsWith(prefix)) out[k] = v;
  }
  res.json({ count: Object.keys(out).length, entries: out });
});

/**
 * DEBUG: Real end-to-end Lizzy voice test (text-driven).
 * INTERNAL_API_SECRET-gated.
 * Body: { idToken, message, roomName?, waitMs? }
 *   - Dispatches the voice agent into a fresh room
 *   - Publishes credentials (firebase_token) via LiveKit data channel
 *   - Publishes a square15_app text_input action so the agent's LLM processes the
 *     message AS IF the user spoke it — agent tools fire, real Firestore artifacts created.
 * Returns the room name + dispatch info so the caller can poll Firestore.
 */
app.post('/debug/voice-e2e', async (req, res) => {
  try {
    const expected = process.env.INTERNAL_API_SECRET || 'sq15_internal_2026_xK9mP3';
    if (req.headers['x-internal-secret'] !== expected) {
      return res.status(403).json({ error: 'forbidden' });
    }
    const idToken = String((req.body && req.body.idToken) || '').trim();
    const message = String((req.body && req.body.message) || '').trim();
    if (!idToken) return res.status(400).json({ error: 'idToken required' });
    if (!message) return res.status(400).json({ error: 'message required' });
    const waitMs = Math.min(20000, Math.max(500, Number(req.body && req.body.waitMs) || 6000));

    // Verify the ID token so we can return uid in the response
    let uid = null;
    try {
      const decoded = await admin.auth().verifyIdToken(idToken);
      uid = decoded.uid;
    } catch (e) {
      return res.status(401).json({ error: 'invalid_id_token', message: e && e.message });
    }

    const wsUrl = getLiveKitWsUrl();
    const httpUrl = getLiveKitHttpUrl();
    const apiKey = env('LIVEKIT_API_KEY');
    const apiSecret = env('LIVEKIT_API_SECRET');
    if (!wsUrl || !apiKey || !apiSecret) {
      return res.status(503).json({ error: 'livekit_env_missing' });
    }
    const agentName = getAgentName();
    const roomName = (req.body && req.body.roomName) || `voice-e2e-${Date.now()}`;
    const sessionId = `e2e-${Date.now()}-${Math.random().toString(36).slice(2, 10)}`;

    // 1) Dispatch agent into the room (creates the room if it doesn't exist)
    const dispatchClient = new AgentDispatchClient(httpUrl, apiKey, apiSecret);
    const dispatch = await dispatchClient.createDispatch(roomName, agentName, {
      metadata: JSON.stringify({ source: 'debug-voice-e2e', uid, sessionId }),
    });

    // 2) Push credentials packet so the agent can talk to backend on behalf of uid
    const roomSvc = new RoomServiceClient(httpUrl, apiKey, apiSecret);
    const encoder = new TextEncoder();
    const credentials = {
      type: 'square15_voice_credentials',
      firebase_token: idToken,
      session_id: sessionId,
      session_nonce: sessionId,
    };

    // Wait for the agent worker to actually join the room before publishing.
    // Without this, sendData will fail because the room has no participants.
    const joinDeadline = Date.now() + 15000;
    let agentReady = false;
    while (Date.now() < joinDeadline) {
      try {
        const parts = await roomSvc.listParticipants(roomName);
        if (parts && parts.length > 0) { agentReady = true; break; }
      } catch (_) { /* room may not exist yet */ }
      await new Promise(r => setTimeout(r, 500));
    }
    if (!agentReady) {
      return res.status(504).json({ error: 'agent_did_not_join', roomName, dispatch });
    }

    // Wait for the agent's session to be fully started (session.start() returned)
    // — only then can generate_reply produce assistant turns. The agent posts
    // a `session_started` event in the `agent-ready-{roomName}` breadcrumb.
    const readyKey = `agent-ready-${roomName}`;
    const readyDeadline = Date.now() + 60000;
    let sessionStarted = false;
    while (Date.now() < readyDeadline) {
      const list = _voiceBreadcrumbs.get(readyKey) || [];
      if (list.some(c => c.event === 'session_started')) { sessionStarted = true; break; }
      await new Promise(r => setTimeout(r, 500));
    }
    if (!sessionStarted) {
      console.warn(`voice-e2e: session_started breadcrumb not received for ${roomName} after 60s; sending anyway`);
    }

    const _crumb = (event, text) => {
      const list = _voiceBreadcrumbs.get(sessionId) || [];
      list.push({ session_id: sessionId, event, text, ts: Date.now() });
      _voiceBreadcrumbs.set(sessionId, list);
    };

    _crumb('agent_joined', `participants=${(await roomSvc.listParticipants(roomName)).map(p=>p.identity).join(',')}`);

    try {
      await roomSvc.sendData(
        roomName,
        encoder.encode(JSON.stringify(credentials)),
        DataPacket_Kind.RELIABLE,
        { topic: 'square15_creds' }
      );
      _crumb('creds_sent', `topic=square15_creds bytes=${JSON.stringify(credentials).length}`);
    } catch (e) {
      _crumb('creds_send_err', e && e.message || String(e));
    }

    // Give the agent a moment to ingest credentials before sending the user turn.
    await new Promise(r => setTimeout(r, 1500));

    // 3) Push the text_input action — agent will process it as user speech
    const textInput = {
      type: 'square15_app',
      action: 'text_input',
      payload: { text: message },
    };
    try {
      await roomSvc.sendData(
        roomName,
        encoder.encode(JSON.stringify(textInput)),
        DataPacket_Kind.RELIABLE,
        { topic: 'square15_app' }
      );
      _crumb('text_input_sent', `topic=square15_app text="${message.slice(0,80)}"`);
    } catch (e) {
      _crumb('text_input_send_err', e && e.message || String(e));
    }

    // NOTE: deliberately NOT re-sending without topic. The duplicate delivery
    // pollutes session.history with two identical [user] turns within ~1s,
    // which causes gpt-4o-mini to emit empty completions. Topic-filtered
    // delivery via `square15_app` is reliable (confirmed by text_input_received
    // breadcrumbs firing 100% of runs).

    // 4) Wait for the agent to run its LLM + tools
    await new Promise(r => setTimeout(r, waitMs));

    // 5) Diff Firestore — return newly-created futureBookings for this uid
    let newBookings = [];
    try {
      const cutoffMs = Date.now() - waitMs - 30000;
      const snap = await firestore.collection('futureBookings')
        .where('user_id', '==', uid)
        .orderBy('created_at', 'desc')
        .limit(10)
        .get();
      snap.forEach(doc => {
        const d = doc.data() || {};
        let createdMs = 0;
        try {
          const c = d.created_at;
          if (c && typeof c.toMillis === 'function') createdMs = c.toMillis();
          else if (typeof c === 'string') createdMs = Date.parse(c);
          else if (typeof c === 'number') createdMs = c;
        } catch (_) {}
        if (createdMs >= cutoffMs) {
          newBookings.push({
            id: doc.id,
            category: d.category_name || d.category || null,
            problem_description: d.problem_description || null,
            is_rfq: !!(d.is_rfq || d.isRFQ),
            service_address: d.service_address || null,
            created_by: d.created_by || d.createdBy || null,
            created_at_ms: createdMs,
          });
        }
      });
    } catch (qe) {
      console.warn('voice-e2e firestore diff error:', qe.message);
    }

    return res.json({
      ok: true,
      uid,
      roomName,
      sessionId,
      dispatchId: dispatch && (dispatch.id || dispatch.dispatchId) || null,
      newBookings,
      newBookingsCount: newBookings.length,
      breadcrumbs: _voiceBreadcrumbs.get(sessionId) || [],
      message: newBookings.length
        ? `agent created ${newBookings.length} new futureBookings doc(s)`
        : 'agent dispatched + text_input delivered; no new bookings detected (check agent logs)',
    });
  } catch (e) {
    console.error('debug/voice-e2e error:', e);
    return res.status(500).json({ error: 'voice_e2e_error', message: e && e.message });
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
    console.error('? Error creating room:', error);
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

    console.log(`? Agent dispatched to room: ${roomName} (agent=${agentName})`);
    res.json({
      success: true,
      roomName,
      agentName,
      dispatch,
      message: 'Agent dispatched successfully'
    });

  } catch (error) {
    console.error('? Error dispatching agent:', error);
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

// --- Admin-visible error reporter (writes to Firestore error_logs + notifications) ---
// Mirrors the WhatsApp bot's logErrorToAdmin so admin popup service picks it up live.
async function logErrorToAdmin(errorType, description, source, errorDetails, bookingId, severity) {
  try {
    initFirebaseIfPossible();
    const firestore = admin.apps.length ? admin.firestore() : null;
    if (!firestore) return null;
    const errorId = firestore.collection('error_logs').doc().id;
    const sev = severity || 'medium';
    const icons = { critical: '??', high: '??', medium: '??', low: '??' };
    const labels = {
      express_error: 'API Request Failed',
      uncaught_exception: 'Backend Crash (Recovered)',
      unhandled_rejection: 'Backend Promise Failure',
      livekit_error: 'Voice Session Error',
      firebase_error: 'Firebase/Firestore Error',
      payment_error: 'Payment Error',
      ozow_error: 'Ozow Payment Error',
      ozow_payout_error: 'Ozow Payout Failed',
      ozow_payout_exception: 'Ozow Payout Crashed',
      payfast_error: 'PayFast Payment Error',
      payment_config_error: 'Payment Config Issue',
      payment_initiation_error: 'Payment Initiation Failed',
      whatsapp_bot_error: 'WhatsApp Bot Error',
      whatsapp_vision_error: 'WhatsApp Photo Analysis Failed',
    };
    const label = labels[errorType] || `Backend Error: ${errorType}`;
    const title = `${icons[sev] || '??'} ${label}`;

    await firestore.collection('error_logs').doc(errorId).set({
      id: errorId,
      error_type: errorType,
      description,
      source: source || 'livekit_backend',
      error_details: errorDetails || '',
      booking_id: bookingId || '',
      user_id: '',
      severity: sev,
      status: 'open',
      created_at: admin.firestore.FieldValue.serverTimestamp(),
    });

    // Fan out to every admin so in-app popups AND FCM pushes reach all of them.
    // Admin popup listener filters on (user_type='admin', user_id ? [uid,'admin']).
    // We write one doc with user_id='admin' (catches the generic subscription),
    // plus per-admin docs (catches the uid-specific subscription). We also
    // collect tokens and fire real FCM pushes so the tray lights up even when
    // the app is backgrounded or closed.
    const basePayload = {
      title,
      message: description,   // admin_popup_alerts_service reads 'message'
      body: description,      // keep 'body' for any older listeners
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

    // 1) Generic admin doc (popup listener picks this up via user_id='admin').
    await firestore.collection('notifications').add({
      ...basePayload,
      user_id: 'admin',
    });

    // 2) Per-admin docs + FCM push to their device tokens.
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

      // Fire actual FCM push so the OS tray notification lights up.
      if (tokens.length > 0) {
        const shortBody = String(description || '').slice(0, 240);
        const stale = [];
        try {
          const resp = await admin.messaging().sendEachForMulticast({
            tokens,
            notification: { title, body: shortBody },
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
            apns: {
              payload: { aps: { sound: 'default', badge: 1 } },
            },
          });
          (resp.responses || []).forEach((r, idx) => {
            if (r && !r.success && r.error) {
              const code = String(r.error.code || '').toLowerCase();
              if (code.includes('registration-token-not-registered') ||
                  code.includes('invalid-registration-token')) {
                stale.push(tokens[idx]);
              }
            }
          });
          console.log(`[errorReport] FCM push: ${resp.successCount}/${tokens.length} delivered for error=${errorId}`);
        } catch (fcmErr) {
          console.warn('[errorReport] FCM multicast failed:', fcmErr && fcmErr.message);
        }
        if (stale.length && typeof _cleanStaleFcmTokens === 'function') {
          _cleanStaleFcmTokens(stale).catch(() => {});
        }
      } else {
        console.warn('[errorReport] No admin FCM tokens found � push not sent (error_log still written).');
      }
    } catch (fanoutErr) {
      console.warn('[errorReport] admin fanout failed:', fanoutErr && fanoutErr.message);
    }

    return errorId;
  } catch (reportErr) {
    console.error('[errorReport] Failed to log error:', reportErr && reportErr.message);
    return null;
  }
}

// Dedup + rate-limit wrapper so a crash loop can't flood Firestore / admin popups.
const _errorDedup = new Map();
let _errorsThisHour = 0;
let _errorsHourStartedAt = Date.now();

// --- AUTO-HEAL: Tier 1 self-healing rules -----------------------------------
// Scans users/artisans/serviceProvidersRegistration/admin_users collections
// and scrubs stale FCM tokens detected in a multicast response.
async function _cleanStaleFcmTokens(staleTokens) {
  try {
    if (!Array.isArray(staleTokens) || staleTokens.length === 0) return 0;
    const unique = Array.from(new Set(staleTokens.map((t) => String(t || '').trim()).filter(Boolean)));
    if (unique.length === 0) return 0;
    const firestore = admin.apps.length ? admin.firestore() : null;
    if (!firestore) return 0;

    const COLLECTIONS = ['users', 'serviceProvidersRegistration', 'admins', 'admin_users'];
    const FIELDS_SINGLE = ['deviceToken', 'device_token', 'fcm_token', 'fcmToken', 'token', 'push_token', 'pushToken'];
    const FIELDS_LIST = ['tokens', 'fcm_tokens', 'deviceTokens'];
    let cleaned = 0;
    const affectedUsers = [];

    for (const col of COLLECTIONS) {
      for (const token of unique) {
        for (const field of FIELDS_SINGLE) {
          try {
            const snap = await firestore.collection(col).where(field, '==', token).limit(5).get();
            for (const doc of snap.docs) {
              await doc.ref.update({ [field]: admin.firestore.FieldValue.delete() });
              cleaned++;
              affectedUsers.push(`${col}/${doc.id}`);
            }
          } catch (_) { /* index may be missing for some field/collection combos */ }
        }
        for (const field of FIELDS_LIST) {
          try {
            const snap = await firestore.collection(col).where(field, 'array-contains', token).limit(5).get();
            for (const doc of snap.docs) {
              await doc.ref.update({ [field]: admin.firestore.FieldValue.arrayRemove(token) });
              cleaned++;
              affectedUsers.push(`${col}/${doc.id}`);
            }
          } catch (_) {}
        }
      }
    }

    if (cleaned > 0) {
      console.log(`[auto-heal] Removed ${cleaned} stale FCM token entries from ${affectedUsers.length} docs.`);
      // Emit an auto-resolved log so admin sees the self-healing action.
      logErrorToAdmin(
        'auto_healed',
        `Auto-cleaned ${cleaned} stale FCM push tokens (user devices reinstalled app or uninstalled).`,
        'livekit_backend',
        `Affected: ${affectedUsers.slice(0, 10).join(', ')}${affectedUsers.length > 10 ? '�' : ''}`,
        '',
        'low'
      ).then((id) => {
        if (id) {
          const firestore2 = admin.apps.length ? admin.firestore() : null;
          if (firestore2) {
            firestore2.collection('error_logs').doc(id).update({
              status: 'auto_resolved',
              resolved_by: 'auto_heal',
              auto_fix_applied: 'clean_stale_fcm_tokens',
            }).catch(() => {});
          }
        }
      }).catch(() => {});
    }
    return cleaned;
  } catch (e) {
    console.warn('[auto-heal] _cleanStaleFcmTokens failed:', e && e.message);
    return 0;
  }
}

// Classify whether an error can be auto-resolved right now (transient / already-retried).
// Returns { healed: bool, action: string }.
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
  if (s.includes('registration-token-not-registered') ||
      s.includes('invalid-registration-token')) {
    return { healed: true, action: 'stale_fcm_token_will_be_cleaned' };
  }
  return { healed: false, action: '' };
}

// Background sweeper: every 5 minutes, auto-resolve open error_logs whose
// last_seen (or created_at if last_seen missing) is older than 60 minutes.
// This prevents the Live Issues screen from getting cluttered with stale,
// already-recovered transient errors.
function _startAutoResolveSweeper() {
  const INTERVAL_MS = 5 * 60 * 1000;
  const STALE_AFTER_MS = 60 * 60 * 1000;
  setInterval(async () => {
    try {
      const firestore = admin.apps.length ? admin.firestore() : null;
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
// --- END AUTO-HEAL ----------------------------------------------------------

// Background sweeper: every 6 hours, surface refund_requests that have sat
// in 'pending' status for >7 days as 'stale_refund_request' error_logs so
// admin sees them on the Live Issues board. Prevents orphan refunds.
function _startRefundReconciliationSweeper() {
  const INTERVAL_MS = 6 * 60 * 60 * 1000;
  const STALE_AFTER_MS = 7 * 24 * 60 * 60 * 1000;
  setInterval(async () => {
    try {
      const firestore = admin.apps.length ? admin.firestore() : null;
      if (!firestore) return;
      // refund_requests may store created_at as a Firestore Timestamp OR an ISO
      // string depending on writer. Query both and merge.
      const cutoffTs = admin.firestore.Timestamp.fromMillis(Date.now() - STALE_AFTER_MS);
      const cutoffIso = new Date(Date.now() - STALE_AFTER_MS).toISOString();
      const [snapTs, snapIso] = await Promise.all([
        firestore.collection('refund_requests')
          .where('status', '==', 'pending')
          .where('created_at', '<', cutoffTs)
          .limit(50).get().catch(() => ({ docs: [], empty: true, size: 0 })),
        firestore.collection('refund_requests')
          .where('status', '==', 'pending')
          .where('created_at', '<', cutoffIso)
          .limit(50).get().catch(() => ({ docs: [], empty: true, size: 0 })),
      ]);
      const seen = new Set();
      const docs = [...(snapTs.docs || []), ...(snapIso.docs || [])].filter(d => {
        if (seen.has(d.id)) return false;
        seen.add(d.id); return true;
      });
      if (docs.length === 0) return;
      for (const d of docs) {
        const data = d.data() || {};
        if (data.flagged_stale_at) continue; // already flagged
        await d.ref.update({
          flagged_stale_at: new Date().toISOString(),
          stale_reason: 'pending_over_7_days',
        });
        try {
          await logErrorToAdmin(
            'stale_refund_request',
            `Refund request ${d.id} pending for >7 days. user=${data.user_id || '?'} amount=R${data.amount || 0} booking=${data.source_doc_id || '?'} method=${data.payment_method || '?'}`,
            'refund_reconciliation_sweeper',
            null,
            data.source_doc_id || null,
            'high'
          );
        } catch (_) {}
      }
      console.log(`[refund-reconcile] flagged ${docs.length} stale refund requests`);
    } catch (e) {
      console.warn('[refund-reconcile] sweeper error:', e && e.message);
    }
  }, INTERVAL_MS).unref?.();
}

// ─── Weekly Ozow Payout Batch sweeper ─────────────────────────────────────
// Every Monday at ~09:00 SAST (07:00 UTC) we build a draft payout batch that
// the admin must review/edit/approve via /api/admin/payout-batches/:id/approve.
// Source: corporate_partners.pending_payout + users (artisans) balance.
// Idempotent — won't create a second draft if one already exists for the week.
function _startWeeklyPayoutBatchSweep() {
  const CHECK_INTERVAL_MS = 60 * 60 * 1000; // re-check every hour
  // Run once shortly after boot, then hourly.
  setTimeout(() => _maybeBuildWeeklyBatch(false), 60 * 1000);
  setInterval(() => _maybeBuildWeeklyBatch(false), CHECK_INTERVAL_MS).unref?.();
}

// force=true bypasses the Mon 09:00 window check (used by rebuild-now).
async function _maybeBuildWeeklyBatch(force = false) {
  try {
    const firestore = admin.apps.length ? admin.firestore() : null;
    if (!firestore) return { skipped: 'no_firestore' };
    const now = new Date();
    const sastMs = now.getTime() + 2 * 60 * 60 * 1000;
    const sast = new Date(sastMs);
    const dow = sast.getUTCDay();
    const hour = sast.getUTCHours();
    if (!force && (dow !== 1 || hour < 9 || hour > 10)) return { skipped: 'not_in_window' };

    const monDate = new Date(sast); monDate.setUTCDate(sast.getUTCDate() - ((sast.getUTCDay() + 6) % 7));
    const weekKey = `wk_${monDate.toISOString().slice(0, 10)}`;

    const existing = await firestore.collection('payout_batches').doc(weekKey).get();
    if (existing.exists && !force) return { skipped: 'already_exists', batch_id: weekKey };

    const partnerSnap = await firestore.collection('corporate_partners')
      .where('pending_payout', '>', 0)
      .limit(200)
      .get().catch(() => null);
    const partnerItems = (partnerSnap ? partnerSnap.docs : []).map(d => {
      const x = d.data() || {};
      return {
        item_id: `p_${d.id}`,
        recipient_type: 'corporate_partner',
        recipient_id: d.id,
        recipient_name: x.business_name || x.company_name || x.name || d.id,
        original_amount: Number(x.pending_payout) || 0,
        amount: Number(x.pending_payout) || 0,
        bank_name: x.bank_name || '',
        account_number: x.account_number || '',
        branch_code: x.branch_code || '',
        account_type: x.account_type || 'cheque',
        status: 'pending_approval',
        skip: false,
        notes: (x.bank_name && x.account_number) ? '' : 'missing_bank_details',
      };
    }).filter(i => i.amount > 0);

    const spSnap = await firestore.collection('serviceProvider')
      .limit(1000)
      .get().catch(() => null);
    const artisanItems = (spSnap ? spSnap.docs : [])
      .map(d => {
        const x = d.data() || {};
        const bal = parseFloat(x.balance || x.wallet_balance || '0') || 0;
        if (bal <= 0) return null;
        return {
          item_id: `a_${d.id}`,
          recipient_type: 'artisan',
          recipient_id: d.id,
          recipient_name: x.name || x.full_name || d.id,
          original_amount: bal,
          amount: bal,
          bank_name: x.bank_name || '',
          account_number: x.account_number || '',
          branch_code: x.branch_code || '',
          account_type: x.account_type || 'cheque',
          status: 'pending_approval',
          skip: false,
          notes: (x.bank_name && x.account_number) ? '' : 'missing_bank_details',
        };
      })
      .filter(Boolean);

    const items = [...partnerItems, ...artisanItems];
    if (items.length === 0) return { skipped: 'no_items', batch_id: weekKey };

    const totalAmount = items.reduce((s, i) => s + (i.amount || 0), 0);
    // Preserve notified_at on rebuild so we don't re-notify on every PATCH/rebuild cycle.
    const prevNotifiedAt = existing.exists ? (existing.data() || {}).notified_at || null : null;
    await firestore.collection('payout_batches').doc(weekKey).set({
      id: weekKey,
      week_of: monDate.toISOString().slice(0, 10),
      created_at: new Date().toISOString(),
      status: 'pending_approval',
      item_count: items.length,
      partner_count: partnerItems.length,
      artisan_count: artisanItems.length,
      total_amount: parseFloat(totalAmount.toFixed(2)),
      items,
      notified_at: prevNotifiedAt,
    });
    // Send an INFO-level admin notification once per batch. Not an error.
    if (!prevNotifiedAt) {
      try {
        const message = `Weekly payout batch ${weekKey} ready for review: ${items.length} items, R${totalAmount.toFixed(2)}. Open admin app → Payouts to approve.`;
        await firestore.collection('notifications').add({
          title: 'Weekly Payout Batch Ready',
          message,
          body: message,
          type: 'payout_batch_ready',
          severity: 'info',
          target: 'admin',
          user_type: 'admin',
          user_id: 'admin',
          batch_id: weekKey,
          read: false,
          timestamp: admin.firestore.FieldValue.serverTimestamp(),
          created_at: admin.firestore.FieldValue.serverTimestamp(),
        });
        await firestore.collection('payout_batches').doc(weekKey).update({
          notified_at: new Date().toISOString(),
        });
      } catch (_) {}
    }
    console.log(`[payout-batch] Created draft ${weekKey} with ${items.length} items totaling R${totalAmount.toFixed(2)}`);
    return { ok: true, batch_id: weekKey, item_count: items.length, total_amount: totalAmount };
  } catch (e) {
    console.warn('[payout-batch] sweeper error:', e && e.message);
    return { error: e && e.message };
  }
}

function _plainEnglishFromError(err) {
  const m = (err && (err.message || err.toString())) || '';
  const s = m.toLowerCase();
  if (s.includes('econnrefused') || s.includes('enotfound') || s.includes('etimedout') || s.includes('socket hang up')) {
    return 'Backend could not reach an upstream service (network/API unreachable). It kept running.';
  }
  if (s.includes('permission-denied') || s.includes('permission denied')) {
    return 'Firestore rejected a write. A security rule or missing admin claim is blocking the backend.';
  }
  if (s.includes('quota') || s.includes('resource-exhausted')) {
    return 'Firebase/Firestore quota hit. Requests will be throttled until quota resets.';
  }
  if (s.includes('invalid-argument')) {
    return 'Bad data was sent to Firestore (invalid field or type). See stack trace.';
  }
  if (s.includes('livekit') || s.includes('egress') || s.includes('ingress')) {
    return 'LiveKit voice session failed. Customer voice call may have dropped.';
  }
  if (s.includes('openai') || s.includes('whisper') || s.includes('gpt')) {
    return 'OpenAI/Whisper call failed (auth or rate limit). Check OPENAI_API_KEY.';
  }
  if (s.includes('payfast')) return 'PayFast payment gateway call failed.';
  if (s.includes('ozow')) return 'Ozow payment gateway call failed.';
  if (s.includes('timeout')) return 'An operation timed out. Backend still running.';
  if (s.includes('cannot read') || s.includes('undefined is not')) {
    return 'Code error � a variable was missing or wrong shape. Auto-recovered.';
  }
  return 'Unexpected backend error. Auto-recovered � server still running. See stack for details.';
}

async function _captureBackendError(kind, err, reqInfo) {
  try {
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
      return;
    }
    _errorDedup.set(key, { firstSeen: now, lastSeen: now, count: 1 });
    // LRU+TTL cap. First sweep entries >10min old, then if still over cap evict oldest by lastSeen.
    if (_errorDedup.size > 500) {
      for (const [k, v] of _errorDedup.entries()) {
        if (now - v.lastSeen > 10 * 60 * 1000) _errorDedup.delete(k);
      }
      if (_errorDedup.size > 500) {
        const sorted = [..._errorDedup.entries()].sort((a, b) => a[1].lastSeen - b[1].lastSeen);
        const toDrop = _errorDedup.size - 500;
        for (let i = 0; i < toDrop; i++) _errorDedup.delete(sorted[i][0]);
      }
    }
    _errorsThisHour += 1;

    const severity = kind === 'uncaught_exception' ? 'critical' : 'high';
    const details = (reqInfo ? `${reqInfo}\n` : '') + String(msg).slice(0, 4000);
    const heal = _tryAutoHeal(kind, err);
    const logId = await logErrorToAdmin(
      kind,
      heal.healed
        ? `[auto-healed] ${_plainEnglishFromError(err)}`
        : _plainEnglishFromError(err),
      'livekit_backend',
      details,
      '',
      heal.healed ? 'low' : severity
    );
    if (heal.healed && logId) {
      try {
        const firestore = admin.apps.length ? admin.firestore() : null;
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

// Error handling middleware � also forwards to admin dashboard
app.use((err, req, res, next) => {
  console.error('? Server error:', err);
  const reqInfo = `${req.method} ${req.originalUrl}`;
  _captureBackendError('express_error', err, reqInfo);
  if (res.headersSent) return next(err);
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
app.post('/api/admin/bootstrap-claims', adminLimiter, async (req, res) => {
  const firestore = requireFirebase(res);
  if (!firestore) return;

  const bootstrapKey = (process.env.ADMIN_BOOTSTRAP_KEY || '').trim();
  const providedKey = (req.headers['x-bootstrap-key'] || '').trim();

  if (!bootstrapKey) {
    return res.status(500).json({ error: 'ADMIN_BOOTSTRAP_KEY not configured on server' });
  }
  if (!providedKey || providedKey.length !== bootstrapKey.length ||
      !crypto.timingSafeEqual(Buffer.from(providedKey), Buffer.from(bootstrapKey))) {
    return res.status(403).json({ error: 'Invalid bootstrap key' });
  }

  const uid = String(req.body?.uid || '').trim();
  if (!uid) {
    return res.status(400).json({ error: 'Missing uid in request body' });
  }
  // Firebase UIDs are 1-128 chars, alphanumeric. Reject anything else early.
  if (!/^[A-Za-z0-9_-]{1,128}$/.test(uid)) {
    return res.status(400).json({ error: 'Invalid uid format' });
  }

  try {
    await admin.auth().setCustomUserClaims(uid, { role: 'admin' });
    console.log(`? Admin custom claims set for UID: ${uid}`);
    return res.json({ success: true, uid, message: 'Admin claims set. User must re-login for claims to take effect.' });
  } catch (e) {
    console.error('? Failed to set admin claims:', e);
    return res.status(500).json({ error: 'Failed to set claims' });
  }
});

/**
 * Self-bootstrap admin custom claims.
 * POST /api/admin/self-bootstrap-claims
 * Header: Authorization: Bearer <Firebase ID token>
 *
 * Anti-fraud (May-2026): the admin app calls this immediately after a
 * successful Firebase Auth login. The backend verifies the caller's ID
 * token, then reads `users/{uid}` in Firestore (Admin SDK bypasses
 * security rules). If both `isAdmin == true` and `isVerified == true`,
 * it sets the `role: 'admin'` custom claim on the user. The admin app
 * then force-refreshes its ID token so the new claim is present in
 * subsequent Firebase Storage uploads (which now require it for
 * `service_providers/**`).
 */
app.post('/api/admin/self-bootstrap-claims', adminLimiter, async (req, res) => {
  const firestore = requireFirebase(res);
  if (!firestore) return;
  try {
    const authHeader = String(req.headers.authorization || req.headers.Authorization || '');
    const idToken = authHeader.startsWith('Bearer ') ? authHeader.slice(7).trim() : '';
    if (!idToken) return res.status(401).json({ error: 'Missing Authorization Bearer token' });

    let decoded;
    try {
      decoded = await admin.auth().verifyIdToken(idToken);
    } catch (e) {
      return res.status(401).json({ error: 'Invalid ID token', detail: e.message });
    }

    const uid = decoded.uid;
    // Short-circuit: if this token already carries an admin tier custom claim
    // (e.g. an owner bootstrapped from OWNER_UID), there is nothing to do.
    // Skipping the Firestore gate avoids locking owners out when their user
    // doc was created without the legacy `isVerified` field.
    const existingClaimRole = String(decoded.role || '').toLowerCase();
    if (existingClaimRole === 'owner' || existingClaimRole === 'finance' ||
        existingClaimRole === 'ops' || existingClaimRole === 'support' ||
        existingClaimRole === 'auditor' || decoded.admin === true) {
      return res.json({
        success: true,
        uid,
        message: 'Admin claim already present. No action taken.',
        existing_role: existingClaimRole || 'admin',
      });
    }
    const userDoc = await firestore.collection('users').doc(uid).get();
    if (!userDoc.exists) return res.status(403).json({ error: 'User not found in Firestore' });
    const u = userDoc.data() || {};
    // Accept either the legacy gate (isAdmin && isVerified) OR a Firestore
    // `admin_tier` value set by the owner via the Admin Roles UI. This avoids
    // having to backfill `isVerified` on every owner-created admin doc.
    const tier = String(u.admin_tier || '').toLowerCase();
    const tierGrants = ['owner', 'finance', 'ops', 'support', 'auditor'].includes(tier);
    const legacyGrants = u.isAdmin === true && u.isVerified === true;
    if (!tierGrants && !legacyGrants) {
      console.warn(`[self-bootstrap-claims] DENIED for ${uid}: isAdmin=${u.isAdmin} isVerified=${u.isVerified} admin_tier=${u.admin_tier || 'none'}`);
      return res.status(403).json({ error: 'Not an admin user' });
    }

    // Preserve any other claims that may already be set.
    const existing = (decoded && decoded.claims) || {};
    const grantRole = tierGrants ? tier : 'admin';
    await admin.auth().setCustomUserClaims(uid, { ...existing, role: grantRole, admin: true });
    console.log(`✅ self-bootstrap-claims: granted ${grantRole} to ${uid} (${u.email || ''})`);
    return res.json({
      success: true,
      uid,
      message: 'Admin claims set. Force-refresh your ID token for the change to take effect.',
    });
  } catch (e) {
    console.error('? self-bootstrap-claims error:', e);
    return res.status(500).json({ error: 'Internal error' });
  }
});

/**
 * Upload an artisan profile image (admin-only).
 * POST /api/admin/upload-artisan-image
 * Headers: Authorization: Bearer <Firebase ID token>
 * Body (JSON, route-local 25 MB limit): {
 *   "artisanId": "<serviceProvider doc id>",
 *   "imageBase64": "<base64 jpeg/png, no data: prefix>",
 *   "contentType": "image/jpeg" | "image/png" (optional, default jpeg)
 * }
 *
 * Anti-fraud (May-2026): the admin's Android Storage SDK has been
 * returning a generic [unknown] error during direct putFile() � likely a
 * regional/SDK quirk. We bypass the client SDK entirely: backend uses
 * the Firebase Admin SDK (bypasses Storage rules), uploads to
 * `service_providers/{artisanId}.jpg`, generates a download URL, and
 * mirrors `imageUrl`/`image` onto `serviceProvider/{artisanId}` in
 * Firestore so the artisan app + admin app + WA bot all see the new
 * picture immediately. Artisans cannot call this endpoint � we verify
 * the caller is an admin via Firestore (Admin SDK can read it bypassing
 * rules; we don't rely on custom claims here).
 */
app.post(
  '/api/admin/upload-artisan-image',
  express.json({ limit: '25mb' }),
  adminLimiter,
  async (req, res) => {
    const firestore = requireFirebase(res);
    if (!firestore) return;
    try {
      // 1) Verify Firebase ID token
      const authHeader = String(req.headers.authorization || req.headers.Authorization || '');
      const idToken = authHeader.startsWith('Bearer ') ? authHeader.slice(7).trim() : '';
      if (!idToken) return res.status(401).json({ error: 'Missing Authorization Bearer token' });

      let decoded;
      try {
        decoded = await admin.auth().verifyIdToken(idToken);
      } catch (e) {
        return res.status(401).json({ error: 'Invalid ID token', detail: e.message });
      }

      // 2) Verify caller is an admin in Firestore
      const callerUid = decoded.uid;
      const userDoc = await firestore.collection('users').doc(callerUid).get();
      if (!userDoc.exists) return res.status(403).json({ error: 'User not found' });
      const u = userDoc.data() || {};
      if (u.isAdmin !== true || u.isVerified !== true) {
        console.warn(`[upload-artisan-image] DENIED for ${callerUid}: isAdmin=${u.isAdmin} isVerified=${u.isVerified}`);
        return res.status(403).json({ error: 'Admin privileges required' });
      }

      // 3) Validate body
      const artisanId = String(req.body?.artisanId || '').trim();
      const rawB64 = String(req.body?.imageBase64 || '').trim();
      const contentType = String(req.body?.contentType || 'image/jpeg').trim();
      if (!artisanId) return res.status(400).json({ error: 'Missing artisanId' });
      // Anti-path-traversal: only allow safe Firestore-style ids.
      if (!/^[A-Za-z0-9_-]{1,128}$/.test(artisanId)) {
        return res.status(400).json({ error: 'Invalid artisanId format' });
      }
      if (!rawB64) return res.status(400).json({ error: 'Missing imageBase64' });
      if (!/^image\/(jpeg|jpg|png)$/i.test(contentType)) {
        return res.status(400).json({ error: 'Unsupported contentType (must be image/jpeg or image/png)' });
      }

      const cleanB64 = rawB64.replace(/^data:image\/\w+;base64,/, '');
      let buf;
      try {
        buf = Buffer.from(cleanB64, 'base64');
      } catch (e) {
        return res.status(400).json({ error: 'Invalid base64' });
      }
      if (buf.length === 0) return res.status(400).json({ error: 'Empty image' });
      if (buf.length > 15 * 1024 * 1024) {
        return res.status(413).json({ error: 'Image exceeds 15MB' });
      }

      // 4) Upload to Storage via Admin SDK (bypasses rules)
      const ext = contentType === 'image/png' ? 'png' : 'jpg';
      const storagePath = `service_providers/${artisanId}.${ext}`;
      const downloadToken = crypto.randomUUID();
      const bucketName = process.env.FIREBASE_STORAGE_BUCKET || 'promaintapp-b618a.firebasestorage.app';
      const bucket = admin.storage().bucket(bucketName);
      const file = bucket.file(storagePath);
      await file.save(buf, {
        contentType,
        metadata: {
          cacheControl: 'public, max-age=3600',
          metadata: {
            firebaseStorageDownloadTokens: downloadToken,
            uploaded_by: callerUid,
            uploaded_at: new Date().toISOString(),
          },
        },
        resumable: false,
        validation: false,
      });

      const encodedPath = encodeURIComponent(storagePath);
      const publicUrl = `https://firebasestorage.googleapis.com/v0/b/${bucket.name}/o/${encodedPath}?alt=media&token=${downloadToken}`;

      // 5) Mirror onto serviceProvider doc (canonical + legacy fields)
      await firestore.collection('serviceProvider').doc(artisanId).set(
        {
          image: publicUrl,
          imageUrl: publicUrl,
          image_updated_at: new Date().toISOString(),
          image_updated_by: callerUid,
        },
        { merge: true }
      );

      console.log(`? admin upload-artisan-image: ${callerUid} ? ${artisanId} (${buf.length} bytes)`);
      return res.json({ success: true, url: publicUrl, path: storagePath, bytes: buf.length });
    } catch (e) {
      console.error('? upload-artisan-image error:', e);
      return res.status(500).json({ error: 'Upload failed' });
    }
  }
);

// -------------------------------------------------------------------------------
// PHASE 5.2 � Secure Finance Approval Pipeline (Tier C)
// Money NEVER moves without: auth ? fraud check ? request doc ? admin approval
// -------------------------------------------------------------------------------

// -- Fraud Detection Engine --------------------------------------------------
async function runFraudChecks({ firestore, type, amount, targetUserId, requestedBy, bookingId }) {
  const alerts = [];
  const amountNum = typeof amount === 'number' ? amount : Number.parseFloat(String(amount).replace(/[^0-9.\-]/g, ''));

  // Rule 1: Amount exceeds daily limit per type
  const DAILY_LIMITS = { refund: 10000, wallet_adjustment: 5000, payout: 50000, fee_override: 2000 };
  const dailyLimit = DAILY_LIMITS[type] || 5000;
  if (amountNum > dailyLimit) {
    alerts.push({ rule: 'amount_exceeds_daily_limit', severity: 'high', detail: `R${amountNum} exceeds R${dailyLimit} limit for ${type}` });
  }

  // Rule 2: Velocity check � max 5 finance requests per user per hour
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

  // Rule 3: Self-dealing � admin requesting funds to themselves
  if (targetUserId === requestedBy) {
    alerts.push({ rule: 'self_dealing', severity: 'critical', detail: 'Admin requesting financial action to own account' });
  }

  // Rule 4: Duplicate refund � same booking refunded within 24 hours
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

// --- Device-sourced error reporter ------------------------------------------
// POST /api/report-error  (authenticated)
// Body: { error_type, description, source?, error_details?, booking_id?, severity? }
// Client/admin Flutter apps POST here when their global crash handler fires.
// This routes through logErrorToAdmin so admin devices get an FCM push too.
app.post('/api/report-error', authMiddleware, async (req, res) => {
  try {
    const {
      error_type,
      description,
      source,
      error_details,
      booking_id,
      severity,
    } = req.body || {};

    if (!error_type || !description) {
      return res.status(400).json({ error: 'missing error_type or description' });
    }

    const errorId = await logErrorToAdmin(
      String(error_type).slice(0, 80),
      String(description).slice(0, 500),
      String(source || (req.user && req.user.email) || 'device').slice(0, 40),
      String(error_details || '').slice(0, 4000),
      String(booking_id || '').slice(0, 80),
      ['critical', 'high', 'medium', 'low'].includes(severity) ? severity : 'medium'
    );

    return res.json({ ok: true, error_id: errorId });
  } catch (err) {
    console.error('[api/report-error]', err && err.message);
    return res.status(500).json({ error: 'failed_to_report', detail: err && err.message });
  }
});

// --- Tier-2 admin one-tap remediation actions -------------------------------
// POST /api/admin/ops/fix
// Body: { error_id: string, action: string, target?: string }
// action ? 'clean_fcm_tokens' | 'reset_dispatch_lock' | 'bootstrap_claims'
//        | 'restart_worker' | 'resolve'
// Admin-only. Applies the action and marks the error_log as status=resolved.
app.post('/api/admin/ops/fix', adminLimiter, async (req, res) => {
  const firestore = requireFirebase(res);
  if (!firestore) return;
  const decoded = await verifyFirebaseAuth(req, res);
  if (!decoded) return;
  const actorUid = decoded.uid;
  const actorRole = await resolveRole({ firestore, uid: actorUid, decodedToken: decoded });
  if (actorRole !== 'admin') {
    return res.status(403).json({ error: 'forbidden', message: 'Admin only' });
  }

  const errorId = String(req.body.error_id || '').trim();
  const action = String(req.body.action || '').trim();
  const target = String(req.body.target || '').trim();
  if (!action) return res.status(400).json({ error: 'missing_action' });

  const result = { action, success: false, detail: '', affected: 0 };

  try {
    if (action === 'clean_fcm_tokens') {
      // target = token string OR user/artisan docId � we scrub by token string;
      // if a docId is given, pull tokens off that doc first.
      let tokens = [];
      if (target) {
        // If it looks like an FCM token (long, contains ':'), use directly.
        if (target.length > 80 && target.includes(':')) {
          tokens = [target];
        } else {
          for (const col of ['users', 'serviceProvidersRegistration', 'admins', 'admin_users']) {
            try {
              const snap = await firestore.collection(col).doc(target).get();
              if (snap.exists) {
                const d = snap.data() || {};
                for (const f of ['deviceToken','device_token','fcm_token','fcmToken','token','push_token','pushToken']) {
                  if (d[f]) tokens.push(String(d[f]));
                }
                for (const f of ['tokens','fcm_tokens','deviceTokens']) {
                  if (Array.isArray(d[f])) d[f].forEach(t => t && tokens.push(String(t)));
                }
                break;
              }
            } catch (_) {}
          }
        }
      }
      if (tokens.length === 0) {
        result.detail = 'No target FCM tokens found to clean. Provide target=<docId> or a token string.';
      } else {
        const cleaned = await _cleanStaleFcmTokens(tokens);
        result.success = true;
        result.affected = cleaned;
        result.detail = `Removed ${cleaned} token entries.`;
      }
    } else if (action === 'reset_dispatch_lock') {
      // target = booking id
      if (!target) {
        result.detail = 'target (booking_id) required';
      } else {
        const bref = firestore.collection('bookings').doc(target);
        const bsnap = await bref.get();
        if (!bsnap.exists) {
          result.detail = `Booking ${target} not found`;
        } else {
          await bref.update({
            in_dispatch: false,
            dispatch_locked_at: admin.firestore.FieldValue.delete(),
            current_dispatch_to: admin.firestore.FieldValue.delete(),
            dispatch_reset_by: actorUid,
            dispatch_reset_at: admin.firestore.FieldValue.serverTimestamp(),
          });
          result.success = true;
          result.affected = 1;
          result.detail = `Cleared dispatch lock on booking ${target}.`;
        }
      }
    } else if (action === 'bootstrap_claims') {
      // target = firebase auth uid to grant admin claim
      if (!target) {
        result.detail = 'target (uid) required';
      } else {
        await admin.auth().setCustomUserClaims(target, { role: 'admin' });
        result.success = true;
        result.affected = 1;
        result.detail = `Granted admin claim to ${target}. They must sign out and back in.`;
      }
    } else if (action === 'restart_worker') {
      // Graceful shutdown: Render will auto-restart the process.
      result.success = true;
      result.detail = 'Worker restart requested. Render will spin up a fresh instance within ~30s.';
      setTimeout(() => { try { process.exit(0); } catch (_) {} }, 500);
    } else if (action === 'resolve') {
      // Just mark the error as resolved (no remediation).
      result.success = true;
      result.detail = 'Error marked resolved without remediation.';
    } else {
      return res.status(400).json({ error: 'unknown_action', action });
    }

    // Mark the error_log entry as resolved with audit trail.
    if (errorId && result.success) {
      try {
        await firestore.collection('error_logs').doc(errorId).update({
          status: 'resolved',
          resolved_by: actorUid,
          resolved_by_role: 'admin',
          resolved_at: admin.firestore.FieldValue.serverTimestamp(),
          auto_fix_applied: action,
          auto_fix_detail: result.detail,
        });
      } catch (e) {
        console.warn('[ops/fix] error_log update failed:', e && e.message);
      }
    }

    return res.json({ ok: true, ...result, request_id: req.requestId || null });
  } catch (e) {
    console.error('[ops/fix] failed:', e && (e.stack || e.message));
    return res.status(500).json({ ok: false, error: 'fix_failed', message: e && e.message, action });
  }
});
// --- END Tier-2 admin ops ---------------------------------------------------

// -- Create Finance Request (admin-only, creates approval doc) ----------------
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

// -- Approve Finance Request (admin-only, requires different admin than requester) --
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

  // Check status � only pending or flagged can be approved
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

  // -- Execute the financial operation ----------------------------------
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

// -- Reject Finance Request (admin-only) --------------------------------------
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

// -- List Finance Requests (admin-only) ---------------------------------------
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
  if (status) {
    q = firestore.collection('finance_requests').where('status', '==', status).orderBy('created_at', 'desc').limit(limit);
  }
  if (type) {
    q = q.where('type', '==', type);
  }

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
    return res.status(500).json({ error: 'internal_error' });
  }
});

// -- Fraud Alerts Dashboard (admin-only) --------------------------------------
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
      // Composite index may not exist yet � fall back to status-only query
      console.warn('[fraud-alerts] Index query failed, falling back:', indexErr.message);
      snap = await firestore.collection('fraud_alerts')
        .where('status', '==', status)
        .limit(limit)
        .get();
    }
    const items = snap.docs.map(d => ({ id: d.id, ...d.data() }));
    return res.json({ success: true, count: items.length, items });
  } catch (e) {
    return res.status(500).json({ error: 'internal_error' });
  }
});

// -- Dismiss Fraud Alert (admin-only) -----------------------------------------
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
    return res.status(500).json({ error: 'internal_error' });
  }
});

// 404 handler
// ─────────────────────────────────────────────────────────────────────────────
// PayJustNow direct integration (scaffolding — keys arrive later).
//
// Flow when live:
//   1. Client POSTs /api/bnpl/payjustnow/create-order with { amount, taskId, ... }
//   2. Backend reads app_config/bnpl_payJustNow → api_key, sandbox/prod flag.
//   3. Backend POSTs to PayJustNow /order endpoint, receives token + redirectUrl.
//   4. Backend stores bnpl_orders/{orderId} with status='pending'.
//   5. Returns { redirect_url, token, order_id } to client.
//   6. Client opens WebView → on confirm redirect, client posts /api/bnpl/payjustnow/capture.
//   7. Backend posts to PayJustNow /order/{token}/capture, marks bnpl_orders captured.
//   8. PayJustNow webhook → /api/bnpl/payjustnow/webhook (signed; we verify).
//
// Right now every endpoint returns 503 because we have no API key.
// When PayJustNow sends us their keys, fill PAYJUSTNOW_* config values and
// flip the COMING_SOON guard at the top — no client changes needed.
// ─────────────────────────────────────────────────────────────────────────────

async function getPayJustNowConfig() {
  try {
    const snap = await admin.firestore()
      .collection('app_config').doc('bnpl_payJustNow').get();
    if (!snap.exists) return null;
    const d = snap.data() || {};
    if (d.enabled !== true) return null;
    const apiKey = (d.api_key || '').toString();
    if (!apiKey) return null;
    return {
      apiKey,
      useSandbox: d.use_sandbox !== false,
      confirmUrl: d.confirm_url || 'https://square15.co.za/bnpl/payJustNow/confirm',
      cancelUrl:  d.cancel_url  || 'https://square15.co.za/bnpl/payJustNow/cancel',
      // Real base URLs will be confirmed by PayJustNow during onboarding.
      // Until then they live in env so we don't have to redeploy to fix them.
      sandboxBase: env('PAYJUSTNOW_SANDBOX_BASE') || '',
      productionBase: env('PAYJUSTNOW_PRODUCTION_BASE') || '',
      webhookSecret: env('PAYJUSTNOW_WEBHOOK_SECRET') || '',
    };
  } catch (e) {
    console.error('[payjustnow] config load error:', e.message);
    return null;
  }
}

app.post('/api/bnpl/payjustnow/create-order', authMiddleware, assistantLimiter, async (req, res) => {
  const cfg = await getPayJustNowConfig();
  if (!cfg) {
    return res.status(503).json({
      ok: false,
      error: 'payjustnow_not_configured',
      message: 'PayJustNow integration is pending merchant approval. Please use another payment method.',
    });
  }
  const base = cfg.useSandbox ? cfg.sandboxBase : cfg.productionBase;
  if (!base) {
    return res.status(503).json({
      ok: false,
      error: 'payjustnow_base_url_missing',
      message: 'PayJustNow base URL not configured. Set PAYJUSTNOW_SANDBOX_BASE / PAYJUSTNOW_PRODUCTION_BASE on Render.',
    });
  }

  const { amount, taskId, consumer } = req.body || {};
  if (!amount || isNaN(parseFloat(amount))) {
    return res.status(400).json({ ok: false, error: 'invalid_amount' });
  }
  const orderId = `SQ15-PJN-${Date.now()}-${Math.random().toString(36).slice(2, 6).toUpperCase()}`;
  const body = {
    amount: parseFloat(amount).toFixed(2),
    merchantReference: orderId,
    merchant: {
      redirectConfirmUrl: cfg.confirmUrl,
      redirectCancelUrl: cfg.cancelUrl,
    },
    consumer: consumer || {},
    description: `Square 15 Maintenance - Job ${taskId || ''}`,
    taxAmount: '0.00',
    shippingAmount: '0.00',
  };

  try {
    const fetch = (await import('node-fetch')).default;
    const resp = await fetch(`${base}/order`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Bearer ${cfg.apiKey}`,
      },
      body: JSON.stringify(body),
    });
    const text = await resp.text();
    let data = {};
    try { data = JSON.parse(text); } catch (_) {}
    if (!resp.ok) {
      console.warn(`[payjustnow] create-order ${resp.status}: ${text.slice(0, 300)}`);
      return res.status(502).json({ ok: false, error: 'provider_error', status: resp.status });
    }
    const token = data.token || data.id || '';
    const redirectUrl = data.redirectCheckoutUrl || data.redirect_url || data.checkoutUrl || '';
    if (!token || !redirectUrl) {
      return res.status(502).json({ ok: false, error: 'provider_response_missing_fields' });
    }
    await admin.firestore().collection('bnpl_orders').doc(orderId).set({
      order_id: orderId,
      provider: 'payJustNow',
      provider_name: 'PayJustNow',
      token,
      amount: parseFloat(amount).toFixed(2),
      task_id: taskId || null,
      uid: req.user && req.user.uid || null,
      status: 'pending',
      sandbox: cfg.useSandbox,
      created_at: admin.firestore.FieldValue.serverTimestamp(),
    }, { merge: true });
    return res.json({ ok: true, order_id: orderId, token, redirect_url: redirectUrl });
  } catch (e) {
    console.error('[payjustnow] create-order error:', e.message);
    return res.status(502).json({ ok: false, error: 'network_error', message: e.message });
  }
});

app.post('/api/bnpl/payjustnow/capture', authMiddleware, async (req, res) => {
  const cfg = await getPayJustNowConfig();
  if (!cfg) return res.status(503).json({ ok: false, error: 'payjustnow_not_configured' });
  const base = cfg.useSandbox ? cfg.sandboxBase : cfg.productionBase;
  const { token, orderId } = req.body || {};
  if (!token) return res.status(400).json({ ok: false, error: 'missing_token' });

  try {
    const fetch = (await import('node-fetch')).default;
    const resp = await fetch(`${base}/order/${encodeURIComponent(token)}/capture`, {
      method: 'POST',
      headers: { Authorization: `Bearer ${cfg.apiKey}` },
    });
    const ok = resp.ok;
    if (orderId) {
      await admin.firestore().collection('bnpl_orders').doc(orderId).set({
        status: ok ? 'captured' : 'capture_failed',
        captured_at: admin.firestore.FieldValue.serverTimestamp(),
      }, { merge: true });
    }
    return res.json({ ok, status: resp.status });
  } catch (e) {
    console.error('[payjustnow] capture error:', e.message);
    return res.status(502).json({ ok: false, error: 'network_error' });
  }
});

// PayJustNow webhook (signature verification — exact header name TBD by PJN docs).
app.post('/api/bnpl/payjustnow/webhook', express.raw({ type: '*/*' }), async (req, res) => {
  const cfg = await getPayJustNowConfig();
  if (!cfg) return res.status(503).send('not_configured');
  const rawBody = req.body && req.body.length ? req.body.toString('utf8') : '';
  const signature = req.header('x-payjustnow-signature') || req.header('x-signature') || '';
  if (cfg.webhookSecret) {
    const expected = crypto.createHmac('sha256', cfg.webhookSecret)
      .update(rawBody).digest('hex');
    if (signature && signature.toLowerCase() !== expected.toLowerCase()) {
      console.warn('[payjustnow] webhook signature mismatch');
      return res.status(401).send('invalid_signature');
    }
  }
  let payload = {};
  try { payload = JSON.parse(rawBody); } catch (_) {}
  const orderId = payload.merchantReference || payload.order_id || '';
  const status = (payload.orderStatus || payload.status || '').toString().toLowerCase();
  if (orderId) {
    try {
      await admin.firestore().collection('bnpl_orders').doc(orderId).set({
        webhook_status: status,
        webhook_received_at: admin.firestore.FieldValue.serverTimestamp(),
        webhook_payload: payload,
      }, { merge: true });
    } catch (e) {
      console.error('[payjustnow] webhook persist error:', e.message);
    }
  }
  res.json({ ok: true });
});



// Export app for serverless/tests
module.exports = app;

// Start server only when executed directly (node server.js)
if (require.main === module) {
  process.on('unhandledRejection', (reason, promise) => {
    console.error('\u274c Unhandled Rejection:', reason);
    const err = reason instanceof Error ? reason : new Error(String(reason));
    _captureBackendError('unhandled_rejection', err);
    // DO NOT exit � keep serving other requests
  });
  process.on('uncaughtException', (error) => {
    console.error('\u274c Uncaught Exception:', error);
    _captureBackendError('uncaught_exception', error);
    // DO NOT exit for non-fatal errors. Render will restart us only if truly broken.
  });

  app.listen(PORT, async () => {
    console.log('?? Square 15 Livekit Backend');
    console.log(`?? Server running on port ${PORT}`);
    console.log(`?? Health check: http://localhost:${PORT}/health`);
    console.log(`?? Token endpoint: http://localhost:${PORT}/api/token`);
    console.log(`?? Voice start endpoint: http://localhost:${PORT}/api/voice/start`);
    console.log(`?? Environment: ${process.env.NODE_ENV}`);
    // ─── Gap #14: Ozow prod safety at startup ───
    try {
      const ozowErrs = assertOzowProdSafety();
      if (ozowErrs.length > 0) {
        console.error('🚨 OZOW PROD SAFETY WARNING AT STARTUP:', ozowErrs);
        try {
          admin.firestore().collection('error_logs').add({
            error_type: 'ozow_prod_safety_warning_startup',
            severity: 'critical',
            source: 'livekit_backend',
            errors: ozowErrs,
            created_at: new Date().toISOString(),
          });
        } catch (_) {}
      } else if (env('OZOW_IS_TEST') === 'true') {
        console.log('✅ Ozow: SANDBOX mode (no money will move).');
      } else {
        console.log('✅ Ozow: LIVE mode — credentials passed safety check.');
      }
    } catch (e) { console.warn('Ozow safety assertion threw:', e.message); }

    // ─── Owner bootstrap ───
    // If OWNER_UID is set in env, ensure that uid has the `owner` custom
    // claim. Idempotent and safe to run on every startup.
    try {
      initFirebaseIfPossible();
      if (firebaseInitError) {
        console.warn('Owner bootstrap skipped (Firebase not configured):', firebaseInitError.message);
        throw firebaseInitError;
      }
      const ownerUid = env('OWNER_UID');
      if (ownerUid) {
        const user = await admin.auth().getUser(ownerUid).catch(() => null);
        if (user) {
          const existing = user.customClaims || {};
          if (existing.role !== 'owner') {
            await admin.auth().setCustomUserClaims(ownerUid, { ...existing, role: 'owner', admin: true });
            await admin.firestore().collection('admin_role_audit').add({
              action: 'owner_bootstrapped',
              target_uid: ownerUid,
              target_email: user.email || null,
              old_role: existing.role || null,
              new_role: 'owner',
              changed_by: 'system_bootstrap',
              created_at: new Date().toISOString(),
            });
            console.log(`👑 Owner role granted to ${ownerUid} (${user.email || '?'})`);
          } else {
            console.log(`👑 Owner already configured: ${ownerUid} (${user.email || '?'})`);
          }
        } else {
          console.warn(`⚠️ OWNER_UID=${ownerUid} not found in Firebase Auth`);
        }
      } else {
        console.warn('⚠️ No OWNER_UID env var set. No admin can grant roles or bypass daily caps until one is configured.');
      }
    } catch (e) { console.warn('Owner bootstrap error:', e.message); }
    // LK-13: hard refusal � if anyone leaves the no-auth voice flag enabled in
    // production, log loudly to error_logs and ALSO refuse to enable it (the
    // flag is read again at request time; we set NODE_ENV-dependent override).
    try {
      const dangerFlag = String(process.env.ALLOW_VOICE_START_WITHOUT_AUTH || '').toLowerCase();
      const isProd = String(process.env.NODE_ENV || '').toLowerCase() === 'production';
      if (isProd && (dangerFlag === '1' || dangerFlag === 'true' || dangerFlag === 'yes' || dangerFlag === 'on')) {
        console.error('?? SECURITY: ALLOW_VOICE_START_WITHOUT_AUTH is enabled in production. This lets anyone start a voice session without Firebase auth. The flag is being IGNORED � set it to false in Render env vars to silence this warning.');
        // Forcibly clear so downstream isEnvTruthy() reads false
        process.env.ALLOW_VOICE_START_WITHOUT_AUTH = 'false';
        try {
          admin.firestore().collection('error_logs').add({
            error_type: 'unsafe_config_blocked',
            severity: 'critical',
            source: 'livekit_backend',
            description: 'ALLOW_VOICE_START_WITHOUT_AUTH was true in production at startup. The flag was forcibly disabled. Update Render env vars to remove the warning.',
            created_at: admin.firestore.FieldValue.serverTimestamp(),
            read: false,
          }).catch(() => {});
        } catch (_) {}
      }
    } catch (_) {}
    console.log('? Server ready to accept requests\n');
    try { _startAutoResolveSweeper(); console.log('?? Auto-heal sweeper started (every 5 min).'); } catch (_) {}
    try { _startRefundReconciliationSweeper(); console.log('?? Refund-reconciliation sweeper started (every 6h).'); } catch (_) {}
    try { _startWeeklyPayoutBatchSweep(); console.log('?? Weekly Ozow payout-batch sweeper started (hourly check, fires Mon 09:00 SAST).'); } catch (_) {}
  });
}
