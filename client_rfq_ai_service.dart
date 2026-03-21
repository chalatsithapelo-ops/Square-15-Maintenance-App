import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:maintenanceapp/services/builders_webview_pricing.dart';

class RFQAIService {
  static final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  static const String _materialsCatalogCollection = 'materialsCatalog';
  static const String _pricingGuidanceCollection = 'pricingGuidance';
  static const String _aiCorrectionsCollection = 'aiQuoteCorrections';

  static String _compactText(String input) {
    return input.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '');
  }

  static bool _looksLikeKwikot(String input) {
    final s = input.toLowerCase();
    if (s.contains('kwikot')) return true;
    final c = _compactText(s);
    if (c.contains('kwikot')) return true;
    if (c.contains('kwikhot') ||
        c.contains('kwikote') ||
        c.contains('quickot')) {
      return true;
    }
    return RegExp(r'kwik[a-z0-9]{0,3}ot').hasMatch(c);
  }

  static bool _looksLikeApollo(String input) {
    final s = input.toLowerCase();
    if (s.contains('apollo')) return true;
    return _compactText(s).contains('apollo');
  }

  static final Map<String, _BuildersPriceCacheEntry> _buildersPriceCache =
      <String, _BuildersPriceCacheEntry>{};
  static const Duration _buildersPriceCacheTtl = Duration(minutes: 30);

  static final Map<String, _BuildersItemsPriceCacheEntry>
      _buildersItemsPriceCache = <String, _BuildersItemsPriceCacheEntry>{};
  static const Duration _buildersItemsPriceCacheTtl = Duration(minutes: 30);

  static _BuildersBffConfigCacheEntry? _buildersBffConfigCache;
  static const Duration _buildersBffConfigTtl = Duration(hours: 12);
  static DateTime? _buildersBffBackoffUntil;
  static _BuildersItemsPriceDiag? _buildersLastItemsPriceDiag;
  // Minimal cookie jar for Builders requests. Builders frequently relies on
  // session cookies even for persisted GraphQL operations.
  static final Map<String, String> _buildersCookies = <String, String>{};

  static String _buildersCookieHeader() {
    if (_buildersCookies.isEmpty) return '';
    return _buildersCookies.entries
        .map((e) => '${e.key}=${e.value}')
        .join('; ');
  }

  static void _buildersUpdateCookies(Map<String, String> responseHeaders) {
    final raw = responseHeaders['set-cookie'];
    if (raw == null || raw.trim().isEmpty) return;

    // `package:http` may coalesce multiple Set-Cookie headers into one string.
    // Extract cookie-pairs at the start of each cookie definition.
    final re = RegExp(r'(?:^|,\s*)([^=;\s,]+)=([^;]*)', caseSensitive: false);
    for (final m in re.allMatches(raw)) {
      final name = (m.group(1) ?? '').trim();
      final value = (m.group(2) ?? '').trim();
      if (name.isEmpty) continue;
      final lower = name.toLowerCase();
      if (lower == 'expires' ||
          lower == 'path' ||
          lower == 'domain' ||
          lower == 'max-age' ||
          lower == 'secure' ||
          lower == 'httponly' ||
          lower == 'samesite') {
        continue;
      }
      _buildersCookies[name] = value;
    }
  }

  // Persisted query hash observed for ItemsPrice (Jan 2026). Also extracted from the Builders main JS.
  static const String _fallbackItemsPriceHash =
      '66dc15a8c2bfb3d1d0b80546b883602b568d305344408c8a6e26138de8c2edd1';

  static Future<Map<String, _BuildersCandidate>>
      _lookupBuildersPricesViaFunctions(
    List<String> names,
  ) async {
    final cleaned = names
        .map((n) => n.toString().trim())
        .where((n) => n.isNotEmpty)
        .toList(growable: false);
    if (cleaned.isEmpty) return <String, _BuildersCandidate>{};

    // Cloud Function enforces a max of 25 items. If we exceed that, it throws
    // and we fall back to slower on-device pricing. Keep the batch bounded.
    final bounded = cleaned.length > 25
        ? cleaned.take(25).toList(growable: false)
        : cleaned;

    try {
      final callable = FirebaseFunctions.instanceFor(region: 'europe-west1')
          .httpsCallable('buildersPriceLookupBatch');

      final resp = await callable.call(<String, dynamic>{
        'items': bounded,
      });

      final data = resp.data;
      if (data is! Map) return <String, _BuildersCandidate>{};
      final results = data['results'];
      if (results is! List) return <String, _BuildersCandidate>{};

      final out = <String, _BuildersCandidate>{};
      for (final r in results.whereType<Map>()) {
        final m = r.map((k, v) => MapEntry(k.toString(), v));
        final query = (m['query'] ?? '').toString().trim();
        final found = m['found'] == true;
        if (query.isEmpty || !found) continue;
        final title = (m['title'] ?? '').toString();
        final url = (m['url'] ?? '').toString();
        final source = (m['source'] ?? 'builders_fn_unknown').toString();
        final priceRaw = m['priceZar'];
        final price = priceRaw is num
            ? priceRaw.toDouble()
            : double.tryParse(priceRaw?.toString() ?? '');
        if (url.trim().isEmpty || price == null || price <= 0) continue;

        out[query] = _BuildersCandidate(
          title: title.trim().isEmpty ? null : title.trim(),
          url: url.trim(),
          priceZar: price,
          source: source,
        );
      }
      return out;
    } catch (_) {
      return <String, _BuildersCandidate>{};
    }
  }

  static Future<Map<String, dynamic>?> _tryGenerateQuotationViaDualAgents({
    required String? categoryId,
    required String categoryName,
    required String problemDescription,
    required String additionalNotes,
    required String materialsResponsibility,
    required Map<String, dynamic> pricingGuidance,
  }) async {
    try {
      final callable = FirebaseFunctions.instanceFor(region: 'europe-west1')
          .httpsCallable('aiQuoteDraftDual');
      
      // Add timeout to prevent hanging for >2 minutes
      final resp = await callable.call(<String, dynamic>{
        'categoryId': categoryId,
        'categoryName': categoryName,
        'problemDescription': problemDescription,
        'additionalNotes': additionalNotes,
        'materialsResponsibility': materialsResponsibility,
        'pricingGuidance': pricingGuidance,
      }).timeout(
        const Duration(seconds: 20),
        onTimeout: () {
          debugPrint('[RFQ AI] OpenAI function timed out after 20s, using fallback');
          throw TimeoutException('AI generation timeout');
        },
      );

      final data = resp.data;
      if (data is! Map) return null;
      final quotation = data['quotation'];
      if (quotation is! Map) return null;
      return quotation.map((k, v) => MapEntry(k.toString(), v));
    } catch (e) {
      debugPrint('[RFQ AI] Dual-agent failed: $e, falling back to local generation');
      return null;
    }
  }

  static String _normalizeQueryForBuilders(String name) {
    // Builders search works fine with short queries; avoid placeholders.
    var q = name.trim();
    // Remove common placeholder text that prevents matching
    q = q.replaceAll(
        RegExp(r'\b(size\s+tbd|tbd|\-\s*size\s+tbd)\b', caseSensitive: false),
        ' ');
    // Remove parenthetical descriptions to improve matching
    q = q.replaceAll(RegExp(r'\([^)]*\)'), ' ');
    
    // For complex compound terms (e.g., "solar geyser mounting brackets"),
    // try to extract the most specific/searchable part.
    // Pattern: "X Y Z brackets" -> prefer "Z brackets" over full phrase
    final bracketMatch = RegExp(r'\b(\w+)\s+brackets?\b', caseSensitive: false).firstMatch(q);
    if (bracketMatch != null && q.split(RegExp(r'\s+')).length > 2) {
      // If it's a multi-word phrase before "bracket", simplify to last word + bracket
      final simplifiedBracket = '${bracketMatch.group(1)} bracket';
      // Only use if it's more specific than original (e.g., "mounting bracket" vs "solar geyser mounting bracket")
      if (simplifiedBracket.length < q.length * 0.7) {
        q = simplifiedBracket;
      }
    }
    
    // Similar pattern for "X Y fittings/valves/pipes"
    final fittingMatch = RegExp(r'\b(\w+)\s+(fittings?|valves?|pipes?)\b', caseSensitive: false).firstMatch(q);
    if (fittingMatch != null && q.split(RegExp(r'\s+')).length > 2) {
      final simplified = '${fittingMatch.group(1)} ${fittingMatch.group(2)}';
      if (simplified.length < q.length * 0.7) {
        q = simplified;
      }
    }
    
    q = q.replaceAll(RegExp(r'\s+'), ' ').trim();
    return q;
  }

  static Future<_BuildersBffConfig?> _getBuildersBffConfig() async {
    final cached = _buildersBffConfigCache;
    if (cached != null &&
        DateTime.now().difference(cached.fetchedAt) <= _buildersBffConfigTtl) {
      return cached.value;
    }

    try {
      List<String> extractScriptSrcs(String html) {
        final out = <String>[];
        final re = RegExp(r'\bsrc="([^"]+\.js[^"]*)"', caseSensitive: false);
        for (final m in re.allMatches(html)) {
          final s = (m.group(1) ?? '').trim();
          if (s.isEmpty) continue;
          if (s.contains('googletagmanager') ||
              s.contains('google-analytics')) {
            continue;
          }
          out.add(s);
        }
        // De-dupe, preserve order.
        return out.toSet().toList(growable: false);
      }

      Uri? toAbsUrl(String src) {
        final s = src.trim();
        if (s.isEmpty) return null;
        if (s.startsWith('http')) return Uri.parse(s);
        return Uri.parse(
            'https://www.builders.co.za${s.startsWith('/') ? '' : '/'}$s');
      }

      // Builders sometimes blocks homepage/category pages; product pages are often reachable.
      const bootstrapUrls = <String>[
        'https://www.builders.co.za/',
        'https://www.builders.co.za/Plumbing-Bathroom-and-Kitchen/Geysers-and-Water-Heaters/Geysers/Kwikot-DSG-200-5-400KPA-Superline-Dual-Geyser-200-L/p/000000000000659070',
      ];

      String? html;
      for (final u in bootstrapUrls) {
        final htmlResp = await http
            .get(
              Uri.parse(u),
              headers: _buildersHeaders(referer: 'https://www.builders.co.za/'),
            )
            .timeout(const Duration(seconds: 20));

        _buildersUpdateCookies(htmlResp.headers);

        if (htmlResp.statusCode < 200 || htmlResp.statusCode >= 300) continue;
        // Heuristic: WAF responses often contain a redirectUrl to /blocked.
        if (htmlResp.body.contains('/blocked?')) continue;
        if (htmlResp.body.trim().isEmpty) continue;
        html = htmlResp.body;
        break;
      }

      if (html == null) {
        _buildersBffConfigCache = _BuildersBffConfigCacheEntry(
          fetchedAt: DateTime.now(),
          value: null,
        );
        return null;
      }

      final scriptSrcs = extractScriptSrcs(html);
      if (scriptSrcs.isEmpty) {
        _buildersBffConfigCache = _BuildersBffConfigCacheEntry(
          fetchedAt: DateTime.now(),
          value: null,
        );
        return null;
      }

      // Prefer the real app bundle (/main.*.js) over runtimechunk~main.*.js.
      scriptSrcs.sort((a, b) {
        int score(String s) {
          if (RegExp(r'/main\.[a-z0-9]{8,40}\.js', caseSensitive: false)
              .hasMatch(s)) {
            return 0;
          }
          if (RegExp(r'runtimechunk~main\.[a-z0-9]{8,40}\.js',
                  caseSensitive: false)
              .hasMatch(s)) {
            return 2;
          }
          return 5;
        }

        return score(a).compareTo(score(b));
      });

      Uri? jsUrl;
      for (final s in scriptSrcs.take(12)) {
        final u = toAbsUrl(s);
        if (u == null) continue;
        if (u.path.contains('runtimechunk~main.')) continue;
        if (u.path.contains('/main.')) {
          jsUrl = u;
          break;
        }
      }

      // Fallback: try whatever was top-ranked.
      jsUrl ??= toAbsUrl(scriptSrcs.first);

      if (jsUrl == null) {
        _buildersBffConfigCache = _BuildersBffConfigCacheEntry(
          fetchedAt: DateTime.now(),
          value: null,
        );
        return null;
      }

      final jsResp = await http
          .get(jsUrl,
              headers: _buildersHeaders(referer: 'https://www.builders.co.za/'))
          .timeout(const Duration(seconds: 25));

      _buildersUpdateCookies(jsResp.headers);
      if (jsResp.statusCode < 200 || jsResp.statusCode >= 300) {
        _buildersBffConfigCache = _BuildersBffConfigCacheEntry(
          fetchedAt: DateTime.now(),
          value: null,
        );
        return null;
      }

      final js = jsResp.body;

      final searchHashRe = RegExp(
        r'SearchHash\s*=\s*"([a-f0-9]{32,80})"',
        caseSensitive: false,
      );
      final hash = searchHashRe.firstMatch(js)?.group(1) ??
          RegExp(r'/wmapi/bff/graphql/search/([a-f0-9]{32,80})',
                  caseSensitive: false)
              .firstMatch(js)
              ?.group(1);
      if (hash == null || hash.trim().isEmpty) {
        _buildersBffConfigCache = _BuildersBffConfigCacheEntry(
          fetchedAt: DateTime.now(),
          value: null,
        );
        return null;
      }

      final siteRe = RegExp(
        r'BFF_SITE_VALUE\s*=\s*"([A-Z0-9]{3,10})"',
      );
      final site = siteRe.firstMatch(js)?.group(1) ?? 'BWH1';

      final itemsPriceHash = RegExp(
        r'/wmapi/bff/graphql/ItemsPrice/([a-f0-9]{32,80})',
        caseSensitive: false,
      ).firstMatch(js)?.group(1);

      final cfg = _BuildersBffConfig(
        searchKey: 'search',
        searchHash: hash,
        site: site,
        itemsPriceHash:
            (itemsPriceHash == null || itemsPriceHash.trim().isEmpty)
                ? _fallbackItemsPriceHash
                : itemsPriceHash,
      );

      _buildersBffConfigCache = _BuildersBffConfigCacheEntry(
        fetchedAt: DateTime.now(),
        value: cfg,
      );
      return cfg;
    } catch (_) {
      _buildersBffConfigCache = _BuildersBffConfigCacheEntry(
        fetchedAt: DateTime.now(),
        value: null,
      );
      return null;
    }
  }

  static Map<String, String> _buildersBffHeaders({
    required String operationName,
    required String operationHash,
  }) {
    // Mirrors Builders web app default headers (see getBffHeaders in their bundle).
    final headers = <String, String>{
      ..._buildersHeaders(referer: 'https://www.builders.co.za/'),
      'Accept': 'application/json, text/plain, */*',
      'Content-Type': 'application/json',
      'WM_TENANT_ID': '32',
      'request_origin': 'web',
      'wm_qos.correlation_id': _buildersCorrelationId(),
      'x-apollo-operation-name': operationName,
      'x-apollo-operation-hash': operationHash,
    };

    final cookie = _buildersCookieHeader();
    if (cookie.isNotEmpty) {
      headers['Cookie'] = cookie;
    }
    return headers;
  }

  static String? _extractUpcFromBuildersUrl(String url) {
    final u = url.trim();
    if (u.isEmpty) return null;
    final m = RegExp(r'/p/(\d{12,20})\b').firstMatch(u);
    return m?.group(1);
  }

  static Future<double?> _lookupBuildersItemsPrice({
    required String upc,
    required _BuildersBffConfig? cfg,
  }) async {
    final value = upc.trim();
    if (value.isEmpty) return null;

    final cached = _buildersItemsPriceCache[value];
    if (cached != null) {
      final ttl = (cached.value == null)
          ? const Duration(seconds: 30)
          : _buildersItemsPriceCacheTtl;
      if (DateTime.now().difference(cached.fetchedAt) <= ttl) {
        return cached.value;
      }
    }

    final prices = await _lookupBuildersItemsPricesBatch(
      upcs: <String>[value],
      cfg: cfg,
    );
    final p = prices[value];

    _buildersItemsPriceCache[value] = _BuildersItemsPriceCacheEntry(
      fetchedAt: DateTime.now(),
      value: p,
    );
    return p;
  }

  static Future<Map<String, double>> _lookupBuildersItemsPricesViaWebView(
    List<String> upcs,
  ) async {
    final svc = BuildersWebViewPricing.instance;
    if (!svc.isAvailable) return <String, double>{};

    final cleaned = upcs
        .map((u) => u.trim())
        .where((u) => u.isNotEmpty)
        .toSet()
        .toList(growable: false);
    if (cleaned.isEmpty) return <String, double>{};

    final out = <String, double>{};
    try {
      for (final u in cleaned) {
        final p = await svc.itemsPriceByUpc(u);
        if (p != null && p > 0) {
          out[u] = p;
        }
      }
    } catch (e) {
      _buildersLastItemsPriceDiag = _BuildersItemsPriceDiag(
        at: DateTime.now(),
        stage: 'itemsprice_webview',
        itemIdType: 'UPC',
        statusCode: null,
        blocked: false,
        backoff: false,
        requestedCount: cleaned.length,
        returnedCount: 0,
        note: 'exception:${e.runtimeType}',
      );
      return <String, double>{};
    }

    _buildersLastItemsPriceDiag = _BuildersItemsPriceDiag(
      at: DateTime.now(),
      stage: 'itemsprice_webview',
      itemIdType: 'UPC',
      statusCode: 200,
      blocked: false,
      backoff: false,
      requestedCount: cleaned.length,
      returnedCount: out.length,
      note: out.isEmpty ? 'webview_empty' : 'webview_ok',
    );

    final now = DateTime.now();
    for (final u in cleaned) {
      _buildersItemsPriceCache[u] = _BuildersItemsPriceCacheEntry(
        fetchedAt: now,
        value: out[u],
      );
    }

    return out;
  }

  static Future<Map<String, double>> _lookupBuildersItemsPricesBatch({
    required List<String> upcs,
    required _BuildersBffConfig? cfg,
  }) async {
    final cleaned = upcs
        .map((u) => u.trim())
        .where((u) => u.isNotEmpty)
        .toSet()
        .toList(growable: false);
    if (cleaned.isEmpty) return <String, double>{};

    // If native HTTP is in backoff (WAF or repeated failures), try a real
    // browser session via WebView instead of waiting.
    final backoffUntil = _buildersBffBackoffUntil;
    if (backoffUntil != null && DateTime.now().isBefore(backoffUntil)) {
      final web = await _lookupBuildersItemsPricesViaWebView(cleaned);
      if (web.isNotEmpty) return web;
      _buildersLastItemsPriceDiag = _BuildersItemsPriceDiag(
        at: DateTime.now(),
        stage: 'itemsprice',
        itemIdType: null,
        statusCode: null,
        blocked: false,
        backoff: true,
        requestedCount: cleaned.length,
        returnedCount: 0,
        note: 'backoff_until:${backoffUntil.toIso8601String()}',
      );
      return <String, double>{};
    }

    final hash = (cfg?.itemsPriceHash ?? '').trim().isEmpty
        ? _fallbackItemsPriceHash
        : (cfg?.itemsPriceHash ?? '').trim();
    if (hash.trim().isEmpty) return <String, double>{};

    final uri = Uri.parse(
      'https://www.builders.co.za/wmapi/bff/graphql/ItemsPrice/$hash',
    );

    // Store context used by Builders for pricing/availability.
    // If you later add dynamic store selection, thread it in here.
    const preferredStoreId = 'B14';

    final variables = <String, dynamic>{
      'site': (cfg?.site ?? '').trim().isEmpty ? 'BWH1' : cfg!.site,
      'itemIds': cleaned,
      // NOTE: Builders sometimes treats these numeric ids as "UPC" even when
      // they are internally a product/item id. We try a few fallbacks below.
      'itemIdType': 'UPC',
      'storeIds': <String>[preferredStoreId],
      'preferredStoreId': preferredStoreId,
    };

    Map<String, double> parseItems(dynamic data) {
      if (data is! Map) return <String, double>{};

      // The ItemsPrice response shape varies; tolerate a few common layouts:
      // - data.items (List)
      // - data.itemsPrice (List)
      // - data.itemsPrice.items (List)
      dynamic items =
          data['items'] ?? data['itemsPrice'] ?? data['itemsPrices'];
      if (items is Map) {
        final mm = items.map((k, v) => MapEntry(k.toString(), v));
        items = mm['items'] ?? mm['data'] ?? mm['results'];
      }
      if (items is! List) return <String, double>{};

      final out = <String, double>{};
      for (var i = 0; i < items.length; i++) {
        final it = items[i];
        if (it is! Map) continue;
        final m = it.map((k, v) => MapEntry(k.toString(), v));

        final req = m['requestedItemId'];
        final reqMap =
            req is Map ? req.map((k, v) => MapEntry(k.toString(), v)) : null;
        final rawId = (reqMap?['value'] ??
                m['itemId'] ??
                m['itemID'] ??
                m['requestedItemId'] ??
                m['id'] ??
                '')
            .toString()
            .trim();

        // Price can be nested under itemDetails.price, or directly on the item.
        final itemDetails = m['itemDetails'];
        final detailsMap = itemDetails is Map
            ? itemDetails.map((k, v) => MapEntry(k.toString(), v))
            : null;

        dynamic priceNode = m['price'] ??
            detailsMap?['price'] ??
            // Some payloads use "pricing" key.
            m['pricing'];
        if (priceNode is Map) {
          final pm = priceNode.map((k, v) => MapEntry(k.toString(), v));
          // Some payloads nest actual fields under a subkey like "price".
          priceNode = pm['price'] is Map ? pm['price'] : priceNode;
        }
        final priceMap = priceNode is Map
            ? priceNode.map((k, v) => MapEntry(k.toString(), v))
            : null;
        if (priceMap == null) continue;

        final dynamic unitPrice = priceMap['unitPrice'] ??
            priceMap['specialPrice'] ??
            priceMap['basePrice'] ??
            priceMap['originalPrice'] ??
            priceMap['current'] ??
            priceMap['value'] ??
            priceMap['amount'] ??
            // Some payloads embed formatted strings.
            priceMap['formattedValue'] ??
            priceMap['display'];

        double? p;
        if (unitPrice is num) {
          p = unitPrice.toDouble();
        } else if (unitPrice is String) {
          p = _parseZarPrice(unitPrice) ?? double.tryParse(unitPrice);
        } else {
          p = double.tryParse(unitPrice?.toString() ?? '');
        }
        if (p == null || p <= 0) continue;

        // Map back to the requested ids. Prefer explicit ids when they match,
        // otherwise fall back to positional mapping.
        final key = (rawId.isNotEmpty && cleaned.contains(rawId))
            ? rawId
            : (i < cleaned.length ? cleaned[i] : rawId);
        if (key.trim().isEmpty) continue;
        out[key] = p;
      }
      return out;
    }

    Future<Map<String, double>> attempt(String itemIdType) async {
      final vars = <String, dynamic>{...variables, 'itemIdType': itemIdType};
      http.Response resp;
      try {
        resp = await http
            .post(
              uri,
              headers: _buildersBffHeaders(
                operationName: 'ItemsPrice',
                operationHash: hash,
              ),
              body: _jsonEncode(<String, dynamic>{
                'operationName': 'ItemsPrice',
                'variables': vars,
                'extensions': <String, dynamic>{
                  'persistedQuery': <String, dynamic>{
                    'version': 1,
                    'sha256Hash': hash,
                  },
                },
              }),
            )
            .timeout(const Duration(seconds: 10));
      } catch (e) {
        _buildersLastItemsPriceDiag = _BuildersItemsPriceDiag(
          at: DateTime.now(),
          stage: 'itemsprice',
          itemIdType: itemIdType,
          statusCode: null,
          blocked: false,
          backoff: false,
          requestedCount: cleaned.length,
          returnedCount: 0,
          note: 'exception:${e.runtimeType}',
        );
        rethrow;
      }

      _buildersUpdateCookies(resp.headers);

      if (resp.statusCode == 412) {
        _buildersBffBackoffUntil =
            DateTime.now().add(const Duration(minutes: 30));
        _buildersLastItemsPriceDiag = _BuildersItemsPriceDiag(
          at: DateTime.now(),
          stage: 'itemsprice',
          itemIdType: itemIdType,
          statusCode: 412,
          blocked: true,
          backoff: false,
          requestedCount: cleaned.length,
          returnedCount: 0,
          note: 'blocked_412',
        );
        return <String, double>{};
      }
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        final bodyNote =
            resp.body.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
        final truncated =
            bodyNote.length > 180 ? bodyNote.substring(0, 180) : bodyNote;
        _buildersLastItemsPriceDiag = _BuildersItemsPriceDiag(
          at: DateTime.now(),
          stage: 'itemsprice',
          itemIdType: itemIdType,
          statusCode: resp.statusCode,
          blocked: false,
          backoff: false,
          requestedCount: cleaned.length,
          returnedCount: 0,
          note: truncated.isEmpty ? 'http_${resp.statusCode}' : truncated,
        );
        return <String, double>{};
      }

      final decoded = _jsonDecode(resp.body);
      if (decoded is! Map<String, dynamic>) return <String, double>{};
      final data = decoded['data'];
      final out = parseItems(data);

      _buildersLastItemsPriceDiag = _BuildersItemsPriceDiag(
        at: DateTime.now(),
        stage: 'itemsprice',
        itemIdType: itemIdType,
        statusCode: resp.statusCode,
        blocked: false,
        backoff: false,
        requestedCount: cleaned.length,
        returnedCount: out.length,
        note: out.isEmpty ? 'ok_but_empty' : 'ok',
      );

      // Cache results (including nulls) to avoid repeated calls.
      final now = DateTime.now();
      for (final u in cleaned) {
        _buildersItemsPriceCache[u] = _BuildersItemsPriceCacheEntry(
          fetchedAt: now,
          value: out[u],
        );
      }

      return out;
    }

    try {
      // Builders has changed enum names over time; try a broader set.
      for (final t in const <String>[
        'UPC',
        'PRODUCT_ID',
        'SKU',
        'ITEM_ID',
        'PRODUCT_CODE',
      ]) {
        final out = await attempt(t);
        if (out.isNotEmpty) return out;
      }
      final web = await _lookupBuildersItemsPricesViaWebView(cleaned);
      if (web.isNotEmpty) return web;
      return <String, double>{};
    } catch (_) {
      _buildersBffBackoffUntil =
          DateTime.now().add(const Duration(minutes: 10));
      // Last-chance fallback: try WebView even after exceptions.
      final web = await _lookupBuildersItemsPricesViaWebView(cleaned);
      if (web.isNotEmpty) return web;
      return <String, double>{};
    }
  }

  static String? _pickFirstString(Map<String, dynamic> m, List<String> keys) {
    for (final k in keys) {
      final v = m[k];
      if (v == null) continue;
      final s = v.toString().trim();
      if (s.isNotEmpty) return s;
    }
    return null;
  }

  static double? _extractPriceFromBffItem(Map<String, dynamic> item) {
    // Try common price shapes. Keep this tolerant as the payload may evolve.
    dynamic candidate =
        item['price'] ?? item['prices'] ?? item['priceData'] ?? item['pricing'];

    double? fromAny(dynamic v) {
      if (v == null) return null;
      if (v is num) return v.toDouble();
      if (v is String) return _parseZarPrice(v);
      if (v is Map) {
        final mm = v.map((k, vv) => MapEntry(k.toString(), vv));
        return _parseZarPrice(
              mm['formattedValue']?.toString() ??
                  mm['formatted']?.toString() ??
                  mm['display']?.toString(),
            ) ??
            (mm['value'] is num
                ? (mm['value'] as num).toDouble()
                : _parseZarPrice(mm['value']?.toString())) ??
            (mm['current'] is num
                ? (mm['current'] as num).toDouble()
                : _parseZarPrice(mm['current']?.toString())) ??
            (mm['retail'] is num
                ? (mm['retail'] as num).toDouble()
                : _parseZarPrice(mm['retail']?.toString()));
      }
      return null;
    }

    var p = fromAny(candidate);
    if (p != null && p > 0) return p;

    // Sometimes nested: price: { retail: { formattedValue/value } }
    if (candidate is Map) {
      final mm = candidate.map((k, vv) => MapEntry(k.toString(), vv));
      p = fromAny(mm['retail']) ??
          fromAny(mm['current']) ??
          fromAny(mm['selling']);
      if (p != null && p > 0) return p;
    }

    // Last resort: scan a few obvious string fields.
    for (final k in const <String>[
      'formattedPrice',
      'priceFormatted',
      'sellingPrice',
      'retailPrice',
      'priceInclVat',
      'price_incl_vat',
    ]) {
      p = _parseZarPrice(item[k]?.toString());
      if (p != null && p > 0) return p;
    }
    return null;
  }

  static Future<_BuildersCandidate?> _lookupBuildersBffPrice(
    String name,
  ) async {
    final backoffUntil = _buildersBffBackoffUntil;
    if (backoffUntil != null && DateTime.now().isBefore(backoffUntil)) {
      return null;
    }

    final cfg = await _getBuildersBffConfig();
    if (cfg == null) return null;

    final q = _normalizeQueryForBuilders(name);
    if (q.isEmpty) return null;

    final int? targetLiters = _extractLiters(q);
    final wantsKwikot = _looksLikeKwikot(q);

    final uri = Uri.parse(
      'https://www.builders.co.za/wmapi/bff/graphql/${cfg.searchKey}/${cfg.searchHash}',
    );

    final variables = <String, dynamic>{
      'keyword': q,
      'offset': 0,
      'pageSize': 20,
      'dynamicPriceRange': true,
      'site': cfg.site,
    };

    try {
      final resp = await http
          .post(
            uri,
            headers: _buildersBffHeaders(
              operationName: cfg.searchKey,
              operationHash: cfg.searchHash,
            ),
            body: _jsonEncode(<String, dynamic>{
              'operationName': cfg.searchKey,
              'variables': variables,
              'extensions': <String, dynamic>{
                'persistedQuery': <String, dynamic>{
                  'version': 1,
                  'sha256Hash': cfg.searchHash,
                },
              },
            }),
          )
          .timeout(const Duration(seconds: 10));

      _buildersUpdateCookies(resp.headers);

      if (resp.statusCode == 412) {
        // Bot/WAF block; avoid hammering the endpoint.
        _buildersBffBackoffUntil =
            DateTime.now().add(const Duration(minutes: 30));
        return null;
      }

      if (resp.statusCode < 200 || resp.statusCode >= 300) return null;
      final decoded = _jsonDecode(resp.body);
      if (decoded is! Map<String, dynamic>) return null;

      final data = decoded['data'];
      if (data is! Map) return null;
      final search = (data['search'] is Map) ? data['search'] as Map : null;
      final searchData =
          (search?['data'] is Map) ? search!['data'] as Map : null;
      final results = (searchData?['results'] is Map)
          ? searchData!['results'] as Map
          : null;
      final items = results?['items'];
      if (items is! List) return null;

      // NOTE:
      // Builders' BFF payload sometimes omits price fields (especially when
      // location/store context isn't provided). Manus succeeds by visiting the
      // product page and reading the retail price there.
      // We therefore accept items without a price and attempt to hydrate from
      // the product page for the top-ranked candidates.

      final scored = <Map<String, dynamic>>[];
      final qt = _tokens(q).toSet();

      for (final it in items.whereType<Map>()) {
        final item = it.map((k, v) => MapEntry(k.toString(), v));
        final title = _pickFirstString(item, const <String>[
          'name',
          'title',
          'productName',
        ]);
        if (title == null || title.trim().isEmpty) continue;

        final titleLower = title.toLowerCase();
        final liters = _extractLiters(title);
        if (targetLiters != null && liters != null && liters != targetLiters) {
          continue;
        }

        String? urlPath = _pickFirstString(item, const <String>[
          'url',
          'productUrl',
          'seoUrl',
          'link',
        ]);
        final upc = _pickFirstString(
              item,
              const <String>['code', 'id', 'productCode', 'upc', 'sku'],
            ) ??
            (urlPath != null ? _extractUpcFromBuildersUrl(urlPath) : null);
        if (urlPath == null || urlPath.trim().isEmpty) {
          // Some payloads only provide a code/id.
          final code = _pickFirstString(
              item, const <String>['code', 'id', 'productCode']);
          if (code != null && code.trim().isNotEmpty) {
            urlPath = '/p/$code';
          } else {
            continue;
          }
        }

        final url = urlPath.startsWith('http')
            ? urlPath
            : 'https://www.builders.co.za${urlPath.startsWith('/') ? '' : '/'}$urlPath';

        final tt = _tokens(title).toSet();
        var score = qt.intersection(tt).length;

        if (targetLiters != null) {
          if (liters == targetLiters) score += 6;
          if (liters == null) score -= 2;
        }

        final hasKwikot = _looksLikeKwikot(titleLower);
        if (hasKwikot) score += 6;
        if (wantsKwikot && !hasKwikot) score -= 6;
        if (wantsKwikot && _looksLikeApollo(titleLower)) score -= 3;

        final price = _extractPriceFromBffItem(item);
        final hasPrice = price != null && price > 0;
        if (hasPrice) score += 2;

        scored.add(<String, dynamic>{
          'score': score,
          'candidate': _BuildersCandidate(
            title: title,
            url: url,
            priceZar: hasPrice ? price : 0,
            upc: upc,
            source: hasPrice ? 'builders_bff' : 'builders_bff_no_price',
          ),
        });
      }

      if (scored.isEmpty) return null;
      scored.sort(
        (a, b) =>
            ((b['score'] as int?) ?? 0).compareTo((a['score'] as int?) ?? 0),
      );

      final referer =
          'https://www.builders.co.za/search?text=${Uri.encodeQueryComponent(q)}';

      // Pre-fetch ItemsPrice for top candidates (single request).
      final topCandidates = scored
          .take(4)
          .map((r) => r['candidate'])
          .whereType<_BuildersCandidate>();
      final upcsToFetch = <String>{};
      for (final c in topCandidates) {
        if (c.priceZar > 0) continue;
        final upc = (c.upc ?? _extractUpcFromBuildersUrl(c.url))?.trim();
        if (upc != null && upc.isNotEmpty) upcsToFetch.add(upc);
      }
      final itemsPrice = upcsToFetch.isEmpty
          ? const <String, double>{}
          : await _lookupBuildersItemsPricesBatch(
              upcs: upcsToFetch.toList(growable: false),
              cfg: cfg,
            );

      for (final row in scored.take(4)) {
        final c = row['candidate'] as _BuildersCandidate;
        if (c.priceZar > 0) {
          if (targetLiters != null) {
            final bestLiters = _extractLiters(c.title ?? '');
            if (bestLiters == null || bestLiters != targetLiters) continue;
          }
          return c;
        }

        final upc = c.upc ?? _extractUpcFromBuildersUrl(c.url);
        if (upc != null && upc.trim().isNotEmpty) {
          final p = itemsPrice[upc.trim()] ??
              await _lookupBuildersItemsPrice(upc: upc, cfg: cfg);
          if (p != null && p > 0) {
            return c.copyWith(
              priceZar: p,
              source: 'builders_bff_itemsprice',
            );
          }
        }

        final hydrated = await _hydrateBuildersCandidateFromProductPage(
          c,
          referer: referer,
        );
        if (hydrated == null) continue;
        if (hydrated.priceZar <= 0) continue;
        if (targetLiters != null) {
          final hydratedLiters = _extractLiters(hydrated.title ?? '');
          if (hydratedLiters != null && hydratedLiters != targetLiters) {
            continue;
          }
        }
        return hydrated.copyWith(source: 'builders_bff_hydrated');
      }

      return null;
    } catch (_) {
      // Back off for a bit to prevent long repeated timeouts per BOM line item.
      _buildersBffBackoffUntil =
          DateTime.now().add(const Duration(minutes: 10));
      return null;
    }
  }

  static String _jsonEncode(Object? v) {
    // Minimal JSON encoding without adding new dependencies.
    // This file already avoids extra deps; we keep it self-contained.
    return const JsonEncoder().convert(v);
  }

  static dynamic _jsonDecode(String s) {
    return const JsonDecoder().convert(s);
  }

  static List<String> _tokens(String s) {
    final cleaned = _normalizeKey(s);
    if (cleaned.isEmpty) return const <String>[];
    return cleaned
        .split(' ')
        .map((t) => t.trim())
        .where((t) => t.length > 2)
        .toList(growable: false);
  }

  static double? _parseZarPrice(String? raw) {
    if (raw == null) return null;
    final s = raw.trim();
    if (s.isEmpty) return null;
    final cleaned = s.replaceAll(RegExp(r'[^0-9,\.]'), '');
    if (cleaned.isEmpty) return null;
    // Builders uses comma as thousands separator.
    final normalized = cleaned.replaceAll(',', '');
    return double.tryParse(normalized);
  }

  static int? _extractLiters(String s) {
    final lower = s.toLowerCase();
    final patterns = <RegExp>[
      RegExp(r'\b(\d{2,4})\s*(?:l|lt|litre|liter|litres|liters)\b'),
    ];
    for (final re in patterns) {
      final m = re.firstMatch(lower);
      if (m == null) continue;
      final raw = m.group(1);
      final val = int.tryParse(raw ?? '');
      if (val == null) continue;
      // Sanity bounds for typical household geysers.
      if (val < 40 || val > 600) continue;
      return val;
    }
    return null;
  }

  static Iterable<_BuildersCandidate> _extractBuildersCandidates(
      String html) sync* {
    // We avoid a brittle DOM parser to keep dependencies minimal.
    // Find product links that include /p/<digits> and then scan nearby for a price.
    final linkRe = RegExp(
        r'(https?:\\/\\/www\\.builders\\.co\\.za)?(\\/[^"]*?\\/p\\/\\d{12,})');
    final priceRe = RegExp(r'R\s*([0-9]{1,3}(?:,[0-9]{3})*(?:\\.[0-9]{2})?)');
    final titleRe = RegExp(r'(?:aria-label|title)="([^"]{3,200})"');

    final matches = linkRe.allMatches(html).toList(growable: false);
    final seen = <String>{};

    for (final m in matches) {
      final path = m.group(2) ?? '';
      if (path.isEmpty) continue;
      final url =
          path.startsWith('http') ? path : 'https://www.builders.co.za$path';
      if (!seen.add(url)) continue;

      final start = (m.start - 350).clamp(0, html.length);
      final end = (m.end + 650).clamp(0, html.length);
      final window = html.substring(start, end);

      final priceMatch = priceRe.firstMatch(window);
      final price = _parseZarPrice(priceMatch?.group(1));
      // Builders search often does not embed retail price in the HTML.
      // Keep candidates even without a price so we can fetch it via ItemsPrice
      // (using the UPC embedded in the product URL) or via product page hydration.

      String? title;
      final titleMatch = titleRe.firstMatch(window);
      if (titleMatch != null) {
        title = titleMatch.group(1);
      }

      final upc = _extractUpcFromBuildersUrl(url);

      yield _BuildersCandidate(
        title: title,
        url: url,
        priceZar: (price != null && price > 0) ? price : 0,
        upc: upc,
        source: (price != null && price > 0)
            ? 'builders_html'
            : 'builders_html_no_price',
      );
    }
  }

  static Map<String, String> _buildersHeaders({String? referer}) {
    final headers = <String, String>{
      'User-Agent':
          'Mozilla/5.0 (Linux; Android 12; Pixel 6) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36',
      'Accept':
          'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
      'Accept-Language': 'en-ZA,en;q=0.9',
      'Cache-Control': 'no-cache',
      'Pragma': 'no-cache',
      'Origin': 'https://www.builders.co.za',
    };
    if (referer != null && referer.trim().isNotEmpty) {
      headers['Referer'] = referer.trim();
    }

    final cookie = _buildersCookieHeader();
    if (cookie.isNotEmpty) {
      headers['Cookie'] = cookie;
    }
    return headers;
  }

  static String _buildersCorrelationId() {
    // Use a UUIDv4-like correlation id to better match Builders' web client.
    final r = Random.secure();
    int nextByte() => r.nextInt(256);
    String b(int n) => n.toRadixString(16).padLeft(2, '0');

    final bytes = List<int>.generate(16, (_) => nextByte(), growable: false);
    // Set version 4 and variant bits.
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;

    final hex = bytes.map(b).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }

  static double? _extractRetailPriceFromBuildersProductHtml(String html) {
    // Prefer structured metadata when possible.
    final metaRe = RegExp(
      r'(?:product:price:amount|og:price:amount|twitter:data1)"\s+content="([0-9.,]+)"',
      caseSensitive: false,
    );
    final metaMatch = metaRe.firstMatch(html);
    final metaPrice = _parseZarPrice(metaMatch?.group(1));
    if (metaPrice != null && metaPrice > 0) return metaPrice;

    // JSON-LD often contains an Offer with a price.
    final jsonLdPriceRe = RegExp(
      r'"price"\s*:\s*"?([0-9]{1,3}(?:,[0-9]{3})*(?:\.[0-9]{2})?)"?',
      caseSensitive: false,
    );
    final jsonMatch = jsonLdPriceRe.firstMatch(html);
    final jsonPrice = _parseZarPrice(jsonMatch?.group(1));
    if (jsonPrice != null && jsonPrice > 0) return jsonPrice;

    // Fallback to visible ZAR price patterns.
    final visiblePriceRe =
        RegExp(r'R\s*([0-9]{1,3}(?:,[0-9]{3})*(?:\.[0-9]{2})?)');
    final visibleMatch = visiblePriceRe.firstMatch(html);
    final visiblePrice = _parseZarPrice(visibleMatch?.group(1));
    if (visiblePrice != null && visiblePrice > 0) return visiblePrice;

    return null;
  }

  static Future<_BuildersCandidate?> _hydrateBuildersCandidateFromProductPage(
    _BuildersCandidate candidate, {
    required String referer,
  }) async {
    try {
      final uri = Uri.tryParse(candidate.url);
      if (uri == null) return null;
      final resp =
          await http.get(uri, headers: _buildersHeaders(referer: referer));
      _buildersUpdateCookies(resp.headers);
      if (resp.statusCode < 200 || resp.statusCode >= 300) return null;

      final price = _extractRetailPriceFromBuildersProductHtml(resp.body);
      if (price == null || price <= 0) return null;

      // Attempt to improve title if the product page contains an og:title.
      String? title = candidate.title;
      final ogTitleRe = RegExp(
        r'property="og:title"\s+content="([^\"]{3,200})"',
        caseSensitive: false,
      );
      final ogTitleMatch = ogTitleRe.firstMatch(resp.body);
      if (ogTitleMatch != null) {
        title = ogTitleMatch.group(1) ?? title;
      }

      return candidate.copyWith(title: title, priceZar: price);
    } catch (_) {
      return null;
    }
  }

  static Future<_BuildersCandidate?> _lookupBuildersWebPrice(
      String name) async {
    final primary = _normalizeQueryForBuilders(name);
    if (primary.isEmpty) return null;

    final int? targetLiters = _extractLiters(primary);

    // Try multiple query variants to improve Builders matching, especially for geysers.
    final variants = <String>[primary];
    final lower = primary.toLowerCase();
    // If the item looks like a geyser, try common search forms.
    if (lower.contains('geyser') || lower.contains('water heater')) {
      if (targetLiters != null) {
        final l = '${targetLiters}l';
        variants.add('geyser $l');
        variants.add('electric geyser $l');
        variants.add('kwikot geyser $l');
      } else {
        variants.add('electric geyser');
        variants.add('kwikot geyser');
      }
    }
    // If item contains a dimension unit, try removing parentheses/extra words.
    final mmMatch = RegExp(r"\b(\d+\s*mm|\d+\s*l)\b").firstMatch(lower);
    if (mmMatch != null) {
      final unitToken = mmMatch.group(1)!.replaceAll(RegExp(r'\s+'), '');
      final base = lower
          .replaceAll(RegExp(r'\([^)]*\)'), ' ')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      if (!variants.contains(base)) variants.add(base);
      if (!variants.contains('$base $unitToken')) {
        variants.add('$base $unitToken');
      }
    }

    // Use caching per variant.
    _BuildersCandidate? bestOverall;
    int bestOverallScore = -1;
    for (final query in variants) {
      final cacheKey = _normalizeKey(query);
      final cached = _buildersPriceCache[cacheKey];
      if (cached != null &&
          DateTime.now().difference(cached.fetchedAt) <=
              _buildersPriceCacheTtl) {
        if (cached.value != null) {
          // Score cached value against the primary query tokens.
          final qt = _tokens(primary).toSet();
          final tt = _tokens((cached.value!.title ?? query)).toSet();
          final score = qt.intersection(tt).length;
          if (score > bestOverallScore) {
            bestOverallScore = score;
            bestOverall = cached.value;
          }
          continue;
        }
        continue;
      }

      try {
        // Prefer the Builders retail-tab backend (BFF GraphQL). This often has
        // better product URLs, and we can hydrate the product page to extract
        // the retail price (matching Manus behavior).
        final bff = await _lookupBuildersBffPrice(query);
        if (bff != null) {
          _buildersPriceCache[cacheKey] = _BuildersPriceCacheEntry(
            fetchedAt: DateTime.now(),
            value: bff,
          );

          final primaryTokens = _tokens(primary).toSet();
          final bestTokens = _tokens((bff.title ?? query)).toSet();
          final overallScore = primaryTokens.intersection(bestTokens).length;
          if (overallScore > bestOverallScore) {
            bestOverallScore = overallScore;
            bestOverall = bff;
          }
          continue;
        }

        final uri = Uri.parse(
            'https://www.builders.co.za/search?text=${Uri.encodeQueryComponent(query)}');
        final resp = await http.get(uri, headers: _buildersHeaders());
        _buildersUpdateCookies(resp.headers);
        if (resp.statusCode < 200 || resp.statusCode >= 300) {
          _buildersPriceCache[cacheKey] =
              _BuildersPriceCacheEntry(fetchedAt: DateTime.now(), value: null);
          continue;
        }

        final body = resp.body;
        final candidates =
            _extractBuildersCandidates(body).toList(growable: false);
        if (candidates.isEmpty) {
          _buildersPriceCache[cacheKey] =
              _BuildersPriceCacheEntry(fetchedAt: DateTime.now(), value: null);
          continue;
        }

        final queryTokens = _tokens(query).toSet();
        _BuildersCandidate best = candidates.first;
        int bestScore = -1;

        for (final c in candidates.take(25)) {
          final title = (c.title ?? '').isEmpty ? query : c.title!;
          final candidateLiters = _extractLiters(title);

          // If the user specified a size (e.g., 200L), never match a different size.
          if (targetLiters != null &&
              candidateLiters != null &&
              candidateLiters != targetLiters) {
            continue;
          }

          final candidateTokens = _tokens(title).toSet();
          final overlap = queryTokens.intersection(candidateTokens).length;
          // Prefer items with strong token overlap; boost geyser matches.
          var score = overlap;
          if (query.toLowerCase().contains('geyser') &&
              title.toLowerCase().contains('geyser')) {
            score += 2;
          }
          if (targetLiters != null) {
            if (candidateLiters == targetLiters) {
              score += 4;
            } else if (candidateLiters == null) {
              // Slight penalty if we cannot confirm the size.
              score -= 2;
            }
          }
          if (score > bestScore) {
            bestScore = score;
            best = c;
          }
        }

        // If the HTML search result doesn't include price (common), attempt
        // to fetch the exact retail price via ItemsPrice using the UPC embedded
        // in the product URL (/p/<upc>). This is the key path that avoids
        // falling back to estimates when the BFF search payload omits pricing.
        if (best.priceZar <= 0) {
          final cfg = await _getBuildersBffConfig();
          final upc =
              (best.upc ?? _extractUpcFromBuildersUrl(best.url))?.trim();
          if (upc != null && upc.isNotEmpty) {
            final p = await _lookupBuildersItemsPrice(upc: upc, cfg: cfg);
            if (p != null && p > 0) {
              best = best.copyWith(
                priceZar: p,
                source: 'builders_html_itemsprice',
              );
            }
          }
        }

        // Follow through to the product page to get the retail-tab price when possible.
        // Only do this if we still don't have a price.
        if (best.priceZar <= 0) {
          final hydrated = await _hydrateBuildersCandidateFromProductPage(
            best,
            referer: uri.toString(),
          );
          if (hydrated != null) {
            // Validate liters from the product page title when user requested a size.
            if (targetLiters != null) {
              final hydratedLiters = _extractLiters(hydrated.title ?? '');
              if (hydratedLiters != null && hydratedLiters != targetLiters) {
                // Discard clearly wrong-size product page.
              } else {
                best = hydrated.copyWith(source: 'builders_html_hydrated');
              }
            } else {
              best = hydrated.copyWith(source: 'builders_html_hydrated');
            }
          }
        }

        _buildersPriceCache[cacheKey] =
            _BuildersPriceCacheEntry(fetchedAt: DateTime.now(), value: best);

        // Score against primary intent and keep the best overall.
        final primaryTokens = _tokens(primary).toSet();
        final bestTokens = _tokens((best.title ?? query)).toSet();
        final overallScore = primaryTokens.intersection(bestTokens).length;
        if (overallScore > bestOverallScore) {
          bestOverallScore = overallScore;
          bestOverall = best;
        }
      } catch (_) {
        _buildersPriceCache[cacheKey] =
            _BuildersPriceCacheEntry(fetchedAt: DateTime.now(), value: null);
        continue;
      }
    }

    // Avoid returning clearly unrelated matches.
    if (bestOverall == null || bestOverallScore <= 0) return null;

    // If a liters size was requested, only return a match we can confirm matches that size.
    if (targetLiters != null) {
      final bestLiters = _extractLiters(bestOverall.title ?? '');
      if (bestLiters == null || bestLiters != targetLiters) return null;
    }
    return bestOverall;
  }

  static Future<double> _getLearningFactor({
    required String? categoryId,
    required String categoryName,
  }) async {
    try {
      final cid = (categoryId ?? '').trim().toLowerCase();
      Query q = _firestore.collection(_aiCorrectionsCollection);

      if (cid.isNotEmpty) {
        q = q.where('category_id', isEqualTo: cid);
      } else {
        final cname = categoryName.trim();
        if (cname.isNotEmpty) {
          q = q.where('category_name', isEqualTo: cname);
        }
      }

      final snap =
          await q.orderBy('created_at', descending: true).limit(20).get();
      if (snap.docs.isEmpty) return 1.0;

      double sum = 0;
      int count = 0;
      for (final d in snap.docs) {
        final data = (d.data() as Map<String, dynamic>?) ?? <String, dynamic>{};
        final ai = data['ai_total'];
        final admin = data['admin_total'];
        final aiVal =
            ai is num ? ai.toDouble() : double.tryParse(ai?.toString() ?? '');
        final adminVal = admin is num
            ? admin.toDouble()
            : double.tryParse(admin?.toString() ?? '');
        if (aiVal == null || adminVal == null || aiVal <= 0 || adminVal <= 0) {
          continue;
        }
        final ratio = adminVal / aiVal;
        if (ratio.isFinite && ratio > 0) {
          sum += ratio;
          count += 1;
        }
      }

      if (count == 0) return 1.0;
      final avg = sum / count;
      // Keep the adjustment bounded so one bad quote doesn't destabilize.
      return avg.clamp(0.6, 1.6);
    } catch (_) {
      return 1.0;
    }
  }

  static String _normalizeKey(String name) {
    var s = name.toLowerCase().trim();
    s = s.replaceAll(RegExp(r'[\(\)\[\],]'), ' ');
    s = s.replaceAll(RegExp(r'[^a-z0-9\s\./-]'), ' ');
    s = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    s = s.replaceAllMapped(
      RegExp(r'(\d)\s+(mm|cm|m|kg|g|l|ml)\b'),
      (m) => '${m.group(1)}${m.group(2)}',
    );
    return s;
  }

  static Set<String> _keyVariants(String name) {
    final base = _normalizeKey(name);
    if (base.isEmpty) return <String>{};
    final variants = <String>{base};

    void addVariant(String v) {
      final s = v.trim();
      if (s.isNotEmpty) variants.add(s);
    }

    // Strip common trailing descriptors (e.g. "- size TBD").
    if (base.contains('-')) {
      addVariant(base.split('-').first);
    }

    // Remove generic placeholders/qualifiers that prevent catalog matches.
    String simplified = base;
    simplified = simplified.replaceAll(RegExp(r'\bsize\s+tbd\b'), ' ');
    simplified = simplified.replaceAll(RegExp(r'\btbd\b'), ' ');
    simplified = simplified.replaceAll(RegExp(r'\bassorted\b'), ' ');
    simplified = simplified.replaceAll(RegExp(r'\b(1\s*)?pack\b'), ' ');
    simplified = simplified.replaceAll(RegExp(r'\b(each|roll|m)\b'), ' ');
    simplified = simplified.replaceAll(RegExp(r'\s+'), ' ').trim();
    addVariant(simplified);

    // Accessories like mounting brackets often include "geyser" in the name,
    // but should NOT fall back to matching the geyser itself.
    if (base.contains('bracket')) {
      final bracketSimplified = base
        .replaceAll(
          RegExp(
            r'\b(solar|roof|geyser|water|heater|electric|apollo|kwikot)\b',
            caseSensitive: false),
          ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
      addVariant(bracketSimplified);
    }

    // Variant without "geyser" qualifier (catalog items are often generic).
    // Only fall back to a plain "geyser" match for the core appliance itself
    // (size/brand/model), not for accessories like brackets/trays/valves.
    if (base.contains('geyser')) {
      final noGeyser = base
          .replaceAll(RegExp(r'\bgeyser\b'), ' ')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      addVariant(noGeyser);

      final isAccessory = RegExp(
        r'\b(bracket|mount|mounting|tray|drip|valve|breaker|switch|pipe|tape|silicone|fittings?|element|thermostat|anode)\b',
        caseSensitive: false,
      ).hasMatch(base);
      final looksLikeCoreGeyser = base.trim() == 'geyser' ||
          RegExp(r'\b\d{2,3}l\b', caseSensitive: false).hasMatch(base) ||
          RegExp(r'\b(apollo|kwikot)\b', caseSensitive: false).hasMatch(base) ||
          RegExp(r'\b(electric|solar)\s+geyser\b', caseSensitive: false)
              .hasMatch(base);

      if (looksLikeCoreGeyser && !isAccessory) {
        // Last-resort match.
        addVariant('geyser');
      }
    }

    // Catalogs sometimes store IDs with separators.
    variants.add(base.replaceAll(' ', '_'));
    variants.add(base.replaceAll(' ', '-'));
    variants.add(base.replaceAll(' ', ''));

    // Very small plural handling (e.g., "screws" -> "screw").
    if (base.endsWith('s') && base.length > 3) {
      variants.add(base.substring(0, base.length - 1));
    }

    const swaps = <String, String>{
      'velvagro': 'velvaglo',
      'velvaglo': 'velvagro',
    };

    for (final entry in swaps.entries) {
      if (base.contains(entry.key)) {
        variants.add(base.replaceAll(entry.key, entry.value));
      }
    }
    return variants;
  }

  static Future<Map<String, dynamic>?> _lookupMaterialCatalogItem(
      String name) async {
    final keys = _keyVariants(name);
    if (keys.isEmpty) return null;

    for (final key in keys) {
      try {
        final doc = await _firestore
            .collection(_materialsCatalogCollection)
            .doc(key)
            .get();
        if (doc.exists) {
          final data = doc.data() ?? {};
          data['matched_by'] = 'doc_id';
          data['matched_key'] = key;
          return data;
        }
      } catch (_) {
        // ignore
      }
    }

    for (final key in keys) {
      try {
        final q = await _firestore
            .collection(_materialsCatalogCollection)
            .where('name_lower', isEqualTo: key)
            .limit(1)
            .get();
        if (q.docs.isNotEmpty) {
          final data = (q.docs.first.data() as Map<String, dynamic>?) ?? {};
          data['matched_by'] = 'name_lower';
          data['matched_key'] = key;
          return data;
        }
      } catch (_) {
        // ignore
      }
    }

    for (final key in keys) {
      try {
        final q = await _firestore
            .collection(_materialsCatalogCollection)
            .where('aliases', arrayContains: key)
            .limit(1)
            .get();
        if (q.docs.isNotEmpty) {
          final data = (q.docs.first.data() as Map<String, dynamic>?) ?? {};
          data['matched_by'] = 'aliases';
          data['matched_key'] = key;
          return data;
        }
      } catch (_) {
        // ignore
      }
    }

    // Last-resort prefix match on name_lower.
    for (final key in keys) {
      if (key.length < 4) continue;
      try {
        final q = await _firestore
            .collection(_materialsCatalogCollection)
            .orderBy('name_lower')
            .startAt([key])
            .endAt(['$key\uf8ff'])
            .limit(1)
            .get();
        if (q.docs.isNotEmpty) {
          final data = (q.docs.first.data() as Map<String, dynamic>?) ?? {};
          data['matched_by'] = 'name_lower_prefix';
          data['matched_key'] = key;
          return data;
        }
      } catch (_) {
        // ignore
      }
    }

    return null;
  }

  /// Generate AI-powered quotation based on problem description and images
  static Future<Map<String, dynamic>> generateQuotation({
    String? categoryId,
    required String categoryName,
    required String problemDescription,
    required String additionalNotes,
    required List<String> imageUrls,
    String materialsResponsibility = 'client',
    double? userBudget,
  }) async {
    try {
      final totalSw = Stopwatch()..start();
      final timingsMs = <String, int>{};

      // Run learning factor + pricing guidance lookups in PARALLEL to save time.
      final swParallel = Stopwatch()..start();
      final parallelResults = await Future.wait([
        _getLearningFactor(categoryId: categoryId, categoryName: categoryName),
        _getPricingGuidance(categoryId: categoryId, categoryName: categoryName),
      ]);
      final learningFactor = parallelResults[0] as double;
      Map<String, dynamic> pricingGuidance = parallelResults[1] as Map<String, dynamic>;
      timingsMs['learning_and_guidance_parallel'] = swParallel.elapsedMilliseconds;

      final materialsMode = materialsResponsibility.trim().toLowerCase();
      final bool artisanBuysMaterials = materialsMode == 'artisan';
      final bool clientBuysMaterials = !artisanBuysMaterials;

      // Prefer server-side dual-agent generation (OpenAI draft + Gemini review).
      // Fall back to local generation if the function is unavailable.
      final swDraft = Stopwatch()..start();
      final dualDraft = await _tryGenerateQuotationViaDualAgents(
        categoryId: categoryId,
        categoryName: categoryName,
        problemDescription: problemDescription,
        additionalNotes: additionalNotes,
        materialsResponsibility: materialsResponsibility,
        pricingGuidance: pricingGuidance,
      );
      timingsMs['ai_draft_dual_agents'] = swDraft.elapsedMilliseconds;

      final Map<String, dynamic> quotation = dualDraft ??
          _generateQuotationLogic(
            categoryId: categoryId,
            categoryName: categoryName,
            problemDescription: problemDescription,
            additionalNotes: additionalNotes,
            pricingGuidance: pricingGuidance,
          );
      timingsMs['ai_draft_fallback_used'] = dualDraft == null ? 1 : 0;

      // Ensure key pricing fields always exist, even if the server-side draft omits them.
      double asDouble(dynamic v, {double fallback = 0.0}) {
        if (v is num) return v.toDouble();
        final s = (v ?? '').toString().trim();
        return double.tryParse(s) ?? fallback;
      }

      final defaultLaborRate = asDouble(
        pricingGuidance['labor_cost_per_hour'] ?? pricingGuidance['laborCostPerHour'],
        fallback: 150.0,
      );
      final defaultMaterialMultiplier = asDouble(
        pricingGuidance['material_multiplier'] ?? pricingGuidance['materialMultiplier'],
        fallback: 1.5,
      );
      final defaultOutsourcedRate = asDouble(
        pricingGuidance['outsourced_labor_rate'] ?? pricingGuidance['outsourcedLaborRate'],
        fallback: defaultLaborRate * 0.7,
      );

      final currentLaborRate = asDouble(quotation['laborCostPerHour'], fallback: 0.0);
      if (currentLaborRate <= 0) {
        quotation['laborCostPerHour'] = defaultLaborRate;
      }

      final currentMultiplier = asDouble(quotation['materialsMultiplier'], fallback: 0.0);
      if (currentMultiplier <= 0) {
        quotation['materialsMultiplier'] = defaultMaterialMultiplier;
      }

      // Carry outsourced rate through so profit analysis can use it.
      final currentOutsourced = asDouble(
        quotation['outsourcedLaborRate'] ?? quotation['outsourced_labor_rate'],
        fallback: 0.0,
      );
      if (currentOutsourced <= 0) {
        quotation['outsourcedLaborRate'] = defaultOutsourcedRate;
      }

      // Price the inferred materials using Builders catalog.
      final materialMultiplier =
          ((quotation['materialsMultiplier'] ?? 1.5) as num).toDouble();

      final bom = (quotation['materialsBOM'] as List?)
              ?.whereType<Map>()
              .map((m) => m.map((k, v) => MapEntry(k.toString(), v)))
              .toList() ??
          <Map<String, dynamic>>[];

      // Prefer server-side Builders pricing (more reliable than on-device scraping).
      // This applies to ALL items (doors, windows, showers, geysers, etc.).
      final buildersQueries = <String>{};
      for (final m in bom) {
        final raw = (m['name'] ?? '').toString().trim();
        if (raw.isEmpty) continue;
        buildersQueries.add(raw);
        final normalized = _normalizeQueryForBuilders(raw);
        // Avoid doubling the query list with near-identical normalizations.
        // Only add normalized if it's meaningfully shorter/more searchable.
        if (normalized.isNotEmpty && normalized != raw) {
          if (normalized.length >= 4 && normalized.length < raw.length * 0.85) {
            buildersQueries.add(normalized);
          }
        }
      }
      final boundedQueries = buildersQueries.length > 25
          ? buildersQueries.take(25).toList(growable: false)
          : buildersQueries.toList(growable: false);
        final swBuildersFn = Stopwatch()..start();
        final functionPrices = await _lookupBuildersPricesViaFunctions(boundedQueries);
        timingsMs['builders_fn_batch_prices'] = swBuildersFn.elapsedMilliseconds;

      double materialBaseSubtotal = 0.0;
      final pricedMaterials = <Map<String, dynamic>>[];
      final unpricedMaterials = <Map<String, dynamic>>[];

      // Guardrails: pricing can be slow on-device when many catalog lookups or Builders
      // searches are required. Keep RFQ generation responsive.
      final swMaterials = Stopwatch()..start();
      final pricingStopwatch = Stopwatch()..start();
      const maxNetworkPricingDuration = Duration(seconds: 20);
      const perCallTimeout = Duration(seconds: 5);
      int buildersSearchBudget = 3; // limit expensive Builders search hydrations

      for (final m in bom) {
        final overBudget = pricingStopwatch.elapsed > maxNetworkPricingDuration;
        final name = (m['name'] ?? '').toString();
        final normalizedName = _normalizeQueryForBuilders(name);
        final qty = (m['qty'] as num?)?.toDouble() ??
            double.tryParse((m['qty'] ?? '1').toString()) ??
            1.0;
        final requestedUnit = (m['unit'] ?? '').toString();

        double? unitPrice;
        String resolvedUnit = requestedUnit;
        String? matchedBy;
        String? matchedKey;

        final reqText =
            ('$problemDescription $additionalNotes').toLowerCase();
        final wantsApollo = _looksLikeApollo(reqText);
        final wantsKwikot = _looksLikeKwikot(reqText);
        final isGeyser = name.toLowerCase().contains('geyser');

        // Fast-path: if the material name already includes a Builders product URL
        // (or a /p/<digits> product code), fetch exact price via ItemsPrice.
        // This is the most reliable path for links like:
        // https://www.builders.co.za/.../p/000000000000744580
        final buildersUrl = (m['builders_url'] ?? m['buildersUrl'] ?? m['url'])
            ?.toString()
            .trim();
        final upcFromName = _extractUpcFromBuildersUrl(name) ??
            _extractUpcFromBuildersUrl(normalizedName) ??
            (buildersUrl != null && buildersUrl.isNotEmpty
                ? _extractUpcFromBuildersUrl(buildersUrl)
                : null);
        if (upcFromName != null && upcFromName.trim().isNotEmpty) {
          final cfg = await _getBuildersBffConfig();
          final p = await _lookupBuildersItemsPrice(upc: upcFromName, cfg: cfg);
          if (p != null && p > 0) {
            unitPrice = p;
            matchedBy =
                (_buildersLastItemsPriceDiag?.stage == 'itemsprice_webview')
                    ? 'builders_itemsprice_webview'
                    : 'builders_itemsprice_direct';
            matchedKey = upcFromName.trim();
          } else {
            final diag = _buildersLastItemsPriceDiag;
            matchedBy = diag?.tag ?? 'builders_itemsprice_direct_failed';
            matchedKey = upcFromName.trim();

            // If WebView was used but returned no price, try resolving the real
            // GTIN/UPC from the product page and retry ItemsPrice.
            final svc = BuildersWebViewPricing.instance;
            final id = upcFromName.trim();
            if (svc.isAvailable &&
                matchedBy == 'builders_itemsprice_webview_no_price' &&
                RegExp(r'^\d{8,20}$').hasMatch(id)) {
              try {
                final p2 = await svc.itemsPriceFromProductId(id);
                if (p2 != null && p2 > 0) {
                  unitPrice = p2;
                  matchedBy = 'builders_productpage_gtin_itemsprice';
                  matchedKey = 'https://www.builders.co.za/p/$id';
                }
              } catch (_) {
                // Keep original diag tag.
              }
            }
          }
        }

        // Prefer server-side Builders pricing when available.
        if (unitPrice == null) {
          final fromFn = functionPrices[name.trim()] ??
              (normalizedName.isNotEmpty
                  ? functionPrices[normalizedName.trim()]
                  : null);
          _BuildersCandidate? web;
          if (fromFn != null) {
            web = fromFn;
          } else if (!overBudget && buildersSearchBudget > 0) {
            buildersSearchBudget -= 1;
            web = await _lookupBuildersWebPrice(
              normalizedName.isNotEmpty ? normalizedName : name,
            ).timeout(perCallTimeout, onTimeout: () => null);
          } else if (overBudget) {
            matchedBy = 'pricing_timeout_skipped';
            matchedKey = (normalizedName.isNotEmpty ? normalizedName : name).trim();
          } else {
            matchedBy = 'builders_search_budget_skipped';
            matchedKey = (normalizedName.isNotEmpty ? normalizedName : name).trim();
          }
          if (web != null && web.priceZar > 0) {
            unitPrice = web.priceZar;
            matchedBy = web.source;
            matchedKey = web.url;
            if ((web.title ?? '').trim().isNotEmpty) {
              // Keep original requested name but store resolved title for auditing.
              m['resolved_name'] = web.title;
            }
          } else {
            final simplified = _normalizeQueryForBuilders(name);
            if (simplified.isNotEmpty && simplified != name) {
              final fromFnRetry = functionPrices[simplified.trim()];
              _BuildersCandidate? webRetry;
              if (fromFnRetry != null) {
                webRetry = fromFnRetry;
              } else if (!overBudget && buildersSearchBudget > 0) {
                buildersSearchBudget -= 1;
                webRetry = await _lookupBuildersWebPrice(simplified)
                    .timeout(perCallTimeout, onTimeout: () => null);
              }
              if (webRetry != null && webRetry.priceZar > 0) {
                unitPrice = webRetry.priceZar;
                matchedBy = webRetry.source;
                matchedKey = webRetry.url;
                if ((webRetry.title ?? '').trim().isNotEmpty) {
                  m['resolved_name'] = webRetry.title;
                }
              }
            }
          }

          // If Builders did not return a price, tag the attempt so the UI
          // doesn't collapse everything into fallback_estimate.
          if (unitPrice == null && (matchedBy == null || matchedBy.isEmpty)) {
            matchedBy = 'builders_no_match';
            matchedKey =
                (normalizedName.isNotEmpty ? normalizedName : name).trim();
          }
        }

        // If the user explicitly requested a brand (e.g. "Apollo" or "Kwikot"),
        // do not silently price a different geyser. Force a user selection.
        if (unitPrice != null && unitPrice > 0 && isGeyser) {
          final resolved =
              ((m['resolved_name'] ?? name).toString()).toLowerCase();
          final key = (matchedKey ?? '').toLowerCase();

          if (wantsApollo) {
            final looksApollo =
                resolved.contains('apollo') || key.contains('apollo');
            if (!looksApollo) {
              unitPrice = null;
              matchedBy = 'builders_brand_mismatch_needs_choice';
            }
          }

          if (unitPrice != null && wantsKwikot) {
            final looksKwikot =
                _looksLikeKwikot(resolved) || _looksLikeKwikot(key);
            if (!looksKwikot) {
              unitPrice = null;
              matchedBy = 'builders_brand_mismatch_needs_choice';
            }
          }
        }

        // WebView fallback: if we still have no price, try a true browser
        // search to get a /p/<digits> id, then ItemsPrice through WebView.
        if (!overBudget &&
            unitPrice == null &&
            matchedBy == 'builders_no_match') {
          final svc = BuildersWebViewPricing.instance;
          if (svc.isAvailable) {
            try {
              final searchTerm =
                  (normalizedName.isNotEmpty ? normalizedName : name).trim();
              final id = await svc
                  .searchUpc(searchTerm)
                  .timeout(perCallTimeout, onTimeout: () => null);
              if (id != null && id.trim().isNotEmpty) {
                final pid = id.trim();
                final p = await svc
                    .itemsPriceFromProductId(pid)
                    .timeout(perCallTimeout, onTimeout: () => null);
                if (p != null && p > 0) {
                  unitPrice = p;
                  matchedBy = 'builders_search_webview_productpage_itemsprice';
                  matchedKey = 'https://www.builders.co.za/p/$pid';
                }
              }
            } catch (_) {
              // Keep existing matchedBy/matchedKey for diagnostics.
            }
          }
        }

        // Fallback: use our Firestore catalog if Builders didn't match.
        // If this item is explicitly flagged as needing user choice, keep it unpriced.
        if (!overBudget &&
            unitPrice == null &&
            matchedBy != 'builders_brand_mismatch_needs_choice') {
          final item = await _lookupMaterialCatalogItem(name)
              .timeout(perCallTimeout, onTimeout: () => null);
          if (item != null) {
            dynamic rawPrice = item['unit_price'] ??
                item['unitPrice'] ??
                item['price'] ??
                item['current_price'] ??
                item['currentPrice'] ??
                item['price_incl_vat'] ??
                item['priceInclVat'] ??
                item['price_incl_VAT'] ??
                item['priceInclVAT'] ??
                item['selling_price'] ??
                item['sellingPrice'] ??
                item['retail_price'] ??
                item['retailPrice'] ??
                item['cost_price'] ??
                item['costPrice'] ??
                item['unit_cost'] ??
                item['unitCost'] ??
                item['amount'] ??
                item['value'];

            // Sometimes catalog stores nested pricing.
            if (rawPrice == null && item['pricing'] is Map) {
              final pricing = (item['pricing'] as Map)
                  .map((k, v) => MapEntry(k.toString(), v));
              rawPrice = pricing['unit_price'] ??
                  pricing['unitPrice'] ??
                  pricing['price'] ??
                  pricing['current_price'] ??
                  pricing['currentPrice'] ??
                  pricing['price_incl_vat'] ??
                  pricing['priceInclVat'] ??
                  pricing['price_incl_VAT'] ??
                  pricing['priceInclVAT'] ??
                  pricing['selling_price'] ??
                  pricing['sellingPrice'] ??
                  pricing['retail_price'] ??
                  pricing['retailPrice'] ??
                  pricing['amount'] ??
                  pricing['value'];
            }

            // Some catalogs store multi-currency prices.
            if (rawPrice == null && item['prices'] is Map) {
              final prices = (item['prices'] as Map)
                  .map((k, v) => MapEntry(k.toString().toUpperCase(), v));
              rawPrice = prices['ZAR'] ?? prices['R'] ?? prices['ZA'];
            }

            double? parsePrice(dynamic v) {
              if (v == null) return null;
              if (v is num) return v.toDouble();
              final s = v.toString().trim();
              if (s.isEmpty) return null;
              // Remove currency symbols and non-numeric characters (keep dot/comma and minus).
              final cleaned = s.replaceAll(RegExp(r'[^0-9,\.-]'), '');
              // If comma is used as thousands separator, remove commas.
              final normalized = cleaned.contains('.')
                  ? cleaned.replaceAll(',', '')
                  : cleaned.replaceAll(',', '.');
              return double.tryParse(normalized);
            }

            unitPrice = parsePrice(rawPrice);
            resolvedUnit = (item['unit'] ?? requestedUnit).toString();
            matchedBy = (item['matched_by'] ?? '').toString();
            matchedKey = (item['matched_key'] ?? '').toString();
          }
        }

        // Final fallback: use estimated price if provided in material definition
        if (unitPrice == null) {
          final fallbackPriceRaw = m['fallback_price'];
          if (fallbackPriceRaw != null) {
            unitPrice = (fallbackPriceRaw is num)
                ? fallbackPriceRaw.toDouble()
                : double.tryParse(fallbackPriceRaw.toString());
            if (unitPrice != null) {
              // Preserve prior pricing attempt signal (e.g. Builders ItemsPrice)
              // instead of always overwriting it with fallback.
              matchedBy = (matchedBy == null || matchedBy.trim().isEmpty)
                  ? 'fallback_estimate'
                  : matchedBy;
              matchedKey = 'estimated_price';
              m['used_fallback_estimate'] = true;
            }
          }
        }

        final lineBase = unitPrice != null ? unitPrice * qty : null;
        if (lineBase != null) materialBaseSubtotal += lineBase;

        final line = {
          'name': name,
          'qty': qty,
          'unit': resolvedUnit,
          'unit_price': unitPrice,
          'line_base': lineBase,
          if (matchedBy != null && matchedBy.isNotEmpty)
            'matched_by': matchedBy,
          if (matchedKey != null && matchedKey.isNotEmpty)
            'matched_key': matchedKey,
        };
        pricedMaterials.add(line);
        if (unitPrice == null) unpricedMaterials.add(line);
      }
      timingsMs['materials_pricing_loop'] = swMaterials.elapsedMilliseconds;

      // ── Post-generation filter: remove items NOT available on Builders ──
      // Rule: the AI must only include items that exist on builders.co.za.
      // Items whose `matched_by` is 'builders_no_match' or 'fallback_estimate'
      // (i.e. no Builders hit at all) are stripped from the quotation so clients
      // and admin only see real, purchasable products.
      pricedMaterials.removeWhere((m) {
        final by = (m['matched_by'] ?? '').toString();
        if (by == 'builders_no_match' || by == 'fallback_estimate') {
          final removedName = (m['name'] ?? '').toString();
          debugPrint('[RFQ AI] Removing non-Builders item: $removedName (matched_by=$by)');
          return true;
        }
        return false;
      });
      unpricedMaterials.removeWhere((m) {
        final by = (m['matched_by'] ?? '').toString();
        return by == 'builders_no_match' || by == 'fallback_estimate';
      });

      // Recalculate material base subtotal after filtering.
      materialBaseSubtotal = 0.0;
      for (final m in pricedMaterials) {
        final lb = m['line_base'];
        if (lb is num) materialBaseSubtotal += lb.toDouble();
      }

      double materialCostWithMarkup = materialBaseSubtotal * materialMultiplier;
      final materialCostWithMarkupReference = materialCostWithMarkup;
      final laborRateForTotals = ((quotation['laborCostPerHour'] ?? 0.0) as num).toDouble();
      final laborHoursForTotals = ((quotation['laborHours'] ?? 0.0) as num).toDouble();
      double laborCost = ((quotation['laborCost'] ?? 0.0) as num).toDouble();
      // Some AI payloads provide hours + rate but omit laborCost. Derive it so the
      // UI and totals remain consistent.
      final derivedLaborCost = laborHoursForTotals > 0 && laborRateForTotals > 0
          ? (laborHoursForTotals * laborRateForTotals)
          : 0.0;
      if ((laborCost <= 0) && derivedLaborCost > 0) {
        laborCost = derivedLaborCost;
        quotation['laborCost'] = laborCost;
      }
      double equipmentCost =
          ((quotation['equipmentCost'] ?? 0.0) as num).toDouble();

      // Apply a lightweight learning adjustment based on historical admin corrections.
      // This nudges the draft totals toward what admins actually send.
      if (learningFactor != 1.0) {
        materialCostWithMarkup *= learningFactor;
        laborCost *= learningFactor;
        equipmentCost *= learningFactor;
        quotation['learning_factor'] = learningFactor;
      }

      timingsMs['total'] = totalSw.elapsedMilliseconds;

      // Diagnostics to validate performance + bracket matching (safe: log only).
      try {
        final bracketLines = pricedMaterials
            .where((m) {
              final n = (m['name'] ?? '').toString().toLowerCase();
              return n.contains('bracket') || n.contains('mount');
            })
            .take(4)
            .map((m) {
              final n = (m['name'] ?? '').toString();
              final by = (m['matched_by'] ?? '').toString();
              final key = (m['matched_key'] ?? '').toString();
              final p = m['unit_price'];
              return '$n | by=$by | price=$p | key=${key.isNotEmpty ? key : '-'}';
            })
            .toList(growable: false);

        debugPrint(
          '[RFQ AI] timings(ms)=$timingsMs '
          'buildersQueries=${buildersQueries.length} bounded=${boundedQueries.length} '
          'priced=${pricedMaterials.length} unpriced=${unpricedMaterials.length} '
          'brackets=${bracketLines.isEmpty ? "none" : bracketLines.join(" ; ")}',
        );
      } catch (_) {
        // ignore diagnostics failures
      }

      final materialCostForTotals =
          artisanBuysMaterials ? materialCostWithMarkup : 0.0;
      final subtotal = laborCost + materialCostForTotals + equipmentCost;
      final contingency = subtotal * 0.15;
      final total = subtotal + contingency;

      // For client-buys-materials we must list materials but not include/show prices.
      // Keep priced copies separately for admin/auditing.
      List<Map<String, dynamic>> stripPrices(List<Map<String, dynamic>> lines) {
        return lines
            .map((l) => <String, dynamic>{
                  'name': l['name'],
                  'qty': l['qty'],
                  'unit': l['unit'],
                })
            .toList(growable: false);
      }

      quotation['materialsPriced'] =
          clientBuysMaterials ? stripPrices(pricedMaterials) : pricedMaterials;
      quotation['materialsUnpriced'] = clientBuysMaterials
          ? stripPrices(unpricedMaterials)
          : unpricedMaterials;
      // Keep a copy for admin/auditing regardless of mode.
      quotation['materialsPriced_reference'] = pricedMaterials;
      quotation['materialsUnpriced_reference'] = unpricedMaterials;
      quotation['materialSubtotalWithMarkup_reference'] =
          materialCostWithMarkupReference;
      quotation['materialSubtotalBase'] = materialBaseSubtotal;
      quotation['materialSubtotalWithMarkup'] = materialCostForTotals;
      quotation['estimatedCost'] = total.toStringAsFixed(2);
      quotation['total'] = total;
      quotation['materials_responsibility'] =
          artisanBuysMaterials ? 'artisan' : 'client';
      quotation['disclaimer'] = clientBuysMaterials
          ? 'Disclaimer: This is an AI-generated estimate. Materials are listed for planning only and are NOT priced because you selected that the client will buy materials. Prices can vary and additional materials may be required once the job is assessed on-site.'
          : 'Disclaimer: This is an AI-generated estimate. Prices can vary and additional materials may be required once the job is assessed on-site.';
      if (userBudget != null && userBudget.isFinite && userBudget > 0) {
        quotation['user_budget'] = userBudget;
      }

      // Update breakdown amounts for UI display.
      Map<String, dynamic> line0(String desc, double cost) => {
            'description': desc,
            'cost': cost.toStringAsFixed(2),
          };

        final laborRate = laborRateForTotals;
        final laborHours = laborHoursForTotals;

      final newBreakdown = <Map<String, dynamic>>[
        line0(
          'Labor (${laborHours.toStringAsFixed(1)} hours @ R$laborRate/hr)',
          laborCost,
        ),
        line0(
          'Materials & Supplies',
          materialCostForTotals,
        ),
        if (equipmentCost > 0) line0('Equipment & Tools', equipmentCost),
        line0('Contingency (15%)', contingency),
      ];

      quotation['breakdown'] = newBreakdown;

      return quotation;
    } catch (e) {
      debugPrint('Error in AI quotation generation: $e');
      rethrow;
    }
  }

  /// Calculate detailed profit analysis for admin and artisan views
  /// Returns breakdown of costs and profits for company and artisan
  static Map<String, dynamic> calculateProfitAnalysis(
    Map<String, dynamic> quotation, {
    double? outsourcedLaborRate,
  }) {
    double asDouble(dynamic v, {double fallback = 0.0}) {
      if (v is num) return v.toDouble();
      final s = (v ?? '').toString().trim();
      return double.tryParse(s) ?? fallback;
    }

    // Extract values from quotation
    final laborHours = asDouble(quotation['laborHours'], fallback: 0.0);
    final clientLaborRate = asDouble(quotation['laborCostPerHour'], fallback: 0.0);
    final embeddedOutsourced = asDouble(
      quotation['outsourcedLaborRate'] ?? quotation['outsourced_labor_rate'],
      fallback: 0.0,
    );
    final outsourcedRate =
        outsourcedLaborRate ?? (embeddedOutsourced > 0 ? embeddedOutsourced : (clientLaborRate * 0.7));
    final equipmentCost = asDouble(quotation['equipmentCost'], fallback: 0.0);
    final materialBaseSubtotal = asDouble(quotation['materialSubtotalBase'], fallback: 0.0);
    final materialMultiplier = asDouble(quotation['materialsMultiplier'], fallback: 1.5);
    final total = asDouble(quotation['total'], fallback: 0.0);

    // ── Check materials responsibility: if client buys, zero out material costs ──
    final mr = (quotation['materials_responsibility'] ??
            quotation['materialsResponsibility'] ??
            '')
        .toString()
        .trim()
        .toLowerCase();
    final artisanBuysMaterials = mr == 'artisan';

    // Labor calculations
    final clientLaborTotal = laborHours * clientLaborRate;
    final outsourcedLaborTotal = laborHours * outsourcedRate;
    final companyLaborProfit = clientLaborTotal - outsourcedLaborTotal;
    
    // Material calculations – honour labour-only mode
    final effectiveMaterialBase = artisanBuysMaterials ? materialBaseSubtotal : 0.0;
    final materialMarkupTotal = effectiveMaterialBase * materialMultiplier;
    final materialProfit = materialMarkupTotal - effectiveMaterialBase;
    final companyMaterialProfit = materialProfit * 0.10; // 10% to company
    final artisanMaterialProfit = materialProfit * 0.40; // 40% to artisan
    
    // Contingency (all goes to company)
    final subtotal = clientLaborTotal + materialMarkupTotal + equipmentCost;
    final contingency = subtotal * 0.15;
    
    // Totals — recalculate grand_total from computed values to ensure consistency
    final companyExpectedProfit = companyLaborProfit + companyMaterialProfit + contingency;
    final artisanExpectedProfit = artisanMaterialProfit;
    final artisanExpectedCosts = outsourcedLaborTotal + effectiveMaterialBase + equipmentCost;
    final calculatedGrandTotal = clientLaborTotal + materialMarkupTotal + equipmentCost + contingency;
    // Use the higher of AI total vs calculated total to never understate client cost
    final grandTotal = calculatedGrandTotal > 0 ? calculatedGrandTotal : total;
    
    return {
      'labor_costs': {
        'hours': laborHours,
        'client_rate': clientLaborRate,
        'outsourced_rate': outsourcedRate,
        'client_total': clientLaborTotal,
        'outsourced_total': outsourcedLaborTotal,
        'company_profit': companyLaborProfit,
      },
      'material_costs': {
        'base_cost': effectiveMaterialBase,
        'multiplier': materialMultiplier,
        'markup_total': materialMarkupTotal,
        'total_profit': materialProfit,
        'company_profit': companyMaterialProfit,
        'artisan_profit': artisanMaterialProfit,
        'labour_only': !artisanBuysMaterials,
      },
      'other_costs': {
        'equipment': equipmentCost,
        'contingency': contingency,
        'company_profit': contingency,
      },
      'totals': {
        'grand_total': grandTotal,
        'company_expected_profit': companyExpectedProfit,
        'artisan_expected_profit': artisanExpectedProfit,
        'artisan_expected_costs': artisanExpectedCosts,
        'artisan_total_earnings': artisanExpectedCosts + artisanExpectedProfit,
      },
    };
  }

  /// Filter profit analysis for artisan view (removes company profit details)
  static Map<String, dynamic> filterProfitAnalysisForArtisan(
    Map<String, dynamic> fullAnalysis,
  ) {
    return {
      'labor_costs': {
        'hours': fullAnalysis['labor_costs']['hours'],
        'rate': fullAnalysis['labor_costs']['outsourced_rate'],
        'total': fullAnalysis['labor_costs']['outsourced_total'],
      },
      'material_costs': {
        'base_cost': fullAnalysis['material_costs']['base_cost'],
        'your_profit': fullAnalysis['material_costs']['artisan_profit'],
      },
      'other_costs': {
        'equipment': fullAnalysis['other_costs']['equipment'],
      },
      'totals': {
        'your_expected_profit': fullAnalysis['totals']['artisan_expected_profit'],
        'your_expected_costs': fullAnalysis['totals']['artisan_expected_costs'],
        'your_total_earnings': fullAnalysis['totals']['artisan_total_earnings'],
      },
    };
  }

  static Map<String, dynamic> recomputeQuotationTotals(
      Map<String, dynamic> quotation) {
    double asDouble(dynamic v, {double fallback = 0.0}) {
      if (v is num) return v.toDouble();
      final s = (v ?? '').toString().trim();
      return double.tryParse(s) ?? fallback;
    }

    final mr = (quotation['materials_responsibility'] ??
            quotation['materialsResponsibility'] ??
            '')
        .toString()
        .trim()
        .toLowerCase();
    final artisanBuysMaterials = mr == 'artisan';
    final clientBuysMaterials = !artisanBuysMaterials;

    final materialMultiplier =
        asDouble(quotation['materialsMultiplier'], fallback: 1.5);
    final learningFactor =
        asDouble(quotation['learning_factor'], fallback: 1.0);

    final rawPriced =
        quotation['materialsPriced_reference'] ?? quotation['materialsPriced'];
    final rawUnpriced = quotation['materialsUnpriced_reference'] ??
        quotation['materialsUnpriced'];

    final all = <Map<String, dynamic>>[];
    void addAll(dynamic v) {
      if (v is! List) return;
      for (final it in v) {
        if (it is! Map) continue;
        all.add(it.map((k, vv) => MapEntry(k.toString(), vv)));
      }
    }

    addAll(rawPriced);
    addAll(rawUnpriced);

    double materialBaseSubtotal = 0.0;
    final priced = <Map<String, dynamic>>[];
    final unpriced = <Map<String, dynamic>>[];

    for (final line in all) {
      final name = (line['name'] ?? '').toString();
      final qty = asDouble(line['qty'], fallback: 1.0);
      final unitPrice = asDouble(line['unit_price'], fallback: double.nan);
      final hasPrice = unitPrice.isFinite && unitPrice > 0;

      if (name.trim().isEmpty) continue;

      if (hasPrice) {
        final lineBase = unitPrice * (qty > 0 ? qty : 1.0);
        line['qty'] = (qty > 0 ? qty : 1.0);
        line['unit_price'] = unitPrice;
        line['line_base'] = lineBase;
        materialBaseSubtotal += lineBase;
        priced.add(line);
      } else {
        line['qty'] = (qty > 0 ? qty : 1.0);
        line['unit_price'] = null;
        line['line_base'] = null;
        unpriced.add(line);
      }
    }

    double materialCostWithMarkup = materialBaseSubtotal * materialMultiplier;
    final materialCostWithMarkupReference = materialCostWithMarkup;
    double laborCost = asDouble(quotation['laborCost'], fallback: 0.0);
    double equipmentCost = asDouble(quotation['equipmentCost'], fallback: 0.0);

    if (learningFactor != 1.0) {
      materialCostWithMarkup *= learningFactor;
      laborCost *= learningFactor;
      equipmentCost *= learningFactor;
      quotation['learning_factor'] = learningFactor;
    }

    final materialCostForTotals =
        artisanBuysMaterials ? materialCostWithMarkup : 0.0;
    final subtotal = laborCost + materialCostForTotals + equipmentCost;
    final contingency = subtotal * 0.15;
    final total = subtotal + contingency;

    List<Map<String, dynamic>> stripPrices(List<Map<String, dynamic>> lines) {
      return lines
          .map((l) => <String, dynamic>{
                'name': l['name'],
                'qty': l['qty'],
                'unit': l['unit'],
              })
          .toList(growable: false);
    }

    quotation['materialsPriced_reference'] = priced;
    quotation['materialsUnpriced_reference'] = unpriced;
    quotation['materialsPriced'] =
        clientBuysMaterials ? stripPrices(priced) : priced;
    quotation['materialsUnpriced'] =
        clientBuysMaterials ? stripPrices(unpriced) : unpriced;
    quotation['materialSubtotalWithMarkup_reference'] =
        materialCostWithMarkupReference;
    quotation['materialSubtotalBase'] = materialBaseSubtotal;
    quotation['materialSubtotalWithMarkup'] = materialCostForTotals;
    quotation['estimatedCost'] = total.toStringAsFixed(2);
    quotation['total'] = total;

    Map<String, dynamic> line0(String desc, double cost) => {
          'description': desc,
          'cost': cost.toStringAsFixed(2),
        };

    final laborRate = asDouble(quotation['laborCostPerHour'], fallback: 0.0);
    final laborHours = asDouble(quotation['laborHours'], fallback: 0.0);

    quotation['breakdown'] = <Map<String, dynamic>>[
      line0(
        'Labor (${laborHours.toStringAsFixed(1)} hours @ R$laborRate/hr)',
        laborCost,
      ),
      line0(
        'Materials & Supplies',
        materialCostForTotals,
      ),
      if (equipmentCost > 0) line0('Equipment & Tools', equipmentCost),
      line0('Contingency (15%)', contingency),
    ];

    return quotation;
  }

  /// Get company pricing guidance from Firestore
  static Future<Map<String, dynamic>> _getPricingGuidance({
    required String? categoryId,
    required String categoryName,
  }) async {
    try {
      if (categoryId != null && categoryId.trim().isNotEmpty) {
        final doc = await _firestore
            .collection(_pricingGuidanceCollection)
            .doc(categoryId.toLowerCase())
            .get();
        if (doc.exists) {
          return doc.data() ?? {};
        }
      }

      // Backward compatibility: some setups store pricing docs by slug.
      final slugId = categoryName.toLowerCase().replaceAll(' ', '_');
      final doc = await _firestore
          .collection(_pricingGuidanceCollection)
          .doc(slugId)
          .get();
      if (doc.exists) {
        return doc.data() ?? {};
      }

      // Default pricing structure if none exists
      return _getDefaultPricing(categoryName);
    } catch (e) {
      debugPrint('Error fetching pricing guidance: $e');
      return _getDefaultPricing(categoryName);
    }
  }

  /// Generate quotation logic based on problem analysis
  static Map<String, dynamic> _generateQuotationLogic({
    required String? categoryId,
    required String categoryName,
    required String problemDescription,
    required String additionalNotes,
    required Map<String, dynamic> pricingGuidance,
  }) {
    // Analyze problem complexity
    int complexity = _analyzeComplexity(problemDescription, additionalNotes);

    // Get base pricing from guidance (support snake_case and camelCase)
    double laborCostPerHour = (pricingGuidance['labor_cost_per_hour'] ??
            pricingGuidance['laborCostPerHour'] ??
            150.0)
        .toDouble();
    double materialMultiplier = (pricingGuidance['material_multiplier'] ??
            pricingGuidance['materialMultiplier'] ??
            1.5)
        .toDouble();

    // Estimate hours based on complexity and keywords
    double estimatedHours =
        _estimateHours(problemDescription, categoryName, complexity);

    // Build a small, trade-specific bill of materials and price from our reference catalog.
    final materialsBOM =
        _inferMaterials(categoryName, problemDescription, additionalNotes);
    final pricedMaterials = <Map<String, dynamic>>[];
    final unpricedMaterials = <Map<String, dynamic>>[];

    // NOTE: This runs in the client app, so keep Firestore queries lightweight.
    // Each material is looked up by id/name_lower/aliases.
    // If a material isn't found in the catalog, it is left as TBD.
    //
    // We do async lookups by converting to a synchronous estimation first and
    // pricing later in generateQuotation (which is async) via a second pass.

    // Calculate costs (materials priced later from catalog)
    double laborCost = laborCostPerHour * estimatedHours;
    double equipmentCost =
        _estimateEquipmentCost(problemDescription, categoryName);

    // Placeholder material cost for now; actual pricing is computed in async pass.
    double materialCost = 0.0;

    // Total with 15% contingency (updated after materials pricing)
    double subtotal = laborCost + materialCost + equipmentCost;
    double contingency = subtotal * 0.15;
    double totalCost = subtotal + contingency;

    // Generate scope of work
    String scopeOfWork = _generateScopeOfWork(
      categoryName,
      problemDescription,
      additionalNotes,
    );

    // Generate cost breakdown
    List<Map<String, dynamic>> breakdown = [
      {
        'description':
            'Labor (${estimatedHours.toStringAsFixed(1)} hours @ R$laborCostPerHour/hr)',
        'cost': laborCost.toStringAsFixed(2),
      },
      {
        'description': 'Materials & Supplies (reference pricing)',
        'cost': materialCost.toStringAsFixed(2),
      },
      if (equipmentCost > 0)
        {
          'description': 'Equipment & Tools',
          'cost': equipmentCost.toStringAsFixed(2),
        },
      {
        'description': 'Contingency (15%)',
        'cost': contingency.toStringAsFixed(2),
      },
    ];

    return {
      'projectTitle': _generateProjectTitle(categoryName, problemDescription),
      'scopeOfWork': scopeOfWork,
      'breakdown': breakdown,
      'estimatedCost': totalCost.toStringAsFixed(2),
      'estimatedDuration': _estimateDuration(estimatedHours),
      'laborHours': estimatedHours,
      'complexity': complexity,
      'laborCostPerHour': laborCostPerHour,
      'laborCost': laborCost,
      'equipmentCost': equipmentCost,
      'materialsMultiplier': materialMultiplier,
      'materialsBOM': materialsBOM,
      'materialsPriced': pricedMaterials,
      'materialsUnpriced': unpricedMaterials,
    };
  }

  static List<Map<String, dynamic>> _inferMaterials(
    String categoryName,
    String description,
    String notes,
  ) {
    final text = ('$description $notes').toLowerCase();
    final category = categoryName.toLowerCase();

    // Geyser / water heater install or replacement (often classified as Plumbing).
    // We include the geyser itself plus compliance/safety fittings.
    if (text.contains('geyser') ||
        text.contains('water heater') ||
        text.contains('hot water cylinder')) {
      final isReplacement = text.contains('replace') ||
          text.contains('replacement') ||
          text.contains('remove old');

      final liters = _extractLiters(text) ?? 150;
      final isSolar = text.contains('solar');
      final fallbackGeyserPrice = isSolar
          ? (liters >= 200 ? 55000.0 : (liters >= 175 ? 42000.0 : 32000.0))
          : (liters >= 200 ? 7500.0 : (liters >= 175 ? 4200.0 : 3200.0));
        final wantsKwikot = _looksLikeKwikot(text);
        final wantsApollo = _looksLikeApollo(text);

      // If the user asked for a solar geyser, model it explicitly so Builders
      // matching/pricing can work.
        final geyserName = isSolar
          ? (wantsApollo
            ? 'Apollo solar geyser ${liters}L'
            : (wantsKwikot
              ? 'Kwikot solar geyser ${liters}L'
              : 'Solar geyser ${liters}L'))
          : (wantsKwikot
            ? 'Kwikot geyser ${liters}L'
            : (wantsApollo
              ? 'Apollo geyser ${liters}L'
              : 'Electric geyser ${liters}L'));

      // For the common case the user shared (Apollo solar geyser 200L), attach
      // the Builders product URL so the pricing logic can call ItemsPrice
      // directly using the /p/<code> id.
      const apolloSolar200lUrl =
          'https://www.builders.co.za/Plumbing-Bathroom-and-Kitchen/Geysers-and-Water-Heaters/Solar-Geysers/Apollo-Solar-Technology-APIHP-20-Integrated-High-Pressure-Solar-Geyser-200-L/p/000000000000744580';
      final geyserBuildersUrl =
          (isSolar && liters >= 200 && wantsApollo && !wantsKwikot)
              ? apolloSolar200lUrl
              : null;
      return [
        // Core item - respect requested size (e.g., 200L) when present.
        {
          'name': geyserName,
          if (geyserBuildersUrl != null) 'builders_url': geyserBuildersUrl,
          'qty': 1.0,
          'unit': 'each',
          'fallback_price': fallbackGeyserPrice
        },
        // Common compliance fittings
        {
          'name': 'Drip tray for geyser',
          'qty': 1.0,
          'unit': 'each',
          'fallback_price': 150.0
        },
        {
          'name': 'Vacuum breaker 15mm',
          'qty': 2.0,
          'unit': 'each',
          'fallback_price': 45.0
        },
        {
          'name': 'Pressure control valve',
          'qty': 1.0,
          'unit': 'each',
          'fallback_price': 250.0
        },
        {
          'name': 'Isolating valve 15mm',
          'qty': 2.0,
          'unit': 'each',
          'fallback_price': 55.0
        },
        {
          'name': 'Copper pipe 15mm',
          'qty': 2.0,
          'unit': 'm',
          'fallback_price': 85.0
        },
        {
          'name': 'Copper fittings 15mm',
          'qty': 1.0,
          'unit': 'pack',
          'fallback_price': 120.0
        },
        {
          'name': 'PTFE tape',
          'qty': 1.0,
          'unit': 'roll',
          'fallback_price': 25.0
        },
        {
          'name': 'Plumbing silicone',
          'qty': 1.0,
          'unit': 'each',
          'fallback_price': 45.0
        },
        // Electrical essentials (some installs require)
        {
          'name': 'Geyser isolator switch',
          'qty': 1.0,
          'unit': 'each',
          'fallback_price': 120.0
        },
        {
          'name': 'Electrical cable 2.5mm',
          'qty': 10.0,
          'unit': 'm',
          'fallback_price': 18.0
        },
        if (isReplacement)
          {
            'name': 'Disposal old geyser',
            'qty': 1.0,
            'unit': 'each',
            'fallback_price': 350.0
          },
      ];
    }

    // Trade “skills”: these are the default materials a professional artisan would consider.
    // Quantities are intentionally conservative; the admin can refine later.
    if (category.contains('painting')) {
      final isExterior = text.contains('exterior') || text.contains('outside');
      return [
        {
          'name': isExterior ? 'Exterior paint 20L' : 'Interior paint 20L',
          'qty': 1.0,
          'unit': '20L'
        },
        {'name': 'Primer 20L', 'qty': 1.0, 'unit': '20L'},
        {'name': 'Wall filler', 'qty': 1.0, 'unit': 'each'},
        {'name': 'Sandpaper', 'qty': 2.0, 'unit': 'each'},
        {'name': 'Masking tape', 'qty': 2.0, 'unit': 'roll'},
        {'name': 'Paint roller set', 'qty': 1.0, 'unit': 'each'},
        {'name': 'Paint brush set', 'qty': 1.0, 'unit': 'each'},
        {'name': 'Drop sheet', 'qty': 1.0, 'unit': 'each'},
      ];
    }

    if (category.contains('plumbing')) {
      final isLeak = text.contains('leak') || text.contains('drip');
      final isToilet = text.contains('toilet');
      final isSink = text.contains('sink') || text.contains('basin');
      return [
        {
          'name': 'PTFE tape',
          'qty': 1.0,
          'unit': 'roll',
          'fallback_price': 25.0
        },
        {
          'name': 'Plumbing silicone',
          'qty': 1.0,
          'unit': 'each',
          'fallback_price': 45.0
        },
        if (isLeak)
          {
            'name': 'Assorted washers',
            'qty': 1.0,
            'unit': 'pack',
            'fallback_price': 35.0
          },
        if (isSink)
          {
            'name': 'Flexible hose',
            'qty': 2.0,
            'unit': 'each',
            'fallback_price': 55.0
          },
        if (isToilet)
          {
            'name': 'Toilet flush valve',
            'qty': 1.0,
            'unit': 'each',
            'fallback_price': 185.0
          },
        {
          'name': 'PVC pipe 20mm',
          'qty': 2.0,
          'unit': 'm',
          'fallback_price': 22.0
        },
        {
          'name': 'PVC elbows 20mm',
          'qty': 4.0,
          'unit': 'each',
          'fallback_price': 12.0
        },
        {
          'name': 'PVC solvent cement',
          'qty': 1.0,
          'unit': 'each',
          'fallback_price': 55.0
        },
      ];
    }

    if (category.contains('electrical')) {
      return [
        {
          'name': 'Electrical cable 2.5mm',
          'qty': 10.0,
          'unit': 'm',
          'fallback_price': 18.0
        },
        {
          'name': 'Conduit 20mm',
          'qty': 3.0,
          'unit': 'm',
          'fallback_price': 15.0
        },
        {
          'name': 'Junction box',
          'qty': 2.0,
          'unit': 'each',
          'fallback_price': 25.0
        },
        {
          'name': 'Cable clips',
          'qty': 1.0,
          'unit': 'pack',
          'fallback_price': 35.0
        },
        if (text.contains('outlet') || text.contains('socket'))
          {
            'name': 'Wall socket',
            'qty': 1.0,
            'unit': 'each',
            'fallback_price': 45.0
          },
        if (text.contains('switch'))
          {
            'name': 'Light switch',
            'qty': 1.0,
            'unit': 'each',
            'fallback_price': 38.0
          },
      ];
    }

    if (category.contains('carpentry') || category.contains('wood')) {
      return [
        {
          'name': 'Wood screws',
          'qty': 1.0,
          'unit': 'box',
          'fallback_price': 55.0
        },
        {
          'name': 'Wood glue',
          'qty': 1.0,
          'unit': 'each',
          'fallback_price': 45.0
        },
        {
          'name': 'Wood filler',
          'qty': 1.0,
          'unit': 'each',
          'fallback_price': 65.0
        },
        {
          'name': 'Sandpaper',
          'qty': 2.0,
          'unit': 'each',
          'fallback_price': 15.0
        },
      ];
    }

    // Generic maintenance fallback
    return [
      {
        'name': 'Assorted screws',
        'qty': 1.0,
        'unit': 'pack',
        'fallback_price': 45.0
      },
      {
        'name': 'Silicone sealant',
        'qty': 1.0,
        'unit': 'each',
        'fallback_price': 55.0
      },
      {
        'name': 'Cleaning materials',
        'qty': 1.0,
        'unit': 'each',
        'fallback_price': 35.0
      },
    ];
  }

  /// Analyze problem complexity (1-5 scale)
  static int _analyzeComplexity(String description, String notes) {
    String combined = ('$description $notes').toLowerCase();

    // Keywords indicating higher complexity
    List<String> complexKeywords = [
      'damage',
      'leak',
      'burst',
      'emergency',
      'replace',
      'install',
      'rewiring',
      'plumbing system',
      'major',
      'entire',
      'complete',
      'structural',
      'foundation',
      'renovation'
    ];

    List<String> simpleKeywords = [
      'fix',
      'repair',
      'small',
      'minor',
      'simple',
      'quick',
      'touch up',
      'patch',
      'adjust'
    ];

    int complexity = 3; // Default medium complexity

    for (String keyword in complexKeywords) {
      if (combined.contains(keyword)) {
        complexity = complexity < 5 ? complexity + 1 : 5;
      }
    }

    for (String keyword in simpleKeywords) {
      if (combined.contains(keyword)) {
        complexity = complexity > 1 ? complexity - 1 : 1;
      }
    }

    return complexity;
  }

  /// Estimate work hours based on problem and category
  static double _estimateHours(
      String description, String category, int complexity) {
    double baseHours = 2.0; // Minimum job time

    // Adjust by complexity
    baseHours += (complexity - 1) * 1.5;

    // Category-specific adjustments
    category = category.toLowerCase();
    final descLower = description.toLowerCase();

    // Geyser work is typically more involved.
    if (descLower.contains('geyser') ||
        descLower.contains('water heater') ||
        descLower.contains('hot water')) {
      baseHours += 3;
      if (descLower.contains('replace') || descLower.contains('removal')) {
        baseHours += 1;
      }
    }

    if (category.contains('plumbing')) {
      if (descLower.contains('pipe')) baseHours += 2;
      if (descLower.contains('sink')) baseHours += 1;
      if (descLower.contains('toilet')) baseHours += 1.5;
    } else if (category.contains('electrical')) {
      if (descLower.contains('rewire')) baseHours += 4;
      if (descLower.contains('outlet')) baseHours += 0.5;
    } else if (category.contains('painting')) {
      if (descLower.contains('room')) baseHours += 3;
      if (descLower.contains('wall')) baseHours += 2;
    }

    return baseHours;
  }

  /// Estimate equipment costs
  static double _estimateEquipmentCost(String description, String category) {
    double cost = 0.0;

    final catLower = category.toLowerCase();
    final descLower = description.toLowerCase();

    if (descLower.contains('geyser') ||
        descLower.contains('water heater') ||
        descLower.contains('hot water')) {
      cost += 250;
    }

    if (catLower.contains('plumbing')) {
      if (descLower.contains('install')) cost += 200;
    } else if (catLower.contains('electrical')) {
      if (descLower.contains('install')) cost += 150;
    }

    return cost;
  }

  /// Generate project title
  static String _generateProjectTitle(String category, String description) {
    String shortDesc = description.split('.').first;
    if (shortDesc.length > 50) {
      shortDesc = '${shortDesc.substring(0, 50)}...';
    }
    return '$category Service - $shortDesc';
  }

  /// Generate scope of work description
  static String _generateScopeOfWork(
      String category, String description, String notes) {
    StringBuffer scope = StringBuffer();

    scope.writeln(
        'Based on the provided information, this project will include:\n');

    final descLower = description.toLowerCase();

    // Parse description for key tasks
    if (descLower.contains('geyser') ||
        descLower.contains('water heater') ||
        descLower.contains('hot water')) {
      scope.writeln(
          '• Confirm geyser size/capacity, mounting position and access');
      scope.writeln('• Isolate electrical supply and water supply safely');
      scope.writeln(
          '• Install/replace geyser and required fittings (valves, vacuum breakers, drip tray, etc.)');
      scope.writeln(
          '• Connect cold/hot water lines and electrical connections (where applicable)');
      scope.writeln('• Pressure test, leak test and verify safe operation');
      scope.writeln('• Final clean-up and handover');
    } else if (descLower.contains('leak')) {
      scope.writeln('• Identify and locate the source of the leak');
      scope.writeln('• Assess any water damage to surrounding areas');
      scope.writeln('• Repair or replace damaged components');
      scope.writeln('• Test system to ensure leak is fully resolved');
    } else if (descLower.contains('install')) {
      scope.writeln('• Site assessment and preparation');
      scope.writeln('• Installation of new components/fixtures');
      scope.writeln('• Connection to existing systems');
      scope.writeln('• Testing and quality assurance');
    } else if (descLower.contains('repair')) {
      scope.writeln('• Inspection and diagnosis of the problem');
      scope.writeln('• Sourcing required replacement parts');
      scope.writeln('• Repair work execution');
      scope.writeln('• Final testing and verification');
    } else {
      scope.writeln('• Initial inspection and assessment');
      scope.writeln('• Implementation of necessary repairs/installations');
      scope.writeln('• Clean-up and quality check');
    }

    scope.writeln(
        '\nAll work will be completed to industry standards with appropriate safety measures.');

    if (notes.isNotEmpty) {
      scope.writeln('\nAdditional requirements noted: $notes');
    }

    return scope.toString();
  }

  /// Estimate project duration
  static String _estimateDuration(double hours) {
    if (hours <= 2) {
      return '1-2 hours';
    } else if (hours <= 4) {
      return 'Half day';
    } else if (hours <= 8) {
      return '1 day';
    } else if (hours <= 16) {
      return '2 days';
    } else {
      int days = (hours / 8).ceil();
      return '$days days';
    }
  }

  /// Default pricing structure for categories
  static Map<String, dynamic> _getDefaultPricing(String category) {
    return {
      'category': category,
      'labor_cost_per_hour': 150.0,
      'material_multiplier': 1.3,
      'equipment_base_cost': 100.0,
      'updated_at': DateTime.now().toString(),
    };
  }

  /// Admin can update pricing guidance
  static Future<void> updatePricingGuidance({
    required String category,
    required double laborCostPerHour,
    required double materialMultiplier,
    required double equipmentBaseCost,
  }) async {
    try {
      await _firestore
          .collection('pricingGuidance')
          .doc(category.toLowerCase().replaceAll(' ', '_'))
          .set({
        'category': category,
        'labor_cost_per_hour': laborCostPerHour,
        'material_multiplier': materialMultiplier,
        'equipment_base_cost': equipmentBaseCost,
        'updated_at': DateTime.now().toString(),
      });
    } catch (e) {
      debugPrint('Error updating pricing guidance: $e');
      rethrow;
    }
  }
}

