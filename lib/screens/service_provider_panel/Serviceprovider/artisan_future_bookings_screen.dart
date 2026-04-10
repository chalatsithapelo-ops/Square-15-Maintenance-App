import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:maintenanceapp/controller/app_controller.dart';
import 'package:maintenanceapp/model/future_booking_model.dart';
import 'package:maintenanceapp/services/future_booking_service.dart';

class ArtisanFutureBookingsScreen extends StatelessWidget {
  const ArtisanFutureBookingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final AppController appController = Get.find();

    return Scaffold(
      appBar: AppBar(
        title: Text('Future Bookings',
            style: GoogleFonts.roboto(color: Colors.white)),
        backgroundColor: const Color(0xFFc5a520),
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: StreamBuilder<QuerySnapshot>(
        stream: FutureBookingService.futureBookingsRef
            .where('service_provider_id', isEqualTo: appController.userId.value)
            // Include the paid/accepted states so the artisan can see bookings
            // after the client completes payment.
            .where('status', whereIn: [
              'pending',
              'confirmed',
              'pending_payment',
              'accepted',
              'in_progress'
            ])
            .orderBy('scheduled_date', descending: false)
            .snapshots(),
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }

          if (snapshot.data!.docs.isEmpty) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.event_busy, size: 80, color: Colors.grey.shade400),
                  const SizedBox(height: 20),
                  Text(
                    'No upcoming bookings',
                    style: GoogleFonts.roboto(
                        fontSize: 18, color: Colors.grey.shade600),
                  ),
                ],
              ),
            );
          }

          return ListView.builder(
            physics: const BouncingScrollPhysics(),
            itemCount: snapshot.data!.docs.length,
            padding: const EdgeInsets.all(10),
            itemBuilder: (context, index) {
              final doc = snapshot.data!.docs[index];
              final data =
                  (doc.data() as Map<String, dynamic>?) ?? <String, dynamic>{};
              final status =
                  (data['status'] ?? '').toString().trim().toLowerCase();
              final paymentStatus = (data['payment_status'] ?? '')
                  .toString()
                  .trim()
                  .toLowerCase();
              final tasksManagementId =
                  (data['tasks_management_id'] ?? '').toString().trim();

              final depositPaid = data['deposit_paid'] == true;
              final balancePaid = data['balance_paid'] == true;
              final canStart = status != 'in_progress' &&
                  (paymentStatus == 'paid' || paymentStatus == 'deposit_paid' || depositPaid);
              final canCancel = status != 'in_progress';

              FutureBookingModel booking =
                  FutureBookingModel.fromDocument(data);
              booking.id ??= doc.id;

              final scheduledDateTime =
                  FutureBookingService.tryParseScheduledDateTimeFromDocument(
                          data) ??
                      DateTime.now();
              final timeUntil = scheduledDateTime.difference(DateTime.now());

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
                            child: const Icon(Icons.calendar_today,
                                color: Color(0xFFc5a520), size: 24),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  DateFormat('EEEE, MMM dd, yyyy')
                                      .format(scheduledDateTime),
                                  style: GoogleFonts.roboto(
                                      fontSize: 16,
                                      fontWeight: FontWeight.bold),
                                ),
                                Text(
                                  DateFormat('hh:mm a')
                                      .format(scheduledDateTime),
                                  style: GoogleFonts.roboto(
                                      fontSize: 14,
                                      color: Colors.grey.shade600),
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
                          Icon(Icons.build,
                              size: 18, color: Colors.grey.shade600),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              booking.taskName ?? 'Service',
                              style: GoogleFonts.roboto(
                                  fontSize: 14, fontWeight: FontWeight.w600),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),

                      // Cost
                      Row(
                        children: [
                          Icon(Icons.attach_money,
                              size: 18, color: Colors.grey.shade600),
                          const SizedBox(width: 8),
                          Text(
                            'Earning: R${booking.cost}',
                            style: GoogleFonts.roboto(
                                fontSize: 14, color: Colors.black87),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),

                      // Time Until
                      if (timeUntil.isNegative == false) ...[
                        Row(
                          children: [
                            Icon(Icons.schedule,
                                size: 18, color: Colors.grey.shade600),
                            const SizedBox(width: 8),
                            Text(
                              timeUntil.inDays > 0
                                  ? 'In ${timeUntil.inDays} day${timeUntil.inDays > 1 ? 's' : ''}'
                                  : timeUntil.inHours > 0
                                      ? 'In ${timeUntil.inHours} hour${timeUntil.inHours > 1 ? 's' : ''}'
                                      : 'Soon',
                              style: GoogleFonts.roboto(
                                  fontSize: 14,
                                  color: const Color(0xFFc5a520),
                                  fontWeight: FontWeight.w600),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                      ],

                      // Description
                      if (booking.description != null &&
                          booking.description!.isNotEmpty) ...[
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(Icons.notes,
                                size: 18, color: Colors.grey.shade600),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                'Client Notes: ${booking.description}',
                                style: GoogleFonts.roboto(
                                    fontSize: 13,
                                    color: Colors.grey.shade700,
                                    fontStyle: FontStyle.italic),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                      ],

                      // Service Location Address
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(Icons.location_on,
                              size: 18, color: Colors.grey.shade600),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              booking.isServiceOnCurrentLocation == 'yes'
                                  ? 'Location: Client\'s current location'
                                  : 'Location: ${(booking.userProvidedAddress?.isNotEmpty == true) ? booking.userProvidedAddress! : "Address not provided"}',
                              style: GoogleFonts.roboto(
                                  fontSize: 13,
                                  color: Colors.black87,
                                  fontWeight: FontWeight.w500),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),

                      // Status badge
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color: (paymentStatus == 'paid' || balancePaid)
                              ? Colors.green.shade100
                              : (paymentStatus == 'deposit_paid' || depositPaid)
                                  ? Colors.blue.shade100
                                  : booking.artisanConfirmed == 'yes'
                                      ? Colors.orange.shade100
                                      : Colors.amber.shade100,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: (paymentStatus == 'paid' || balancePaid)
                                ? Colors.green.shade900
                                : (paymentStatus == 'deposit_paid' || depositPaid)
                                    ? Colors.blue.shade900
                                    : booking.artisanConfirmed == 'yes'
                                        ? Colors.orange.shade900
                                        : Colors.amber.shade900,
                          ),
                        ),
                        child: Text(
                          (status == 'in_progress' || status == 'progress')
                              ? 'In Progress'
                              : (paymentStatus == 'paid' || balancePaid)
                                  ? 'Fully Paid \u2705'
                                  : (paymentStatus == 'deposit_paid' || depositPaid)
                                      ? () {
                                          final bal = double.tryParse((data['balance_amount'] ?? '').toString()) ??
                                              ((double.tryParse(booking.cost ?? '0') ?? 0) * 0.65);
                                          return bal > 0
                                              ? 'Deposit Paid \u2705 (Balance: R${bal.toStringAsFixed(0)})'
                                              : 'Deposit Paid \u2705 (Balance due after job)';
                                        }()
                                      : (status == 'accepted'
                                          ? 'Accepted & Paid'
                                          : (booking.artisanConfirmed == 'yes'
                                              ? 'Awaiting Client Payment'
                                              : 'Awaiting Your Confirmation')),
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: (paymentStatus == 'paid' || balancePaid)
                                ? Colors.green.shade900
                                : (paymentStatus == 'deposit_paid' || depositPaid)
                                    ? Colors.blue.shade900
                                    : booking.artisanConfirmed == 'yes'
                                        ? Colors.orange.shade900
                                        : Colors.amber.shade900,
                          ),
                        ),
                      ),
                      const SizedBox(height: 15),

                      if (booking.artisanConfirmed == 'yes') ...[
                        Row(
                          children: [
                            Expanded(
                              child: ElevatedButton.icon(
                                onPressed: canStart
                                    ? () async {
                                        final ok = await showDialog<bool>(
                                              context: context,
                                              builder: (context) => AlertDialog(
                                                title: Text(
                                                  'Going to site',
                                                  style: GoogleFonts.roboto(
                                                      fontWeight:
                                                          FontWeight.bold),
                                                ),
                                                content: Text(
                                                  'This will mark the booking as in progress.',
                                                  style: GoogleFonts.roboto(),
                                                ),
                                                actions: [
                                                  TextButton(
                                                    onPressed: () =>
                                                        Navigator.pop(
                                                            context, false),
                                                    child: const Text('Cancel'),
                                                  ),
                                                  ElevatedButton(
                                                    onPressed: () =>
                                                        Navigator.pop(
                                                            context, true),
                                                    child:
                                                        const Text('Confirm'),
                                                  ),
                                                ],
                                              ),
                                            ) ??
                                            false;
                                        if (!ok) return;

                                        final updated =
                                            await FutureBookingService
                                                .markBookingInProgress(
                                          bookingId: booking.id ?? doc.id,
                                          tasksManagementId: tasksManagementId,
                                        );
                                        if (!context.mounted) return;
                                        ScaffoldMessenger.of(context)
                                            .showSnackBar(
                                          SnackBar(
                                            content: Text(
                                              updated
                                                  ? 'Booking started (in progress)'
                                                  : 'Could not start booking',
                                            ),
                                            backgroundColor: updated
                                                ? Colors.green
                                                : Colors.red,
                                          ),
                                        );
                                      }
                                    : null,
                                icon:
                                    const Icon(Icons.directions_car, size: 18),
                                label: const Text('Going to site'),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: const Color(0xFFc5a520),
                                  foregroundColor: Colors.white,
                                ),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: OutlinedButton.icon(
                                onPressed: canCancel
                                    ? () async {
                                        final ok = await showDialog<bool>(
                                              context: context,
                                              builder: (context) => AlertDialog(
                                                title: Text(
                                                  'Cancel appointment',
                                                  style: GoogleFonts.roboto(
                                                      fontWeight:
                                                          FontWeight.bold),
                                                ),
                                                content: Text(
                                                  'This will immediately reassign the booking to another artisan.',
                                                  style: GoogleFonts.roboto(),
                                                ),
                                                actions: [
                                                  TextButton(
                                                    onPressed: () =>
                                                        Navigator.pop(
                                                            context, false),
                                                    child: const Text('Keep'),
                                                  ),
                                                  ElevatedButton(
                                                    onPressed: () =>
                                                        Navigator.pop(
                                                            context, true),
                                                    style: ElevatedButton
                                                        .styleFrom(
                                                            backgroundColor:
                                                                Colors.red),
                                                    child: const Text(
                                                      'Cancel',
                                                      style: TextStyle(
                                                          color: Colors.white),
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ) ??
                                            false;
                                        if (!ok) return;

                                        final updated =
                                            await FutureBookingService
                                                .artisanCancelAndReassign(
                                          bookingId: booking.id ?? doc.id,
                                        );
                                        if (!context.mounted) return;
                                        ScaffoldMessenger.of(context)
                                            .showSnackBar(
                                          SnackBar(
                                            content: Text(
                                              updated
                                                  ? 'Booking reassigned'
                                                  : 'Could not cancel/reassign booking',
                                            ),
                                            backgroundColor: updated
                                                ? Colors.green
                                                : Colors.red,
                                          ),
                                        );
                                      }
                                    : null,
                                icon: const Icon(Icons.cancel, size: 18),
                                label: const Text('Cancel'),
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: Colors.red,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 15),
                      ],

                      // Action Buttons
                      if (booking.artisanConfirmed != 'yes') ...[
                        Row(
                          children: [
                            Expanded(
                              child: ElevatedButton.icon(
                                onPressed: () => _confirmBooking(
                                  context,
                                  booking,
                                  tasksManagementId: tasksManagementId,
                                ),
                                icon: const Icon(Icons.check, size: 18),
                                label: const Text('Confirm'),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: Colors.green,
                                  foregroundColor: Colors.white,
                                ),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: ElevatedButton.icon(
                                onPressed: () =>
                                    _declineBooking(context, booking),
                                icon: const Icon(Icons.close, size: 18),
                                label: const Text('Decline'),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: Colors.red,
                                  foregroundColor: Colors.white,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ] else ...[
                        ElevatedButton.icon(
                          onPressed: status == 'in_progress'
                              ? null
                              : () => _reportUnavailable(context, booking),
                          icon: const Icon(Icons.event_busy, size: 18),
                          label: const Text('I\'m No Longer Available'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.orange,
                            foregroundColor: Colors.white,
                            minimumSize: const Size(double.infinity, 40),
                          ),
                        ),
                        // Confirm Balance Received button for deposit bookings
                        if (depositPaid && !balancePaid) ...[
                          const SizedBox(height: 10),
                          ElevatedButton.icon(
                            onPressed: () async {
                              final ok = await showDialog<bool>(
                                    context: context,
                                    builder: (context) => AlertDialog(
                                      title: Text(
                                        'Confirm Balance Received',
                                        style: GoogleFonts.roboto(
                                            fontWeight: FontWeight.bold),
                                      ),
                                      content: Text(
                                        'Confirm that the client has paid the remaining balance for this job? This will mark the booking as fully paid.',
                                        style: GoogleFonts.roboto(),
                                      ),
                                      actions: [
                                        TextButton(
                                          onPressed: () =>
                                              Navigator.pop(context, false),
                                          child: const Text('Cancel'),
                                        ),
                                        ElevatedButton(
                                          onPressed: () =>
                                              Navigator.pop(context, true),
                                          style: ElevatedButton.styleFrom(
                                              backgroundColor: Colors.green),
                                          child: const Text('Confirm Paid',
                                              style: TextStyle(
                                                  color: Colors.white)),
                                        ),
                                      ],
                                    ),
                                  ) ??
                                  false;
                              if (!ok) return;

                              final updated = await FutureBookingService
                                  .confirmBalanceReceived(
                                bookingId: booking.id ?? doc.id,
                                tasksManagementId: tasksManagementId,
                              );
                              if (!context.mounted) return;
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(
                                    updated
                                        ? 'Balance confirmed — booking fully paid!'
                                        : 'Could not confirm balance',
                                  ),
                                  backgroundColor:
                                      updated ? Colors.green : Colors.red,
                                ),
                              );
                            },
                            icon: const Icon(Icons.payments, size: 18),
                            label:
                                const Text('Confirm Balance Received'),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.green,
                              foregroundColor: Colors.white,
                              minimumSize: const Size(double.infinity, 40),
                            ),
                          ),
                        ],
                      ],
                    ],
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }

  void _confirmBooking(
    BuildContext context,
    FutureBookingModel booking, {
    required String tasksManagementId,
  }) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Confirm Booking',
            style: GoogleFonts.roboto(fontWeight: FontWeight.bold)),
        content: Text('Are you confirming your availability for this booking?',
            style: GoogleFonts.roboto()),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () async {
              final appController = Get.find<AppController>();
              if (tasksManagementId.trim().isNotEmpty) {
                await FutureBookingService.tasksManagementRef
                    .doc(tasksManagementId.trim())
                    .set(
                  {
                    'accept': '1',
                    'status': 'pending_payment',
                    'service_provider_id': appController.userId.value,
                    'service_provider_name': appController.userName.value,
                    'updated_at': DateTime.now().toString(),
                  },
                  SetOptions(merge: true),
                );
              }

              await FutureBookingService.futureBookingsRef
                  .doc(booking.id)
                  .update({
                'artisan_confirmed': 'yes',
                // After artisan confirms, client must complete payment.
                'status': 'pending_payment',
                'service_provider_id': appController.userId.value,
                'updated_at': DateTime.now().toString(),
              });

              // For WhatsApp bookings: also update the MAIN tasksManagement
              // doc and notify the client via WhatsApp.
              final fbSnap = await FutureBookingService.futureBookingsRef
                  .doc(booking.id)
                  .get();
              final source = (fbSnap.data()?['source'] ?? '')
                  .toString()
                  .trim()
                  .toLowerCase();
              if (source == 'whatsapp' || source == 'whatsapp_rfq') {
                // Update main doc so payment handler detects acceptance
                FutureBookingService.tasksManagementRef
                    .doc(booking.id)
                    .set({
                  'accept': '1',
                  'artisan_confirmed': 'yes',
                  'status': 'pending_payment',
                  'service_provider_id': appController.userId.value,
                  'service_provider_name': appController.userName.value,
                  'updated_at': DateTime.now().toString(),
                }, SetOptions(merge: true));
                // Notify WhatsApp client
                try {
                  http.post(
                    Uri.parse(
                        'https://square15-whatsapp-bot.onrender.com/api/artisan-accepted'),
                    headers: {'Content-Type': 'application/json'},
                    body: jsonEncode({
                      'bookingId': booking.id,
                      'artisanName': appController.userName.value,
                    }),
                  );
                } catch (_) {}
              }

              // Do NOT auto-deduct wallet here — let the client pay explicitly
              // so the artisan sees 'pending_payment' status until client pays.

              // Notify customer
              await FutureBookingService.sendNotificationToUser(
                userId: booking.userId!,
                title: 'Payment required',
                type: 'future_booking_payment_required',
                message:
                    'Your booking is confirmed. Please pay to confirm the order. Note: funds will be immediately refunded if the work is not done or if the artisan cancels without going to site.',
                data: {
                  'booking_id': booking.id ?? '',
                  'type': 'future_booking_payment_required',
                },
              );

              await FutureBookingService.sendNotificationToUser(
                userId: booking.userId!,
                message:
                    'Your artisan has confirmed the booking for ${booking.scheduledDate}',
              );

              Navigator.pop(context);
              Get.snackbar('Success', 'Booking confirmed',
                  backgroundColor: Colors.green, colorText: Colors.white);
            },
            style: ElevatedButton.styleFrom(backgroundColor: Colors.green),
            child: const Text('Confirm', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  void _declineBooking(BuildContext context, FutureBookingModel booking) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Decline Booking',
            style: GoogleFonts.roboto(fontWeight: FontWeight.bold)),
        content: Text('This booking will be reassigned to another artisan.',
            style: GoogleFonts.roboto()),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () async {
              // Reassign booking
              bool reassigned = await FutureBookingService.reassignBooking(
                bookingId: booking.id!,
                booking: booking,
              );

              if (reassigned) {
                Navigator.pop(context);
                Get.snackbar('Success', 'Booking declined and reassigned',
                    backgroundColor: Colors.green, colorText: Colors.white);
              } else {
                Navigator.pop(context);
                Get.snackbar('Notice',
                    'No available artisan found. Customer will be notified.',
                    backgroundColor: Colors.orange, colorText: Colors.white);

                // Mark as cancelled if no artisan available
                await FutureBookingService.futureBookingsRef
                    .doc(booking.id)
                    .update({
                  'status': 'cancelled',
                  'updated_at': DateTime.now().toString(),
                });

                // Restore wallet if it was already deducted.
                await FutureBookingService.refundWalletForBooking(
                  bookingId: booking.id ?? '',
                  reason: 'cancelled_no_artisan_available',
                );

                await FutureBookingService.sendNotificationToUser(
                  userId: booking.userId!,
                  message:
                      'Unfortunately, no artisan is available for your scheduled booking. Please reschedule.',
                );
              }
            },
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Decline', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  void _reportUnavailable(BuildContext context, FutureBookingModel booking) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Report Unavailability',
            style: GoogleFonts.roboto(fontWeight: FontWeight.bold)),
        content: Text(
            'The booking will be automatically reassigned to another available artisan.',
            style: GoogleFonts.roboto()),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () async {
              // Reassign booking
              bool reassigned = await FutureBookingService.reassignBooking(
                bookingId: booking.id!,
                booking: booking,
              );

              if (reassigned) {
                Navigator.pop(context);
                Get.snackbar('Success', 'Booking reassigned to another artisan',
                    backgroundColor: Colors.green, colorText: Colors.white);
              } else {
                Navigator.pop(context);
                Get.snackbar('Notice',
                    'No available artisan found. Customer will be notified.',
                    backgroundColor: Colors.orange, colorText: Colors.white);

                await FutureBookingService.futureBookingsRef
                    .doc(booking.id)
                    .update({
                  'status': 'cancelled',
                  'updated_at': DateTime.now().toString(),
                });

                // Restore wallet if it was already deducted.
                await FutureBookingService.refundWalletForBooking(
                  bookingId: booking.id ?? '',
                  reason: 'cancelled_no_replacement_artisan',
                );

                await FutureBookingService.sendNotificationToUser(
                  userId: booking.userId!,
                  message:
                      'Your artisan is no longer available. Unfortunately, no replacement was found. Please reschedule.',
                );
              }
            },
            style: ElevatedButton.styleFrom(backgroundColor: Colors.orange),
            child: const Text('Confirm Unavailability',
                style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }
}
