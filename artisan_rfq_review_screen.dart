import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:maintenanceapp/controller/app_controller.dart';
import 'package:maintenanceapp/services/future_booking_service.dart';

/// Artisan RFQ Review Screen - for artisans to accept or reject RFQs
class ArtisanRFQReviewScreen extends StatefulWidget {
  final String bookingId;
  final Map<String, dynamic> bookingData;

  const ArtisanRFQReviewScreen({
    super.key,
    required this.bookingId,
    required this.bookingData,
  });

  @override
  State<ArtisanRFQReviewScreen> createState() => _ArtisanRFQReviewScreenState();
}

class _ArtisanRFQReviewScreenState extends State<ArtisanRFQReviewScreen> {
  static const Color _square15Gold = Color(0xFFD4AF37);
  final appController = Get.find<AppController>();
  
  Map<String, dynamic>? profitAnalysis;
  Map<String, dynamic>? aiQuote;
  bool isLoading = false;

  @override
  void initState() {
    super.initState();
    profitAnalysis = (widget.bookingData['profit_analysis_artisan'] as Map?)?.cast<String, dynamic>();
    aiQuote = (widget.bookingData['ai_quote'] as Map?)?.cast<String, dynamic>();
  }

  @override
  Widget build(BuildContext context) {
    final rfqTotal = ((widget.bookingData['rfq_total'] ?? 0.0) as num).toDouble();
    final categoryName = (widget.bookingData['category_name'] ?? '').toString();
    final problemDesc = (widget.bookingData['problem_description'] ?? '').toString();

    return Scaffold(
      appBar: AppBar(
        title: Text('RFQ Opportunity', style: GoogleFonts.roboto()),
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
                  _buildHeader(rfqTotal, categoryName),
                  const SizedBox(height: 16),
                  _buildProblemDescription(problemDesc),
                  const SizedBox(height: 16),
                  if (profitAnalysis != null) _buildArtisanEarnings(),
                  const SizedBox(height: 16),
                  if (aiQuote != null) _buildMaterialsList(),
                  const SizedBox(height: 24),
                  _buildActionButtons(),
                ],
              ),
            ),
    );
  }

  Widget _buildHeader(double total, String category) {
    return Card(
      color: _square15Gold.withAlpha(50),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Job Value',
              style: GoogleFonts.roboto(fontSize: 14, color: Colors.grey[700]),
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
              'Job Description',
              style: GoogleFonts.roboto(fontSize: 16, fontWeight: FontWeight.bold),
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

  Widget _buildArtisanEarnings() {
    final labor = profitAnalysis!['labor_costs'] as Map?;
    final materials = profitAnalysis!['material_costs'] as Map?;
    final other = profitAnalysis!['other_costs'] as Map?;
    final totals = profitAnalysis!['totals'] as Map?;

    return Card(
      color: Colors.green[50],
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.account_balance_wallet, color: Colors.green),
                const SizedBox(width: 8),
                Text(
                  'Your Earnings Breakdown',
                  style: GoogleFonts.roboto(fontSize: 16, fontWeight: FontWeight.bold),
                ),
              ],
            ),
            const Divider(height: 24),
            
            // Labor
            Text('Labor', style: GoogleFonts.roboto(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            _earningsLine('Hours', '${labor?['hours']?.toStringAsFixed(1) ?? "0"} hrs'),
            _earningsLine('Your Rate', 'R${labor?['rate']?.toStringAsFixed(2) ?? "0"}/hr'),
            _earningsLine('Labor Total', 'R${labor?['total']?.toStringAsFixed(2) ?? "0"}', bold: true),
            
            const Divider(height: 24),
            
            // Materials
            Text('Materials', style: GoogleFonts.roboto(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            _earningsLine('Base Material Cost', 'R${materials?['base_cost']?.toStringAsFixed(2) ?? "0"}'),
            _earningsLine('Your Profit from Materials', 'R${materials?['your_profit']?.toStringAsFixed(2) ?? "0"}',
                color: Colors.green[700]!),
            
            const Divider(height: 24),
            
            // Equipment
            Text('Equipment', style: GoogleFonts.roboto(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            _earningsLine('Equipment & Tools', 'R${other?['equipment']?.toStringAsFixed(2) ?? "0"}'),
            
            const Divider(height: 24),
            
            // Summary
            Text('Summary', style: GoogleFonts.roboto(fontWeight: FontWeight.bold, fontSize: 16)),
            const SizedBox(height: 8),
            _earningsLine('Your Expected Profit', 'R${totals?['your_expected_profit']?.toStringAsFixed(2) ?? "0"}',
                color: Colors.green[800]!, bold: true, fontSize: 16),
            _earningsLine('Your Expected Costs', 'R${totals?['your_expected_costs']?.toStringAsFixed(2) ?? "0"}'),
            _earningsLine('Your Total Earnings', 'R${totals?['your_total_earnings']?.toStringAsFixed(2) ?? "0"}',
                bold: true, fontSize: 18),
          ],
        ),
      ),
    );
  }

  Widget _earningsLine(String label, String value, {bool bold = false, Color? color, double fontSize = 14}) {
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

  Widget _buildMaterialsList() {
    final priced = (aiQuote!['materialsPriced_reference'] as List?)?.cast<Map>() ?? [];
    final unpriced = (aiQuote!['materialsUnpriced_reference'] as List?)?.cast<Map>() ?? [];

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Materials List',
              style: GoogleFonts.roboto(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            if (priced.isNotEmpty) ...[
              Text('Priced Items', style: GoogleFonts.roboto(fontWeight: FontWeight.w600)),
              ...priced.map((m) => _materialLine(m)),
            ],
            if (unpriced.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text('Unpriced Items', style: GoogleFonts.roboto(fontWeight: FontWeight.w600)),
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

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          const Icon(Icons.build_circle_outlined, size: 14, color: _square15Gold),
          const SizedBox(width: 8),
          Expanded(child: Text(name, style: GoogleFonts.roboto(fontSize: 13))),
          Text(
            '${qty.toStringAsFixed(qty % 1 == 0 ? 0 : 1)} $unit',
            style: GoogleFonts.roboto(fontSize: 12, color: Colors.grey[600]),
          ),
        ],
      ),
    );
  }

  Widget _buildActionButtons() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ElevatedButton.icon(
          onPressed: _acceptRFQ,
          icon: const Icon(Icons.check_circle),
          label: const Text('Accept This Job'),
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.green,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.all(16),
          ),
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: _rejectRFQ,
          icon: const Icon(Icons.cancel),
          label: const Text('Reject This Job'),
          style: OutlinedButton.styleFrom(
            foregroundColor: Colors.red,
            padding: const EdgeInsets.all(16),
          ),
        ),
      ],
    );
  }

  Future<void> _acceptRFQ() async {
    setState(() => isLoading = true);
    try {
      final artisanId = appController.userId.value;
      final now = DateTime.now();

      // 1. Update futureBookings → pending_payment
      await FirebaseFirestore.instance
          .collection('futureBookings')
          .doc(widget.bookingId)
          .update({
        'rfq_status': 'accepted_converted',
        'status': 'pending_payment',
        'service_provider_id': artisanId,
        'artisan_confirmed': 'yes',
        'rfq_accepted_at': now.toString(),
        'rfq_accepted_by': artisanId,
        'requires_scheduling': true,
      });

      // 2. Update the tasksManagement bridge record(s) for this artisan
      final tmSnap = await FirebaseFirestore.instance
          .collection('tasksManagement')
          .where('future_booking_id', isEqualTo: widget.bookingId)
          .where('service_provider_id', isEqualTo: artisanId)
          .limit(1)
          .get();

      if (tmSnap.docs.isNotEmpty) {
        await tmSnap.docs.first.reference.update({
          'accept': '1',
          'status': 'pending_payment',
          'artisan_confirmed': 'yes',
          'updated_at': now.toString(),
          'updated_by': artisanId,
        });
      }

      // 3. Notify the client to make payment
      final clientId =
          (widget.bookingData['user_id'] ?? '').toString().trim();
      if (clientId.isNotEmpty) {
        final artisanName = appController.userName.value.isNotEmpty
            ? appController.userName.value
            : 'Your artisan';
        final scheduledDate =
            (widget.bookingData['scheduled_date'] ?? '').toString();

        // Confirmation notification
        FutureBookingService.sendNotificationToUser(
          userId: clientId,
          title: 'Artisan Accepted Your Job',
          message:
              '$artisanName has accepted your quote request. '
              'Please complete payment so the booking can proceed.',
          type: 'future_booking_payment_required',
          data: {
            'booking_id': widget.bookingId,
            'type': 'future_booking_payment_required',
          },
        ).catchError((e) {
          debugPrint('[acceptRFQ] notify client error: $e');
        });

        // Also write a notification doc so the client sees it in-app
        try {
          await FirebaseFirestore.instance.collection('notifications').add({
            'userId': clientId,
            'title': 'Payment Required',
            'message':
                '$artisanName accepted your quote request'
                '${scheduledDate.isNotEmpty ? ' for $scheduledDate' : ''}.'
                ' Please complete payment to confirm the booking.',
            'type': 'future_booking_payment_required',
            'booking_id': widget.bookingId,
            'view': false,
            'created_at': FieldValue.serverTimestamp(),
          });
        } catch (e) {
          debugPrint('[acceptRFQ] write notification doc error: $e');
        }
      }

      if (mounted) {
        Get.back();
        Get.snackbar(
          'Success',
          'Job accepted! The client has been notified to make payment.',
          backgroundColor: Colors.green,
          colorText: Colors.white,
        );
      }
    } catch (e) {
      Get.snackbar('Error', 'Failed to accept: $e',
          backgroundColor: Colors.red, colorText: Colors.white);
    } finally {
      setState(() => isLoading = false);
    }
  }

  Future<void> _rejectRFQ() async {
    final reasonController = TextEditingController();
    
    final confirmed = await Get.dialog<bool>(
      AlertDialog(
        title: const Text('Reject Job'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Please provide a reason for rejection:'),
            const SizedBox(height: 12),
            TextField(
              controller: reasonController,
              decoration: const InputDecoration(
                hintText: 'e.g., Price too low, timeline too tight...',
                border: OutlineInputBorder(),
              ),
              maxLines: 3,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Get.back(result: false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              if (reasonController.text.trim().isEmpty) {
                Get.snackbar('Required', 'Please provide a rejection reason');
                return;
              }
              Get.back(result: true);
            },
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Reject Job'),
          ),
        ],
      ),
    );

    if (confirmed != true || reasonController.text.trim().isEmpty) return;

    setState(() => isLoading = true);
    try {
      final currentRejections = (widget.bookingData['rfq_artisan_rejections'] as List?)?.cast<Map>() ?? [];
      currentRejections.add({
        'artisan_id': appController.userId.value,
        'artisan_name': appController.userName.value,
        'reason': reasonController.text.trim(),
        'rejected_at': DateTime.now().toString(),
      });

      final rejectionCount = currentRejections.length;

      await FirebaseFirestore.instance
          .collection('futureBookings')
          .doc(widget.bookingId)
          .update({
        'rfq_artisan_rejections': currentRejections,
        'rfq_artisan_rejection_count': rejectionCount,
        // If 3 rejections, route to admin
        if (rejectionCount >= 3) ...{
          'rfq_status': 'pending_admin_review',
          'rfq_submitted_to': 'admin',
          'rfq_artisan_rejection_threshold_reached': true,
        },
      });

      Get.back();
      final message = rejectionCount >= 3
          ? 'Job rejected. This RFQ will be reviewed by admin due to multiple rejections.'
          : 'Job rejected. Thank you for your feedback.';
      Get.snackbar('Rejected', message,
          backgroundColor: Colors.orange, colorText: Colors.white);
    } catch (e) {
      Get.snackbar('Error', 'Failed to reject: $e',
          backgroundColor: Colors.red, colorText: Colors.white);
    } finally {
      setState(() => isLoading = false);
    }
  }
}