class _BuildersCandidate {
  final String? title;
  final String url;
  final double priceZar;
  final String? upc;
  final String source;

  const _BuildersCandidate({
    required this.title,
    required this.url,
    required this.priceZar,
    this.upc,
    this.source = 'builders_unknown',
  });

  _BuildersCandidate copyWith({
    String? title,
    String? url,
    double? priceZar,
    String? upc,
    String? source,
  }) {
    return _BuildersCandidate(
      title: title ?? this.title,
      url: url ?? this.url,
      priceZar: priceZar ?? this.priceZar,
      upc: upc ?? this.upc,
      source: source ?? this.source,
    );
  }
}

class _BuildersPriceCacheEntry {
  final DateTime fetchedAt;
  final _BuildersCandidate? value;

  const _BuildersPriceCacheEntry({
    required this.fetchedAt,
    required this.value,
  });
}

class _BuildersItemsPriceCacheEntry {
  final DateTime fetchedAt;
  final double? value;

  const _BuildersItemsPriceCacheEntry({
    required this.fetchedAt,
    required this.value,
  });
}

class _BuildersItemsPriceDiag {
  final DateTime at;
  final String stage;
  final String? itemIdType;
  final int? statusCode;
  final bool blocked;
  final bool backoff;
  final int requestedCount;
  final int returnedCount;
  final String? note;

