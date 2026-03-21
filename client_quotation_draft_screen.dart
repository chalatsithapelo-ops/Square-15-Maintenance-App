import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:maintenanceapp/controller/app_controller.dart';
import 'package:maintenanceapp/services/builders_webview_pricing.dart';
import 'package:maintenanceapp/services/future_booking_service.dart';
import 'package:maintenanceapp/services/rfq_ai_service.dart';
import 'package:maintenanceapp/utils/primary_button.dart';
import 'package:webview_flutter/webview_flutter.dart';

class QuotationDraftScreen extends StatefulWidget {
  final String categoryName;
  final String categoryId;
  final String problemDescription;
  final String additionalNotes;
  final List<String> imageUrls;
  final bool serviceOnCurrentLocation;
  final String serviceAddress;
  final String serviceLat;
  final String serviceLng;
  final double? initialBudget;
  final String? initialMaterialsResponsibility; // 'client' | 'artisan'

  const QuotationDraftScreen({
    super.key,
    required this.categoryName,
    required this.categoryId,
    required this.problemDescription,
    required this.additionalNotes,
    required this.imageUrls,
    required this.serviceOnCurrentLocation,
    required this.serviceAddress,
    required this.serviceLat,
    required this.serviceLng,
    this.initialBudget,
    this.initialMaterialsResponsibility,
  });

  @override
  State<QuotationDraftScreen> createState() => _QuotationDraftScreenState();
}

class _QuotationDraftScreenState extends State<QuotationDraftScreen> {
  static const Color _square15Gold = Color(0xFFc5a520);

  final AppController appController = Get.find();
  final TextEditingController feedbackController = TextEditingController();

  late final WebViewController _buildersWebViewController;

  bool isGenerating = false;
  bool isSubmitting = false;
  Map<String, dynamic>? aiQuotation;
  bool userApproved = false;
  String? materialsResponsibility; // 'client' | 'artisan'
  double? parsedBudget;

