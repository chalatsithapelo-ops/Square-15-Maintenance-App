import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';
import 'package:maintenanceapp/controller/app_controller.dart';
import 'package:maintenanceapp/model/future_booking_model.dart';
import 'package:maintenanceapp/model/task_management_model.dart';
import 'package:maintenanceapp/screens/home/payment_method_view.dart';
import 'package:maintenanceapp/services/future_booking_service.dart';

class FutureBookingsListScreen extends StatelessWidget {
  const FutureBookingsListScreen({super.key});

  static const String _statusApprovedWaitingAssignment =
      'approved_waiting_artisan_assignment';

  @override
  Widget build(BuildContext context) {
    final AppController appController = Get.find();
    const allowedStatuses = <String>{
      'pending',
      'confirmed',
      'rfq_pending',
      'rfq_sent',
      'rfq_approved',
      'rfq_rejected',
      _statusApprovedWaitingAssignment,
    };

    // Important: Keep this query simple to avoid Firestore composite-index errors
    // that otherwise surface as a Stream error and (without hasError handling)
    // look like "loading forever".
    return StreamBuilder<QuerySnapshot>(
      stream: FutureBookingService.futureBookingsRef
          .where('user_id', isEqualTo: appController.userId.value)
          .snapshots(),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                'Error loading bookings: ${snapshot.error}\n\n'
                'If this mentions an index, open the Firebase console link in the error to create it. '
                'If it mentions PERMISSION_DENIED, ensure this account can read futureBookings.',
                textAlign: TextAlign.center,
                style: GoogleFonts.roboto(fontSize: 13, color: Colors.red.shade900),
              ),
            ),
          );
        }

        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }

        final allDocs = snapshot.data?.docs ?? const <QueryDocumentSnapshot>[];
        if (allDocs.isEmpty) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.event_busy, size: 80, color: Colors.grey.shade400),
                const SizedBox(height: 20),
                Text(
                  'No future bookings',
                  style: GoogleFonts.roboto(fontSize: 18, color: Colors.grey.shade600),
                ),
                const SizedBox(height: 10),
                Text(
                  'Schedule a service for a future date',
                  style: GoogleFonts.roboto(fontSize: 14, color: Colors.grey.shade500),
                ),
              ],
            ),
          );
        }

        final docs = allDocs.where((d) {
          final data = (d.data() as Map<String, dynamic>?) ?? <String, dynamic>{};
          final status = (data['status'] ?? '').toString().toLowerCase();
          return allowedStatuses.contains(status);
        }).toList(growable: false);

        if (docs.isEmpty) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.event_busy, size: 80, color: Colors.grey.shade400),
                const SizedBox(height: 20),
                Text(
                  'No future bookings',
                  style:
                      GoogleFonts.roboto(fontSize: 18, color: Colors.grey.shade600),
                ),
                const SizedBox(height: 10),
                Text(
                  'Schedule a service for a future date',
                  style:
                      GoogleFonts.roboto(fontSize: 14, color: Colors.grey.shade500),
                ),
              ],
            ),
          );
        }

        DateTime? tryParseScheduledDateTime(Map<String, dynamic> data) {
          final date = (data['scheduled_date'] ?? '').toString().trim();
          final time = (data['scheduled_time'] ?? '').toString().trim();
          if (date.isEmpty || time.isEmpty) return null;
          try {
            return DateTime.parse('$date $time');
          } catch (_) {
            return null;
          }
        }

        docs.sort((a, b) {
          final aData = (a.data() as Map<String, dynamic>?) ?? <String, dynamic>{};
          final bData = (b.data() as Map<String, dynamic>?) ?? <String, dynamic>{};
          final aDt = tryParseScheduledDateTime(aData);
          final bDt = tryParseScheduledDateTime(bData);
          if (aDt == null && bDt == null) return 0;
          if (aDt == null) return 1;
          if (bDt == null) return -1;
          return aDt.compareTo(bDt);
        });

        return ListView.builder(
          physics: const BouncingScrollPhysics(),
          itemCount: docs.length,
          padding: const EdgeInsets.all(10),
          itemBuilder: (context, index) {
            final doc = docs[index];
            final data = (doc.data() as Map<String, dynamic>?) ?? <String, dynamic>{};
            final status = (data['status'] ?? '').toString().toLowerCase();
            final orderType = (data['order_type'] ?? '').toString().toLowerCase();
            final isRfqFlag =
                (data['is_rfq'] ?? '').toString().toLowerCase() == 'yes';
            final isRfq =
                isRfqFlag || orderType == 'rfq' || status.startsWith('rfq_');

            final paymentStatus = (data['payment_status'] ?? '').toString().trim().toLowerCase();
            final tasksManagementId = (data['tasks_management_id'] ?? '').toString().trim();
            final walletDeductedRaw = data['wallet_deducted'];
            final walletDeducted = walletDeductedRaw is bool
              ? (walletDeductedRaw ? 'yes' : 'no')
              : (walletDeductedRaw ?? '').toString().trim().toLowerCase();
            final walletDeductStatus = (data['wallet_deduct_status'] ?? '').toString().trim().toLowerCase();

            FutureBookingModel booking;
            try {
              booking = FutureBookingModel.fromDocument(data);
            } catch (_) {
              booking = FutureBookingModel(
                id: data['id']?.toString(),
                userId: data['user_id']?.toString(),
                scheduledDate: data['scheduled_date']?.toString(),
                scheduledTime: data['scheduled_time']?.toString(),
                taskName: data['task_name']?.toString(),
                cost: data['cost']?.toString(),
                status: data['status']?.toString(),
              );
            }

            final adminQuote = (data['admin_quote'] as Map<String, dynamic>?) ??
                <String, dynamic>{};
            final quoteItems = (adminQuote['items'] as List?)?.cast<dynamic>() ??
                const <dynamic>[];
            final adminTotalDynamic = data['admin_quote_total'];
            final adminTotal = adminTotalDynamic is num
                ? adminTotalDynamic.toDouble()
                : double.tryParse(adminTotalDynamic?.toString() ?? '');

            final scheduledDateTime = tryParseScheduledDateTime(data);
            final timeUntil = scheduledDateTime?.difference(DateTime.now());

            final bool showPayToConfirm =
              !isRfq &&
              status == 'confirmed' &&
              (booking.artisanConfirmed ?? '').toLowerCase() == 'yes' &&
              paymentStatus != 'paid' &&
              tasksManagementId.isNotEmpty &&
              walletDeducted != 'yes' &&
              (walletDeductStatus.isEmpty || walletDeductStatus != 'deducted');
            
            return Container(
              margin: const EdgeInsets.symmetric(vertical: 8),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                color: Colors.white,
                boxShadow: [
                  BoxShadow(
                    color: Colors.grey.shade300,
                    offset: const Offset(1, 1),
                    spreadRadius: 0.3,
                  ),
                  BoxShadow(
                    color: Colors.grey.shade300,
                    offset: const Offset(-1, -1),
                    spreadRadius: 0.3,
                  ),
                ],
              ),
              child: Padding(
                padding: const EdgeInsets.all(15),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: const Color(0xFFc5a520).withOpacity(0.1),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: const Icon(Icons.calendar_today, color: Color(0xFFc5a520), size: 24),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                scheduledDateTime != null
                                    ? DateFormat('EEEE, MMM dd, yyyy').format(scheduledDateTime)
                                    : 'Date not set',
                                style: GoogleFonts.roboto(fontSize: 16, fontWeight: FontWeight.bold),
                              ),
                              Text(
                                scheduledDateTime != null
                                    ? DateFormat('hh:mm a').format(scheduledDateTime)
                                    : (booking.scheduledTime ?? 'Time not set'),
                                style: GoogleFonts.roboto(fontSize: 14, color: Colors.grey.shade600),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 15),
                    
                    // Service Name
                    Row(
                      children: [
                        Icon(Icons.build, size: 18, color: Colors.grey.shade600),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            booking.taskName ?? booking.categoryName ?? 'Service',
                            style: GoogleFonts.roboto(fontSize: 14, fontWeight: FontWeight.w600),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),

                    // Cost
                    Row(
                      children: [
                        Icon(Icons.attach_money, size: 18, color: Colors.grey.shade600),
                        const SizedBox(width: 8),
                        Text(
                          'Cost: R${booking.cost}',
                          style: GoogleFonts.roboto(fontSize: 14, color: Colors.black87),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),

                    // Status
                    Row(
                      children: [
                        Icon(Icons.info_outline, size: 18, color: Colors.grey.shade600),
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                        color: isRfq
                          ? (status == 'rfq_sent'
                            ? Colors.blue.shade100
                            : status == 'rfq_approved'
                              ? Colors.green.shade100
                              : status == 'rfq_rejected'
                                ? Colors.red.shade100
                                : Colors.amber.shade100)
                          : (status == _statusApprovedWaitingAssignment
                            ? Colors.green.shade100
                            : (booking.artisanConfirmed == 'yes'
                              ? Colors.green.shade100
                              : Colors.amber.shade100)),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                          color: isRfq
                            ? (status == 'rfq_sent'
                              ? Colors.blue.shade900
                              : status == 'rfq_approved'
                                ? Colors.green.shade900
                                : status == 'rfq_rejected'
                                  ? Colors.red.shade900
                                  : Colors.amber.shade900)
                            : (status == _statusApprovedWaitingAssignment
                              ? Colors.green.shade900
                              : (booking.artisanConfirmed == 'yes'
                                ? Colors.green.shade900
                                : Colors.amber.shade900)),
                            ),
                          ),
                          child: Text(
                        isRfq
                          ? (status == 'rfq_pending'
                            ? 'Awaiting Admin Quote'
                            : status == 'rfq_sent'
                              ? 'Quote Ready (Action Required)'
                              : status == 'rfq_approved'
                                ? 'Approved waiting for artisan assignment'
                                : status == 'rfq_rejected'
                                  ? 'Rejected'
                                  : status)
                          : (status == _statusApprovedWaitingAssignment
                            ? 'Approved waiting for artisan assignment'
                            : (booking.artisanConfirmed == 'yes'
                              ? 'Confirmed'
                              : 'Awaiting Artisan Confirmation')),
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                          color: isRfq
                            ? (status == 'rfq_sent'
                              ? Colors.blue.shade900
                              : status == 'rfq_approved'
                                ? Colors.green.shade900
                                : status == 'rfq_rejected'
                                  ? Colors.red.shade900
                                  : Colors.amber.shade900)
                            : (status == _statusApprovedWaitingAssignment
                              ? Colors.green.shade900
                              : (booking.artisanConfirmed == 'yes'
                                ? Colors.green.shade900
                                : Colors.amber.shade900)),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),

                    // Time Until
                    if (timeUntil != null && timeUntil.isNegative == false) ...[
                      Row(
                        children: [
                          Icon(Icons.schedule, size: 18, color: Colors.grey.shade600),
                          const SizedBox(width: 8),
                          Text(
                            timeUntil.inDays > 0
                                ? 'In ${timeUntil.inDays} day${timeUntil.inDays > 1 ? 's' : ''}'
                                : timeUntil.inHours > 0
                                    ? 'In ${timeUntil.inHours} hour${timeUntil.inHours > 1 ? 's' : ''}'
                                    : 'Soon',
                            style: GoogleFonts.roboto(fontSize: 14, color: const Color(0xFFc5a520), fontWeight: FontWeight.w600),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                    ],

                    // Description
                    if (booking.description != null && booking.description!.isNotEmpty) ...[
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(Icons.notes, size: 18, color: Colors.grey.shade600),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'Notes: ${booking.description}',
                              style: GoogleFonts.roboto(fontSize: 13, color: Colors.grey.shade700, fontStyle: FontStyle.italic),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                    ],

                    // Service Location
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(Icons.location_on, size: 18, color: Colors.grey.shade600),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            booking.isServiceOnCurrentLocation == 'yes'
                                ? 'Location: Your current location'
                                : 'Location: ${booking.userProvidedAddress ?? "Address not provided"}',
                            style: GoogleFonts.roboto(fontSize: 13, color: Colors.black87),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),

                    // Reassignment notice
                    if ((int.tryParse(booking.reassignedCount ?? '') ?? 0) > 0) ...[
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: Colors.orange.shade50,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: Colors.orange.shade300),
                        ),
                        child: Row(
                          children: [
                            Icon(Icons.info, size: 16, color: Colors.orange.shade700),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                'This booking has been reassigned to another artisan',
                                style: GoogleFonts.roboto(fontSize: 12, color: Colors.orange.shade900),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 10),
                    ],

                    // Action Buttons
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        TextButton.icon(
                          onPressed: () => _cancelBooking(context, booking),
                          icon: const Icon(Icons.cancel, size: 18),
                          label: const Text('Cancel'),
                          style: TextButton.styleFrom(
                            foregroundColor: Colors.red,
                          ),
                        ),
                        const SizedBox(width: 10),
                        if (isRfq && status == 'rfq_sent') ...[
                          TextButton.icon(
                            onPressed: () => _showQuoteDialog(
                              context: context,
                              adminQuote: adminQuote,
                              adminTotal: adminTotal,
                            ),
                            icon: const Icon(Icons.receipt_long, size: 18),
                            label: const Text('View Quote'),
                          ),
                          const SizedBox(width: 10),
                          ElevatedButton.icon(
                            onPressed: () => _approveQuote(
                              context: context,
                              bookingId: doc.id,
                            ),
                            icon: const Icon(Icons.check_circle, size: 18),
                            label: const Text('Approve'),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.green,
                              foregroundColor: Colors.white,
                            ),
                          ),
                          const SizedBox(width: 10),
                          OutlinedButton.icon(
                            onPressed: () => _rejectQuote(
                              context: context,
                              bookingId: doc.id,
                            ),
                            icon: const Icon(Icons.block, size: 18),
                            label: const Text('Reject'),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: Colors.red,
                            ),
                          ),
                        ] else if (booking.artisanConfirmed == 'yes')
                          ElevatedButton.icon(
                            onPressed: () => _confirmAvailability(context, booking),
                            icon: const Icon(Icons.check_circle, size: 18),
                            label: const Text('Confirm'),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFFc5a520),
                              foregroundColor: Colors.white,
                            ),
                          ),
                      ],
                    ),

                    if (isRfq && adminTotal != null) ...[
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Icon(Icons.payments_outlined,
                              size: 18, color: Colors.grey.shade600),
                          const SizedBox(width: 8),
                          Text(
                            'Admin Quote Total: R${adminTotal.toStringAsFixed(2)}',
                            style: GoogleFonts.roboto(
                                fontSize: 13, color: Colors.black87),
                          ),
                        ],
                      ),
                      if (quoteItems.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: TextButton(
                            onPressed: () => _showQuoteDialog(
                              context: context,
                              adminQuote: adminQuote,
                              adminTotal: adminTotal,
                            ),
                            child: const Text('View quote breakdown'),
                          ),
                        ),
                      ]
                    ],

                    if (showPayToConfirm) ...[
                      const SizedBox(height: 14),
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Colors.orange.shade50,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: Colors.orange.shade200),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                const Icon(Icons.payments_outlined, color: Colors.orange),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    'Payment required to confirm this future booking',
                                    style: GoogleFonts.roboto(fontSize: 13, fontWeight: FontWeight.w600),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 10),
                            SizedBox(
                              width: double.infinity,
                              child: ElevatedButton.icon(
                                onPressed: () => _payToConfirmFutureBooking(
                                  context: context,
                                  tasksManagementId: tasksManagementId,
                                ),
                                icon: const Icon(Icons.lock_open),
                                label: const Text('Pay to confirm order'),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: Colors.orange,
                                  foregroundColor: Colors.white,
                                ),
                              ),
                            ),
                            const SizedBox(height: 10),
                            Text(
                              'Note: Funds will be immediately refunded should the work not be done or should the artisan cancel the job without going to site.',
                              style: GoogleFonts.roboto(fontSize: 12, color: Colors.grey.shade700),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _payToConfirmFutureBooking({
    required BuildContext context,
    required String tasksManagementId,
  }) async {
    final AppController appController = Get.find();
    try {
      final tmDoc = await FutureBookingService.tasksManagementRef
          .doc(tasksManagementId)
          .get();
      final tmData = tmDoc.data() ?? <String, dynamic>{};
      if (tmData.isEmpty) {
        Get.snackbar('Error', 'Payment record not found.', backgroundColor: Colors.red, colorText: Colors.white);
        return;
      }

      final taskManagementModel = TaskManagementModel.fromDocument(tmData);
      final costRaw = (tmData['cost'] ?? '').toString().trim();
      final costNum = double.tryParse(costRaw.replaceAll(',', ''));
      if (costNum == null || costNum <= 0) {
        Get.snackbar(
          'Payment Unavailable',
          'This booking does not have a payable amount yet.',
          backgroundColor: Colors.orange,
          colorText: Colors.white,
        );
        return;
      }

      appController.isPaymentUsingPayFast.value = true;
      final url = await appController.initiatePayment(cost: costNum.toStringAsFixed(2));
      if (url.trim().isEmpty) {
        Get.snackbar('Error', 'Could not start payment. Please try again.', backgroundColor: Colors.red, colorText: Colors.white);
        return;
      }
      appController.webUrl.value = url;

      Get.to(
        () => PaymentMethodView(taskManagementModel: taskManagementModel),
        transition: Transition.fadeIn,
      );
    } catch (e) {
      debugPrint('payToConfirmFutureBooking error: $e');
      Get.snackbar('Error', 'Could not start payment.', backgroundColor: Colors.red, colorText: Colors.white);
    }
  }

  void _showQuoteDialog({
    required BuildContext context,
    required Map<String, dynamic> adminQuote,
    required double? adminTotal,
  }) {
    final items = (adminQuote['items'] as List?)?.cast<dynamic>() ??
        const <dynamic>[];
    final notes = (adminQuote['notes'] ?? '').toString();

    final materialItems = <Map<String, dynamic>>[];
    final otherItems = <Map<String, dynamic>>[];
    for (final raw in items) {
      final m = (raw as Map?)?.cast<String, dynamic>() ?? <String, dynamic>{};
      final desc = (m['description'] ?? '').toString();
      if (desc.toLowerCase().startsWith('materials:')) {
        materialItems.add(m);
      } else {
        otherItems.add(m);
      }
    }

    String fmtMoney(dynamic v) {
      final n = v is num ? v.toDouble() : double.tryParse(v?.toString() ?? '');
      return n == null ? 'TBD' : n.toStringAsFixed(2);
    }

    double? toDouble(dynamic v) {
      if (v == null) return null;
      if (v is num) return v.toDouble();
      return double.tryParse(v.toString());
    }

    double sumLineTotals(Iterable<Map<String, dynamic>> lines) {
      double sum = 0;
      for (final m in lines) {
        final lt = toDouble(m['line_total']);
        if (lt != null) {
          sum += lt;
          continue;
        }
        final qty = toDouble(m['qty']) ?? 0;
        final unit = toDouble(m['unit_price']) ?? 0;
        sum += qty * unit;
      }
      return sum;
    }

    final subtotal = toDouble(adminQuote['subtotal']) ??
        sumLineTotals([...materialItems, ...otherItems]);
    final vatPercent = toDouble(adminQuote['vat_percent']);
    final vatAmount = toDouble(adminQuote['vat_amount']);
    final total = adminTotal ?? toDouble(adminQuote['total']) ?? (subtotal + (vatAmount ?? 0));

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Quote Details'),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (materialItems.isNotEmpty) ...[
                  const Text('Materials', style: TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  ...materialItems.map((m) {
                    final desc = (m['description'] ?? '').toString().replaceFirst(RegExp('^Materials:\\s*', caseSensitive: false), '');
                    final qty = (m['qty'] ?? '').toString();
                    final uom = (m['uom'] ?? '').toString();
                    final unit = fmtMoney(m['unit_price']);
                    final line = fmtMoney(m['line_total']);
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Text('- $desc (${qty.isNotEmpty ? qty : '1'}${uom.isNotEmpty ? ' $uom' : ''})  •  R$unit  •  R$line'),
                    );
                  }),
                  const Divider(),
                ],

                if (otherItems.isNotEmpty) ...[
                  const Text('Line Items', style: TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  ...otherItems.map((m) {
                    final desc = (m['description'] ?? '').toString();
                    final qty = (m['qty'] ?? '').toString();
                    final uom = (m['uom'] ?? '').toString();
                    final unit = fmtMoney(m['unit_price']);
                    final line = fmtMoney(m['line_total']);
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Text('- $desc (${qty.isNotEmpty ? qty : '1'}${uom.isNotEmpty ? ' $uom' : ''})  •  R$unit  •  R$line'),
                    );
                  }),
                  const Divider(),
                ],

                // Totals (match admin formatting)
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('Subtotal', style: TextStyle(fontWeight: FontWeight.w600)),
                    Text('R${subtotal.toStringAsFixed(2)}'),
                  ],
                ),
                const SizedBox(height: 6),
                if (vatPercent != null || vatAmount != null)
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        vatPercent != null
                            ? 'VAT (${vatPercent.toStringAsFixed(vatPercent % 1 == 0 ? 0 : 1)}%)'
                            : 'VAT',
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      Text('R${(vatAmount ?? 0).toStringAsFixed(2)}'),
                    ],
                  ),
                const SizedBox(height: 6),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('Total', style: TextStyle(fontWeight: FontWeight.bold)),
                    Text('R${total.toStringAsFixed(2)}', style: const TextStyle(fontWeight: FontWeight.bold)),
                  ],
                ),
                if (notes.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  const Text('Notes/Terms',
                      style: TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 6),
                  Text(notes),
                ]
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Future<void> _approveQuote({
    required BuildContext context,
    required String bookingId,
  }) async {
    await FutureBookingService.futureBookingsRef.doc(bookingId).update({
      'status': _statusApprovedWaitingAssignment,
      // Move the RFQ into Bookings after client approval.
      'is_rfq': 'no',
      'order_type': 'order',
      'user_approved': 'yes',
      'user_approved_at': DateTime.now().toString(),
      'updated_at': DateTime.now().toString(),
    });

    await FutureBookingService.sendNotificationToAdmin(
      bookingId: bookingId,
      title: 'Approved waiting for artisan assignment',
      type: _statusApprovedWaitingAssignment,
      message:
          'Client approved the quote. Booking $bookingId is waiting for artisan assignment.',
    );

    if (context.mounted) {
      Get.snackbar('Success', 'Quote approved',
          backgroundColor: Colors.green, colorText: Colors.white);
    }
  }

  Future<void> _rejectQuote({
    required BuildContext context,
    required String bookingId,
  }) async {
    final controller = TextEditingController();

    final reason = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Reject Quote'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            labelText: 'Reason (optional)',
          ),
          maxLines: 3,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Reject', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );

    if (reason == null) return;

    await FutureBookingService.futureBookingsRef.doc(bookingId).update({
      'status': 'rfq_rejected',
      'user_approved': 'no',
      'user_reject_reason': reason,
      'user_rejected_at': DateTime.now().toString(),
      'updated_at': DateTime.now().toString(),
    });

    await FutureBookingService.sendNotificationToAdmin(
      bookingId: bookingId,
      title: 'RFQ Rejected',
      type: 'rfq_rejected',
      message: reason.isNotEmpty
          ? 'Client rejected the RFQ quote for booking $bookingId. Reason: $reason'
          : 'Client rejected the RFQ quote for booking $bookingId.',
    );

    if (context.mounted) {
      Get.snackbar('Done', 'Quote rejected',
          backgroundColor: Colors.red, colorText: Colors.white);
    }
  }

  void _cancelBooking(BuildContext context, FutureBookingModel booking) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Cancel Booking', style: GoogleFonts.roboto(fontWeight: FontWeight.bold)),
        content: Text('Are you sure you want to cancel this booking?', style: GoogleFonts.roboto()),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('No'),
          ),
          ElevatedButton(
            onPressed: () async {
              await FutureBookingService.futureBookingsRef.doc(booking.id).update({
                'status': 'cancelled',
                'updated_at': DateTime.now().toString(),
              });

              // Restore wallet if it was already deducted.
              await FutureBookingService.refundWalletForBooking(
                bookingId: booking.id ?? '',
                reason: 'cancelled_by_customer',
              );
              
              // Notify artisan
              if (booking.serviceProviderId != null) {
                await FutureBookingService.sendNotificationToArtisan(
                  artisanId: booking.serviceProviderId!,
                  bookingId: booking.id!,
                  message: 'Booking for ${booking.scheduledDate} has been cancelled by customer',
                );
              }
              
              Navigator.pop(context);
              Get.snackbar('Success', 'Booking cancelled', backgroundColor: Colors.green, colorText: Colors.white);
            },
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Yes, Cancel', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  void _confirmAvailability(BuildContext context, FutureBookingModel booking) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Confirm Availability', style: GoogleFonts.roboto(fontWeight: FontWeight.bold)),
        content: Text('Please confirm you will be available for this booking.', style: GoogleFonts.roboto()),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () async {
              await FutureBookingService.futureBookingsRef.doc(booking.id).update({
                'user_confirmed': 'yes',
                'updated_at': DateTime.now().toString(),
              });
              
              Navigator.pop(context);
              Get.snackbar('Success', 'Availability confirmed', backgroundColor: Colors.green, colorText: Colors.white);
            },
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFc5a520)),
            child: const Text('Confirm', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }
}