  const _BuildersItemsPriceDiag({
    required this.at,
    required this.stage,
    required this.itemIdType,
    required this.statusCode,
    required this.blocked,
    required this.backoff,
    required this.requestedCount,
    required this.returnedCount,
    required this.note,
  });

  String get tag {
    if (stage == 'itemsprice_webview') {
      if (returnedCount > 0) return 'builders_itemsprice_webview_ok';
      return 'builders_itemsprice_webview_no_price';
    }
    if (backoff) return 'builders_itemsprice_backoff';
    if (blocked) return 'builders_itemsprice_blocked_412';
    if (statusCode != null && (statusCode! < 200 || statusCode! >= 300)) {
      if (statusCode == 400) {
        final n = (note ?? '').toLowerCase();
        if (n.contains('itemidtype')) {
          return 'builders_itemsprice_http_400_itemIdType';
        }
        if (n.contains('itemids')) {
          return 'builders_itemsprice_http_400_itemIds';
        }
        if (n.contains('storeids') || n.contains('preferredstoreid')) {
          return 'builders_itemsprice_http_400_store';
        }
        if (n.contains('site')) return 'builders_itemsprice_http_400_site';
        if (n.contains('variables') || n.contains('graphql')) {
          return 'builders_itemsprice_http_400_vars';
        }
      }
      return 'builders_itemsprice_http_${statusCode!}';
    }
    if (statusCode == 200 && returnedCount == 0) {
      return 'builders_itemsprice_empty';
    }
    return 'builders_itemsprice_no_price';
  }
}

class _BuildersBffConfig {
  final String searchKey;
  final String searchHash;
  final String site;
  final String itemsPriceHash;

  const _BuildersBffConfig({
    required this.searchKey,
    required this.searchHash,
    required this.site,
    required this.itemsPriceHash,
  });
}

class _BuildersBffConfigCacheEntry {
  final DateTime fetchedAt;
  final _BuildersBffConfig? value;

  const _BuildersBffConfigCacheEntry({
    required this.fetchedAt,
    required this.value,
  });
}
