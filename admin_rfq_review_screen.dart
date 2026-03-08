import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:admain_maintence_app/services/admin_notification_service.dart';

/// Admin RFQ Review Screen - for reviewing and managing RFQ requests
class AdminRFQReviewScreen extends StatefulWidget {
  final String bookingId;
  final Map<String, dynamic> bookingData;

  const AdminRFQReviewScreen({
    super.key,
    required this.bookingId,
    required this.bookingData,
  });

  @override
  State<AdminRFQReviewScreen> createState() => _AdminRFQReviewScreenState();
}

class _AdminRFQReviewScreenState extends State<AdminRFQReviewScreen> {
  static const Color _square15Gold = Color(0xFFD4AF37);

  Map<String, dynamic>? profitAnalysis;
  Map<String, dynamic>? aiQuote;
  bool isLoading = false;

  /// Resolve the parent (main) category for a booking.
  /// The booking's `category_name` is often a subcategory (e.g. "bathroom")
  /// while artisans register under the parent category (e.g. "plumbing").
  /// This method looks up the Firestore categories tree to find the parent.
  Future<String> _resolveParentCategory(String rfqCategory) async {
    if (rfqCategory.isEmpty) return rfqCategory;

    // 1. Check if rfqCategory already IS a parent category.
    final parentSnap = await FirebaseFirestore.instance
        .collection('category')
        .where('parent_id', isEqualTo: '')
        .get();

    for (final doc in parentSnap.docs) {
      final name = (doc.data()['name'] ?? '').toString().toLowerCase().trim();
      if (name == rfqCategory) return rfqCategory; // already a parent
    }

    // 2. rfqCategory is likely a subcategory — find which parent it belongs to.
    final subSnap = await FirebaseFirestore.instance
        .collection('category')
        .where('parent_id', isNotEqualTo: '')
        .get();

    for (final doc in subSnap.docs) {
      final name = (doc.data()['name'] ?? '').toString().toLowerCase().trim();
      if (name == rfqCategory) {
        final parentId = (doc.data()['parent_id'] ?? '').toString().trim();
        if (parentId.isEmpty) continue;
        // Lookup the parent doc
        for (final pDoc in parentSnap.docs) {
          final pId = (pDoc.data()['id'] ?? pDoc.id).toString().trim();
          if (pId == parentId) {
            final parentName = (pDoc.data()['name'] ?? '').toString().toLowerCase().trim();
            debugPrint('[category] Resolved subcategory "$rfqCategory" → parent "$parentName"');
            return parentName;
          }
        }
      }
    }

    // 3. Also check if booking data has a serviceCategory or mainCategory hint.
    final sc = (widget.bookingData['serviceCategory'] ??
            widget.bookingData['service_category'] ??
            widget.bookingData['mainCategory'] ??
            '')
        .toString()
        .toLowerCase()
        .trim();
    if (sc.isNotEmpty && sc != rfqCategory) {
      debugPrint('[category] Using serviceCategory from booking: "$sc"');
      return sc;
    }

    return rfqCategory;
  }

  /// Check if an artisan matches the given category (parent or sub).
  bool _artisanMatchesCategory(Map<String, dynamic> artisanData, String rfqCategory, String parentCategory) {
    if (rfqCategory.isEmpty && parentCategory.isEmpty) return true;

    final artisanMainCat = (artisanData['mainCategory'] ?? '').toString().toLowerCase().trim();
    final catArray = (artisanData['category'] is List) ? (artisanData['category'] as List) : [];
    final subCatArray = (artisanData['subCategory'] is List) ? (artisanData['subCategory'] as List) : [];

    final allCats = <String>[
      artisanMainCat,
      ...catArray.map((c) => c.toString().toLowerCase().trim()),
      ...subCatArray.map((c) => c.toString().toLowerCase().trim()),
    ];

    // Match against both the original subcategory name AND the resolved parent
    if (allCats.any((c) => c == parentCategory)) return true;
    if (allCats.any((c) => c == rfqCategory)) return true;
    // Partial match: artisan mainCategory contains or is contained by parent
    if (parentCategory.isNotEmpty && artisanMainCat.isNotEmpty) {
      if (artisanMainCat.contains(parentCategory) || parentCategory.contains(artisanMainCat)) return true;
    }
    return false;
  }

  CollectionReference<Map<String, dynamic>> get _rfqPrimary =>
      FirebaseFirestore.instance.collection('futureBookings');
  CollectionReference<Map<String, dynamic>> get _rfqLegacy =>
      FirebaseFirestore.instance.collection('future_bookings');

  Future<void> _writeRfqPatch(Map<String, dynamic> patch) async {
    final id = widget.bookingId.trim();
    if (id.isEmpty) return;

    // Write to both collections (merge) to eliminate schema/collection drift.
    Future<void> safeSet(CollectionReference<Map<String, dynamic>> col) async {
      try {
        await col.doc(id).set(patch, SetOptions(merge: true));
      } catch (_) {
        // ignore
      }
    }

    await Future.wait([
      safeSet(_rfqPrimary),
      safeSet(_rfqLegacy),
    ]);
  }

  static List<String> _extractImageUrls(Map<String, dynamic> data) {
    final candidates = <dynamic>[
      data['image_urls'],
      data['work_images'],
      data['work_image_urls'],
      data['imageUrls'],
      data['images'],
      data['photos'],
      data['client_images'],
      data['rfq_images'],
    ];

    for (final c in candidates) {
      if (c is List) {
        final urls = c
            .map((e) => e.toString().trim())
            .where((e) => e.isNotEmpty)
            .toList();
        if (urls.isNotEmpty) return urls;
      }
      if (c is String) {
        final s = c.trim();
        if (s.isEmpty) continue;
        // Try JSON list string
        try {
          final decoded = jsonDecode(s);
          if (decoded is List) {
            final urls = decoded
                .map((e) => e.toString().trim())
                .where((e) => e.isNotEmpty)
                .toList();
            if (urls.isNotEmpty) return urls;
          }
        } catch (_) {
          // ignore
        }
      }
    }

    return const <String>[];
  }

  static Map<String, dynamic>? _extractProfitAnalysis(
      Map<String, dynamic> data) {
    final candidates = <dynamic>[
      data['profit_analysis_admin'],
      data['profit_analysis'],
      data['profitability_analysis'],
      data['profitAnalysis'],
    ];

    for (final c in candidates) {
      if (c is Map) {
        return c.map((k, v) => MapEntry(k.toString(), v));
      }
      if (c is String) {
        final s = c.trim();
        if (s.isEmpty) continue;
        try {
          final decoded = jsonDecode(s);
          if (decoded is Map) {
            return decoded.map((k, v) => MapEntry(k.toString(), v));
          }
        } catch (_) {
          // ignore
        }
      }
    }

    final aq = data['ai_quote'];
    if (aq is Map) {
      final pa = aq['profit_analysis_admin'] ??
          aq['profit_analysis'] ??
          aq['profitability_analysis'];
      if (pa is Map) {
        return pa.map((k, v) => MapEntry(k.toString(), v));
      }
    }

    return null;
  }

