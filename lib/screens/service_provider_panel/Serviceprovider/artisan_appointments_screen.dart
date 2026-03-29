import 'dart:async';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';
import 'package:image_picker/image_picker.dart';
import 'package:maintenanceapp/model/future_booking_model.dart';
import 'package:maintenanceapp/services/future_booking_service.dart';
import 'package:maintenanceapp/screens/service_provider_panel/Serviceprovider/artisan_calendar_screen.dart';
import 'package:maintenanceapp/controller/service_provider_controller.dart';
import 'package:maintenanceapp/model/task_management_model.dart';
import 'package:maintenanceapp/screens/home/booking/attachment_view.dart';
import 'package:maintenanceapp/screens/home/booking/booking.dart';
import 'package:maintenanceapp/screens/home/booking/google_map_view.dart';
import 'package:maintenanceapp/services/firestore_services/firebase_services.dart';
import 'package:maintenanceapp/utils/primary_button.dart';

class ArtisanAppointmentsScreen extends StatelessWidget {
  final List<String> artisanIds;

  const ArtisanAppointmentsScreen({
    super.key,
    required this.artisanIds,
  });

  DateTime? _parseBookingDateTime(FutureBookingModel booking) {
    final date = (booking.scheduledDate ?? '').trim();
    final time = (booking.scheduledTime ?? '').trim();
    if (date.isEmpty || time.isEmpty) return null;
    return FutureBookingService.tryParseScheduledDateTimePublic(date, time);
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    final height = MediaQuery.of(context).size.height;
    final ids = artisanIds
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toSet()
        .toList();
    if (ids.isEmpty) {
      return Scaffold(
        appBar: AppBar(
          title: Text('Appointments',
              style: GoogleFonts.roboto(color: Colors.white)),
          backgroundColor: const Color(0xFFc5a520),
          iconTheme: const IconThemeData(color: Colors.white),
        ),
        body: const Center(child: Text('No artisan id found')),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text('Appointments',
            style: GoogleFonts.roboto(color: Colors.white)),
        backgroundColor: const Color(0xFFc5a520),
        iconTheme: const IconThemeData(color: Colors.white),
        actions: [
          IconButton(
            tooltip: 'Calendar',
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => ArtisanCalendarScreen(artisanIds: ids),
                ),
              );
            },
            icon: const Icon(Icons.calendar_month, color: Colors.white),
          ),
        ],
      ),
      body: StreamBuilder<QuerySnapshot>(
        stream: FutureBookingService.futureBookingsRef
            .where('service_provider_id',
                whereIn: ids.length > 10 ? ids.sublist(0, 10) : ids)
            .snapshots(),
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }

          final docs = snapshot.data!.docs;
          final bookings = <_BookingWithData>[];

          for (final d in docs) {
            final data =
                (d.data() as Map<String, dynamic>?) ?? <String, dynamic>{};
            if (data.isEmpty) continue;

            final booking = FutureBookingModel.fromDocument(data);
            booking.id ??= (data['id'] ?? d.id).toString();

            final status = (data['status'] ?? booking.status ?? '')
                .toString()
                .toLowerCase()
                .trim();
            final isRfq = (data['is_rfq'] ?? booking.isRFQ ?? '')
                .toString()
                .toLowerCase()
                .trim();
            if (isRfq == 'yes') continue;

            // Skip cancelled and closed orders
            if (status.contains('cancel') ||
                status == 'closed' ||
                status == 'completed') {
              continue;
            }

            if (status != 'pending' &&
                status != 'confirmed' &&
                status != 'pending_payment' &&
                status != 'accepted' &&
                status != 'in_progress' &&
                status != 'progress') {
              continue;
            }
            final dt = _parseBookingDateTime(booking);
            if (dt == null) continue;

            // Hide extremely old appointments from the UI (still removable in Firestore).
            if (dt.isBefore(DateTime.now().subtract(const Duration(days: 180)))) {
              continue;
            }
            bookings.add(
              _BookingWithData(
                docId: d.id,
                data: data,
                booking: booking,
              ),
            );
          }

          if (bookings.isEmpty) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.event_busy, size: 80, color: Colors.grey.shade400),
                  const SizedBox(height: 20),
                  Text(
                    'No upcoming appointments',
                    style: GoogleFonts.roboto(
                        fontSize: 18, color: Colors.grey.shade600),
                  ),
                ],
              ),
            );
          }

          bookings.sort((a, b) {
            final adt = _parseBookingDateTime(a.booking);
            final bdt = _parseBookingDateTime(b.booking);
            if (adt == null && bdt == null) return 0;
            if (adt == null) return 1;
            if (bdt == null) return -1;
            return adt.compareTo(bdt);
          });

          final appointmentDateTimes = bookings
              .map((b) => _parseBookingDateTime(b.booking))
              .whereType<DateTime>()
              .toList(growable: false);

          final clashBookingIds = <String>{};
          for (var i = 0; i < appointmentDateTimes.length - 1; i++) {
            final a = appointmentDateTimes[i];
            final b = appointmentDateTimes[i + 1];
            if (a.difference(b).abs().inHours < 2) {
              final aId = (bookings[i].booking.id ?? '').trim();
              final bId = (bookings[i + 1].booking.id ?? '').trim();
              if (aId.isNotEmpty) clashBookingIds.add(aId);
              if (bId.isNotEmpty) clashBookingIds.add(bId);
            }
          }

          return ListView.builder(
            physics: const BouncingScrollPhysics(),
            itemCount: bookings.length,
            padding: const EdgeInsets.all(10),
            itemBuilder: (context, index) {
              final row = bookings[index];
              final booking = row.booking;
              final data = row.data;
              final bookingId = (row.docId).trim().isNotEmpty
                  ? row.docId.trim()
                  : (booking.id ?? '').trim();

              final status = (data['status'] ?? booking.status ?? '')
                  .toString()
                  .toLowerCase()
                  .trim();
              final paymentStatus = (data['payment_status'] ?? '')
                  .toString()
                  .toLowerCase()
                  .trim();
              final tasksManagementId =
                  (data['tasks_management_id'] ?? '').toString().trim();
              final description = (data['description'] ?? booking.description)
                  ?.toString()
                  .trim();
              final providedAddress =
                  (data['provided_address'] ?? booking.userProvidedAddress)
                      ?.toString()
                      .trim();
              final serviceOnLocation = (data['service_on_location'] ??
                      booking.isServiceOnCurrentLocation)
                  ?.toString()
                  .trim()
                  .toLowerCase();
              final userId =
                  (data['user_id'] ?? booking.userId ?? '').toString().trim();

              final isInProgress =
                  status == 'in_progress' || status == 'progress';

              final canStart = !isInProgress &&
                  (paymentStatus == 'paid' || status == 'accepted');
              final canCancel = !isInProgress;

              final dt = _parseBookingDateTime(booking)!;
              final timeUntil = dt.difference(DateTime.now());
              final hasClash =
                  clashBookingIds.contains((booking.id ?? '').trim());

                final isOld =
                  dt.isBefore(DateTime.now().subtract(const Duration(days: 30)));
                final isPast = dt.isBefore(DateTime.now());
                final allowDelete = isOld || (isPast && hasClash);

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
                            child: Icon(
                              hasClash
                                  ? Icons.warning_amber_rounded
                                  : Icons.calendar_today,
                              color: hasClash
                                  ? Colors.red
                                  : const Color(0xFFc5a520),
                              size: 24,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  DateFormat('EEEE, MMM dd, yyyy').format(dt),
                                  style: GoogleFonts.roboto(
                                      fontSize: 16,
                                      fontWeight: FontWeight.bold),
                                ),
                                Text(
                                  DateFormat('hh:mm a').format(dt),
                                  style: GoogleFonts.roboto(
                                      fontSize: 14,
                                      color: Colors.grey.shade600),
                                ),
                              ],
                            ),
                          ),
                          if (hasClash)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 10, vertical: 4),
                              decoration: BoxDecoration(
                                color: Colors.red.shade100,
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(color: Colors.red.shade900),
                              ),
                              child: Text(
                                'Clash',
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                  color: Colors.red.shade900,
                                ),
                              ),
                            ),

                          if (allowDelete) ...[
                            const SizedBox(width: 8),
                            IconButton(
                              tooltip: 'Delete appointment',
                              onPressed: () async {
                                final ok = await showDialog<bool>(
                                      context: context,
                                      builder: (context) => AlertDialog(
                                        title: Text(
                                          'Delete appointment',
                                          style: GoogleFonts.roboto(
                                              fontWeight: FontWeight.bold),
                                        ),
                                        content: Text(
                                          'This will permanently delete this appointment. Only use this for very old or incorrect appointments.',
                                          style: GoogleFonts.roboto(),
                                        ),
                                        actions: [
                                          TextButton(
                                            onPressed: () =>
                                                Navigator.pop(context, false),
                                            child: const Text('Cancel'),
                                          ),
                                          ElevatedButton(
                                            style: ElevatedButton.styleFrom(
                                                backgroundColor: Colors.red),
                                            onPressed: () =>
                                                Navigator.pop(context, true),
                                            child: const Text(
                                              'Delete',
                                              style:
                                                  TextStyle(color: Colors.white),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ) ??
                                    false;
                                if (!ok) return;

                                try {
                                  await FutureBookingService.futureBookingsRef
                                      .doc(bookingId)
                                      .delete();
                                  if (tasksManagementId.isNotEmpty) {
                                    await FirebaseService.tasksManagementRef
                                        .doc(tasksManagementId)
                                        .delete();
                                  }
                                  if (!context.mounted) return;
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                      content:
                                          Text('Appointment deleted successfully'),
                                      backgroundColor: Colors.green,
                                    ),
                                  );
                                } catch (e) {
                                  if (!context.mounted) return;
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text('Delete failed: $e'),
                                      backgroundColor: Colors.red,
                                    ),
                                  );
                                }
                              },
                              icon: const Icon(Icons.delete_forever,
                                  color: Colors.red),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 12),
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
                      const SizedBox(height: 8),
                      if (!timeUntil.isNegative) ...[
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
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                      ],
                      Row(
                        children: [
                          Icon(Icons.info_outline,
                              size: 18, color: Colors.grey.shade600),
                          const SizedBox(width: 8),
                          Text(
                            isInProgress
                                ? 'In Progress'
                                : (paymentStatus == 'paid' ||
                                        status == 'accepted')
                                    ? 'Accepted & Paid'
                                    : status == 'pending_payment' ||
                                            status == 'confirmed'
                                        ? 'Awaiting Payment'
                                        : 'Pending',
                            style: GoogleFonts.roboto(
                                fontSize: 13,
                                color: Colors.black87,
                                fontWeight: FontWeight.w600),
                          ),
                        ],
                      ),
                      if (providedAddress != null &&
                          providedAddress.isNotEmpty) ...[
                        const SizedBox(height: 10),
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(Icons.location_on,
                                size: 18, color: Colors.grey.shade600),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                'Location: $providedAddress',
                                style: GoogleFonts.roboto(
                                  fontSize: 13,
                                  color: Colors.black87,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                      if (description != null && description.isNotEmpty) ...[
                        const SizedBox(height: 10),
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(Icons.notes,
                                size: 18, color: Colors.grey.shade600),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                'Client Notes: $description',
                                style: GoogleFonts.roboto(
                                  fontSize: 13,
                                  color: Colors.grey.shade700,
                                  fontStyle: FontStyle.italic,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                      const SizedBox(height: 12),
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
                                                  child: const Text('Confirm'),
                                                ),
                                              ],
                                            ),
                                          ) ??
                                          false;
                                      if (!ok) return;

                                      final updated = await FutureBookingService
                                          .markBookingInProgress(
                                        bookingId: bookingId,
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
                              icon: const Icon(Icons.directions_car, size: 18),
                              label: Text(
                                isInProgress ? 'In Progress' : 'Going to site',
                              ),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFFc5a520),
                                foregroundColor: Colors.white,
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          // Chat button (show when tasksManagement exists and accept==1)
                          if (tasksManagementId.isNotEmpty)
                            StreamBuilder<
                                DocumentSnapshot<Map<String, dynamic>>>(
                              stream: FirebaseFirestore.instance
                                  .collection('tasksManagement')
                                  .doc(tasksManagementId)
                                  .snapshots(),
                              builder: (context, tmSnap) {
                                if (!tmSnap.hasData) {
                                  return const SizedBox(width: 10);
                                }
                                final accept =
                                    (tmSnap.data?.data()?['accept'] ?? '')
                                        .toString();
                                if (accept != '1') {
                                  return const SizedBox(width: 10);
                                }
                                final record = TaskManagementModel.fromDocument(
                                  tmSnap.data!.data()!,
                                  docId: tmSnap.data!.id,
                                );
                                return Row(
                                  children: [
                                    ChatIconWidget(
                                        record: record, isArtisanSide: true),
                                    const SizedBox(width: 10),
                                  ],
                                );
                              },
                            ),
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
                                                  style:
                                                      ElevatedButton.styleFrom(
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

                                      final updated = await FutureBookingService
                                          .artisanCancelAndReassign(
                                        bookingId: bookingId,
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

                      // Full in-progress workflow (match Requests screen)
                      if (isInProgress && tasksManagementId.isNotEmpty) ...[
                        const SizedBox(height: 14),
                        _InProgressWorkflowPanel(
                          tasksManagementId: tasksManagementId,
                          userId: userId,
                          width: width,
                          height: height,
                          bookingDocId: bookingId,
                        ),
                      ],
                      if (hasClash) ...[
                        const SizedBox(height: 10),
                        Text(
                          'This appointment is too close to another one. Please reschedule to avoid clashes.',
                          style: GoogleFonts.roboto(
                              fontSize: 12, color: Colors.red.shade700),
                        ),
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
}

class _InProgressWorkflowPanel extends StatefulWidget {
  final String tasksManagementId;
  final String userId;
  final double width;
  final double height;
  final String bookingDocId;

  const _InProgressWorkflowPanel({
    required this.tasksManagementId,
    required this.userId,
    required this.width,
    required this.height,
    required this.bookingDocId,
  });

  @override
  State<_InProgressWorkflowPanel> createState() =>
      _InProgressWorkflowPanelState();
}

class _InProgressWorkflowPanelState extends State<_InProgressWorkflowPanel> {
  final ServiceProviderController _spController = Get.find();
  final TextEditingController _notesController = TextEditingController();

  XFile? _picked;

  @override
  void dispose() {
    _notesController.dispose();
    super.dispose();
  }

  Future<XFile?> _pickImage(BuildContext context) async {
    final source = await showDialog<ImageSource>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Choose option'),
        content: SingleChildScrollView(
          child: ListBody(
            children: [
              const Divider(height: 1),
              ListTile(
                onTap: () => Navigator.pop(context, ImageSource.gallery),
                title: const Text('Gallery'),
                leading: const Icon(Icons.photo_library),
              ),
              const Divider(height: 1),
              ListTile(
                onTap: () => Navigator.pop(context, ImageSource.camera),
                title: const Text('Camera'),
                leading: const Icon(Icons.camera_alt),
              ),
            ],
          ),
        ),
      ),
    );

    if (source == null) return null;
    return ImagePicker().pickImage(source: source);
  }

  Future<String> _loadUserName(String uid) async {
    final id = uid.trim();
    if (id.isEmpty) return 'Client';
    try {
      final qs = await FirebaseService.userRef
          .where('uid', isEqualTo: id)
          .limit(1)
          .get();
      if (qs.docs.isEmpty) return 'Client';
      final name = (qs.docs.first.data()['name'] ?? '').toString().trim();
      return name.isNotEmpty ? name : 'Client';
    } catch (_) {
      return 'Client';
    }
  }

  Future<void> _uploadPickedImage({
    required TaskManagementModel record,
  }) async {
    if (_picked == null) return;
    final notes = _notesController.text.trim();
    if (notes.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Add Notes First'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    // Bridge into the existing controller upload pipeline.
    _spController.imageProvider.value = _picked;
    await _spController.saveBeforeAndAfterImage(
      to: (record.userId ?? '').toString(),
      referId: (record.artisanImageDocId ?? '').toString(),
      taskId: (record.id ?? '').toString(),
      notes: notes,
    );

    if (!mounted) return;
    setState(() {
      _picked = null;
    });
    _notesController.clear();
  }

  Future<void> _viewAttachment({
    required String taskManagementId,
    required bool before,
  }) async {
    try {
      final qs = await FirebaseService.artisanTaskImages
          .where('task_management_id', isEqualTo: taskManagementId)
          .where(before ? 'before_work' : 'after_work', isNotEqualTo: '')
          .limit(1)
          .get();
      if (!mounted) return;
      if (qs.docs.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Attachment not found!'),
            backgroundColor: Colors.orange,
          ),
        );
        return;
      }
      final path =
          (qs.docs.first.data()[before ? 'before_work' : 'after_work'] ?? '')
              .toString()
              .trim();
      if (path.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Attachment not found!'),
            backgroundColor: Colors.orange,
          ),
        );
        return;
      }
      Get.to(() => AttachmentView(imagePath: path));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Could not load attachment: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final tmId = widget.tasksManagementId.trim();
    if (tmId.isEmpty) return const SizedBox();

    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: FirebaseService.tasksManagementRef.doc(tmId).snapshots(),
      builder: (context, snapshot) {
        if (!snapshot.hasData || snapshot.data?.data() == null) {
          return const SizedBox();
        }

        final record = TaskManagementModel.fromDocument(
          snapshot.data!.data()!,
          docId: snapshot.data!.id,
        );

        final canChat =
            (record.accept ?? '') == '1' && (record.status ?? '') == 'progress';
        final artisanImages = (record.artisanImages ?? '').toString().trim();
        final orderNo = (record.orderNo ?? '').toString().trim();

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Order number row
            if (orderNo.isNotEmpty) ...[
              Row(
                children: [
                  Icon(Icons.tag, size: 16, color: Colors.grey.shade600),
                  const SizedBox(width: 6),
                  Text(
                    'Order #$orderNo',
                    style: GoogleFonts.roboto(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: const Color(0xFFc5a520),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
            ],
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Job Actions',
                  style: GoogleFonts.roboto(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (canChat)
                  ChatIconWidget(record: record, isArtisanSide: true),
              ],
            ),
            const SizedBox(height: 10),

            // ---- Job Timer with Pause/Resume ----
            _JobTimerWidget(
              tasksManagementId: tmId,
              record: record,
            ),
            const SizedBox(height: 10),

            // Job list (same as Requests)
            StreamBuilder<QuerySnapshot>(
              stream: FirebaseService.tasksManagementRef
                  .doc(tmId)
                  .collection('jobs')
                  .snapshots(),
              builder: (context, jobsSnap) {
                if (!jobsSnap.hasData || jobsSnap.data!.docs.isEmpty) {
                  return const SizedBox();
                }
                return SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: List.generate(jobsSnap.data!.docs.length, (i) {
                      final job = jobsSnap.data!.docs[i];
                      final taskId = (job['task_id'] ?? '').toString().trim();
                      if (taskId.isEmpty) return const SizedBox();
                      return StreamBuilder<
                          DocumentSnapshot<Map<String, dynamic>>>(
                        stream: FirebaseService.taskRef.doc(taskId).snapshots(),
                        builder: (context, taskSnap) {
                          final name =
                              (taskSnap.data?.data()?['name'] ?? 'Service')
                                  .toString()
                                  .trim();
                          final desc =
                              (job['description'] ?? '').toString().trim();
                          final cost = (job['cost'] ?? '').toString().trim();
                          return Container(
                            padding: const EdgeInsets.all(8),
                            margin: const EdgeInsets.only(right: 8, bottom: 5),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(8),
                              color: Colors.white,
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.grey.shade200,
                                  offset: const Offset(1, 1),
                                  spreadRadius: 2,
                                  blurRadius: 2,
                                )
                              ],
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 4, vertical: 2),
                                  margin: const EdgeInsets.only(
                                      right: 8, bottom: 5),
                                  decoration: BoxDecoration(
                                    color: Colors.grey.shade100,
                                    borderRadius: BorderRadius.circular(3),
                                    border:
                                        Border.all(color: Colors.grey.shade700),
                                  ),
                                  child: Row(
                                    children: [
                                      Container(
                                        margin: const EdgeInsets.only(right: 5),
                                        padding: const EdgeInsets.all(5),
                                        decoration: BoxDecoration(
                                          color: Colors.grey.shade500,
                                          shape: BoxShape.circle,
                                        ),
                                      ),
                                      Text(
                                        name,
                                        style: GoogleFonts.lato(
                                          fontSize: 14,
                                          color: Colors.grey.shade700,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                if (desc.isNotEmpty)
                                  Text(
                                    desc,
                                    style: GoogleFonts.lato(
                                      fontSize: 12,
                                      color: Colors.grey.shade700,
                                    ),
                                  ),
                                if (cost.isNotEmpty)
                                  Text(
                                    'R$cost',
                                    style: GoogleFonts.lato(
                                      fontSize: 12,
                                      color: Colors.grey.shade700,
                                    ),
                                  ),
                              ],
                            ),
                          );
                        },
                      );
                    }),
                  ),
                );
              },
            ),

            // Track User
            GestureDetector(
              onTap: () async {
                final uid = (record.userId ?? widget.userId).toString().trim();
                if (uid.isEmpty) return;
                final name = await _loadUserName(uid);
                if (!mounted) return;
                Get.to(() => GoogleMapView(
                      id: uid,
                      name: name,
                      taskRecord: record,
                    ));
              },
              child: Container(
                margin: const EdgeInsets.only(top: 10),
                padding: const EdgeInsets.all(5),
                decoration: BoxDecoration(
                  color: Colors.amber.shade50,
                  borderRadius: BorderRadius.circular(5),
                  border: Border.all(color: Colors.amber.shade300),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.grey.shade200,
                      blurRadius: 0.5,
                      spreadRadius: 0.5,
                    )
                  ],
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      'Track User',
                      style: GoogleFonts.lato(
                        fontWeight: FontWeight.w700,
                        color: Colors.amber.shade500,
                        fontSize: 16,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Image.asset('assets/images/track.png', height: 30),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 10),

            // Notes
            Obx(
              () => AnimatedSwitcher(
                duration: const Duration(milliseconds: 250),
                child: _spController.showNotedField.value
                    ? Card(
                        elevation: 2,
                        color: Colors.white,
                        child: TextField(
                          controller: _notesController,
                          cursorColor: Colors.black,
                          style: GoogleFonts.roboto(fontSize: 12),
                          decoration: InputDecoration(
                            labelText: 'Add Notes',
                            labelStyle: GoogleFonts.roboto(
                              color: const Color(0xffACADB9),
                              fontSize: widget.width * 0.04,
                            ),
                            border: InputBorder.none,
                            focusedBorder: const OutlineInputBorder(
                              borderSide: BorderSide(color: Colors.white),
                            ),
                            filled: true,
                            fillColor: Colors.white,
                            prefixIcon: Icon(
                              Icons.description,
                              color: const Color(0xffACADB9),
                              size: widget.width * 0.07,
                            ),
                            contentPadding: const EdgeInsets.symmetric(
                              vertical: 5.0,
                              horizontal: 10.0,
                            ),
                          ),
                        ),
                      )
                    : SizedBox(
                        height: widget.height * 0.05,
                        width: widget.width,
                        child: PrimaryButton(
                          title: 'Add Notes',
                          radius: 5,
                          onPressed: () =>
                              _spController.showNotedField.value = true,
                        ),
                      ),
              ),
            ),

            const SizedBox(height: 8),

            // Before/After cards
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                _MiniPickerCard(
                  title: 'Before Work',
                  color: artisanImages == '0'
                      ? Colors.blue.shade500
                      : Colors.grey.shade500,
                  icon: artisanImages == '0' ? Icons.upload : Icons.attachment,
                  onTap: () async {
                    if (artisanImages == '0') {
                      if (_notesController.text.trim().isEmpty) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('Add Notes First'),
                            backgroundColor: Colors.orange,
                          ),
                        );
                        return;
                      }
                      _spController.isBeforeWorkImage.value = true;
                      final picked = await _pickImage(context);
                      if (!mounted) return;
                      if (picked == null) return;
                      setState(() => _picked = picked);
                    } else {
                      await _viewAttachment(
                        taskManagementId: tmId,
                        before: true,
                      );
                    }
                  },
                ),
                _MiniPickerCard(
                  title: 'After Work',
                  color: artisanImages == '1'
                      ? Colors.green.shade500
                      : Colors.grey.shade500,
                  icon: artisanImages == '1' ? Icons.upload : Icons.attachment,
                  onTap: () async {
                    if (artisanImages == '1') {
                      if (_notesController.text.trim().isEmpty) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('Add Notes First'),
                            backgroundColor: Colors.orange,
                          ),
                        );
                        return;
                      }
                      _spController.isBeforeWorkImage.value = false;
                      final picked = await _pickImage(context);
                      if (!mounted) return;
                      if (picked == null) return;
                      setState(() => _picked = picked);
                    } else if (artisanImages == '2') {
                      await _viewAttachment(
                        taskManagementId: tmId,
                        before: false,
                      );
                    } else {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Upload Before Work first'),
                          backgroundColor: Colors.orange,
                        ),
                      );
                    }
                  },
                ),
              ],
            ),

            if (_picked != null) ...[
              const SizedBox(height: 10),
              Stack(
                clipBehavior: Clip.none,
                alignment: Alignment.center,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Image.file(
                      File(_picked!.path),
                      fit: BoxFit.cover,
                      height: 150,
                      width: widget.width,
                    ),
                  ),
                  Obx(() => _spController.isUploading.value
                      ? Positioned(
                          child: CircularProgressIndicator(
                            color: Colors.amber.shade500,
                          ),
                        )
                      : const SizedBox()),
                ],
              ),
              const SizedBox(height: 10),
              SizedBox(
                height: widget.height * 0.05,
                child: PrimaryButton(
                  radius: 5,
                  fontSize: 12,
                  title: _spController.isUploading.value
                      ? 'Uploading....!'
                      : 'Upload Image',
                  onPressed: () async => _uploadPickedImage(record: record),
                  color: Colors.green.shade500,
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}

class _MiniPickerCard extends StatelessWidget {
  final String title;
  final Color color;
  final VoidCallback onTap;
  final IconData icon;

  const _MiniPickerCard({
    required this.title,
    required this.color,
    required this.onTap,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        GestureDetector(
          onTap: onTap,
          child: Container(
            margin: const EdgeInsets.only(bottom: 5, top: 5),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: color.withOpacity(0.2),
              borderRadius: BorderRadius.circular(5),
              border: Border.all(color: color),
            ),
            child: Icon(icon, color: color),
          ),
        ),
        Text(title, style: GoogleFonts.lato(color: color, fontSize: 12)),
      ],
    );
  }
}