  static String _compactText(String input) {
    return input.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '');
  }

  static bool _looksLikeKwikot(String input) {
    final s = input.toLowerCase();
    if (s.contains('kwikot')) return true;
    final c = _compactText(s);
    if (c.contains('kwikot')) return true;
    // Common voice/typing variants.
    if (c.contains('kwikhot') ||
        c.contains('kwikote') ||
        c.contains('quickot')) {
      return true;
    }
    // Heuristic: "kwik" ... "ot" within a small span.
    return RegExp(r'kwik[a-z0-9]{0,3}ot').hasMatch(c);
  }

  static bool _looksLikeApollo(String input) {
    final s = input.toLowerCase();
    if (s.contains('apollo')) return true;
    return _compactText(s).contains('apollo');
  }

  static String _normalizeBuildersImageUrl(String raw) {
    var s = raw.trim();
    if (s.isEmpty) return '';

    // Guard against srcset-like values: "url 320w".
    s = s.split(RegExp(r'\s+')).first;

    // Guard against CSS wrappers: url("...").
    final cssWrapMatch =
        RegExp('^url\\(["\']?(.*?)["\']?\\)\$', caseSensitive: false);
    final m = cssWrapMatch.firstMatch(s);
    if (m != null) {
      s = (m.group(1) ?? '').trim();
    }

    // Strip lingering quotes.
    s = s.replaceAll('"', '').replaceAll("'", '').trim();
    if (s.isEmpty) return '';

    if (s.startsWith('data:')) return s;
    if (s.startsWith('//')) return 'https:$s';
    if (s.startsWith('/')) return 'https://www.builders.co.za$s';
    return s;
  }

  static bool _isGenericBuildersQuery(String qLower) {
    final q = qLower.trim();
    if (q.isEmpty) return true;
    // If the query has no numbers and only 1-2 meaningful tokens, it's often too generic
    // for Builders search (e.g. "sealant", "cleaning supplies").
    final hasNumber = RegExp(r'\d').hasMatch(q);
    final tokens = q
        .split(RegExp(r'\s+'))
        .map((s) => s.trim())
        .where((s) => s.length >= 3)
        .toList(growable: false);
    return !hasNumber && tokens.length <= 2;
  }

  String _categoryHintForBuilders() {
    final s = widget.categoryName.toLowerCase();
    // Use a safe category hint that narrows results without pulling in large primary
    // nouns like "geyser" that can dominate generic items.
    if (s.contains('plumb') || s.contains('bath') || s.contains('toilet')) return 'plumbing';
    if (s.contains('electric') || s.contains('electrical')) return 'electrical';
    if (s.contains('paint')) return 'paint';
    if (s.contains('roof')) return 'roofing';
    if (s.contains('air') && s.contains('condition')) return 'air conditioner';
    if (s.contains('carpenter') || s.contains('wood')) return 'hardware';
    return widget.categoryName.trim().isNotEmpty ? widget.categoryName.trim() : 'hardware';
  }

  static String _bestLineQuery(Map<String, dynamic> line) {
    String pick(String key) => (line[key] ?? '').toString().trim();
    final name = pick('name');
    final resolved = pick('resolved_name');
    // Prefer the more descriptive text; avoid using resolved_name alone because it may
    // have been overwritten by an earlier (incorrect) selection.
    final nameScore = name.replaceAll(RegExp(r'[^a-zA-Z0-9 ]'), ' ').trim().length;
    final resolvedScore =
        resolved.replaceAll(RegExp(r'[^a-zA-Z0-9 ]'), ' ').trim().length;
    if (nameScore == 0 && resolvedScore == 0) return '';
    if (nameScore >= resolvedScore) return name;
    return resolved;
  }

  List<String> get _workImageUrls {
    final urls = widget.imageUrls
        .map((u) => u.toString().trim())
        .where((u) => u.isNotEmpty)
        .map((u) => u.startsWith('//') ? 'https:$u' : u)
        .where((u) => u.startsWith('http://') || u.startsWith('https://'))
        .toList(growable: false);
    return urls;
  }

  double get _materialsMultiplier {
    final raw = aiQuotation?['materialsMultiplier'];
    if (raw is num) return raw.toDouble();
    final parsed = double.tryParse((raw ?? '').toString().trim());
    return (parsed != null && parsed.isFinite && parsed > 0) ? parsed : 1.5;
  }

  bool get _artisanBuysMaterials {
    final raw = (aiQuotation?['materials_responsibility'] ??
            materialsResponsibility ??
            '')
        .toString()
        .trim()
        .toLowerCase();
    return raw == 'artisan';
  }

  bool get _hasPrefilledInputs {
    final b = widget.initialBudget;
    final mr = (widget.initialMaterialsResponsibility ?? '').trim();
    return b != null && b.isFinite && b > 0 && mr.isNotEmpty;
  }

  bool _needsBuildersDisambiguation(Map<String, dynamic> line) {
    final matchedBy = (line['matched_by'] ?? '').toString();
    if (matchedBy.startsWith('builders_')) return true;
    if (matchedBy.contains('builders')) return true;
    // Treat pricing guardrails as “needs user choice” so the sheet doesn’t disappear
    // when we skip expensive Builders lookups.
    if (matchedBy == 'pricing_timeout_skipped') return true;
    if (matchedBy == 'builders_search_budget_skipped') return true;
    return matchedBy == 'builders_no_match';
  }

  Future<Map<String, String>?> _showBuildersCandidatePicker(
    List<Map<String, String>> allCandidatesSorted,
  ) async {
    if (!mounted) return null;

    final shownProductIds = <String>{};
    List<Map<String, String>> visible = <Map<String, String>>[];
    bool isLoading = false;
    bool hasMore = true;

    Future<void> loadNextBatch(StateSetter setSheetState) async {
      if (isLoading) return;
      setSheetState(() => isLoading = true);
      try {
        // Pick next 3 candidates not yet shown.
        final next = allCandidatesSorted
            .where((e) => !shownProductIds.contains((e['productId'] ?? '').trim()))
            .take(3)
            .map((e) => Map<String, String>.from(e))
            .toList(growable: true);

        if (next.isEmpty) {
          setSheetState(() {
            hasMore = false;
            isLoading = false;
          });
          return;
        }

        // Resolve missing images.
        for (var i = 0; i < next.length; i++) {
          final c = Map<String, String>.from(next[i]);
          final img = (c['imageUrl'] ?? '').trim();
          final isPlaceholder = img.contains('/sample.') || img.contains('placeholder');
          final pid = (c['productId'] ?? '').trim();
          if (pid.isEmpty) continue;

          if (img.isEmpty || isPlaceholder) {
            try {
              final resolved = await BuildersWebViewPricing.instance
                  .imageFromProductId(pid)
                  .timeout(const Duration(seconds: 8), onTimeout: () => null);
              if (resolved != null && resolved.trim().isNotEmpty) {
                c['imageUrl'] = resolved.trim();
                next[i] = c;
              }
            } catch (_) {
              // ignore
            }
          }
        }

        // Normalize image URLs for display.
        final normalized = next
            .map((c) => <String, String>{
                  ...c,
                  'imageUrl': _normalizeBuildersImageUrl(
                    (c['imageUrl'] ?? '').toString(),
                  ),
                })
            .toList(growable: false);

        for (final c in normalized) {
          final pid = (c['productId'] ?? '').trim();
          if (pid.isNotEmpty) shownProductIds.add(pid);
        }

        setSheetState(() {
          visible = normalized;
          isLoading = false;
          hasMore = true;
        });
      } catch (_) {
        setSheetState(() => isLoading = false);
      }
    }

    return showModalBottomSheet<Map<String, String>>(
      context: context,
      isScrollControlled: true,
      enableDrag: false,
      useSafeArea: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) {
        // Kick off the first batch once the sheet is built.
        Widget thumbFor(String img) {
          final u = img.trim();
          if (u.isEmpty || u.startsWith('data:')) {
            return Container(
              color: Colors.grey.shade200,
              child: Icon(
                Icons.image_not_supported_outlined,
                color: Colors.grey.shade600,
              ),
            );
          }

          return Image.network(
            u,
            fit: BoxFit.cover,
            headers: const <String, String>{
              'User-Agent':
                  'Mozilla/5.0 (Linux; Android 12) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36',
              'Referer': 'https://www.builders.co.za/',
            },
            loadingBuilder: (context, child, loadingProgress) {
              if (loadingProgress == null) return child;
              return Container(
                color: Colors.grey.shade200,
                alignment: Alignment.center,
                child: SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    value: loadingProgress.expectedTotalBytes != null
                        ? loadingProgress.cumulativeBytesLoaded /
                            loadingProgress.expectedTotalBytes!
                        : null,
                  ),
                ),
              );
            },
            errorBuilder: (context, error, stackTrace) {
              return InkWell(
                onTap: () {
                  showDialog<void>(
                    context: context,
                    builder: (ctx) {
                      final host = Uri.tryParse(u)?.host ?? '';
                      return AlertDialog(
                        title: const Text('Image failed'),
                        content: SingleChildScrollView(
                          child: Text(
                            'Host: $host\n\nURL:\n$u\n\nError:\n${error.toString()}',
                          ),
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.of(ctx).pop(),
                            child: const Text('OK'),
                          ),
                        ],
                      );
                    },
                  );
                },
                child: Container(
                  color: Colors.grey.shade200,
                  child: Icon(
                    Icons.broken_image_outlined,
                    color: Colors.grey.shade600,
                  ),
                ),
              );
            },
          );
        }

        final sheetHeight = MediaQuery.of(context).size.height * 0.75;
        return StatefulBuilder(
          builder: (context, setSheetState) {
            if (visible.isEmpty && !isLoading && hasMore) {
              Future.microtask(() => loadNextBatch(setSheetState));
            }

            return SizedBox(
              height: sheetHeight,
              child: Stack(
                children: [
                  Column(
                    children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Select a Builders item',
                        style: GoogleFonts.roboto(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: _square15Gold,
                        ),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close),
                      color: Colors.grey.shade700,
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                        child: visible.isEmpty
                            ? Center(
                                child: Text(
                                  hasMore
                                      ? 'Loading items…'
                                      : 'No more items to show.',
                                  style: GoogleFonts.roboto(
                                    color: Colors.black87,
                                    fontSize: 14,
                                  ),
                                ),
                              )
                            : ListView.separated(
                                itemCount: visible.length,
                                separatorBuilder: (_, __) => const Divider(height: 1),
                                itemBuilder: (context, index) {
                                  final c = visible[index];
                    final title = (c['title'] ?? '').toString().trim();
                    final img = (c['imageUrl'] ?? '').toString().trim();

                                  return InkWell(
                                    onTap: () => Navigator.of(context).pop(c),
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 16,
                                        vertical: 12,
                                      ),
                                      child: Row(
                                        crossAxisAlignment: CrossAxisAlignment.center,
                                        children: [
                                          ClipRRect(
                                            borderRadius: BorderRadius.circular(12),
                                            child: SizedBox(
                                              width: 120,
                                              height: 120,
                                              child: thumbFor(img),
                                            ),
                                          ),
                                          const SizedBox(width: 12),
                                          Expanded(
                                            child: Text(
                                              title.isEmpty ? 'Builders item' : title,
                                              style: GoogleFonts.roboto(
                                                fontSize: 16,
                                                height: 1.2,
                                                color: Colors.black87,
                                              ),
                                            ),
                                          ),
                                          const SizedBox(width: 8),
                                          Icon(
                                            Icons.chevron_right,
                                            color: Colors.grey.shade600,
                                          ),
                                        ],
                                      ),
                                    ),
                                  );
                                },
                              ),
                      ),
                      const Divider(height: 1),
                      Container(
                        padding: const EdgeInsets.all(16),
                        child: SizedBox(
                          width: double.infinity,
                          child: ElevatedButton.icon(
                            onPressed: (hasMore && !isLoading)
                                ? () => loadNextBatch(setSheetState)
                                : null,
                            icon: const Icon(Icons.refresh),
                            label: const Text('Load different items'),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: _square15Gold,
                              foregroundColor: Colors.black,
                              padding: const EdgeInsets.symmetric(vertical: 14),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  if (isLoading)
                    Positioned.fill(
                      child: Container(
                        color: Colors.black.withOpacity(0.05),
                        alignment: Alignment.center,
                        child: const SizedBox(
                          width: 28,
                          height: 28,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      ),
                    ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _chooseBuildersItemForMaterial({
    required bool isPricedList,
    required int index,
  }) async {
    if (aiQuotation == null) return;

    // Prefer reference lists (these keep diagnostics + prices even when the client buys materials).
    final pricedRef = ((aiQuotation!['materialsPriced_reference'] ??
                aiQuotation!['materialsPriced']) as List?)
            ?.whereType<Map>()
            .map((m) => m.map((k, v) => MapEntry(k.toString(), v)))
            .cast<Map<String, dynamic>>()
            .toList() ??
        <Map<String, dynamic>>[];
    final unpricedRef = ((aiQuotation!['materialsUnpriced_reference'] ??
                aiQuotation!['materialsUnpriced']) as List?)
            ?.whereType<Map>()
            .map((m) => m.map((k, v) => MapEntry(k.toString(), v)))
            .cast<Map<String, dynamic>>()
            .toList() ??
        <Map<String, dynamic>>[];

    final targetList = isPricedList ? pricedRef : unpricedRef;
    if (index < 0 || index >= targetList.length) return;

    final line = Map<String, dynamic>.from(targetList[index]);
    final query = _bestLineQuery(line);
    if (query.isEmpty) return;

    final qLower = query.toLowerCase();
    final bool isMountingRequest =
        qLower.contains('mounting bracket') ||
        qLower.contains('mounting structure') ||
        qLower.contains('mounting kit') ||
        qLower.contains('mounting frame') ||
        (qLower.contains('bracket') &&
            (qLower.contains('solar') || qLower.contains('geyser')));
    final aiDisclaimer = (aiQuotation?['disclaimer'] ?? '').toString();
    final requestTextLower =
      ('${widget.problemDescription} ${widget.additionalNotes} $aiDisclaimer $query')
        .toLowerCase();

    // Only apply brand preference when it makes sense.
    // Example: selecting a drip tray shouldn't force Kwikot results.
    final isDripTray = qLower.contains('drip tray') || qLower.contains('driptray');
    // Treat mounting/structure lines as accessories, not geyser units.
    final isGeyser = qLower.contains('geyser') && !isDripTray && !isMountingRequest;
    final queryMentionsBrand =
        _looksLikeKwikot(query) || _looksLikeApollo(query);
    final bool applyBrandPreference = isGeyser || queryMentionsBrand;

    String? expectedBrand;
    if (applyBrandPreference) {
      // Prefer the brand explicitly mentioned in THIS line item.
      if (_looksLikeKwikot(query)) {
        expectedBrand = 'kwikot';
      } else if (_looksLikeApollo(query)) {
        expectedBrand = 'apollo';
      } else {
        // Only fall back to the broader request if it clearly indicates a
        // single brand preference.
        final wantsK = _looksLikeKwikot(requestTextLower);
        final wantsA = _looksLikeApollo(requestTextLower);
        if (wantsK && !wantsA) {
          expectedBrand = 'kwikot';
        } else if (wantsA && !wantsK) {
          expectedBrand = 'apollo';
        }
      }
    }

    final wantsApollo = expectedBrand == 'apollo';
    final wantsKwikot = expectedBrand == 'kwikot';

    String mountingFocusedQuery(String original) {
      final s = original.toLowerCase();
      final hasSolar = s.contains('solar');
      final wantsRoof = s.contains('roof');
      // Builders tends to return better results with shorter queries.
      // Also avoid including "geyser" which can dominate results.
      final parts = <String>[
        if (hasSolar) 'solar',
        if (wantsRoof) 'roof',
        'mounting',
        // Try both common naming patterns.
        if (s.contains('frame')) 'frame' else 'kit',
        if (s.contains('bracket')) 'bracket',
        if (s.contains('stand')) 'stand',
      ];
      return parts.join(' ').trim();
    }

    // Improve query for cable searches to avoid getting only clips/accessories
    String effectiveQuery = (expectedBrand != null && !qLower.contains(expectedBrand))
        ? '$query ${expectedBrand[0].toUpperCase()}${expectedBrand.substring(1)}'
        : query;

    // For mounting/structure lines, use a short, mounting-focused query. Including
    // "geyser" often returns only tank units.
    if (isMountingRequest) {
      effectiveQuery = mountingFocusedQuery(effectiveQuery);
    }

    // For generic line-items, add a safe category hint to improve relevance.
    // Avoid stuffing the full problem description (it can bias results to the main item,
    // e.g. "geyser"), which is bad for small consumables.
    if (_isGenericBuildersQuery(qLower)) {
      final hint = _categoryHintForBuilders();
      if (hint.isNotEmpty && !effectiveQuery.toLowerCase().contains(hint.toLowerCase())) {
        effectiveQuery = '$effectiveQuery $hint';
      }
    }
    
    // For cable searches, add "wire" or "conductor" to prioritize actual cables over clips
    if (qLower.contains('cable') && !qLower.contains('clip') && !qLower.contains('strap')) {
      if (!qLower.contains('wire') && !qLower.contains('conductor')) {
        effectiveQuery = '$effectiveQuery wire';
      }
    }

    // Show searching message - will be dismissed when picker shows
    final searchingSnackBar = ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Searching…'),
        duration: Duration(seconds: 30),
      ),
    );

    // Fetch more than we show so we can rank to the best 3.
    // We keep this fairly high because we apply filters below.
    Future<List<Map<String, String>>> runSearch(String q) async {
      return BuildersWebViewPricing.instance
          .searchTopProducts(q, limit: (isGeyser || isMountingRequest) ? 24 : 12);
    }

        // Ensure Builders session is ready only when we actually need to search.
        await BuildersWebViewPricing.instance.ensureBootstrapped();

    List<Map<String, String>> rawCandidates =
        await runSearch(effectiveQuery);

    // Debug log to see what images we got from search
    print('[Builders Search] Got ${rawCandidates.length} results');
    for (final c in rawCandidates.take(5)) {
      print('[Builders Search]   ${c['title']}: imageUrl="${c['imageUrl']}"');
    }

    // Seed a known, commonly requested Kwikot 200L geyser product.
    // This protects the flow when Builders search results are not fully
    // rendered/scrapable in the WebView session.
    if (isGeyser && wantsKwikot && !qLower.contains('solar')) {
      final m = RegExp(r'(\d{2,3})\s*l').firstMatch(qLower);
      final liters = m != null ? int.tryParse(m.group(1) ?? '') : null;
      if (liters != null && liters >= 200) {
        const kwikot200Url =
            'https://www.builders.co.za/Plumbing-Bathroom-and-Kitchen/Geysers-and-Water-Heaters/Geysers/Kwikot-DSG-200-5-400KPA-Superline-Dual-Geyser-200-L/p/000000000000659070';
        rawCandidates = <Map<String, String>>[
          {
            'productId': '000000000000659070',
            'title': 'Kwikot DSG 200L geyser',
            'url': kwikot200Url,
            'imageUrl': '',
          },
          ...rawCandidates.where((c) => (c['productId'] ?? '').trim() != '000000000000659070'),
        ];
      }
    }

    // If a brand was specified and we got nothing useful, try a few targeted
    // queries. Builders often uses model names (e.g., "DSG") instead of
    // repeating the brand in visible titles.
    if (rawCandidates.isEmpty && expectedBrand != null && isGeyser) {
      final int? liters = RegExp(r'(\d{2,3})\s*l')
                  .firstMatch(qLower)
                  ?.group(1)
                  .toString()
                  .trim()
                  .isNotEmpty ==
              true
          ? int.tryParse(
              RegExp(r'(\d{2,3})\s*l').firstMatch(qLower)!.group(1)!,
            )
          : null;

      final brandLabel = expectedBrand == 'kwikot' ? 'Kwikot' : 'Apollo';
      final variants = <String>{
        '$brandLabel geyser${liters != null ? ' ${liters}L' : ''}',
        '$brandLabel geyser${liters != null ? ' $liters l' : ''}',
        if (expectedBrand == 'kwikot') '$brandLabel DSG${liters != null ? ' $liters' : ''}',
        if (expectedBrand == 'kwikot') '$brandLabel Superline${liters != null ? ' $liters' : ''}',
        if (qLower.contains('solar')) '$brandLabel solar geyser${liters != null ? ' ${liters}L' : ''}',
        if (qLower.contains('solar')) '$brandLabel solar geyser${liters != null ? ' $liters l' : ''}',
      };

      for (final v in variants) {
        final res = await runSearch(v);
        if (res.isNotEmpty) {
          rawCandidates = res;
          break;
        }
      }
    }

    // Targeted fallback for solar geyser mounting structure lines.
    // Builders often indexes these as "mounting kit/frame/roof mount" or under
    // "collector" rather than "geyser".
    if (rawCandidates.isEmpty && isMountingRequest) {
      String simplify(String s) {
        var out = s.toLowerCase();
        out = out.replaceAll('mounting structure', 'mounting kit');
        out = out.replaceAll('mounting frame', 'mounting kit');
        out = out.replaceAll(RegExp(r'\s+'), ' ').trim();
        return out;
      }

      final variants = <String>{
        simplify(effectiveQuery),
        simplify(query),
        'solar geyser mounting kit',
        'solar geyser roof mounting kit',
        'solar geyser mounting frame',
        'solar geyser roof bracket',
        'solar geyser mounting bracket',
        'solar geyser stand',
        'solar roof mounting bracket',
        'solar roof bracket',
        'solar mounting bracket',
        'solar mounting kit',
        'solar collector mounting kit',
        'solar collector roof mount',
        'solar mounting frame',
        'roof mounting kit',
        'roof bracket',
      };

      for (final v in variants) {
        final vv = v.trim();
        if (vv.isEmpty) continue;
        final res = await runSearch(vv);
        if (res.isNotEmpty) {
          rawCandidates = res;
          break;
        }
      }
    }
    if (!mounted) return;

    if (rawCandidates.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No Builders matches found.')),
      );
      return;
    }

    int scoreCandidate(Map<String, String> c) {
      final t = (c['title'] ?? '').toLowerCase();
      final u = (c['url'] ?? '').toLowerCase();
      final text = '$t $u';
      int score = 0;

      // Filter out service/installation pages.
      if (text.contains('installation') || text.contains('service')) return -9999;

      // For cable/pipe searches, strongly down-score accessories unless query asks for them
      final queryWantsAccessory = qLower.contains('clip') || qLower.contains('strap') || qLower.contains('tie') || qLower.contains('clamp');
      if ((qLower.contains('cable') || qLower.contains('pipe')) && !queryWantsAccessory) {
        if (text.contains('clip') || text.contains('strap') || text.contains('tie') || text.contains('clamp')) {
          score -= 100;  // Down-score heavily but don't hard-reject
        }
      }

      // Strong type filter: a geyser request must return geyser/water-heater items.
      if (isGeyser &&
          !(text.contains('geyser') ||
              text.contains('water heater') ||
              u.contains('geysers') ||
              u.contains('water-heaters') ||
              u.contains('water-heater'))) {
        return -9999;
      }

      // If the line item does NOT mention geyser (and it's a generic consumable),
      // strongly down-rank full geyser units to prevent irrelevant suggestions.
      final isGeneric = _isGenericBuildersQuery(qLower);
      if (!isGeyser && isGeneric) {
        if (text.contains('geyser') || text.contains('water heater') || u.contains('geysers')) {
          score -= 120;
        }
      }

      // Strong type filter: a drip tray request should return drip tray items.
      if (isDripTray && !(text.contains('drip tray') || text.contains('driptray'))) {
        return -9999;
      }

      // Mounting/structure requests: prefer mounting-related keywords, but do NOT
      // hard-reject everything (Builders often returns mixed results).
      if (isMountingRequest) {
        final hasMountKeyword = text.contains('mounting') ||
            text.contains('bracket') ||
            text.contains('stand') ||
            text.contains('support') ||
            text.contains('frame') ||
            text.contains('roof') ||
            text.contains('rack');
        if (hasMountKeyword) {
          score += 20;
        } else {
          score -= 35;
        }
        // Down-rank full tank units when searching for mounting hardware.
        if (text.contains('geyser') && !hasMountKeyword) score -= 15;
      }

      // If the query is for a geyser unit (not accessories), exclude common accessory-only items.
      final bool queryWantsSolar = qLower.contains('solar');
      final int? liters = RegExp(r'(\d{2,3})\s*l').firstMatch(qLower) != null
          ? int.tryParse(RegExp(r'(\d{2,3})\s*l').firstMatch(qLower)!.group(1)!)
          : null;
      final accessoryKeywords = <String>[
        'isolator',
        'switch',
        'circuit breaker',
        'breaker',
        'vacuum breaker',
        'pressure control',
        'safety valve',
        'valve',
        'drip tray',
        'tray',
        'element',
        'thermostat',
      ];
      final bool queryIsAccessory = accessoryKeywords.any((k) => qLower.contains(k));
      if (isGeyser && !queryIsAccessory) {
        if (accessoryKeywords.any((k) => t.contains(k))) {
          return -9999;
        }
      }

      // If the query specifies solar, require solar in title.
      if (isGeyser && queryWantsSolar && !text.contains('solar')) {
        return -9999;
      }

      // If the query specifies liters (e.g. 200L), require it in title.
      if (isGeyser && liters != null) {
        final token1 = '${liters}l';
        final token2 = '$liters l';
        final token3 = '$liters litre';
        final token4 = '$liters liter';
        final token5 = '$liters liters';
        final token6 = '$liters litres';
        if (!(text.contains(token1) ||
            text.contains(token2) ||
            text.contains(token3) ||
            text.contains(token4) ||
            text.contains(token5) ||
            text.contains(token6))) {
          return -9999;
        }
      }

      // If a specific brand is required, prefer it strongly, but don't hard-filter.
      // The picker is already a user confirmation step; showing candidates is better
      // than "no match" when Builders doesn't include the brand name in titles.
      if (wantsKwikot && !_looksLikeKwikot(t)) score -= 50;
      if (wantsApollo && !_looksLikeApollo(t)) score -= 50;

      if (wantsApollo && _looksLikeApollo(t)) score += 20;
      if (wantsKwikot && _looksLikeKwikot(t)) score += 20;
      if (expectedBrand != null) {
        final matchesBrand = expectedBrand == 'kwikot'
            ? _looksLikeKwikot(text)
            : _looksLikeApollo(text);
        if (!matchesBrand) score -= 20;
      }
      if (wantsKwikot && _looksLikeApollo(t)) score -= 6;
      if (wantsApollo && _looksLikeKwikot(t)) score -= 6;

      if (isGeyser && t.contains('geyser')) score += 3;
      if (queryWantsSolar && text.contains('solar')) score += 6;
      if (liters != null && (t.contains('${liters}l') || t.contains('$liters l'))) {
        score += 8;
      }
      // Token overlap
      for (final tok in qLower
          .split(RegExp(r'\s+'))
          .map((s) => s.trim())
          .where((s) => s.length >= 3)) {
        if (text.contains(tok)) score += 1;
      }
      // Prefer results with images
      if ((c['imageUrl'] ?? '').trim().isNotEmpty) score += 1;
      return score;
    }

    final scored = rawCandidates
        .map((c) => MapEntry<Map<String, String>, int>(c, scoreCandidate(c)))
        // Anything this low is considered an explicit reject by the scorer.
        .where((e) => e.value > -9000)
        .toList(growable: false);

    if (scored.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No matching Builders items found.')),
      );
      return;
    }

    // If the user specified a brand, prefer that brand strongly.
    // For solar geysers, if no exact brand match exists, show closest matches with warning
    // (Builders may not stock all brands for solar).
    final List<MapEntry<Map<String, String>, int>> scoredPreferred;
    if (expectedBrand != null) {
      bool matchesBrandTitle(Map<String, String> c) {
        final t = (c['title'] ?? '').toLowerCase();
        final u = (c['url'] ?? '').toLowerCase();
        final hay = '$t $u';
        return expectedBrand == 'kwikot'
            ? _looksLikeKwikot(hay)
            : _looksLikeApollo(hay);
      }

      final filtered = scored.where((e) => matchesBrandTitle(e.key)).toList(growable: false);
      if (filtered.isNotEmpty) {
        scoredPreferred = filtered;
      } else {
        // For solar geysers, Builders stock may be limited. Show top results anyway.
        final isSolarGeyser = qLower.contains('solar') && isGeyser;
        if (isSolarGeyser && scored.isNotEmpty) {
          scoredPreferred = scored;
          final brand = expectedBrand == 'kwikot' ? 'Kwikot' : 'Apollo';
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                  'No $brand solar geysers found. Showing closest matches - verify brand before selecting.'),
              duration: const Duration(seconds: 4),
            ),
          );
        } else {
          final msg = expectedBrand == 'kwikot'
              ? 'No Kwikot items found on Builders (try changing litres/model name).'
              : 'No Apollo items found on Builders (try changing litres/model name).';
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(msg)),
          );
          return;
        }
      }
    } else {
      scoredPreferred = scored;
    }

    scoredPreferred.sort((a, b) => b.value.compareTo(a.value));

    final picked = await _showBuildersCandidatePicker(
      scoredPreferred.map((e) => Map<String, String>.from(e.key)).toList(growable: false),
    );

    if (!mounted || picked == null) return;

    final pid = (picked['productId'] ?? '').trim();
    if (pid.isEmpty) return;

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Pricing selected item…')),
    );
    double? price =
        await BuildersWebViewPricing.instance.itemsPriceFromProductId(pid);
    if ((price == null || price <= 0) &&
        (picked['url'] ?? '').toString().trim().isNotEmpty) {
      price = await BuildersWebViewPricing.instance.priceFromUrl(
        (picked['url'] ?? '').toString(),
      );
    }
    if (!mounted) return;

    if (price == null || price <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not fetch a price for that item.')),
      );
      return;
    }

    final qty = (line['qty'] as num?)?.toDouble() ??
        double.tryParse((line['qty'] ?? '').toString()) ??
        1.0;

    line['unit_price'] = price;
    line['line_base'] = price * (qty > 0 ? qty : 1.0);
    final pickedTitle = (picked['title'] ?? '').toString().trim();
    if (pickedTitle.isNotEmpty) {
      line['resolved_name'] = pickedTitle;
    }
    line['matched_by'] = 'builders_user_selected';
    line['matched_key'] = (picked['url'] ?? '').toString();
    // Persist the product image URL so admin/artisan can see the chosen product
    final pickedImage = (picked['imageUrl'] ?? '').toString().trim();
    if (pickedImage.isNotEmpty) {
      line['builders_image_url'] = _normalizeBuildersImageUrl(pickedImage);
    }

    if (isPricedList) {
      pricedRef[index] = line;
    } else {
      unpricedRef[index] = line;
    }

    aiQuotation!['materialsPriced_reference'] = pricedRef;
    aiQuotation!['materialsUnpriced_reference'] = unpricedRef;
    RFQAIService.recomputeQuotationTotals(aiQuotation!);

    setState(() {});
  }

  List<Widget> _buildMaterialsSection() {
    final priced = ((aiQuotation?['materialsPriced_reference'] ??
                aiQuotation?['materialsPriced']) as List?)
            ?.cast<dynamic>() ??
        const <dynamic>[];
    final unpriced = ((aiQuotation?['materialsUnpriced_reference'] ??
                aiQuotation?['materialsUnpriced']) as List?)
            ?.cast<dynamic>() ??
        const <dynamic>[];
    // If the client will purchase materials, we must NOT show any prices.
    final bool allowPriceDisplay = _artisanBuysMaterials;

    final rows = <Widget>[];

    Widget rowFor(
      dynamic raw, {
      required bool showPrice,
      required bool isPricedList,
      required int index,
    }) {
      final m = (raw as Map?)?.cast<String, dynamic>() ?? <String, dynamic>{};
      final name = (m['name'] ?? '').toString();
      final resolvedName = (m['resolved_name'] ?? '').toString();
      final matchedBy = (m['matched_by'] ?? '').toString();
      final qty = (m['qty'] as num?)?.toDouble() ??
          double.tryParse((m['qty'] ?? '').toString()) ??
          1.0;
      final unit = (m['unit'] ?? '').toString();
      final unitPriceNum = (m['unit_price'] as num?)?.toDouble() ??
          double.tryParse((m['unit_price'] ?? '').toString());
      final lineBaseNum = (m['line_base'] as num?)?.toDouble() ??
          (unitPriceNum != null ? unitPriceNum * qty : null);

      final multiplier = _materialsMultiplier;
      final displayUnitPriceNum =
          unitPriceNum != null ? unitPriceNum * multiplier : null;
      final displayLineBaseNum =
          lineBaseNum != null ? lineBaseNum * multiplier : null;

      final priceText = (allowPriceDisplay && showPrice)
          ? (unitPriceNum != null
              ? 'R${(displayUnitPriceNum ?? unitPriceNum).toStringAsFixed(2)}'
              : 'TBD')
          : '';
      final lineText = (allowPriceDisplay && showPrice)
          ? (lineBaseNum != null
              ? 'R${(displayLineBaseNum ?? lineBaseNum).toStringAsFixed(2)}'
              : 'TBD')
          : '';

      return Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            InkWell(
              onTap: () {
                          // Remove this item from the list
                          final pricedRef = ((aiQuotation!['materialsPriced_reference'] ??
                                      aiQuotation!['materialsPriced']) as List?)
                                  ?.whereType<Map>()
                                  .map((m) => m.map((k, v) => MapEntry(k.toString(), v)))
                                  .cast<Map<String, dynamic>>()
                                  .toList() ??
                              <Map<String, dynamic>>[];
                          final unpricedRef = ((aiQuotation!['materialsUnpriced_reference'] ??
                                      aiQuotation!['materialsUnpriced']) as List?)
                                  ?.whereType<Map>()
                                  .map((m) => m.map((k, v) => MapEntry(k.toString(), v)))
                                  .cast<Map<String, dynamic>>()
                                  .toList() ??
                              <Map<String, dynamic>>[];
                          
                          if (isPricedList) {
                            pricedRef.removeAt(index);
                            aiQuotation!['materialsPriced_reference'] = pricedRef;
                          } else {
                            unpricedRef.removeAt(index);
                            aiQuotation!['materialsUnpriced_reference'] = unpricedRef;
                          }
                          RFQAIService.recomputeQuotationTotals(aiQuotation!);
                          setState(() {});
                        },
              child: Icon(
                Icons.close,
                size: 18,
                color: Colors.grey.shade600,
              ),
            ),
            const SizedBox(width: 8),
            const Icon(Icons.build_circle_outlined,
                color: _square15Gold, size: 16),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name.isNotEmpty ? name : 'Material',
                    style: GoogleFonts.roboto(fontSize: 13),
                  ),
                  if (resolvedName.trim().isNotEmpty &&
                      resolvedName.trim() != name.trim())
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        'Matched: $resolvedName',
                        style: GoogleFonts.roboto(
                            fontSize: 11, color: Colors.grey.shade700),
                      ),
                    ),
                  if (_needsBuildersDisambiguation(m))
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Align(
                            alignment: Alignment.centerLeft,
                            child: TextButton(
                              style: TextButton.styleFrom(
                                foregroundColor: _square15Gold,
                                padding: EdgeInsets.zero,
                                visualDensity: VisualDensity.compact,
                              ),
                              onPressed: () => _chooseBuildersItemForMaterial(
                                isPricedList: isPricedList,
                                index: index,
                              ),
                              child: const Text('Choose item'),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  '${qty.toStringAsFixed(qty % 1 == 0 ? 0 : 1)} ${unit.isNotEmpty ? unit : ''}'
                      .trim(),
                  style: GoogleFonts.roboto(
                      fontSize: 12, color: Colors.grey.shade700),
                ),
                if (allowPriceDisplay)
                  Text(
                    '$priceText  •  $lineText',
                    style: GoogleFonts.roboto(
                        fontSize: 12, fontWeight: FontWeight.bold),
                  ),
              ],
            ),
          ],
        ),
      );
    }

    if (priced.isNotEmpty) {
      rows.add(Text('Priced items',
          style:
              GoogleFonts.roboto(fontSize: 13, fontWeight: FontWeight.w600)));
      rows.add(const SizedBox(height: 8));
      for (var i = 0; i < priced.length; i++) {
        final m = priced[i];
        final unitPriceRaw = (m as Map?)?['unit_price'];
        final unitPriceNum = (unitPriceRaw is num)
            ? unitPriceRaw.toDouble()
            : double.tryParse((unitPriceRaw ?? '').toString());
        rows.add(rowFor(
          m,
          showPrice: unitPriceNum != null,
          isPricedList: true,
          index: i,
        ));
      }
    }

    if (unpriced.isNotEmpty) {
      if (rows.isNotEmpty) rows.add(const SizedBox(height: 10));
      rows.add(Text('Unpriced items (admin will confirm)',
          style:
              GoogleFonts.roboto(fontSize: 13, fontWeight: FontWeight.w600)));
      rows.add(const SizedBox(height: 8));
      for (var i = 0; i < unpriced.length; i++) {
        final m = unpriced[i];
        rows.add(rowFor(
          m,
          showPrice: false,
          isPricedList: false,
          index: i,
        ));
      }
    }

    if (rows.isEmpty) {
      rows.add(Text('No materials list available.',
          style:
              GoogleFonts.roboto(fontSize: 13, color: Colors.grey.shade700)));
    }

    return rows;
  }

  @override
  void initState() {
    super.initState();

    // Hidden WebView used as a real browser session for Builders pricing.
    _buildersWebViewController = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0x00000000));
    BuildersWebViewPricing.instance
        .attachController(_buildersWebViewController);
    // NOTE: Bootstrapping Builders (homepage load + config discovery) can be slow.
    // Defer it until the user explicitly opens the Builders picker.

    // This screen is now strictly driven by values collected earlier in the RFQ workflow.
    final b = widget.initialBudget;
    if (b != null && b.isFinite && b > 0) {
      parsedBudget = b;
    }

    final mr = (widget.initialMaterialsResponsibility ?? '').trim();
    if (mr.isNotEmpty) {
      materialsResponsibility = mr;
    }

    // If prefilled, immediately generate the quotation.
    if (_hasPrefilledInputs) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _generateAIQuotation();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_hasPrefilledInputs) {
      return Scaffold(
        appBar: AppBar(
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('AI Quotation Draft',
                  style: GoogleFonts.roboto(color: Colors.white, fontSize: 18)),
              Text('Review & Submit',
                  style:
                      GoogleFonts.roboto(color: Colors.white70, fontSize: 12)),
            ],
          ),
          backgroundColor: _square15Gold,
          iconTheme: const IconThemeData(color: Colors.white),
        ),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Missing required RFQ details.',
                  style: GoogleFonts.roboto(
                      fontSize: 16, fontWeight: FontWeight.bold),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Text(
                  'Please go back and provide your budget and who will buy materials before generating a quotation.',
                  style: GoogleFonts.roboto(
                      fontSize: 13, color: Colors.grey.shade700),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: PrimaryButton(
                    onPressed: () => Get.back(),
                    color: _square15Gold,
                    title: 'Go Back',
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('AI Quotation Draft',
                style: GoogleFonts.roboto(color: Colors.white, fontSize: 18)),
            Text('Review & Submit',
                style: GoogleFonts.roboto(color: Colors.white70, fontSize: 12)),
          ],
        ),
        backgroundColor: _square15Gold,
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: Stack(
        children: [
          SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Step Indicator
                Container(
                  padding: const EdgeInsets.all(15),
                  decoration: BoxDecoration(
                    color: _square15Gold.withOpacity(0.10),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                        color: _square15Gold.withOpacity(0.40), width: 1),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.info_outline,
                          color: _square15Gold, size: 24),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'Review the AI draft quotation and submit it for admin review.',
                          style: GoogleFonts.roboto(
                              fontSize: 13, color: Colors.grey.shade800),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 25),

                if (_workImageUrls.isNotEmpty) ...[
                  Text('Attached Photos',
                      style: GoogleFonts.roboto(
                          fontSize: 15, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 10),
                  SizedBox(
                    height: 96,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      itemCount: _workImageUrls.length,
                      separatorBuilder: (_, __) => const SizedBox(width: 10),
                      itemBuilder: (context, i) {
                        final url = _workImageUrls[i];
                        return ClipRRect(
                          borderRadius: BorderRadius.circular(10),
                          child: Image.network(
                            url,
                            width: 96,
                            height: 96,
                            fit: BoxFit.cover,
                            errorBuilder: (context, error, stackTrace) {
                              return Container(
                                width: 96,
                                height: 96,
                                color: Colors.grey.shade100,
                                child: const Icon(
                                  Icons.image_not_supported_outlined,
                                  color: Colors.grey,
                                ),
                              );
                            },
                          ),
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 25),
                ],

                // AI Generated Quotation
                Text('AI Generated Quotation',
                    style: GoogleFonts.roboto(
                        fontSize: 18, fontWeight: FontWeight.bold)),
                const SizedBox(height: 15),

                if (isGenerating)
                  Container(
                    padding: const EdgeInsets.all(30),
                    decoration: BoxDecoration(
                      color: Colors.grey.shade100,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Column(
                      children: [
                        const CircularProgressIndicator(color: _square15Gold),
                        const SizedBox(height: 20),
                        Text(
                          'AI is analyzing your requirements...',
                          style: GoogleFonts.roboto(
                              fontSize: 14, color: Colors.grey.shade700),
                        ),
                      ],
                    ),
                  )
                else if (aiQuotation != null) ...[
                  Container(
                    padding: const EdgeInsets.all(15),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: Colors.grey.shade300, width: 1),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.grey.shade200,
                          blurRadius: 5,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Project Title
                        Row(
                          children: [
                            const Icon(Icons.description,
                                color: _square15Gold, size: 24),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                aiQuotation!['projectTitle'] ??
                                    'Service Quotation',
                                style: GoogleFonts.roboto(
                                    fontSize: 16, fontWeight: FontWeight.bold),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 15),
                        const Divider(),
                        const SizedBox(height: 15),

                        // Scope of Work
                        Text('Scope of Work:',
                            style: GoogleFonts.roboto(
                                fontSize: 15, fontWeight: FontWeight.bold)),
                        const SizedBox(height: 8),
                        Text(
                          aiQuotation!['scopeOfWork'] ?? '',
                          style: GoogleFonts.roboto(fontSize: 14, height: 1.5),
                        ),
                        const SizedBox(height: 20),

                        // Materials List
                        if (aiQuotation!['materialsPriced'] != null ||
                            aiQuotation!['materialsUnpriced'] != null) ...[
                          Text('Materials List:',
                              style: GoogleFonts.roboto(
                                  fontSize: 15, fontWeight: FontWeight.bold)),
                          const SizedBox(height: 8),
                          Container(
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: Colors.blue.shade50,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                  color: Colors.blue.shade200, width: 1),
                            ),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Icon(Icons.info_outline,
                                    size: 18, color: Colors.blue.shade700),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    'Tap "Choose item" on any material below to select '
                                    'the exact product you prefer. Your selection will '
                                    'be shared with the artisan and admin so they '
                                    'purchase the right item for your job.\n\n'
                                    'Tap the "X" to remove any material items that '
                                    'might not be necessary.',
                                    style: GoogleFonts.roboto(
                                      fontSize: 12,
                                      color: Colors.blue.shade800,
                                      height: 1.4,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 10),
                          ..._buildMaterialsSection(),
                          const SizedBox(height: 15),
                        ],

                        // Materials & Labor Breakdown
                        if (aiQuotation!['breakdown'] != null) ...[
                          Text('Cost Breakdown:',
                              style: GoogleFonts.roboto(
                                  fontSize: 15, fontWeight: FontWeight.bold)),
                          const SizedBox(height: 10),
                          ...List<Widget>.from(
                              (aiQuotation!['breakdown'] as List).map((item) {
                            return Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: Row(
                                children: [
                                  const Icon(Icons.check_circle,
                                      color: _square15Gold, size: 16),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      item['description'],
                                      style: GoogleFonts.roboto(fontSize: 13),
                                    ),
                                  ),
                                  Text(
                                    'R${item['cost']}',
                                    style: GoogleFonts.roboto(
                                        fontSize: 13,
                                        fontWeight: FontWeight.bold),
                                  ),
                                ],
                              ),
                            );
                          })),
                          const SizedBox(height: 15),
                        ],

                        const Divider(),
                        const SizedBox(height: 10),

                        // Total Estimated Cost
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              'Total Estimated Cost:',
                              style: GoogleFonts.roboto(
                                  fontSize: 16, fontWeight: FontWeight.bold),
                            ),
                            Text(
                              'R${aiQuotation!['estimatedCost']}',
                              style: GoogleFonts.roboto(
                                fontSize: 20,
                                fontWeight: FontWeight.bold,
                                color: _square15Gold,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 15),

                        // Timeline
                        if (aiQuotation!['estimatedDuration'] != null) ...[
                          Row(
                            children: [
                              const Icon(Icons.access_time,
                                  color: Colors.grey, size: 18),
                              const SizedBox(width: 8),
                              Text(
                                'Estimated Duration: ${aiQuotation!['estimatedDuration']}',
                                style: GoogleFonts.roboto(
                                    fontSize: 13, color: Colors.grey.shade700),
                              ),
                            ],
                          ),
                        ],

                        if ((aiQuotation!['disclaimer'] ?? '')
                            .toString()
                            .trim()
                            .isNotEmpty) ...[
                          const SizedBox(height: 12),
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: _square15Gold.withOpacity(0.10),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                  color: _square15Gold.withOpacity(0.40)),
                            ),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Icon(Icons.info_outline,
                                    color: _square15Gold, size: 18),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Text(
                                    (aiQuotation!['disclaimer'] ?? '')
                                        .toString(),
                                    style: GoogleFonts.roboto(
                                        fontSize: 12,
                                        color: Colors.grey.shade800,
                                        height: 1.3),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 25),

                  // User Feedback
                  Text('Your Feedback',
                      style: GoogleFonts.roboto(
                          fontSize: 18, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  Text(
                    'Are you satisfied with this quotation?',
                    style: GoogleFonts.roboto(
                        fontSize: 14, color: Colors.grey.shade600),
                  ),
                  const SizedBox(height: 10),

                  Row(
                    children: [
                      Expanded(
                        child: CheckboxListTile(
                          title: Text('Yes, looks good!',
                              style: GoogleFonts.roboto()),
                          value: userApproved,
                          activeColor: _square15Gold,
                          onChanged: (value) {
                            setState(() {
                              userApproved = value ?? false;
                            });
                          },
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 15),

                  TextField(
                    controller: feedbackController,
                    maxLines: 3,
                    decoration: InputDecoration(
                      hintText:
                          'Add any comments or concerns about this quotation (optional)',
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10)),
                      contentPadding: const EdgeInsets.all(15),
                    ),
                  ),
                  const SizedBox(height: 30),

                  // Submit Button
                  isSubmitting
                      ? const Center(
                          child:
                              CircularProgressIndicator(color: _square15Gold))
                      : SizedBox(
                          width: double.infinity,
                          child: PrimaryButton(
                            onPressed: _submitRFQToAdmin,
                            color: _square15Gold,
                            title: 'Submit to Admin for Review',
                          ),
                        ),
                ],
              ],
            ),
          ),
          Offstage(
            offstage: true,
            child: SizedBox(
              width: 1,
              height: 1,
              child: WebViewWidget(controller: _buildersWebViewController),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _generateAIQuotation() async {
    if (!_hasPrefilledInputs) {
      Get.snackbar(
        'Required',
        'Please provide your budget and materials choice before generating.',
        backgroundColor: _square15Gold,
        colorText: Colors.white,
      );
      return;
    }

    final b = parsedBudget;

    setState(() => isGenerating = true);

    final sw = Stopwatch()..start();

    try {
      // Call AI service to generate quotation
      final quotation = await RFQAIService.generateQuotation(
        categoryId: widget.categoryId,
        categoryName: widget.categoryName,
        problemDescription: widget.problemDescription,
        additionalNotes: widget.additionalNotes,
        imageUrls: widget.imageUrls,
        materialsResponsibility: materialsResponsibility ?? 'client',
        userBudget: b,
      );
      sw.stop();

      String bracketDiag = '';
      try {
        final priced = (quotation['materialsPriced'] as List?)?.whereType<Map>()
                .map((m) => m.map((k, v) => MapEntry(k.toString(), v)))
                .toList() ??
            <Map<String, dynamic>>[];
        final bracket = priced.firstWhere(
          (m) {
            final n = (m['name'] ?? '').toString().toLowerCase();
            return n.contains('bracket') || n.contains('mount');
          },
          orElse: () => <String, dynamic>{},
        );
        if (bracket.isNotEmpty) {
          final by = (bracket['matched_by'] ?? '').toString();
          final p = bracket['unit_price'];
          bracketDiag = by.isNotEmpty ? ' • brackets:$by (R$p)' : '';
        }
      } catch (_) {
        // ignore
      }

      setState(() {
        aiQuotation = quotation;
        isGenerating = false;
      });

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Generated in ${(sw.elapsedMilliseconds / 1000).toStringAsFixed(1)}s$bracketDiag',
          ),
          duration: const Duration(seconds: 4),
          backgroundColor: _square15Gold,
        ),
      );
    } catch (e) {
      debugPrint('Error generating AI quotation: $e');
      setState(() => isGenerating = false);

      if (sw.isRunning) sw.stop();
      final secs = (sw.elapsedMilliseconds / 1000).toStringAsFixed(1);

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Could not generate quotation (after ${secs}s).'),
          backgroundColor: _square15Gold,
          duration: const Duration(seconds: 4),
        ),
      );
    }
  }

  Future<void> _submitRFQToAdmin() async {
    if (aiQuotation == null || isGenerating) {
      Get.snackbar(
        'Please Wait',
        'AI quotation is still generating. Please wait a moment.',
        backgroundColor: _square15Gold,
        colorText: Colors.white,
      );
      return;
    }

    final b = parsedBudget;
    if (b == null || b <= 0) {
      Get.snackbar(
        'Required',
        'Please generate the quotation first.',
        backgroundColor: _square15Gold,
        colorText: Colors.white,
      );
      return;
    }

    if ((materialsResponsibility ?? '').isEmpty) {
      Get.snackbar(
        'Required',
        'Please choose who will buy materials before submitting.',
        backgroundColor: _square15Gold,
        colorText: Colors.white,
      );
      return;
    }

    if (!userApproved) {
      Get.snackbar(
        'Required',
        'Please confirm the quotation looks good before submitting.',
        backgroundColor: _square15Gold,
        colorText: Colors.white,
      );
      return;
    }

    if (!mounted) return;
    setState(() => isSubmitting = true);

    try {
      // Date/time scheduling is deferred until AFTER admin reviews and
      // approves the RFQ.  The client will pick a date when they accept the
      // admin-amended quote (see client_rfq_response_screen.dart).
      final scheduledDate = '';   // will be set post-approval
      final scheduledTime = '';

      // Calculate profit analysis for admin and artisan
      final total = ((aiQuotation?['total'] ?? 0.0) as num).toDouble();
      final profitAnalysis = RFQAIService.calculateProfitAnalysis(aiQuotation!);
      final profitAnalysisArtisan = RFQAIService.filterProfitAnalysisForArtisan(profitAnalysis);
      
      // Determine routing: if client buys materials, always go to artisans.
      // Only route to admin for high-value jobs where artisan provides materials.
      final bool clientBuysMats = (materialsResponsibility ?? 'client').trim().toLowerCase() == 'client';
      final isHighValue = !clientBuysMats && total >= 10000.0;
      final rfqStatus = (clientBuysMats || !isHighValue) ? 'pending_artisan_acceptance' : 'pending_admin_review';
      final rfqSubmittedTo = (clientBuysMats || !isHighValue) ? 'artisan' : 'admin';
      
      final result = await FutureBookingService.createBookingAndNotify(
        userId: appController.userId.value,
        jobIds: const [],
        taskNamesById: const {},
        taskCostsById: const {},
        scheduledDate: scheduledDate,
        scheduledTime: scheduledTime,
        serviceOnCurrentLocation: widget.serviceOnCurrentLocation,
        userLat: appController.userLat.value,
        userLng: appController.userLng.value,
        providedAddress:
            widget.serviceOnCurrentLocation ? '' : widget.serviceAddress,
        otherLat: widget.serviceOnCurrentLocation ? '' : widget.serviceLat,
        otherLng: widget.serviceOnCurrentLocation ? '' : widget.serviceLng,
        workImageUrls: widget.imageUrls,
        description: widget.problemDescription,
        categoryId: widget.categoryId,
        categoryName: widget.categoryName,
        materialsResponsibility: materialsResponsibility ?? 'client',
        aiQuote: aiQuotation,
        isRFQRequested: true,
        rfqReason: 'client_requested',
        createdBy: 'rfq_workflow',
      ).timeout(
        const Duration(seconds: 60),
        onTimeout: () => throw TimeoutException('RFQ submission timed out after 60 seconds'),
      );

      final bookingId = (result['bookingId'] ?? '').toString();
      if (bookingId.trim().isNotEmpty) {
        await FutureBookingService.futureBookingsRef.doc(bookingId).update({
          'user_budget': b,
          'user_feedback': feedbackController.text.trim(),
          'user_draft_approved': 'yes',
          'user_draft_approved_at': DateTime.now().toString(),
          'materials_responsibility': materialsResponsibility ?? 'client',
          // RFQ-specific fields
          'problem_description': widget.problemDescription,
          'additional_notes': widget.additionalNotes,
          'image_urls': widget.imageUrls,
          // Backward/forward compatibility: admin screens may read different keys.
          'work_images': widget.imageUrls,
          'work_image_urls': widget.imageUrls,
          // New RFQ workflow fields
          'rfq_status': rfqStatus,
          'rfq_submitted_to': rfqSubmittedTo,
          'rfq_submitted_at': DateTime.now().toString(),
          'rfq_total': total,
          'profit_analysis_admin': profitAnalysis,
          'profit_analysis_artisan': profitAnalysisArtisan,
          'rfq_artisan_rejections': [],
          'rfq_artisan_rejection_count': 0,
          'rfq_client_rejections': [],
          // Scheduling is now captured at submission.
          'requires_scheduling': true,
        }).timeout(const Duration(seconds: 30));
      }

      Get.back();
      Get.back();

      final successMessage = rfqSubmittedTo == 'admin'
          ? 'Your RFQ (R${total.toStringAsFixed(2)}) has been submitted to admin for review. You will be contacted shortly.'
          : 'Your RFQ (R${total.toStringAsFixed(2)}) has been submitted to available artisans. You will be notified when an artisan responds.';

      Get.snackbar(
        'Success',
        successMessage,
        backgroundColor: Colors.green,
        colorText: Colors.white,
        duration: const Duration(seconds: 5),
      );
    } on TimeoutException catch (e) {
      debugPrint('RFQ submission timeout: $e');
      Get.snackbar(
        'Timeout',
        'Request is taking too long. Please check your connection and try again.',
        backgroundColor: Colors.orange,
        colorText: Colors.white,
        duration: const Duration(seconds: 5),
      );
    } catch (e) {
      debugPrint('Error submitting RFQ: $e');
      Get.snackbar(
        'Error',
        'Failed to submit request. Please try again.',
        backgroundColor: Colors.red,
        colorText: Colors.white,
      );
    } finally {
      if (mounted) setState(() => isSubmitting = false);
    }
  }

  @override
  void dispose() {
    BuildersWebViewPricing.instance.detachController();
    feedbackController.dispose();
    super.dispose();
  }
}