  @override
  void initState() {
    super.initState();
    profitAnalysis = _extractProfitAnalysis(widget.bookingData);
    aiQuote = (widget.bookingData['ai_quote'] as Map?)
        ?.map((k, v) => MapEntry(k.toString(), v));

    // Debug logging
    print('[Admin RFQ] Booking ID: ${widget.bookingId}');
    print('[Admin RFQ] Has profit_analysis_admin: ${profitAnalysis != null}');
    print('[Admin RFQ] Has ai_quote: ${aiQuote != null}');
    print('[Admin RFQ] Image URLs raw: ${widget.bookingData['image_urls']}');
    print(
        '[Admin RFQ] Image URLs type: ${widget.bookingData['image_urls']?.runtimeType}');
    if (profitAnalysis != null) {
      print(
          '[Admin RFQ] Profit Analysis keys: ${profitAnalysis!.keys.toList()}');
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: _rfqPrimary.doc(widget.bookingId).snapshots(),
      builder: (context, snapshot) {
        final liveData = snapshot.data?.data();
        final data = <String, dynamic>{
          ...widget.bookingData,
          if (liveData != null) ...liveData,
        };

        // Try multiple fields for total: rfq_total, then ai_quote.total, then total
        // Handle both num and String types robustly
        double rfqTotal = 0.0;
        for (final key in ['rfq_total', 'admin_quote_total', 'total', 'cost', 'quote_amount']) {
          final v = data[key];
          if (v == null) continue;
          if (v is num && v > 0) { rfqTotal = v.toDouble(); break; }
          final parsed = double.tryParse(v.toString().replaceAll(RegExp(r'[^0-9.]'), ''));
          if (parsed != null && parsed > 0) { rfqTotal = parsed; break; }
        }
        if (rfqTotal <= 0) {
          final aq = data['ai_quote'];
          if (aq is Map) {
            final aqV = aq['total'] ?? aq['estimatedCost'];
            if (aqV is num && aqV > 0) rfqTotal = aqV.toDouble();
            else if (aqV != null) {
              final p = double.tryParse(aqV.toString().replaceAll(RegExp(r'[^0-9.]'), ''));
              if (p != null && p > 0) rfqTotal = p;
            }
          }
        }
        final rfqStatus = (data['rfq_status'] ?? '').toString();
        final categoryName = (data['category_name'] ?? '').toString();
        final problemDesc = (data['problem_description'] ?? '').toString();
        final imageUrls = _extractImageUrls(data);

        final extractedProfit = _extractProfitAnalysis(data);
        final extractedAiQuote = (data['ai_quote'] as Map?)
            ?.map((k, v) => MapEntry(k.toString(), v));

        return Scaffold(
          appBar: AppBar(
            title: Text('RFQ Review', style: GoogleFonts.roboto()),
            backgroundColor: _square15Gold,
            foregroundColor: Colors.black,
          ),
          body: isLoading
              ? const Center(child: CircularProgressIndicator())
              : SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildHeader(rfqTotal, rfqStatus, categoryName),
                      const SizedBox(height: 16),
                      _buildProblemDescription(problemDesc),
                      const SizedBox(height: 16),
                      if (imageUrls.isNotEmpty) _buildClientImages(imageUrls),
                      const SizedBox(height: 16),
                      if (extractedProfit != null)
                        _buildProfitAnalysis(extractedProfit),
                      const SizedBox(height: 16),
                      if (extractedAiQuote != null)
                        _buildMaterialsList(extractedAiQuote),
                      const SizedBox(height: 16),
                      _buildRejectionHistory(),
                      const SizedBox(height: 24),
                      _buildActionButtons(),
                    ],
                  ),
                ),
        );
      },
    );
  }

  Widget _buildHeader(double total, String status, String category) {
    Color statusColor = Colors.orange;
    String statusText = status;

    switch (status) {
      case 'pending_admin_review':
        statusColor = Colors.orange;
        statusText = 'Pending Your Review';
        break;
      case 'pending_client_response':
        statusColor = Colors.blue;
        statusText = 'Waiting for Client Response';
        break;
      case 'rfq_pending_payment':
        statusColor = Colors.orange;
        statusText = 'Awaiting Payment';
        break;
      case 'under_negotiation':
        statusColor = Colors.blue;
        statusText = 'Under Negotiation';
        break;
      case 'rfq_approved_waiting_assignment':
        statusColor = Colors.purple;
        statusText = 'Waiting for Assignment';
        break;
      case 'accepted_converted':
        statusColor = Colors.green;
        statusText = 'Accepted & Converted';
        break;
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'RFQ Total',
                  style:
                      GoogleFonts.roboto(fontSize: 14, color: Colors.grey[700]),
                ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: statusColor.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    statusText,
                    style: GoogleFonts.roboto(
                      fontSize: 12,
                      color: statusColor,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'R${total.toStringAsFixed(2)}',
              style: GoogleFonts.roboto(
                fontSize: 32,
                fontWeight: FontWeight.bold,
                color: _square15Gold,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              category,
              style: GoogleFonts.roboto(fontSize: 16, color: Colors.grey[600]),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildProblemDescription(String description) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Problem Description',
              style:
                  GoogleFonts.roboto(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(
              description,
              style: GoogleFonts.roboto(fontSize: 14),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildClientImages(List<String> imageUrls) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.photo_library, color: Colors.blue),
                const SizedBox(width: 8),
                Text(
                  'Client Photos (${imageUrls.length})',
                  style: GoogleFonts.roboto(
                      fontSize: 16, fontWeight: FontWeight.bold),
                ),
              ],
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 120,
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                itemCount: imageUrls.length,
                itemBuilder: (context, index) {
                  final url = imageUrls[index];
                  return Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: GestureDetector(
                      onTap: () {
                        // Show full-screen image
                        showDialog(
                          context: context,
                          builder: (ctx) => Dialog(
                            child: InteractiveViewer(
                              child: Image.network(url, fit: BoxFit.contain),
                            ),
                          ),
                        );
                      },
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: Image.network(
                          url,
                          width: 120,
                          height: 120,
                          fit: BoxFit.cover,
                          errorBuilder: (context, error, stackTrace) =>
                              Container(
                            width: 120,
                            height: 120,
                            color: Colors.grey[300],
                            child: const Icon(Icons.broken_image),
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildProfitAnalysis(Map<String, dynamic> profitAnalysis) {
    final labor = profitAnalysis['labor_costs'] as Map?;
    final materials = profitAnalysis['material_costs'] as Map?;
    final other = profitAnalysis['other_costs'] as Map?;
    final totals = profitAnalysis['totals'] as Map?;

    return Card(
      color: Colors.green[50],
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.analytics, color: Colors.green),
                const SizedBox(width: 8),
                Text(
                  'Profit Analysis (Admin View)',
                  style: GoogleFonts.roboto(
                      fontSize: 16, fontWeight: FontWeight.bold),
                ),
              ],
            ),
            const Divider(height: 24),

            // Labor Breakdown
            Text('Labor',
                style: GoogleFonts.roboto(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            _profitLine(
                'Hours', '${labor?['hours']?.toStringAsFixed(1) ?? "0"} hrs'),
            _profitLine('Client Rate',
                'R${labor?['client_rate']?.toStringAsFixed(2) ?? "0"}/ hr'),
            _profitLine('Outsourced Rate',
                'R${labor?['outsourced_rate']?.toStringAsFixed(2) ?? "0"}/hr'),
            _profitLine('Client Total',
                'R${labor?['client_total']?.toStringAsFixed(2) ?? "0"}',
                bold: true),
            _profitLine('Outsourced Total',
                'R${labor?['outsourced_total']?.toStringAsFixed(2) ?? "0"}'),
            _profitLine('Company Profit',
                'R${labor?['company_profit']?.toStringAsFixed(2) ?? "0"}',
                color: Colors.green[700]!),

            const Divider(height: 24),

            // Material Breakdown — hide when labour-only
            if (materials?['labour_only'] == true) ...[
              Text('Materials',
                  style: GoogleFonts.roboto(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.orange.shade50,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Icon(Icons.info_outline, size: 16, color: Colors.orange.shade700),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text('Labour Only — Client buys materials',
                        style: GoogleFonts.roboto(
                          fontSize: 13, color: Colors.orange.shade800,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ] else ...[
              Text('Materials',
                  style: GoogleFonts.roboto(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              _profitLine('Base Cost',
                  'R${materials?['base_cost']?.toStringAsFixed(2) ?? "0"}'),
              _profitLine('Multiplier',
                  '${materials?['multiplier']?.toStringAsFixed(2) ?? "0"}x'),
              _profitLine('Markup Total',
                  'R${materials?['markup_total']?.toStringAsFixed(2) ?? "0"}',
                  bold: true),
              _profitLine('Company Profit (10%)',
                  'R${materials?['company_profit']?.toStringAsFixed(2) ?? "0"}',
                  color: Colors.green[700]!),
              _profitLine('Artisan Profit (40%)',
                  'R${materials?['artisan_profit']?.toStringAsFixed(2) ?? "0"}'),
            ],

            const Divider(height: 24),

            // Other Costs
            Text('Other Costs',
                style: GoogleFonts.roboto(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            _profitLine('Equipment',
                'R${other?['equipment']?.toStringAsFixed(2) ?? "0"}'),
            _profitLine('Contingency (15%)',
                'R${other?['contingency']?.toStringAsFixed(2) ?? "0"}',
                color: Colors.green[700]!),

            const Divider(height: 24),

            // Totals
            Text('Summary',
                style: GoogleFonts.roboto(
                    fontWeight: FontWeight.bold, fontSize: 16)),
            const SizedBox(height: 8),
            _profitLine('Grand Total',
                'R${totals?['grand_total']?.toStringAsFixed(2) ?? "0"}',
                bold: true, fontSize: 18),
            _profitLine('Company Expected Profit',
                'R${totals?['company_expected_profit']?.toStringAsFixed(2) ?? "0"}',
                color: Colors.green[800]!, bold: true, fontSize: 16),
            _profitLine('Artisan Expected Costs',
                'R${totals?['artisan_expected_costs']?.toStringAsFixed(2) ?? "0"}'),
            _profitLine('Artisan Expected Profit',
                'R${totals?['artisan_expected_profit']?.toStringAsFixed(2) ?? "0"}'),
          ],
        ),
      ),
    );
  }

  Widget _profitLine(String label, String value,
      {bool bold = false, Color? color, double fontSize = 14}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: GoogleFonts.roboto(
              fontSize: fontSize,
              fontWeight: bold ? FontWeight.bold : FontWeight.normal,
            ),
          ),
          Text(
            value,
            style: GoogleFonts.roboto(
              fontSize: fontSize,
              fontWeight: bold ? FontWeight.bold : FontWeight.normal,
              color: color ?? Colors.black87,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMaterialsList(Map<String, dynamic> aiQuote) {
    final priced =
        (aiQuote['materialsPriced_reference'] as List?)?.cast<Map>() ?? [];
    final unpriced =
        (aiQuote['materialsUnpriced_reference'] as List?)?.cast<Map>() ?? [];

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Materials List',
              style:
                  GoogleFonts.roboto(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            if (priced.isNotEmpty) ...[
              Text('Priced Items',
                  style: GoogleFonts.roboto(fontWeight: FontWeight.w600)),
              ...priced.map((m) => _materialLine(m)),
            ],
            if (unpriced.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text('Unpriced Items',
                  style: GoogleFonts.roboto(fontWeight: FontWeight.w600)),
              ...unpriced.map((m) => _materialLine(m)),
            ],
          ],
        ),
      ),
    );
  }

  Widget _materialLine(Map material) {
    final name = (material['name'] ?? '').toString();
    final qty = ((material['qty'] ?? 1.0) as num).toDouble();
    final unit = (material['unit'] ?? '').toString();
    final unitPrice = ((material['unit_price'] ?? 0.0) as num).toDouble();
    final resolvedName = (material['resolved_name'] ?? '').toString().trim();
    final matchedBy = (material['matched_by'] ?? '').toString().trim();
    final isClientSelected = matchedBy == 'builders_user_selected';
    final imageUrl = (material['builders_image_url'] ?? '').toString().trim();

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Show product image if available, else icon
          if (imageUrl.isNotEmpty)
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: Image.network(
                imageUrl,
                width: 44,
                height: 44,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => const Icon(
                    Icons.build_circle_outlined,
                    size: 14,
                    color: _square15Gold),
              ),
            )
          else
            const Padding(
              padding: EdgeInsets.only(top: 2),
              child: Icon(Icons.build_circle_outlined,
                  size: 14, color: _square15Gold),
            ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name, style: GoogleFonts.roboto(fontSize: 13)),
                if (resolvedName.isNotEmpty && resolvedName != name) ...[
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      if (isClientSelected)
                        Padding(
                          padding: const EdgeInsets.only(right: 4),
                          child: Icon(Icons.check_circle,
                              size: 12, color: Colors.green.shade600),
                        ),
                      Expanded(
                        child: Text(
                          isClientSelected
                              ? 'Client chose: $resolvedName'
                              : 'Matched: $resolvedName',
                          style: GoogleFonts.roboto(
                            fontSize: 11,
                            color: isClientSelected
                                ? Colors.green.shade700
                                : Colors.grey.shade600,
                            fontWeight: isClientSelected
                                ? FontWeight.w600
                                : FontWeight.normal,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
          Text(
            '${qty.toStringAsFixed(qty % 1 == 0 ? 0 : 1)} $unit',
            style: GoogleFonts.roboto(fontSize: 12, color: Colors.grey[600]),
          ),
          if (unitPrice > 0) ...[
            const SizedBox(width: 12),
            Text(
              'R${unitPrice.toStringAsFixed(2)}',
              style:
                  GoogleFonts.roboto(fontSize: 12, fontWeight: FontWeight.bold),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildRejectionHistory() {
    final artisanRejections =
        (widget.bookingData['rfq_artisan_rejections'] as List?)?.cast<Map>() ??
            [];
    final clientRejections =
        (widget.bookingData['rfq_client_rejections'] as List?)?.cast<Map>() ??
            [];

    if (artisanRejections.isEmpty && clientRejections.isEmpty) {
      return const SizedBox.shrink();
    }

    return Card(
      color: Colors.red[50],
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.warning, color: Colors.red),
                const SizedBox(width: 8),
                Text(
                  'Rejection History',
                  style: GoogleFonts.roboto(
                      fontSize: 16, fontWeight: FontWeight.bold),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (artisanRejections.isNotEmpty) ...[
              Text('Artisan Rejections (${artisanRejections.length})',
                  style: GoogleFonts.roboto(fontWeight: FontWeight.w600)),
              ...artisanRejections.map((r) => _rejectionTile(r, 'Artisan')),
            ],
            if (clientRejections.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text('Client Rejections (${clientRejections.length})',
                  style: GoogleFonts.roboto(fontWeight: FontWeight.w600)),
              ...clientRejections.map((r) => _rejectionTile(r, 'Client')),
            ],
          ],
        ),
      ),
    );
  }

  Widget _rejectionTile(Map rejection, String type) {
    final reason = (rejection['reason'] ?? '').toString();
    final rejectedAt = (rejection['rejected_at'] ?? '').toString();
    final name =
        type == 'Artisan' ? (rejection['artisan_name'] ?? 'Unknown') : 'Client';

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('$name - $rejectedAt',
              style: GoogleFonts.roboto(fontSize: 11, color: Colors.grey[600])),
          Text(reason, style: GoogleFonts.roboto(fontSize: 13)),
        ],
      ),
    );
  }

  Widget _buildActionButtons() {
    final rfqStatus = (widget.bookingData['rfq_status'] ?? '').toString();
    final isApprovedWaiting = rfqStatus == 'rfq_approved_waiting_assignment';
    final isClientApproved = rfqStatus == 'client_approved_rfq' || isApprovedWaiting;
    final isPendingArtisan = rfqStatus == 'pending_artisan_acceptance';
    final isArtisanRejected = rfqStatus == 'artisan_rejected';

    final paymentStatus =
      (widget.bookingData['payment_status'] ?? '').toString().trim().toLowerCase();
    final walletDeductedRaw = widget.bookingData['wallet_deducted'];
    final walletDeducted = walletDeductedRaw is bool
      ? (walletDeductedRaw ? 'yes' : 'no')
      : (walletDeductedRaw ?? '').toString().trim().toLowerCase();
    final isPaid = paymentStatus == 'paid' || walletDeducted == 'yes';
    final canAssign = isClientApproved && isPaid;
    final canReassign = isPendingArtisan || isArtisanRejected;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!isApprovedWaiting) ...[
          ElevatedButton.icon(
            onPressed: _amendAndSendToClient,
            icon: const Icon(Icons.edit),
            label: const Text('Amend Quote & Send to Client'),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.blue,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.all(16),
            ),
          ),
          const SizedBox(height: 12),
        ],
        ElevatedButton.icon(
          onPressed: canAssign ? _assignToArtisan : null,
          icon: const Icon(Icons.person_add),
          label: Text(isApprovedWaiting
              ? 'Assign to External Artisan'
              : 'Assign to Artisan (requires client approval)'),
          style: ElevatedButton.styleFrom(
            backgroundColor: canAssign ? _square15Gold : Colors.grey,
            foregroundColor: Colors.black,
            padding: const EdgeInsets.all(16),
          ),
        ),
        const SizedBox(height: 12),
        ElevatedButton.icon(
          onPressed: canAssign ? _assignInternally : null,
          icon: const Icon(Icons.business),
          label: Text(isApprovedWaiting
              ? 'Assign to Internal Team'
              : 'Assign Internally (requires client approval)'),
          style: ElevatedButton.styleFrom(
            backgroundColor: canAssign ? Colors.green : Colors.grey,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.all(16),
          ),
        ),
        if (!isClientApproved || !isPaid) ...[
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.orange.shade50,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.orange.shade200),
            ),
            child: Row(
              children: [
                const Icon(Icons.info_outline, color: Colors.orange, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    !isClientApproved
                        ? 'Assignment requires client approval. Send amended quote and wait for client confirmation.'
                        : 'Awaiting client payment. Assignment can proceed once payment is received.',
                    style: GoogleFonts.roboto(
                      fontSize: 12,
                      color: Colors.orange.shade900,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 12),
        // ── Reassign (visible when artisan hasn't accepted or rejected) ──
        if (canReassign) ...[
          ElevatedButton.icon(
            onPressed: _reassignToArtisan,
            icon: const Icon(Icons.swap_horiz),
            label: const Text('Reassign / Re-broadcast'),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.orange,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.all(16),
            ),
          ),
          const SizedBox(height: 12),
        ],
        OutlinedButton.icon(
          onPressed: _closeRFQ,
          icon: const Icon(Icons.close),
          label: const Text('Close RFQ'),
          style: OutlinedButton.styleFrom(
            foregroundColor: Colors.red,
            padding: const EdgeInsets.all(16),
          ),
        ),
      ],
    );
  }

  /// Resolves the best available cost/total from booking data.
  /// Returns a numeric string (e.g. "1495.00") or empty string.
  String _resolveCost(Map<String, dynamic> data) {
    for (final key in ['rfq_total', 'admin_quote_total', 'cost', 'quote_amount', 'total']) {
      final v = data[key];
      if (v == null) continue;
      if (v is num && v > 0) return v.toStringAsFixed(2);
      final s = v.toString().replaceAll(RegExp(r'[^0-9.]'), '');
      final parsed = double.tryParse(s);
      if (parsed != null && parsed > 0) return parsed.toStringAsFixed(2);
    }
    // Try ai_quote.total
    final aq = data['ai_quote'];
    if (aq is Map) {
      final t = aq['total'] ?? aq['estimatedCost'];
      if (t is num && t > 0) return t.toDouble().toStringAsFixed(2);
      final s = (t ?? '').toString().replaceAll(RegExp(r'[^0-9.]'), '');
      final parsed = double.tryParse(s);
      if (parsed != null && parsed > 0) return parsed.toStringAsFixed(2);
    }
    return '';
  }

  Widget _profitRow(String label, double value, {bool bold = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Flexible(child: Text(label, style: GoogleFonts.roboto(fontSize: 12, fontWeight: bold ? FontWeight.w600 : FontWeight.normal))),
          Text(
            'R${value.toStringAsFixed(2)}',
            style: GoogleFonts.roboto(
              fontSize: 12,
              fontWeight: bold ? FontWeight.bold : FontWeight.w600,
              color: value >= 0 ? Colors.green.shade800 : Colors.red,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _amendAndSendToClient() async {
    double toDouble(dynamic v) {
      if (v == null) return 0.0;
      if (v is num) return v.toDouble();
      final s = v.toString().trim();
      if (s.isEmpty) return 0.0;
      final cleaned = s.replaceAll(RegExp(r'[^0-9.\-]'), '');
      return double.tryParse(cleaned) ?? 0.0;
    }

    final noteController = TextEditingController(
      text: (widget.bookingData['admin_amendment_notes'] ??
              widget.bookingData['rfq_admin_amend_note'] ??
              '')
          .toString(),
    );

    final baseAi = (aiQuote ?? <String, dynamic>{});

    // ── Check materials responsibility: is this a labour-only job? ──
    final matResp = (widget.bookingData['materials_responsibility'] ??
            baseAi['materials_responsibility'] ??
            baseAi['materialsResponsibility'] ??
            '')
        .toString()
        .trim()
        .toLowerCase();
    final isLabourOnly = matResp != 'artisan'; // 'client' or empty = labour only

    final priced = (baseAi['materialsPriced_reference'] as List?)
            ?.whereType<Map>()
            .map((m) => m.map((k, v) => MapEntry(k.toString(), v)))
            .toList() ??
        <Map<String, dynamic>>[];
    final unpriced = (baseAi['materialsUnpriced_reference'] as List?)
            ?.whereType<Map>()
            .map((m) => m.map((k, v) => MapEntry(k.toString(), v)))
            .toList() ??
        <Map<String, dynamic>>[];

    final initialItems = <Map<String, dynamic>>[
      ...priced,
      ...unpriced,
    ];

    final itemControllers = initialItems.map((m) {
      final name = (m['name'] ?? '').toString();
      final unit = (m['unit'] ?? '').toString();
      final qty = toDouble(m['qty'] ?? 1);
      final unitPrice = toDouble(m['unit_price']);
      return {
        'desc': TextEditingController(text: name),
        'uom': TextEditingController(text: unit),
        'qty': TextEditingController(text: (qty <= 0 ? 1 : qty).toString()),
        'unit': TextEditingController(text: (unitPrice <= 0 ? '' : unitPrice.toString())),
      };
    }).toList(growable: true);

    final laborHoursInitial = toDouble(
      baseAi['laborHours'] ??
          baseAi['labor_hours'] ??
          profitAnalysis?['labor_costs']?['hours'],
    );
    final laborRateInitial = toDouble(
      baseAi['laborCostPerHour'] ??
          baseAi['labor_cost_per_hour'] ??
          profitAnalysis?['labor_costs']?['client_rate'],
    );

    final laborHoursController = TextEditingController(
      text: (laborHoursInitial > 0 ? laborHoursInitial : 0).toString(),
    );
    final laborRateController = TextEditingController(
      text: (laborRateInitial > 0 ? laborRateInitial : 0).toString(),
    );

    Map<String, dynamic>? payload;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) {
          double computeMaterialsTotal() {
            var sum = 0.0;
            for (final c in itemControllers) {
              final qty = toDouble((c['qty'] as TextEditingController).text);
              final unitPrice =
                  toDouble((c['unit'] as TextEditingController).text);
              if (qty > 0 && unitPrice > 0) sum += qty * unitPrice;
            }
            return sum;
          }

          double computeLaborTotal() {
            final h = toDouble(laborHoursController.text);
            final r = toDouble(laborRateController.text);
            if (h <= 0 || r <= 0) return 0.0;
            return h * r;
          }

          final materialsTotal = computeMaterialsTotal();
          final laborTotal = computeLaborTotal();
          // Labour-only: exclude materials from the client total
          final effectiveMaterialsTotal = isLabourOnly ? 0.0 : materialsTotal;
          final total = effectiveMaterialsTotal + laborTotal;

          // ── Live profitability preview ──
          final lH = toDouble(laborHoursController.text);
          final lR = toDouble(laborRateController.text);
          final outsourcedRate = lR * 0.7;
          final companyLaborProfit = (lH * lR) - (lH * outsourcedRate);
          final materialMultiplier = 1.5;
          // Base cost is what admin sees as material total; markup is what client pays
          final materialBaseCost = isLabourOnly ? 0.0 : (materialsTotal / materialMultiplier);
          final materialProfit = isLabourOnly ? 0.0 : (materialsTotal - materialBaseCost);
          final companyMaterialProfit = materialProfit * 0.10;
          final artisanMaterialProfit = materialProfit * 0.40;
          final subtotalForContingency = laborTotal + effectiveMaterialsTotal;
          final contingency = subtotalForContingency * 0.15;
          final companyTotalProfit = companyLaborProfit + companyMaterialProfit + contingency;
          final artisanTotalProfit = artisanMaterialProfit;

          Widget itemRow(int idx) {
            final c = itemControllers[idx];
            return Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  IconButton(
                    onPressed: () {
                      setD(() {
                        itemControllers.removeAt(idx);
                      });
                    },
                    icon: const Icon(Icons.close, size: 18),
                  ),
                  Expanded(
                    child: Column(
                      children: [
                        TextField(
                          controller: c['desc'] as TextEditingController,
                          decoration: const InputDecoration(
                            labelText: 'Material description',
                            isDense: true,
                          ),
                          onChanged: (_) => setD(() {}),
                        ),
                        const SizedBox(height: 6),
                        Row(
                          children: [
                            Expanded(
                              child: TextField(
                                controller: c['qty'] as TextEditingController,
                                keyboardType: TextInputType.number,
                                decoration: const InputDecoration(
                                  labelText: 'Qty',
                                  isDense: true,
                                ),
                                onChanged: (_) => setD(() {}),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: TextField(
                                controller: c['uom'] as TextEditingController,
                                decoration: const InputDecoration(
                                  labelText: 'Unit',
                                  isDense: true,
                                ),
                                onChanged: (_) => setD(() {}),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: TextField(
                                controller: c['unit'] as TextEditingController,
                                keyboardType: TextInputType.number,
                                decoration: const InputDecoration(
                                  labelText: 'Unit price (client)',
                                  isDense: true,
                                ),
                                onChanged: (_) => setD(() {}),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            );
          }

          return AlertDialog(
            title: Text(
              'Amend Quote & Send',
              style: GoogleFonts.roboto(fontWeight: FontWeight.bold),
            ),
            content: SizedBox(
              width: double.maxFinite,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Labour', style: GoogleFonts.roboto(fontWeight: FontWeight.w600)),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: laborHoursController,
                            keyboardType: TextInputType.number,
                            decoration: const InputDecoration(
                              labelText: 'Hours',
                              isDense: true,
                            ),
                            onChanged: (_) => setD(() {}),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: TextField(
                            controller: laborRateController,
                            keyboardType: TextInputType.number,
                            decoration: const InputDecoration(
                              labelText: 'Rate (per hour)',
                              isDense: true,
                            ),
                            onChanged: (_) => setD(() {}),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Text('Materials', style: GoogleFonts.roboto(fontWeight: FontWeight.w600)),
                    if (isLabourOnly) ...[
                      const SizedBox(height: 4),
                      Container(
                        padding: const EdgeInsets.all(6),
                        decoration: BoxDecoration(
                          color: Colors.orange.shade50,
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: Colors.orange.shade300),
                        ),
                        child: Row(
                          children: [
                            Icon(Icons.info_outline, size: 14, color: Colors.orange.shade700),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                'Labour Only — Client buys materials (listed for reference only, not included in total)',
                                style: GoogleFonts.roboto(fontSize: 11, color: Colors.orange.shade800, fontWeight: FontWeight.w600),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                    const SizedBox(height: 8),
                    if (itemControllers.isEmpty)
                      Text('No materials yet.', style: GoogleFonts.roboto(color: Colors.grey[700])),
                    for (var i = 0; i < itemControllers.length; i++) itemRow(i),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        onPressed: () {
                          setD(() {
                            itemControllers.add({
                              'desc': TextEditingController(),
                              'uom': TextEditingController(),
                              'qty': TextEditingController(text: '1'),
                              'unit': TextEditingController(),
                            });
                          });
                        },
                        icon: const Icon(Icons.add),
                        label: const Text('Add material'),
                      ),
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: noteController,
                      maxLines: 3,
                      decoration: const InputDecoration(
                        labelText: 'Notes to client (what changed?)',
                        hintText: 'e.g. Updated labour rate and removed extra materials',
                      ),
                    ),
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.grey.shade100,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.grey.shade300),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Summary', style: GoogleFonts.roboto(fontWeight: FontWeight.w600)),
                          const SizedBox(height: 6),
                          Text('Labour: R${laborTotal.toStringAsFixed(2)}', style: GoogleFonts.roboto(fontSize: 12)),
                          Text('Materials: R${materialsTotal.toStringAsFixed(2)}${isLabourOnly ? " (ref only — not in total)" : ""}', style: GoogleFonts.roboto(fontSize: 12, color: isLabourOnly ? Colors.grey : null)),
                          const SizedBox(height: 6),
                          Text('Total: R${total.toStringAsFixed(2)}', style: GoogleFonts.roboto(fontWeight: FontWeight.bold)),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    // ── Profitability Preview ──
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.green.shade50,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.green.shade300),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Profitability Analysis', style: GoogleFonts.roboto(fontWeight: FontWeight.w600, color: Colors.green.shade800)),
                          const SizedBox(height: 6),
                          _profitRow('Company labour profit', companyLaborProfit),
                          _profitRow('Company material profit (10%)', companyMaterialProfit),
                          _profitRow('Contingency (15%)', contingency),
                          const Divider(height: 12),
                          _profitRow('Company total profit', companyTotalProfit, bold: true),
                          const SizedBox(height: 8),
                          _profitRow('Artisan material profit (40%)', artisanTotalProfit),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel'),
              ),
              ElevatedButton(
                onPressed: total <= 0
                    ? null
                    : () {
                        final items = itemControllers.map((c) {
                          final desc = (c['desc'] as TextEditingController).text.trim();
                          final uom = (c['uom'] as TextEditingController).text.trim();
                          final qty = toDouble((c['qty'] as TextEditingController).text);
                          final unit = toDouble((c['unit'] as TextEditingController).text);
                          return {
                            'description': desc,
                            'uom': uom,
                            'qty': qty,
                            'unit_price': unit,
                            'line_total': (qty > 0 && unit > 0) ? qty * unit : 0.0,
                          };
                        }).where((e) {
                          final d = (e['description'] ?? '').toString().trim();
                          final qty = toDouble(e['qty']);
                          return d.isNotEmpty && qty > 0;
                        }).toList(growable: false);

                        payload = {
                          'note': noteController.text.trim(),
                          'labor_hours': toDouble(laborHoursController.text),
                          'labor_rate': toDouble(laborRateController.text),
                          'items': items,
                          'materials_total': materialsTotal,
                          'labor_total': laborTotal,
                          'total': total,
                          'company_labor_profit': companyLaborProfit,
                          'company_material_profit': companyMaterialProfit,
                          'contingency': contingency,
                          'company_total_profit': companyTotalProfit,
                          'artisan_total_profit': artisanTotalProfit,
                        };

                        Navigator.pop(ctx);
                      },
                style: ElevatedButton.styleFrom(backgroundColor: Colors.blue),
                child: const Text('Send to client', style: TextStyle(color: Colors.white)),
              ),
            ],
          );
        },
      ),
    );

    if (payload == null) return;
    final note = (payload!['note'] ?? '').toString();
    final total = (payload!['total'] as num).toDouble();
    final laborHours = (payload!['labor_hours'] as num).toDouble();
    final laborRate = (payload!['labor_rate'] as num).toDouble();
    final items = (payload!['items'] as List).cast<Map<String, dynamic>>();
    final materialsTotal = (payload!['materials_total'] as num).toDouble();
    final laborTotal = (payload!['labor_total'] as num).toDouble();

    // Build profit analysis matching the client app schema
    final outsourcedRate = laborRate * 0.7;
    final materialBaseCost = materialsTotal / 1.5;
    final profitAnalysisAdmin = {
      'labor_costs': {
        'hours': laborHours,
        'client_rate': laborRate,
        'outsourced_rate': outsourcedRate,
        'client_total': laborTotal,
        'outsourced_total': laborHours * outsourcedRate,
        'company_profit': (payload!['company_labor_profit'] as num).toDouble(),
      },
      'material_costs': {
        'base_cost': materialBaseCost,
        'multiplier': 1.5,
        'markup_total': materialsTotal,
        'total_profit': materialsTotal - materialBaseCost,
        'company_profit': (payload!['company_material_profit'] as num).toDouble(),
        'artisan_profit': (payload!['artisan_total_profit'] as num).toDouble(),
      },
      'other_costs': {
        'equipment': 0.0,
        'contingency': (payload!['contingency'] as num).toDouble(),
        'company_profit': (payload!['contingency'] as num).toDouble(),
      },
      'totals': {
        'grand_total': total,
        'company_expected_profit': (payload!['company_total_profit'] as num).toDouble(),
        'artisan_expected_profit': (payload!['artisan_total_profit'] as num).toDouble(),
      },
    };

    final profitAnalysisArtisan = {
      'labor_costs': {
        'hours': laborHours,
        'rate': outsourcedRate,
        'total': laborHours * outsourcedRate,
      },
      'material_costs': {
        'base_cost': materialBaseCost,
        'your_profit': (payload!['artisan_total_profit'] as num).toDouble(),
      },
      'other_costs': {'equipment': 0.0},
      'totals': {
        'your_expected_profit': (payload!['artisan_total_profit'] as num).toDouble(),
      },
    };

    final adminQuote = {
      'items': items,
      'labor_hours': laborHours,
      'labor_rate': laborRate,
      'labor_total': laborTotal,
      'materials_total': materialsTotal,
      'total': total,
      'notes': note,
      'updated_at': FieldValue.serverTimestamp(),
    };

    setState(() => isLoading = true);
    try {
      // Ensure all identity fields are present so the client's booking query
      // finds this document regardless of which field variant it uses.
      final clientId = (widget.bookingData['user_id'] ??
              widget.bookingData['client_id'] ??
              '')
          .toString()
          .trim();
      final clientIdCamel = (widget.bookingData['userId'] ?? clientId)
          .toString()
          .trim();
      final clientUid = (widget.bookingData['uid'] ?? clientId)
          .toString()
          .trim();

      await _writeRfqPatch({
        // Client needs to explicitly respond before assignment.
        'rfq_status': 'pending_client_response',
        'status': 'rfq_sent',
        'rfq_submitted_to': 'client',
        'rfq_admin_amended_at': DateTime.now().toString(),
        // Compatibility across client/admin screens.
        'admin_amendment_notes': note,
        'rfq_admin_amend_note': note,
        'admin_quote': adminQuote,
        'admin_quote_total': total,
        'rfq_total': total,
        // Profitability analysis
        'profit_analysis_admin': profitAnalysisAdmin,
        'profit_analysis_artisan': profitAnalysisArtisan,
        'updated_at': DateTime.now().toString(),
        // Ensure identity + RFQ flags are present for client query compatibility
        if (clientId.isNotEmpty) 'user_id': clientId,
        if (clientIdCamel.isNotEmpty) 'userId': clientIdCamel,
        if (clientUid.isNotEmpty) 'uid': clientUid,
        if (clientId.isNotEmpty) 'client_id': clientId,
        'is_rfq': 'yes',
        'order_type': 'rfq',
      });

      if (clientId.isNotEmpty) {
        await AdminNotificationService.sendNotificationToUser(
          userId: clientId,
          title: 'RFQ Updated',
          message: note.isEmpty
              ? 'Your quote has been updated. Please review and accept/reject in the app.'
              : 'Your quote has been updated: $note',
          bookingId: widget.bookingId,
          type: 'rfq_amended',
        );
      }

      if (mounted) {
        Get.snackbar('Success', 'Amended RFQ sent to client',
            backgroundColor: Colors.green, colorText: Colors.white);
      }
    } catch (e) {
      Get.snackbar('Error', 'Failed to send amendment: $e',
          backgroundColor: Colors.red, colorText: Colors.white);
    } finally {
      setState(() => isLoading = false);
    }
  }

  Future<void> _assignToArtisan() async {
    // Show dialog to choose: broadcast to all or select specific artisan
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Assign RFQ',
            style: GoogleFonts.roboto(fontWeight: FontWeight.bold)),
        content:
            Text('Choose how to assign this RFQ:', style: GoogleFonts.roboto()),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, 'broadcast'),
            child: const Text('Broadcast to All Artisans'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, 'select'),
            style: ElevatedButton.styleFrom(backgroundColor: _square15Gold),
            child: const Text('Select Specific Artisan'),
          ),
        ],
      ),
    );

    if (choice == null) return;

    if (choice == 'broadcast') {
      await _broadcastToArtisans();
    } else {
      await _selectAndAssignArtisan();
    }
  }

  // ──────────────────────────────────────────────────────────────────────
  //  Creates a tasksManagement bridge record so the artisan sees this
  //  booking in their "Requests" screen.  The artisan app queries
  //  `tasksManagement` by `service_provider_id`.
  // ──────────────────────────────────────────────────────────────────────
  Future<void> _createTasksManagementBridge({required String artisanId}) async {
    // Read fresh data from Firestore to avoid stale cost/total values
    Map<String, dynamic> data;
    try {
      final freshDoc = await _rfqPrimary.doc(widget.bookingId).get();
      data = <String, dynamic>{
        ...widget.bookingData,
        if (freshDoc.exists && freshDoc.data() != null) ...freshDoc.data()!,
      };
    } catch (_) {
      data = widget.bookingData;
    }

    // Check if a bridge record already exists for this artisan + booking
    final existing = await FirebaseFirestore.instance
        .collection('tasksManagement')
        .where('future_booking_id', isEqualTo: widget.bookingId)
        .where('service_provider_id', isEqualTo: artisanId)
        .limit(1)
        .get();

    if (existing.docs.isNotEmpty) {
      debugPrint(
          '[bridge] tasksManagement already exists for artisan=$artisanId booking=${widget.bookingId}');
      return; // Don't create duplicate
    }

    final now = DateTime.now();
    final docRef =
        FirebaseFirestore.instance.collection('tasksManagement').doc();

    final bridgeData = <String, dynamic>{
      'service_provider_id': artisanId,
      'user_id': data['user_id'] ?? '',
      'source': 'future_booking',
      'future_booking_id': widget.bookingId,
      'order_no': data['order_no'] ?? '',
      'status': 'pending',
      'accept': '',
      'artisan_confirmed': 'pending',
      'cost': _resolveCost(data),
      'description': data['description'] ?? data['address'] ?? '',
      'task_id': data['task_id'] ?? data['category_id'] ?? '',
      'task_name': data['task_name'] ?? data['category'] ?? '',
      'category_id': data['category_id'] ?? '',
      'category': data['category'] ?? '',
      'scheduled_date': data['scheduled_date'] ?? data['date'] ?? '',
      'scheduled_time': data['scheduled_time'] ?? data['time'] ?? '',
      'address': data['address'] ?? '',
      'latitude': data['latitude'] ?? '',
      'longitude': data['longitude'] ?? '',
      'user_name': data['user_name'] ?? data['name'] ?? '',
      'user_phone': data['user_phone'] ?? data['phone'] ?? '',
      'creation_date': now.toString(),
      'creationDate': now,
      'timestamp': FieldValue.serverTimestamp(),
    };

    await docRef.set(bridgeData);
    debugPrint(
        '[bridge] Created tasksManagement ${docRef.id} for artisan=$artisanId booking=${widget.bookingId}');
  }

  Future<void> _broadcastToArtisans() async {
    setState(() => isLoading = true);
    try {
      await _writeRfqPatch({
        'rfq_status': 'pending_artisan_acceptance',
        'rfq_submitted_to': 'artisan',
        'rfq_admin_reviewed_at': DateTime.now().toString(),
        'rfq_broadcast': true,
      });

      // Notify client that RFQ has been sent to artisans
      final clientId = widget.bookingData['user_id']?.toString();
      if (clientId != null && clientId.isNotEmpty) {
        await AdminNotificationService.sendNotificationToUser(
          userId: clientId,
          title: 'RFQ Broadcast to Artisans',
          message:
              'Your quote request has been broadcast to all available artisans. You will be notified when an artisan accepts.',
          bookingId: widget.bookingId,
          type: 'rfq_broadcast',
        );
      }

      // ── Notify category-matched active artisans AND create bridge records ──
      final rfqCategory = (widget.bookingData['category_name'] ?? '').toString().toLowerCase().trim();
      // Resolve parent category (e.g. "bathroom" → "plumbing")
      final parentCategory = await _resolveParentCategory(rfqCategory);
      debugPrint('[broadcast] RFQ category: "$rfqCategory" → parent: "$parentCategory"');

      final artisansSnap = await FirebaseFirestore.instance
          .collection('serviceProvider')
          .where('active', isEqualTo: 'y')
          .get();

      // Also try artisans with active == 'yes'
      final artisansSnap2 = await FirebaseFirestore.instance
          .collection('serviceProvider')
          .where('active', isEqualTo: 'yes')
          .get();
      final allArtisanDocs = <String, QueryDocumentSnapshot>{};
      for (final d in artisansSnap.docs) {
        allArtisanDocs[d.id] = d;
      }
      for (final d in artisansSnap2.docs) {
        allArtisanDocs[d.id] = d;
      }

      // Filter to only artisans whose category matches (check parent + sub)
      if (rfqCategory.isNotEmpty || parentCategory.isNotEmpty) {
        allArtisanDocs.removeWhere((id, doc) {
          final data = doc.data() as Map<String, dynamic>? ?? {};
          final match = _artisanMatchesCategory(data, rfqCategory, parentCategory);
          if (!match) {
            debugPrint('[broadcast] Skipping artisan $id (no match for "$parentCategory" / "$rfqCategory")');
          }
          return !match;
        });
        debugPrint('[broadcast] ${allArtisanDocs.length} artisans match category "$parentCategory"');
      }

      int notified = 0;
      for (final artisanDoc in allArtisanDocs.values) {
        try {
          // Create a tasksManagement bridge record so the artisan sees
          // this request in their Requests screen.
          await _createTasksManagementBridge(artisanId: artisanDoc.id);

          await AdminNotificationService.sendNotificationToArtisan(
            artisanId: artisanDoc.id,
            title: 'New Job Available',
            message:
                'A new quote request is available for acceptance. Open the app to review and respond.',
            bookingId: widget.bookingId,
            type: 'rfq_broadcast',
          );
          notified++;
        } catch (e) {
          debugPrint('[broadcast] artisan ${artisanDoc.id} error: $e');
        }
      }

      if (mounted) {
        Get.back();
        Get.snackbar(
          'Success',
          'RFQ broadcast to $notified artisan${notified == 1 ? '' : 's'}',
          backgroundColor: Colors.green,
          colorText: Colors.white,
        );
      }
    } catch (e) {
      Get.snackbar('Error', 'Failed to assign: $e',
          backgroundColor: Colors.red, colorText: Colors.white);
    } finally {
      setState(() => isLoading = false);
    }
  }

  /// Reassign / Re-broadcast an RFQ when no artisan accepted or artisan rejected.
  Future<void> _reassignToArtisan() async {
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Reassign RFQ',
            style: GoogleFonts.roboto(fontWeight: FontWeight.bold)),
        content: Text(
          'No artisan has accepted this job yet. Choose how to reassign:',
          style: GoogleFonts.roboto(),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton.icon(
            onPressed: () => Navigator.pop(ctx, 'broadcast'),
            icon: const Icon(Icons.campaign, size: 18),
            label: const Text('Re-broadcast to All'),
          ),
          ElevatedButton.icon(
            onPressed: () => Navigator.pop(ctx, 'select'),
            icon: const Icon(Icons.person_search, size: 18),
            label: const Text('Select Specific'),
            style: ElevatedButton.styleFrom(backgroundColor: _square15Gold),
          ),
        ],
      ),
    );
    if (choice == null) return;

    if (choice == 'broadcast') {
      // Reset status and re-broadcast
      await _writeRfqPatch({
        'rfq_status': 'pending_artisan_acceptance',
        'rfq_broadcast': true,
        'rfq_assigned_artisan_id': FieldValue.delete(),
        'rfq_assigned_artisan_name': FieldValue.delete(),
        'rfq_reassigned_at': DateTime.now().toString(),
      });
      await _broadcastToArtisans();
    } else {
      // Reset status and let admin pick a specific artisan
      await _writeRfqPatch({
        'rfq_status': 'pending_artisan_acceptance',
        'rfq_broadcast': false,
        'rfq_assigned_artisan_id': FieldValue.delete(),
        'rfq_assigned_artisan_name': FieldValue.delete(),
        'rfq_reassigned_at': DateTime.now().toString(),
      });
      await _selectAndAssignArtisan();
    }
  }

  Future<void> _selectAndAssignArtisan() async {
    // Fetch available artisans filtered by RFQ category
    setState(() => isLoading = true);
    try {
      final rfqCategory = (widget.bookingData['category_name'] ?? '').toString().toLowerCase().trim();
      // Resolve parent category (e.g. "bathroom" → "plumbing")
      final parentCategory = await _resolveParentCategory(rfqCategory);
      debugPrint('[assign] RFQ category: "$rfqCategory" → parent: "$parentCategory"');

      final artisansSnapshot = await FirebaseFirestore.instance
          .collection('serviceProvider')
          .where('active', isEqualTo: 'y')
          .get();

      // Also include artisans with active == 'yes'
      final artisansSnapshot2 = await FirebaseFirestore.instance
          .collection('serviceProvider')
          .where('active', isEqualTo: 'yes')
          .get();

      final allDocs = <String, QueryDocumentSnapshot>{};
      for (final d in artisansSnapshot.docs) {
        allDocs[d.id] = d;
      }
      for (final d in artisansSnapshot2.docs) {
        allDocs[d.id] = d;
      }

      // Filter to category-matching artisans (check parent AND subcategory)
      final matchedDocs = allDocs.values.where((doc) {
        if (rfqCategory.isEmpty && parentCategory.isEmpty) return true;
        final data = doc.data() as Map<String, dynamic>? ?? {};
        return _artisanMatchesCategory(data, rfqCategory, parentCategory);
      }).toList();

      setState(() => isLoading = false);

      if (matchedDocs.isEmpty) {
        Get.snackbar('No Artisans', 'No active artisans found for category "$parentCategory"',
            backgroundColor: Colors.orange, colorText: Colors.white);
        return;
      }

      final artisans = matchedDocs.map((doc) {
        final data = doc.data() as Map<String, dynamic>? ?? {};
        return {
          'id': doc.id,
          'name': data['name'] ?? 'Unknown',
          'email': data['email'] ?? '',
          'phone': data['contact'] ?? data['phone'] ?? '',
          'category': data['mainCategory'] ?? '',
        };
      }).toList();

      // Show artisan picker dialog
      final selectedArtisan = await showDialog<Map<String, dynamic>>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text('Select Artisan',
              style: GoogleFonts.roboto(fontWeight: FontWeight.bold)),
          content: SizedBox(
            width: double.maxFinite,
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: artisans.length,
              itemBuilder: (context, index) {
                final artisan = artisans[index];
                return ListTile(
                  leading: CircleAvatar(
                    backgroundColor: _square15Gold,
                    child: Text(
                      (artisan['name'] as String).substring(0, 1).toUpperCase(),
                      style: const TextStyle(color: Colors.black),
                    ),
                  ),
                  title: Text(artisan['name'] as String),
                  subtitle: Text('${artisan['category']}\n${artisan['phone']}\n${artisan['email']}'),
                  isThreeLine: true,
                  onTap: () => Navigator.pop(ctx, artisan),
                );
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
          ],
        ),
      );

      if (selectedArtisan == null) return;

      // Assign to selected artisan
      setState(() => isLoading = true);
      await _writeRfqPatch({
        'rfq_status': 'pending_artisan_acceptance',
        'rfq_submitted_to': 'artisan',
        'rfq_admin_reviewed_at': DateTime.now().toString(),
        'rfq_assigned_artisan_id': selectedArtisan['id'],
        'rfq_assigned_artisan_name': selectedArtisan['name'],
        'rfq_broadcast': false,
        'service_provider_id': selectedArtisan['id'],
      });

      // ── Create tasksManagement bridge record ──
      await _createTasksManagementBridge(
          artisanId: selectedArtisan['id'] as String);

      // Notify client that RFQ has been assigned
      final clientId = widget.bookingData['user_id']?.toString();
      if (clientId != null && clientId.isNotEmpty) {
        await AdminNotificationService.sendNotificationToUser(
          userId: clientId,
          title: 'RFQ Assigned to Artisan',
          message:
              'Your quote request has been assigned to ${selectedArtisan['name']}. You will be notified when they respond.',
          bookingId: widget.bookingId,
          type: 'rfq_assigned',
        );
      }

      // Notify the selected artisan
      await AdminNotificationService.sendNotificationToArtisan(
        artisanId: selectedArtisan['id'] as String,
        title: 'New RFQ Assignment',
        message:
            'You have been assigned a new quote request. Please review and respond.',
        bookingId: widget.bookingId,
        type: 'rfq_assignment',
      );

      if (mounted) {
        Get.back();
        Get.snackbar('Success', 'RFQ assigned to ${selectedArtisan['name']}',
            backgroundColor: Colors.green, colorText: Colors.white);
      }
    } catch (e) {
      Get.snackbar('Error', 'Failed to assign: $e',
          backgroundColor: Colors.red, colorText: Colors.white);
    } finally {
      setState(() => isLoading = false);
    }
  }

  Future<void> _assignInternally() async {
    setState(() => isLoading = true);
    try {
      await _writeRfqPatch({
        'rfq_status': 'accepted_converted',
        'status': 'confirmed',
        'rfq_assigned_type': 'internal',
        'rfq_admin_reviewed_at': DateTime.now().toString(),
        'requires_scheduling': true,
      });

      // Notify client that RFQ has been accepted internally
      final clientId = widget.bookingData['user_id']?.toString();
      if (clientId != null && clientId.isNotEmpty) {
        await AdminNotificationService.sendNotificationToUser(
          userId: clientId,
          title: 'RFQ Accepted',
          message:
              'Your quote request has been accepted by our internal team. Your booking is now confirmed and will be scheduled soon.',
          bookingId: widget.bookingId,
          type: 'rfq_internal_assignment',
        );
      }

      Get.back();
      Get.snackbar(
          'Success', 'RFQ assigned internally and converted to Future Booking',
          backgroundColor: Colors.green, colorText: Colors.white);
    } catch (e) {
      Get.snackbar('Error', 'Failed to assign: $e',
          backgroundColor: Colors.red, colorText: Colors.white);
    } finally {
      setState(() => isLoading = false);
    }
  }

  Future<void> _closeRFQ() async {
    final confirmed = await Get.dialog<bool>(
      AlertDialog(
        title: const Text('Close RFQ'),
        content: const Text(
            'Are you sure you want to close this RFQ? This action cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Get.back(result: false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Get.back(result: true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Close RFQ'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    setState(() => isLoading = true);
    try {
      await _writeRfqPatch({
        'rfq_status': 'closed',
        'status': 'cancelled',
        'rfq_closed_at': DateTime.now().toString(),
        'rfq_closed_by': 'admin',
      });

      Get.back();
      Get.snackbar('Success', 'RFQ closed',
          backgroundColor: Colors.orange, colorText: Colors.white);
    } catch (e) {
      Get.snackbar('Error', 'Failed to close: $e',
          backgroundColor: Colors.red, colorText: Colors.white);
    } finally {
      setState(() => isLoading = false);
    }
  }
}