class _BookingWithData {
  final String docId;
  final Map<String, dynamic> data;
  final FutureBookingModel booking;

  const _BookingWithData({
    required this.docId,
    required this.data,
    required this.booking,
  });
}

/// Real-time job timer with pause/resume. Reads `in_progress_at`, `is_paused`,
/// `paused_at`, and `total_paused_ms` from the task_management document.
class _JobTimerWidget extends StatefulWidget {
  final String tasksManagementId;
  final TaskManagementModel record;

  const _JobTimerWidget({
    required this.tasksManagementId,
    required this.record,
  });

  @override
  State<_JobTimerWidget> createState() => _JobTimerWidgetState();
}

class _JobTimerWidgetState extends State<_JobTimerWidget> {
  Timer? _ticker;
  Duration _elapsed = Duration.zero;
  bool _isPaused = false;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && !_isPaused) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  Duration _computeElapsed(Map<String, dynamic> data) {
    final inProgressAt = data['in_progress_at'];
    DateTime? start;
    if (inProgressAt is Timestamp) {
      start = inProgressAt.toDate();
    } else if (inProgressAt is String && inProgressAt.isNotEmpty) {
      start = DateTime.tryParse(inProgressAt);
    }
    if (start == null) return Duration.zero;

    final totalPausedMs = (data['total_paused_ms'] ?? 0) is int
        ? data['total_paused_ms'] as int
        : int.tryParse(data['total_paused_ms'].toString()) ?? 0;
    final isPaused = data['is_paused'] == true;

    if (isPaused) {
      final pausedAt = data['paused_at'];
      DateTime? pauseTime;
      if (pausedAt is Timestamp) {
        pauseTime = pausedAt.toDate();
      } else if (pausedAt is String && pausedAt.isNotEmpty) {
        pauseTime = DateTime.tryParse(pausedAt);
      }
      pauseTime ??= DateTime.now();
      final raw = pauseTime.difference(start);
      return raw - Duration(milliseconds: totalPausedMs);
    }

    final raw = DateTime.now().difference(start);
    return raw - Duration(milliseconds: totalPausedMs);
  }

  String _formatDuration(Duration d) {
    if (d.isNegative) d = Duration.zero;
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60);
    return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  Future<void> _togglePause() async {
    final ref = FirebaseService.tasksManagementRef.doc(widget.tasksManagementId);
    final snap = await ref.get();
    if (!snap.exists) return;
    final data = snap.data() as Map<String, dynamic>? ?? {};
    final isPaused = data['is_paused'] == true;

    if (isPaused) {
      // Resume: add paused duration to total_paused_ms
      final pausedAt = data['paused_at'];
      DateTime? pauseTime;
      if (pausedAt is Timestamp) {
        pauseTime = pausedAt.toDate();
      } else if (pausedAt is String && pausedAt.isNotEmpty) {
        pauseTime = DateTime.tryParse(pausedAt);
      }
      final pausedMs = pauseTime != null
          ? DateTime.now().difference(pauseTime).inMilliseconds
          : 0;
      final currentTotal = (data['total_paused_ms'] ?? 0) is int
          ? data['total_paused_ms'] as int
          : int.tryParse(data['total_paused_ms'].toString()) ?? 0;
      await ref.update({
        'is_paused': false,
        'paused_at': FieldValue.delete(),
        'total_paused_ms': currentTotal + pausedMs,
      });
      setState(() => _isPaused = false);
    } else {
      // Pause
      await ref.update({
        'is_paused': true,
        'paused_at': FieldValue.serverTimestamp(),
      });
      setState(() => _isPaused = true);
    }
  }

  Future<void> _saveDraft() async {
    await _togglePause(); // Auto-pause on draft save
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Draft saved — timer paused'),
        backgroundColor: Colors.green,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: FirebaseService.tasksManagementRef
          .doc(widget.tasksManagementId)
          .snapshots(),
      builder: (context, snapshot) {
        if (!snapshot.hasData || snapshot.data?.data() == null) {
          return const SizedBox();
        }
        final data = snapshot.data!.data()!;
        final isPaused = data['is_paused'] == true;
        _isPaused = isPaused;
        _elapsed = _computeElapsed(data);

        return Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: isPaused ? Colors.orange.shade50 : Colors.blue.shade50,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: isPaused ? Colors.orange.shade200 : Colors.blue.shade200,
            ),
          ),
          child: Row(
            children: [
              Icon(
                isPaused ? Icons.pause_circle : Icons.timer,
                color: isPaused ? Colors.orange : Colors.blue.shade700,
                size: 28,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      isPaused ? 'PAUSED' : 'IN PROGRESS',
                      style: GoogleFonts.lato(
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                        color: isPaused ? Colors.orange : Colors.blue.shade700,
                      ),
                    ),
                    Text(
                      _formatDuration(_elapsed),
                      style: GoogleFonts.robotoMono(
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                        color: isPaused ? Colors.orange.shade800 : Colors.blue.shade900,
                      ),
                    ),
                  ],
                ),
              ),
              GestureDetector(
                onTap: _togglePause,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  decoration: BoxDecoration(
                    color: isPaused ? Colors.green : Colors.orange,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    isPaused ? 'RESUME' : 'PAUSE',
                    style: GoogleFonts.lato(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              GestureDetector(
                onTap: _saveDraft,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  decoration: BoxDecoration(
                    color: Colors.grey.shade200,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.grey.shade400),
                  ),
                  child: Text(
                    'SAVE',
                    style: GoogleFonts.lato(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: Colors.grey.shade700,
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
