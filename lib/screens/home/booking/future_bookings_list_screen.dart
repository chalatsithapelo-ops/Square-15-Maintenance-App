import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'dart:async';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_easyloading/flutter_easyloading.dart';
import 'package:flutter_rating_bar/flutter_rating_bar.dart';
import 'package:get/get.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';
import 'package:maintenanceapp/controller/app_controller.dart';
import 'package:maintenanceapp/model/future_booking_model.dart';
import 'package:maintenanceapp/model/task_management_model.dart';
import 'package:maintenanceapp/screens/home/booking/attachment_view.dart';
import 'package:maintenanceapp/screens/home/booking/chat_screen.dart';
import 'package:maintenanceapp/screens/home/booking/chat_icon_widget.dart';
import 'package:maintenanceapp/screens/home/booking/google_map_view.dart';
import 'package:maintenanceapp/screens/home/booking/payment_method_sheet.dart';
import 'package:maintenanceapp/screens/home/rfq/client_rfq_response_screen.dart';
import 'package:maintenanceapp/services/firestore_services/firebase_services.dart';
import 'package:maintenanceapp/services/future_booking_service.dart';
import 'package:maintenanceapp/services/refund_service.dart';
import 'package:url_launcher/url_launcher.dart';

class FutureBookingsListScreen extends StatefulWidget {
  const FutureBookingsListScreen({super.key});

  static const String _statusApprovedWaitingAssignment =
      'approved_waiting_artisan_assignment';

  @override
  State<FutureBookingsListScreen> createState() =>
      _FutureBookingsListScreenState();
}

class _FutureBookingsListScreenState extends State<FutureBookingsListScreen> {
  final AppController _appController = Get.find();

  final Set<String> _orderNoBackfilled = <String>{};

  bool _isNumericRef(String raw) {
    final s = raw.trim();
    if (s.isEmpty) return false;
    return int.tryParse(s) != null;
  }

  bool _shouldPreferTasksOrderNo({
    required bool isRfq,
    required String orderNo,
    required String tasksManagementId,
  }) {
    if (isRfq) return false;
    if (tasksManagementId.trim().isEmpty) return false;
    final s = orderNo.trim();
    if (s.isEmpty) return true;
    if (s.toUpperCase().startsWith('ORD-')) return true;
    return !_isNumericRef(s);
  }

  Future<void> _backfillOrderNoIfNeeded({
    required String bookingDocId,
    required String newOrderNo,
  }) async {
    final id = bookingDocId.trim();
    final orderNo = newOrderNo.trim();
    if (id.isEmpty || orderNo.isEmpty) return;
    if (!_isNumericRef(orderNo)) return;
    if (_orderNoBackfilled.contains(id)) return;

    _orderNoBackfilled.add(id);
    try {
      await FutureBookingService.futureBookingsRef.doc(id).set(
        {
          'order_no': orderNo,
          'updated_at': DateTime.now().toString(),
        },
        SetOptions(merge: true),
      );
    } catch (_) {
      _orderNoBackfilled.remove(id);
    }
  }

  Future<TaskManagementModel?> _loadTaskManagementRecord(String docId) async {
    final id = docId.trim();
    if (id.isEmpty) return null;
    final snap = await FirebaseFirestore.instance
        .collection('tasksManagement')
        .doc(id)
        .get();
    final data = snap.data();
    if (!snap.exists || data == null) return null;
    return TaskManagementModel.fromDocument(data, docId: snap.id);
  }

  Future<String> _loadServiceProviderName(String serviceProviderId) async {
    final id = serviceProviderId.trim();
    if (id.isEmpty) return 'Artisan';
    try {
      final doc = await _appController.serviceProviderRef.doc(id).get();
      final data = doc.data();
      final name = (data?['name'] ?? '').toString().trim();
      return name.isNotEmpty ? name : 'Artisan';
    } catch (_) {
      return 'Artisan';
    }
  }

  Future<void> _openChatFromTasksManagement(
    BuildContext context, {
    required String tasksManagementId,
  }) async {
    final record = await _loadTaskManagementRecord(tasksManagementId);
    if (!mounted) return;
    if (record == null || (record.id ?? '').trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Chat is not available yet for this booking.'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }
    Get.to(() => ChatScreen(task: record, isArtisanSide: false));
  }

  Future<void> _openTrackingFromTasksManagement(
    BuildContext context, {
    required String tasksManagementId,
    required String serviceProviderId,
  }) async {
    final record = await _loadTaskManagementRecord(tasksManagementId);
    if (!mounted) return;
    if (record == null || (record.serviceProviderId ?? '').trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Tracking is not available yet for this booking.'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }
    final providerId = (record.serviceProviderId ?? serviceProviderId).trim();
    if (providerId.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Tracking is not available yet for this booking.'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }
    final providerName = await _loadServiceProviderName(providerId);
    if (!mounted) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => GoogleMapView(
          id: providerId,
          taskRecord: record,
          name: providerName,
        ),
      ),
    );
  }

  StreamSubscription<QuerySnapshot>? _subUserId;
  StreamSubscription<QuerySnapshot>? _subUserIdCamel;
  StreamSubscription<QuerySnapshot>? _subUid;

  Map<String, QueryDocumentSnapshot> _docsUserId =
      <String, QueryDocumentSnapshot>{};
  Map<String, QueryDocumentSnapshot> _docsUserIdCamel =
      <String, QueryDocumentSnapshot>{};
  Map<String, QueryDocumentSnapshot> _docsUid =
      <String, QueryDocumentSnapshot>{};

  Object? _error;
  bool _loading = true;
  String _activeKey = '';

  String _cleanId(String? raw) {
    final s = (raw ?? '').toString().trim();
    if (s.isEmpty) return '';
    final lower = s.toLowerCase();
    if (lower == 'null' || lower == 'undefined') return '';
    return s;
  }

  List<dynamic> _candidateUserIdValues() {
    // IMPORTANT: Keep this list tight. Broadening (e.g. int parsing) risks
    // matching other users' bookings if their numeric ids collide.
    final ids = <String>{};
    final prefId = _cleanId(_appController.userId.value);
    if (prefId.isNotEmpty) ids.add(prefId);
    final authUid = _cleanId(FirebaseAuth.instance.currentUser?.uid);
    if (authUid.isNotEmpty) ids.add(authUid);
    return ids.toList(growable: false);
  }

  Set<String> _activeUserIdSet() {
    return _candidateUserIdValues()
        .map((e) => e.toString().trim())
        .where((e) => e.isNotEmpty)
        .toSet();
  }

  void _cancelStreams() {
    _subUserId?.cancel();
    _subUserIdCamel?.cancel();
    _subUid?.cancel();
    _subUserId = null;
    _subUserIdCamel = null;
    _subUid = null;
  }

  void _wireStreams() {
    final ids = _candidateUserIdValues();
    final key = ids.map((e) => e.toString()).join('|');
    if (key == _activeKey && _subUserId != null) return;

    _cancelStreams();
    _docsUserId = <String, QueryDocumentSnapshot>{};
    _docsUserIdCamel = <String, QueryDocumentSnapshot>{};
    _docsUid = <String, QueryDocumentSnapshot>{};

    if (ids.isEmpty) {
      setState(() {
        _loading = false;
        _error =
            'Missing user id for bookings. Please log out and log in again.';
      });
      return;
    }

    _activeKey = key;

    void onSnap(QuerySnapshot snap, String bucket) {
      final map = <String, QueryDocumentSnapshot>{
        for (final d in snap.docs) d.id: d,
      };
      setState(() {
        _loading = false;
        _error = null;
        if (bucket == 'user_id') _docsUserId = map;
        if (bucket == 'userId') _docsUserIdCamel = map;
        if (bucket == 'uid') _docsUid = map;
      });
    }

    void onErr(Object e) {
      setState(() {
        _loading = false;
        _error = e;
      });
    }

    _subUserId = FutureBookingService.futureBookingsRef
        .where('user_id', whereIn: ids)
        .snapshots()
        .listen((s) => onSnap(s, 'user_id'), onError: onErr);

    // Some flows/backends use camelCase.
    _subUserIdCamel = FutureBookingService.futureBookingsRef
        .where('userId', whereIn: ids)
        .snapshots()
        .listen((s) => onSnap(s, 'userId'), onError: onErr);

    // Some flows/backends use uid.
    _subUid = FutureBookingService.futureBookingsRef
        .where('uid', whereIn: ids)
        .snapshots()
        .listen((s) => onSnap(s, 'uid'), onError: onErr);
  }

  @override
  void initState() {
    super.initState();
    _wireStreams();
  }

  @override
  void dispose() {
    _cancelStreams();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Rewire if userId/Auth uid loads after startup.
    _wireStreams();
    const allowedStatuses = <String>{
      'pending',
      'pending_assignment',
      'pending_payment',
      'paid',
      'progress',
      'in_progress',
      'accepted',
      'confirmed',
      'completed',
      'rfq_pending',
      'rfq_sent',
      'rfq_approved',
      'rfq_rejected',
      FutureBookingsListScreen._statusApprovedWaitingAssignment,
    };

    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            'Error loading bookings: $_error\n\n'
            'If this mentions an index, open the Firebase console link in the error to create it. '
            'If it mentions PERMISSION_DENIED, ensure this account can read futureBookings.',
            textAlign: TextAlign.center,
            style: GoogleFonts.roboto(fontSize: 13, color: Colors.red.shade900),
          ),
        ),
      );
    }

    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    // Merge results from common user id field variants.
    final byId = <String, QueryDocumentSnapshot>{};
    byId.addAll(_docsUserId);
    byId.addAll(_docsUserIdCamel);
    byId.addAll(_docsUid);

    final todayStart =
        DateTime(DateTime.now().year, DateTime.now().month, DateTime.now().day);

    final allDocs = byId.values.toList(growable: false);
    if (allDocs.isEmpty) {
      final idsForUi =
          _candidateUserIdValues().map((e) => e.toString()).toSet().toList();
      final fetchedCount = allDocs.length;
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
            const SizedBox(height: 10),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Text(
                'Fetched $fetchedCount docs (user_id=${_docsUserId.length}, userId=${_docsUserIdCamel.length}, uid=${_docsUid.length}).\n'
                'Searching ids: ${idsForUi.isEmpty ? '(none)' : idsForUi.join(', ')}',
                textAlign: TextAlign.center,
                style: GoogleFonts.roboto(
                    fontSize: 11, color: Colors.grey.shade500),
              ),
            ),
          ],
        ),
      );
    }

    final docs = allDocs.where((d) {
      final data = (d.data() as Map<String, dynamic>?) ?? <String, dynamic>{};

      // Hard ownership filter to prevent showing other users' bookings.
      final activeIds = _activeUserIdSet();
      final docUserId = (data['user_id'] ?? '').toString().trim();
      final docUserIdCamel = (data['userId'] ?? '').toString().trim();
      final docUid = (data['uid'] ?? '').toString().trim();
      final belongsToUser = (docUserId.isNotEmpty &&
              activeIds.contains(docUserId)) ||
          (docUserIdCamel.isNotEmpty && activeIds.contains(docUserIdCamel)) ||
          (docUid.isNotEmpty && activeIds.contains(docUid));
      if (!belongsToUser) return false;

      final status = (data['status'] ?? '').toString().trim().toLowerCase();
      final orderType =
          (data['order_type'] ?? '').toString().trim().toLowerCase();
      final isRfqFlag =
          (data['is_rfq'] ?? '').toString().trim().toLowerCase() == 'yes';
      final paymentStatus =
          (data['payment_status'] ?? '').toString().trim().toLowerCase();
      final walletDeductedRaw = data['wallet_deducted'];
      final walletDeducted = walletDeductedRaw is bool
          ? (walletDeductedRaw ? 'yes' : 'no')
          : (walletDeductedRaw ?? '').toString().trim().toLowerCase();
      final artisanConfirmed =
          (data['artisan_confirmed'] ?? '').toString().trim().toLowerCase();
      final tasksManagementId =
          (data['tasks_management_id'] ?? '').toString().trim();

      // Exclude completed/closed and cancelled bookings from Future tab
      if (status == 'closed' ||
          status == 'cancelled' ||
          status == 'completed') {
        return false;
      }

      // Future Bookings must remain visible after acceptance/payment.
      // Some backends update status to values like 'progress'/'paid' or
      // leave status blank while setting payment flags.
      final isRfq =
          isRfqFlag || orderType == 'rfq' || status.startsWith('rfq_');

      // Keep bookings that are pending payment or confirmed by artisan
      // visible regardless of scheduled date, so the client can still pay.
      final isPendingPayment = status == 'pending_payment' ||
          artisanConfirmed == 'yes' ||
          tasksManagementId.isNotEmpty;

      // Future tab should not show clearly past-dated bookings, but keep
      // payment-pending ones visible so the client can complete payment.
      final scheduled =
          FutureBookingService.tryParseScheduledDateTimeFromDocument(data);
      if (scheduled != null &&
          scheduled.isBefore(todayStart) &&
          !isPendingPayment) {
        return false;
      }

      // For non-RFQ items, Future tab requires a valid scheduled datetime
      // (unless the booking is payment-pending).
      if (!isRfq && scheduled == null && !isPendingPayment) return false;
      if (isRfq) return true;
      if (isPendingPayment) return true;

      if (allowedStatuses.contains(status)) return true;
      if (paymentStatus == 'paid') return true;
      if (walletDeducted == 'yes') return true;

      return false;
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
      return FutureBookingService.tryParseScheduledDateTimeFromDocument(data);
    }

    docs.sort((a, b) {
      final aData = (a.data() as Map<String, dynamic>?) ?? <String, dynamic>{};
      final bData = (b.data() as Map<String, dynamic>?) ?? <String, dynamic>{};

      // Primary: sort by creation time (newest first) so the most recent
      // booking always appears at the top.
      DateTime? tryParseCreatedAt(Map<String, dynamic> d) {
        final ts = d['created_at_ts'];
        if (ts is Timestamp) return ts.toDate();
        final raw = (d['created_at'] ?? d['createdAt'] ?? '').toString().trim();
        if (raw.isEmpty) return null;
        return DateTime.tryParse(raw);
      }

      final aCreated = tryParseCreatedAt(aData);
      final bCreated = tryParseCreatedAt(bData);
      if (aCreated != null && bCreated != null) {
        return bCreated.compareTo(aCreated); // descending
      }
      if (aCreated == null && bCreated != null) return 1;
      if (aCreated != null && bCreated == null) return -1;

      // Fallback: scheduled date descending
      final aDt = tryParseScheduledDateTime(aData);
      final bDt = tryParseScheduledDateTime(bData);
      if (aDt == null && bDt == null) return 0;
      if (aDt == null) return 1;
      if (bDt == null) return -1;
      return bDt.compareTo(aDt);
    });

    return ListView.builder(
      physics: const BouncingScrollPhysics(),
      itemCount: docs.length,
      padding: const EdgeInsets.all(10),
      itemBuilder: (context, index) {
        final doc = docs[index];
        final data =
            (doc.data() as Map<String, dynamic>?) ?? <String, dynamic>{};
        final status = (data['status'] ?? '').toString().toLowerCase();
        final orderType = (data['order_type'] ?? '').toString().toLowerCase();
        final isRfqFlag =
            (data['is_rfq'] ?? '').toString().toLowerCase() == 'yes';
        final isRfq =
            isRfqFlag || orderType == 'rfq' || status.startsWith('rfq_');

        final orderNo = (data['order_no'] ?? '').toString().trim();
        final rfqNo = (data['rfq_no'] ?? '').toString().trim();
        final refNo = isRfq
            ? (rfqNo.isNotEmpty ? rfqNo : '')
            : (orderNo.isNotEmpty ? orderNo : '');

        final paymentStatus =
            (data['payment_status'] ?? '').toString().trim().toLowerCase();
        final tasksManagementId =
            (data['tasks_management_id'] ?? '').toString().trim();
        final walletDeductedRaw = data['wallet_deducted'];
        final walletDeducted = walletDeductedRaw is bool
            ? (walletDeductedRaw ? 'yes' : 'no')
            : (walletDeductedRaw ?? '').toString().trim().toLowerCase();
        final walletDeductStatus = (data['wallet_deduct_status'] ?? '')
            .toString()
            .trim()
            .toLowerCase();

        // RFQ status for navigation + payment gating
        final rfqStatus = (data['rfq_status'] ?? '').toString().trim().toLowerCase();

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
        double? adminTotal = adminTotalDynamic is num
            ? adminTotalDynamic.toDouble()
            : double.tryParse(adminTotalDynamic?.toString() ?? '');

        // For auto-assigned RFQ bookings, admin_quote_total is usually null.
        // Fall back to rfq_total or ai_quote total so the correct amount
        // (e.g. R460 instead of the catalog-inferred R1575) flows to payment.
        if ((adminTotal == null || adminTotal <= 0) && isRfq) {
          final rfqTotalRaw = data['rfq_total'];
          if (rfqTotalRaw is num && rfqTotalRaw > 0) {
            adminTotal = rfqTotalRaw.toDouble();
          } else if (rfqTotalRaw != null) {
            adminTotal = double.tryParse(
                rfqTotalRaw.toString().replaceAll(RegExp(r'[^0-9.]'), ''));
          }
          if (adminTotal == null || adminTotal <= 0) {
            final aq = data['ai_quote'];
            if (aq is Map) {
              final aqTotal = aq['total'] ?? aq['estimatedCost'];
              if (aqTotal is num && aqTotal > 0) {
                adminTotal = aqTotal.toDouble();
              }
            }
          }
        }

        final scheduledDateTime = tryParseScheduledDateTime(data);
        final timeUntil = scheduledDateTime?.difference(DateTime.now());

        bool isTruthyYes(dynamic v) {
          if (v is bool) return v;
          final s = (v ?? '').toString().trim().toLowerCase();
          return s == 'yes' || s == 'true' || s == '1';
        }

        final isPaid = paymentStatus == 'paid' || walletDeducted == 'yes' ||
          isTruthyYes(data['wallet_deducted']);

        final bool rfqIsPayableState = isRfq && !isPaid && (
          // New flow
          rfqStatus == 'rfq_pending_payment' ||
          status == 'pending_payment' ||
          // Legacy/older flows where approval happened but payment was not enforced
          status == FutureBookingsListScreen._statusApprovedWaitingAssignment ||
          rfqStatus == 'rfq_approved_waiting_assignment' ||
          rfqStatus == 'client_approved_rfq'
          );

        final bool showPayToConfirm =
          // Normal future bookings: pay after artisan confirmation.
          (!isRfq &&
            (status == 'confirmed' || status == 'pending_payment') &&
            (booking.artisanConfirmed ?? '').toLowerCase() == 'yes' &&
            !isPaid &&
            tasksManagementId.isNotEmpty &&
            (walletDeductStatus.isEmpty || walletDeductStatus != 'deducted'))
          // RFQ bookings: pay after client approval/scheduling before assignment.
          || (rfqIsPayableState &&
            (walletDeductStatus.isEmpty || walletDeductStatus != 'deducted') &&
            // Either already linked, or we can create the bridge when user taps Pay.
            (tasksManagementId.isNotEmpty || adminTotal != null));

        final isInProgress = status == 'in_progress' || status == 'progress';
        final canChatForFutureBooking =
            tasksManagementId.isNotEmpty &&
            (paymentStatus == 'paid' || status == 'accepted' || isInProgress);

        final preferTasksOrderNo = _shouldPreferTasksOrderNo(
          isRfq: isRfq,
          orderNo: orderNo,
          tasksManagementId: tasksManagementId,
        );

        final nonRfqStatusLabel = isInProgress
            ? 'In Progress'
            : (paymentStatus == 'paid' || status == 'accepted')
                ? 'Accepted & Paid'
                : status == 'pending_payment' || status == 'confirmed'
                    ? 'Awaiting Payment'
                    : status ==
                            FutureBookingsListScreen
                                ._statusApprovedWaitingAssignment
                        ? 'Approved waiting for artisan assignment'
                        : (booking.artisanConfirmed == 'yes'
                            ? 'Artisan Confirmed'
                            : 'Awaiting Artisan Confirmation');

        final nonRfqStatusIsGood = isInProgress ||
            paymentStatus == 'paid' ||
            status == 'accepted' ||
            status == FutureBookingsListScreen._statusApprovedWaitingAssignment;

        final nonRfqStatusBg = nonRfqStatusIsGood
            ? Colors.green.shade100
            : (booking.artisanConfirmed == 'yes'
                ? Colors.green.shade100
                : Colors.amber.shade100);
        final nonRfqStatusBorder = nonRfqStatusIsGood
            ? Colors.green.shade900
            : (booking.artisanConfirmed == 'yes'
                ? Colors.green.shade900
                : Colors.amber.shade900);
        final nonRfqStatusFg = nonRfqStatusBorder;

        final canNavigateToRfqResponse =
          isRfq && rfqStatus == 'pending_client_response';

        return GestureDetector(
          onTap: canNavigateToRfqResponse
              ? () {
                  Get.to(() => ClientRFQResponseScreen(
                        bookingId: doc.id,
                        bookingData: data,
                      ));
                }
              : null,
          child: Container(
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
                        child: const Icon(
                          Icons.calendar_today,
                          color: Color(0xFFc5a520),
                          size: 24,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              scheduledDateTime != null
                                  ? DateFormat('EEEE, MMM dd, yyyy')
                                      .format(scheduledDateTime)
                                  : 'Date not set',
                              style: GoogleFonts.roboto(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            Text(
                              scheduledDateTime != null
                                  ? DateFormat('hh:mm a')
                                      .format(scheduledDateTime)
                                  : (booking.scheduledTime ?? 'Time not set'),
                              style: GoogleFonts.roboto(
                                fontSize: 14,
                                color: Colors.grey.shade600,
                              ),
                            ),
                          ],
                        ),
                      ),
                      // Schedule button when no date is set
                      if (scheduledDateTime == null)
                        InkWell(
                          onTap: () => _scheduleBooking(
                            context: context,
                            bookingId: doc.id,
                          ),
                          borderRadius: BorderRadius.circular(8),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 6),
                            decoration: BoxDecoration(
                              color: const Color(0xFFc5a520).withOpacity(0.15),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                  color: const Color(0xFFc5a520), width: 1),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.event,
                                    size: 16,
                                    color: const Color(0xFFc5a520)),
                                const SizedBox(width: 4),
                                Text('Schedule',
                                    style: GoogleFonts.roboto(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                      color: const Color(0xFFc5a520),
                                    )),
                              ],
                            ),
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
                          style: GoogleFonts.roboto(
                              fontSize: 14, fontWeight: FontWeight.w600),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),

                  if (isRfq && refNo.isNotEmpty) ...[
                    Row(
                      children: [
                        Icon(Icons.tag, size: 18, color: Colors.grey.shade600),
                        const SizedBox(width: 8),
                        Text(
                          refNo,
                          style: GoogleFonts.roboto(
                              fontSize: 13, fontWeight: FontWeight.w600),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                  ] else if (!isRfq && preferTasksOrderNo) ...[
                    FutureBuilder<TaskManagementModel?>(
                      future: _loadTaskManagementRecord(tasksManagementId),
                      builder: (context, snap) {
                        final tasksOrderNo = (snap.data?.orderNo ?? '').trim();
                        final showRef = tasksOrderNo.isNotEmpty
                            ? tasksOrderNo
                            : (orderNo.isNotEmpty ? orderNo : '');

                        if (_isNumericRef(tasksOrderNo) &&
                            tasksOrderNo.isNotEmpty &&
                            tasksOrderNo != orderNo) {
                          // Best-effort backfill so next load is consistent.
                          // Ignore errors (permissions/offline).
                          _backfillOrderNoIfNeeded(
                            bookingDocId: doc.id,
                            newOrderNo: tasksOrderNo,
                          );
                        }

                        if (showRef.isEmpty) return const SizedBox();
                        return Column(
                          children: [
                            Row(
                              children: [
                                Icon(Icons.tag,
                                    size: 18, color: Colors.grey.shade600),
                                const SizedBox(width: 8),
                                Text(
                                  showRef,
                                  style: GoogleFonts.roboto(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 10),
                          ],
                        );
                      },
                    ),
                  ] else if (!isRfq && orderNo.isNotEmpty) ...[
                    Row(
                      children: [
                        Icon(Icons.tag, size: 18, color: Colors.grey.shade600),
                        const SizedBox(width: 8),
                        Text(
                          orderNo,
                          style: GoogleFonts.roboto(
                              fontSize: 13, fontWeight: FontWeight.w600),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                  ],

                  // Cost — for RFQ bookings, prefer rfq_total or ai_quote total
                  // when the booking.cost field is TBD.
                  Builder(builder: (context) {
                    String displayCost = (booking.cost ?? 'TBD').toString().trim();
                    if (displayCost.isEmpty ||
                        displayCost.toUpperCase() == 'TBD' ||
                        displayCost.toUpperCase() == 'RTBD') {
                      // Try rfq_total first
                      final rfqTotalRaw = data['rfq_total'];
                      double? rfqTotal;
                      if (rfqTotalRaw is num && rfqTotalRaw > 0) {
                        rfqTotal = rfqTotalRaw.toDouble();
                      } else if (rfqTotalRaw != null) {
                        rfqTotal = double.tryParse(
                            rfqTotalRaw.toString().replaceAll(RegExp(r'[^0-9.]'), ''));
                      }
                      if (rfqTotal != null && rfqTotal > 0) {
                        displayCost = rfqTotal.toStringAsFixed(2);
                      } else {
                        // Fallback to ai_quote.total
                        final aq = data['ai_quote'];
                        if (aq is Map) {
                          final aqTotal = aq['total'] ?? aq['estimatedCost'];
                          if (aqTotal is num && aqTotal > 0) {
                            displayCost = aqTotal.toDouble().toStringAsFixed(2);
                          }
                        }
                      }
                    }
                    return Row(
                      children: [
                        Icon(Icons.attach_money,
                            size: 18, color: Colors.grey.shade600),
                        const SizedBox(width: 8),
                        Text(
                          'Cost: R$displayCost',
                          style: GoogleFonts.roboto(
                              fontSize: 14, color: Colors.black87),
                        ),
                      ],
                    );
                  }),
                  const SizedBox(height: 10),

                  // Status
                  Row(
                    children: [
                      Icon(Icons.info_outline,
                          size: 18, color: Colors.grey.shade600),
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color: isRfq
                              ? (status == 'rfq_sent'
                                  ? Colors.blue.shade100
                                  : status == 'rfq_approved'
                                      ? Colors.green.shade100
                                      : status == 'rfq_rejected'
                                          ? Colors.red.shade100
                                          : (paymentStatus == 'paid' || status == 'accepted' || isInProgress)
                                              ? Colors.green.shade100
                                              : (status == 'pending_payment' || status == 'confirmed')
                                                  ? Colors.orange.shade100
                                                  : Colors.amber.shade100)
                              : nonRfqStatusBg,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: isRfq
                                ? (status == 'rfq_sent'
                                    ? Colors.blue.shade900
                                    : status == 'rfq_approved'
                                        ? Colors.green.shade900
                                        : status == 'rfq_rejected'
                                            ? Colors.red.shade900
                                            : (paymentStatus == 'paid' || status == 'accepted' || isInProgress)
                                                ? Colors.green.shade900
                                                : (status == 'pending_payment' || status == 'confirmed')
                                                    ? Colors.orange.shade900
                                                    : Colors.amber.shade900)
                                : nonRfqStatusBorder,
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
                                              : (paymentStatus == 'paid' || status == 'accepted')
                                                  ? 'Accepted & Paid'
                                                  : isInProgress
                                                      ? 'In Progress'
                                                      : (status == 'pending_payment' || status == 'confirmed')
                                                          ? 'Awaiting Payment'
                                                          : status)
                              : nonRfqStatusLabel,
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
                                            : (paymentStatus == 'paid' || status == 'accepted' || isInProgress)
                                                ? Colors.green.shade900
                                                : (status == 'pending_payment' || status == 'confirmed')
                                                    ? Colors.orange.shade900
                                                    : Colors.amber.shade900)
                                : nonRfqStatusFg,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),

                  // Assigned artisan info card (photo, name, rating, jobs done)
                  if ((booking.serviceProviderId ?? '').trim().isNotEmpty &&
                      (booking.serviceProviderId ?? '').trim().toLowerCase() != 'admin') ...[
                    FutureBuilder<DocumentSnapshot>(
                      future: _appController.serviceProviderRef
                          .doc(booking.serviceProviderId!.trim())
                          .get(),
                      builder: (context, spSnap) {
                        if (!spSnap.hasData || spSnap.data == null || !spSnap.data!.exists) {
                          return const SizedBox.shrink();
                        }
                        final sp = spSnap.data!.data() as Map<String, dynamic>? ?? {};
                        final artisanName = (sp['name'] ?? '').toString().trim();
                        final artisanImage = (sp['imageUrl'] ?? sp['image'] ?? '').toString().trim();
                        final artisanPhone = (sp['phone'] ?? sp['contact'] ?? sp['phoneNumber'] ?? '').toString().trim();
                        final avgRating = sp['average_rating'] is num
                            ? (sp['average_rating'] as num).toDouble()
                            : double.tryParse((sp['average_rating'] ?? '').toString()) ?? 0.0;
                        final jobsDone = sp['total_jobs_done'] ?? sp['jobs_completed'] ?? 0;
                        final jobsCount = jobsDone is num
                            ? jobsDone.toInt()
                            : int.tryParse(jobsDone.toString()) ?? 0;

                        return Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: const Color(0xFFc5a520).withOpacity(0.07),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: const Color(0xFFc5a520).withOpacity(0.3)),
                          ),
                          child: Row(
                            children: [
                              CircleAvatar(
                                radius: 24,
                                backgroundColor: Colors.grey.shade300,
                                backgroundImage: artisanImage.isNotEmpty
                                    ? NetworkImage(artisanImage)
                                    : null,
                                child: artisanImage.isEmpty
                                    ? Icon(Icons.person, color: Colors.grey.shade600, size: 28)
                                    : null,
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      artisanName.isNotEmpty ? artisanName : 'Artisan',
                                      style: GoogleFonts.roboto(
                                        fontSize: 14,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    Row(
                                      children: [
                                        const Icon(Icons.star, color: Color(0xFFc5a520), size: 16),
                                        const SizedBox(width: 3),
                                        Text(
                                          avgRating > 0 ? avgRating.toStringAsFixed(1) : 'New',
                                          style: GoogleFonts.roboto(fontSize: 13, fontWeight: FontWeight.w500),
                                        ),
                                        const SizedBox(width: 12),
                                        Icon(Icons.work_outline, color: Colors.grey.shade600, size: 15),
                                        const SizedBox(width: 3),
                                        Text(
                                          '$jobsCount job${jobsCount == 1 ? '' : 's'} done',
                                          style: GoogleFonts.roboto(fontSize: 13, color: Colors.grey.shade700),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                              // Call Artisan button
                              if (artisanPhone.isNotEmpty)
                                IconButton(
                                  tooltip: 'Call $artisanName',
                                  onPressed: () async {
                                    final uri = Uri(scheme: 'tel', path: artisanPhone);
                                    if (await canLaunchUrl(uri)) {
                                      await launchUrl(uri);
                                    }
                                  },
                                  icon: const Icon(Icons.phone, color: Color(0xFFc5a520), size: 22),
                                  style: IconButton.styleFrom(
                                    backgroundColor: const Color(0xFFc5a520).withOpacity(0.1),
                                    shape: const CircleBorder(),
                                  ),
                                ),
                              // AI Score tier badge
                              FutureBuilder<DocumentSnapshot>(
                                future: FirebaseFirestore.instance
                                    .collection('artisan_scores')
                                    .doc(booking.serviceProviderId!.trim())
                                    .get(),
                                builder: (ctx, scoreSnap) {
                                  if (!scoreSnap.hasData || !scoreSnap.data!.exists) {
                                    return const SizedBox.shrink();
                                  }
                                  final sd = scoreSnap.data!.data() as Map<String, dynamic>? ?? {};
                                  final tier = (sd['tier'] ?? '').toString();
                                  final score = (sd['composite_score'] as num?)?.toInt() ?? 0;
                                  if (tier.isEmpty) return const SizedBox.shrink();
                                  final color = tier == 'Gold'
                                      ? const Color(0xFFc5a520)
                                      : tier == 'Silver'
                                          ? Colors.blueGrey
                                          : tier == 'Bronze'
                                              ? Colors.brown
                                              : Colors.grey;
                                  return Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                    decoration: BoxDecoration(
                                      color: color.withOpacity(0.15),
                                      borderRadius: BorderRadius.circular(12),
                                      border: Border.all(color: color, width: 1),
                                    ),
                                    child: Column(
                                      children: [
                                        Icon(Icons.emoji_events, color: color, size: 16),
                                        const SizedBox(height: 2),
                                        Text(tier, style: GoogleFonts.roboto(fontSize: 10, fontWeight: FontWeight.w700, color: color)),
                                        Text('$score', style: GoogleFonts.roboto(fontSize: 9, color: color)),
                                      ],
                                    ),
                                  );
                                },
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                    const SizedBox(height: 10),
                  ],

                  // Time Until
                  if (timeUntil != null && timeUntil.isNegative == false) ...[
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
                            'Notes: ${booking.description}',
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

                  // Service Location
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.location_on,
                          size: 18, color: Colors.grey.shade600),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          booking.isServiceOnCurrentLocation == 'yes'
                              ? 'Location: Your current location'
                              : 'Location: ${booking.userProvidedAddress ?? "Address not provided"}',
                          style: GoogleFonts.roboto(
                              fontSize: 13, color: Colors.black87),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),

                  // Reassignment notice
                  if ((int.tryParse(booking.reassignedCount ?? '') ?? 0) >
                      0) ...[
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: Colors.orange.shade50,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.orange.shade300),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.info,
                              size: 16, color: Colors.orange.shade700),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'This booking has been reassigned to another artisan',
                              style: GoogleFonts.roboto(
                                  fontSize: 12, color: Colors.orange.shade900),
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
                        onPressed: isInProgress
                            ? null
                            : () => _cancelBooking(
                                  context,
                                  booking,
                                  tasksManagementId: tasksManagementId,
                                ),
                        icon: const Icon(Icons.cancel, size: 18),
                        label: const Text('Cancel'),
                        style: TextButton.styleFrom(
                          foregroundColor: Colors.red,
                        ),
                      ),
                      const SizedBox(width: 10),
                      if (canChatForFutureBooking) ...[
                        // Stream artisan_images to determine if work is complete
                        StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
                          stream: tasksManagementId.isNotEmpty
                              ? FirebaseFirestore.instance
                                  .collection('tasksManagement')
                                  .doc(tasksManagementId)
                                  .snapshots()
                              : null,
                          builder: (context, tmSnap) {
                            final artisanImages =
                                (tmSnap.data?.data()?['artisan_images'] ?? '')
                                    .toString()
                                    .trim();
                            final isWorkComplete = artisanImages == '2';

                            if (isWorkComplete) {
                              // Show work complete UI with before/after + rating
                              return _WorkCompletePanel(
                                tasksManagementId: tasksManagementId,
                                serviceProviderId:
                                    (booking.serviceProviderId ?? '')
                                        .toString()
                                        .trim(),
                                onRatingSubmitted: () {
                                  // Refresh will happen via stream
                                },
                              );
                            }

                            // Default: show chat + track
                            final tmData =
                                tmSnap.data?.data() ?? <String, dynamic>{};
                            final tmRecord = TaskManagementModel.fromDocument(
                              tmData,
                              docId: tasksManagementId,
                            );
                            return Wrap(
                              spacing: 10,
                              runSpacing: 10,
                              children: [
                                ChatIconWidget(record: tmRecord),
                                if (!isRfq &&
                                    isInProgress &&
                                    (booking.serviceProviderId ?? '')
                                        .toString()
                                        .trim()
                                        .isNotEmpty)
                                  ElevatedButton.icon(
                                    onPressed: () =>
                                        _openTrackingFromTasksManagement(
                                      context,
                                      tasksManagementId: tasksManagementId,
                                      serviceProviderId:
                                          (booking.serviceProviderId ?? '')
                                              .toString(),
                                    ),
                                    icon: const Icon(Icons.map_outlined,
                                        size: 18),
                                    label: const Text('Track Artisan'),
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: const Color(0xFFc5a520),
                                      foregroundColor: Colors.white,
                                    ),
                                  ),
                              ],
                            );
                          },
                        ),
                      ],
                      if (isRfq && status == 'rfq_sent') ...[
                        SizedBox(
                          width: double.infinity,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              TextButton.icon(
                                onPressed: () => _showQuoteDialog(
                                  context: context,
                                  adminQuote: adminQuote,
                                  adminTotal: adminTotal,
                                  bookingId: doc.id,
                                ),
                                icon: const Icon(Icons.receipt_long, size: 18),
                                label: const Text('View Quote'),
                              ),
                              const SizedBox(height: 8),
                              Row(
                                children: [
                                  Expanded(
                                    child: ElevatedButton.icon(
                                      onPressed: () => _approveQuote(
                                        context: context,
                                        bookingId: doc.id,
                                      ),
                                      icon: const Icon(Icons.check_circle,
                                          size: 18),
                                      label: const Text('Approve'),
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: Colors.green,
                                        foregroundColor: Colors.white,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: OutlinedButton.icon(
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
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ],
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
                            bookingId: doc.id,
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
                              const Icon(Icons.payments_outlined,
                                  color: Colors.orange),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  'Payment required to confirm this future booking',
                                  style: GoogleFonts.roboto(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600),
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
                                bookingId: doc.id,
                                existingTasksManagementId: tasksManagementId,
                                payableAmount: adminTotal,
                              ),
                              icon: const Icon(Icons.lock_open),
                              label: const Text('Pay to confirm order'),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xff35540C),
                                foregroundColor: Colors.white,
                              ),
                            ),
                          ),
                          const SizedBox(height: 10),
                          Text(
                            'Note: Funds will be immediately refunded should the work not be done or should the artisan cancel the job without going to site.',
                            style: GoogleFonts.roboto(
                                fontSize: 12, color: Colors.grey.shade700),
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ), // Closes Container
        ); // Closes GestureDetector
      },
    );
  }

  Future<void> _payToConfirmFutureBooking({
    required BuildContext context,
    required String bookingId,
    required String existingTasksManagementId,
    required double? payableAmount,
  }) async {
    try {
      var tasksManagementId = existingTasksManagementId.trim();
      if (tasksManagementId.isEmpty) {
        // RFQ flows may not have the bridge until payment time; create it now.
        final resolved = await FutureBookingService.resolveOrCreateTasksManagementIdForBooking(
          bookingId: bookingId,
        );
        tasksManagementId = (resolved ?? '').trim();
      }

      if (tasksManagementId.isEmpty) {
        Get.snackbar(
          'Payment Unavailable',
          'This booking does not have a payment record yet.',
          backgroundColor: Colors.orange,
          colorText: Colors.white,
        );
        return;
      }

      // Ensure the payment record has a payable amount for RFQs.
      if (payableAmount != null && payableAmount > 0) {
        try {
          await FutureBookingService.tasksManagementRef.doc(tasksManagementId).set(
            {
              'cost': payableAmount.toStringAsFixed(2),
              'updated_at': DateTime.now().toString(),
            },
            SetOptions(merge: true),
          );

          await FutureBookingService.futureBookingsRef.doc(bookingId).set(
            {
              'tasks_management_id': tasksManagementId,
              'cost': payableAmount.toStringAsFixed(2),
              'payment_status': 'pending',
              'status': 'pending_payment',
              'rfq_status': 'rfq_pending_payment',
              'updated_at': DateTime.now().toString(),
            },
            SetOptions(merge: true),
          );
        } catch (_) {
          // Best-effort.
        }
      }

      final tmDoc = await FutureBookingService.tasksManagementRef
          .doc(tasksManagementId)
          .get();
      final tmData = tmDoc.data() ?? <String, dynamic>{};
      if (tmData.isEmpty) {
        Get.snackbar('Error', 'Payment record not found.',
            backgroundColor: Colors.red, colorText: Colors.white);
        return;
      }

      final taskManagementModel =
          TaskManagementModel.fromDocument(tmData, docId: tmDoc.id);
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

      showModalBottomSheet(
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.only(
            topLeft: Radius.circular(16),
            topRight: Radius.circular(16),
          ),
        ),
        context: context,
        builder: (BuildContext context) {
          return ModelBottomSheet(record: taskManagementModel);
        },
      );
    } catch (e) {
      debugPrint('payToConfirmFutureBooking error: $e');
      Get.snackbar('Error', 'Could not start payment.',
          backgroundColor: Colors.red, colorText: Colors.white);
    }
  }

  void _showQuoteDialog({
    required BuildContext context,
    required Map<String, dynamic> adminQuote,
    required double? adminTotal,
    required String bookingId,
  }) {
    final items =
        (adminQuote['items'] as List?)?.cast<dynamic>() ?? const <dynamic>[];
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
    final total = adminTotal ??
        toDouble(adminQuote['total']) ??
        (subtotal + (vatAmount ?? 0));

    // Helper to build a clean item card for the quote dialog
    Widget buildItemCard(Map<String, dynamic> m, {bool isMaterial = false}) {
      String desc = (m['description'] ?? '').toString();
      if (isMaterial) {
        desc = desc.replaceFirst(
            RegExp('^Materials:\\s*', caseSensitive: false), '');
      }
      final qty = (m['qty'] ?? '').toString();
      final uom = (m['uom'] ?? '').toString();
      final unit = fmtMoney(m['unit_price']);
      final line = fmtMoney(m['line_total']);
      final qtyLabel =
          '${qty.isNotEmpty ? qty : '1'}${uom.isNotEmpty ? ' $uom' : ''}';

      return Container(
        padding: const EdgeInsets.all(10),
        margin: const EdgeInsets.only(bottom: 6),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.grey.shade200),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(desc,
                style:
                    const TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
            const SizedBox(height: 4),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('Qty: $qtyLabel',
                    style:
                        TextStyle(fontSize: 12, color: Colors.grey.shade700)),
                Text('@ R$unit',
                    style:
                        TextStyle(fontSize: 12, color: Colors.grey.shade700)),
                Text('R$line',
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w600)),
              ],
            ),
          ],
        ),
      );
    }

    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(ctx).size.height * 0.8,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Title bar
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                decoration: BoxDecoration(
                  color: const Color(0xFFc5a520),
                  borderRadius:
                      const BorderRadius.vertical(top: Radius.circular(16)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.receipt_long, color: Colors.white),
                    const SizedBox(width: 10),
                    const Text('Quote Details',
                        style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 17,
                            color: Colors.white)),
                    const Spacer(),
                    GestureDetector(
                      onTap: () => Navigator.pop(ctx),
                      child: const Icon(Icons.close,
                          color: Colors.white, size: 22),
                    ),
                  ],
                ),
              ),

              // Scrollable content
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (materialItems.isNotEmpty) ...[
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.symmetric(
                              vertical: 8, horizontal: 12),
                          decoration: BoxDecoration(
                            color: Colors.blue.shade50,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Row(
                            children: [
                              Icon(Icons.inventory_2,
                                  size: 16, color: Colors.blue.shade700),
                              const SizedBox(width: 6),
                              Text('Materials',
                                  style: TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 14,
                                      color: Colors.blue.shade800)),
                            ],
                          ),
                        ),
                        const SizedBox(height: 6),
                        ...materialItems
                            .map((m) => buildItemCard(m, isMaterial: true)),
                        const SizedBox(height: 8),
                      ],

                      if (otherItems.isNotEmpty) ...[
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.symmetric(
                              vertical: 8, horizontal: 12),
                          decoration: BoxDecoration(
                            color: Colors.green.shade50,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Row(
                            children: [
                              Icon(Icons.engineering,
                                  size: 16, color: Colors.green.shade700),
                              const SizedBox(width: 6),
                              Text('Services & Labor',
                                  style: TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 14,
                                      color: Colors.green.shade800)),
                            ],
                          ),
                        ),
                        const SizedBox(height: 6),
                        ...otherItems.map((m) => buildItemCard(m)),
                        const SizedBox(height: 8),
                      ],

                      const Divider(thickness: 1.5),
                      const SizedBox(height: 6),

                      // Totals
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Colors.grey.shade100,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Column(
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                const Text('Subtotal',
                                    style: TextStyle(
                                        fontWeight: FontWeight.w600)),
                                Text('R${subtotal.toStringAsFixed(2)}'),
                              ],
                            ),
                            if (vatPercent != null ||
                                vatAmount != null) ...[
                              const SizedBox(height: 6),
                              Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [
                                  Text(
                                    vatPercent != null
                                        ? 'VAT (${vatPercent.toStringAsFixed(vatPercent % 1 == 0 ? 0 : 1)}%)'
                                        : 'VAT',
                                    style: const TextStyle(
                                        fontWeight: FontWeight.w600),
                                  ),
                                  Text(
                                      'R${(vatAmount ?? 0).toStringAsFixed(2)}'),
                                ],
                              ),
                            ],
                            const Divider(),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                const Text('Total',
                                    style: TextStyle(
                                        fontWeight: FontWeight.bold,
                                        fontSize: 16)),
                                Text('R${total.toStringAsFixed(2)}',
                                    style: const TextStyle(
                                        fontWeight: FontWeight.bold,
                                        fontSize: 16,
                                        color: Colors.green)),
                              ],
                            ),
                          ],
                        ),
                      ),

                      if (notes.isNotEmpty) ...[
                        const SizedBox(height: 14),
                        const Text('Notes/Terms',
                            style: TextStyle(
                                fontWeight: FontWeight.bold, fontSize: 14)),
                        const SizedBox(height: 6),
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: Colors.amber.shade50,
                            borderRadius: BorderRadius.circular(8),
                            border:
                                Border.all(color: Colors.amber.shade300),
                          ),
                          child: Text(notes,
                              style: const TextStyle(fontSize: 12)),
                        ),
                      ]
                    ],
                  ),
                ),
              ),

              // Action buttons
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  border: Border(
                      top: BorderSide(color: Colors.grey.shade300)),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () {
                          Navigator.pop(ctx);
                          _rejectQuote(
                              context: context, bookingId: bookingId);
                        },
                        icon: const Icon(Icons.cancel, size: 16),
                        label: const Text('Reject'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.red,
                          side: const BorderSide(color: Colors.red),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: ElevatedButton.icon(
                        onPressed: () {
                          Navigator.pop(ctx);
                          _approveQuote(
                              context: context, bookingId: bookingId);
                        },
                        icon: const Icon(Icons.check_circle, size: 16),
                        label: const Text('Approve'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.green,
                          foregroundColor: Colors.white,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _approveQuote({
    required BuildContext context,
    required String bookingId,
  }) async {
    // --- Ask client to pick a preferred date & time ---
    final now = DateTime.now();
    final selectedDate = await showDatePicker(
      context: context,
      initialDate: now.add(const Duration(days: 1)),
      firstDate: now,
      lastDate: now.add(const Duration(days: 365)),
      helpText: 'Select preferred service date',
    );
    if (selectedDate == null || !context.mounted) return;

    final selectedTime = await showTimePicker(
      context: context,
      initialTime: const TimeOfDay(hour: 9, minute: 0),
      helpText: 'Select preferred time',
    );
    if (selectedTime == null || !context.mounted) return;

    final scheduledDT = DateTime(
      selectedDate.year,
      selectedDate.month,
      selectedDate.day,
      selectedTime.hour,
      selectedTime.minute,
    );

    await FutureBookingService.futureBookingsRef.doc(bookingId).update({
      'status': FutureBookingsListScreen._statusApprovedWaitingAssignment,
      // Keep RFQ flag so admin can still see and assign it
      'rfq_status': 'rfq_approved_waiting_assignment',
      'is_rfq': 'yes', // Keep as RFQ until artisan assigned
      'order_type': 'rfq',
      'user_approved': 'yes',
      'user_approved_at': DateTime.now().toString(),
      'updated_at': DateTime.now().toString(),
      // Scheduled date & time
      'scheduled_date': scheduledDT.toIso8601String(),
      'scheduled_time': '${selectedTime.hour.toString().padLeft(2, '0')}:${selectedTime.minute.toString().padLeft(2, '0')}',
      'requires_scheduling': false,
    });

    await FutureBookingService.sendNotificationToAdmin(
      bookingId: bookingId,
      title: 'Approved waiting for artisan assignment',
      type: FutureBookingsListScreen._statusApprovedWaitingAssignment,
      message:
          'Client approved the quote and selected ${DateFormat('MMM dd, yyyy').format(scheduledDT)} at ${selectedTime.format(context)}. Booking $bookingId is waiting for artisan assignment.',
    );

    if (context.mounted) {
      Get.snackbar('Success', 'Quote approved — service scheduled',
          backgroundColor: Colors.green, colorText: Colors.white);
    }
  }

  /// Let client pick a date for a booking that was approved without one.
  Future<void> _scheduleBooking({
    required BuildContext context,
    required String bookingId,
  }) async {
    final now = DateTime.now();
    final selectedDate = await showDatePicker(
      context: context,
      initialDate: now.add(const Duration(days: 1)),
      firstDate: now,
      lastDate: now.add(const Duration(days: 365)),
      helpText: 'Select service date',
    );
    if (selectedDate == null || !context.mounted) return;

    final selectedTime = await showTimePicker(
      context: context,
      initialTime: const TimeOfDay(hour: 9, minute: 0),
      helpText: 'Select preferred time',
    );
    if (selectedTime == null || !context.mounted) return;

    final scheduledDT = DateTime(
      selectedDate.year,
      selectedDate.month,
      selectedDate.day,
      selectedTime.hour,
      selectedTime.minute,
    );

    await FutureBookingService.futureBookingsRef.doc(bookingId).update({
      'scheduled_date': scheduledDT.toIso8601String(),
      'scheduled_time': '${selectedTime.hour.toString().padLeft(2, '0')}:${selectedTime.minute.toString().padLeft(2, '0')}',
      'requires_scheduling': false,
      'updated_at': DateTime.now().toString(),
    });

    if (context.mounted) {
      Get.snackbar('Scheduled', 'Service date updated',
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

  void _cancelBooking(
    BuildContext context,
    FutureBookingModel booking, {
    required String tasksManagementId,
  }) {
    final status = (booking.status ?? '').toString().trim().toLowerCase();
    if (status == 'in_progress') {
      Get.snackbar(
        'Not allowed',
        'You cannot cancel once the job is in progress.',
        backgroundColor: Colors.orange,
        colorText: Colors.white,
      );
      return;
    }

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Cancel Booking',
            style: GoogleFonts.roboto(fontWeight: FontWeight.bold)),
        content: const Text('Are you sure you want to cancel this booking?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('No'),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.pop(context); // Close dialog immediately
              EasyLoading.show(status: 'Cancelling...');

              try {
                // Update status first for immediate UI feedback
                await FutureBookingService.futureBookingsRef
                    .doc(booking.id)
                    .update({
                  'status': 'cancelled',
                  'updated_at': DateTime.now().toString(),
                });

                // Keep tasksManagement in sync so artisan views remove it.
                final tmId = tasksManagementId.trim();
                if (tmId.isNotEmpty) {
                  await FirebaseFirestore.instance
                      .collection('tasksManagement')
                      .doc(tmId)
                      .update({
                    'status': 'cancelled',
                    'updated_at': DateTime.now().toString(),
                  });
                }

                // Restore wallet if it was already deducted
                await FutureBookingService.refundWalletForBooking(
                  bookingId: booking.id ?? '',
                  reason: 'cancelled_by_customer',
                );

                // Handle card payment refunds (PayFast/PayFlex)
                try {
                  final refundResult = await RefundService.refundFutureBooking(
                    bookingId: booking.id ?? '',
                    reason: 'cancelled_by_customer',
                    initiatedBy: FirebaseAuth.instance.currentUser?.uid ?? '',
                  );
                  if (refundResult.success && refundResult.method == 'refund_request') {
                    Get.snackbar('Refund Submitted',
                      'Your card refund request has been submitted for admin review.',
                      backgroundColor: Colors.blue, colorText: Colors.white,
                      duration: const Duration(seconds: 4));
                  }
                } catch (_) {
                  // Wallet refund already handled above; card refund is best-effort
                }

                // Notify artisan
                if (booking.serviceProviderId != null) {
                  await FutureBookingService.sendNotificationToArtisan(
                    artisanId: booking.serviceProviderId!,
                    bookingId: booking.id!,
                    message:
                        'Booking for ${booking.scheduledDate} has been cancelled by customer',
                  );
                }

                EasyLoading.dismiss();
                Get.snackbar('Success', 'Booking cancelled',
                    backgroundColor: Colors.green, colorText: Colors.white);
              } catch (e) {
                EasyLoading.dismiss();
                Get.snackbar('Error', 'Failed to cancel booking',
                    backgroundColor: Colors.red, colorText: Colors.white);
              }
            },
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Yes, Cancel',
                style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  void _confirmAvailability(BuildContext context, FutureBookingModel booking) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Confirm Availability',
            style: GoogleFonts.roboto(fontWeight: FontWeight.bold)),
        content: Text('Please confirm you will be available for this booking.',
            style: GoogleFonts.roboto()),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () async {
              await FutureBookingService.futureBookingsRef
                  .doc(booking.id)
                  .update({
                'user_confirmed': 'yes',
                'updated_at': DateTime.now().toString(),
              });

              Navigator.pop(context);
              Get.snackbar('Success', 'Availability confirmed',
                  backgroundColor: Colors.green, colorText: Colors.white);
            },
            style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFc5a520)),
            child: const Text('Confirm', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }
}

/// Widget to show work-complete panel with before/after images and rating
class _WorkCompletePanel extends StatefulWidget {
  final String tasksManagementId;
  final String serviceProviderId;
  final VoidCallback onRatingSubmitted;

  const _WorkCompletePanel({
    required this.tasksManagementId,
    required this.serviceProviderId,
    required this.onRatingSubmitted,
  });

  @override
  State<_WorkCompletePanel> createState() => _WorkCompletePanelState();
}

class _WorkCompletePanelState extends State<_WorkCompletePanel> {
  final TextEditingController _feedbackController = TextEditingController();
  double _userRating = 0.0;
  bool _isSubmitting = false;

  @override
  void dispose() {
    _feedbackController.dispose();
    super.dispose();
  }

  Future<Map<String, String>> _loadImageUrls() async {
    try {
      // Prefer loading by the exact image document id recorded on tasksManagement.
      // This matches how the main Bookings screen reads images.
      String imageDocId = '';
      try {
        final tmDoc = await FirebaseService.tasksManagementRef
            .doc(widget.tasksManagementId)
            .get();
        imageDocId =
            (tmDoc.data()?['artisan_image_doc_id'] ?? '').toString().trim();
      } catch (_) {
        // Ignore and fall back to query-by-task id
      }

      if (imageDocId.isNotEmpty) {
        final imgDoc =
            await FirebaseService.artisanTaskImages.doc(imageDocId).get();
        final data = imgDoc.data();
        if (imgDoc.exists && data != null) {
          final beforeUrl = (data['before_work'] ?? '').toString().trim();
          final afterUrl = (data['after_work'] ?? '').toString().trim();
          return {
            'before': beforeUrl,
            'after': afterUrl,
          };
        }
      }

      // Fallback: query by task_management_id in the actual collection used by the app.
      final qs = await FirebaseService.artisanTaskImages
          .where('task_management_id', isEqualTo: widget.tasksManagementId)
          .limit(1)
          .get();

      if (qs.docs.isNotEmpty) {
        final data = qs.docs.first.data();
        final beforeUrl = (data['before_work'] ?? '').toString().trim();
        final afterUrl = (data['after_work'] ?? '').toString().trim();
        return {
          'before': beforeUrl,
          'after': afterUrl,
        };
      }

      // Legacy fallback: some environments used a different collection name.
      final legacyQs = await FirebaseFirestore.instance
          .collection('artisan_task_images')
          .where('task_management_id', isEqualTo: widget.tasksManagementId)
          .limit(1)
          .get();
      if (legacyQs.docs.isNotEmpty) {
        final data = legacyQs.docs.first.data();
        final beforeUrl = (data['before_work'] ?? '').toString().trim();
        final afterUrl = (data['after_work'] ?? '').toString().trim();
        return {
          'before': beforeUrl,
          'after': afterUrl,
        };
      }

      debugPrint(
          'No work images found for tasksManagementId=${widget.tasksManagementId} (imageDocId=$imageDocId)');
      return {'before': '', 'after': ''};
    } catch (e) {
      debugPrint('_loadImageUrls error: $e');
      return {'before': '', 'after': ''};
    }
  }

  Future<void> _submitRating() async {
    if (_userRating < 1) {
      Get.snackbar(
        'Rating Required',
        'Please provide a rating before submitting.',
        backgroundColor: Colors.orange,
        colorText: Colors.white,
      );
      return;
    }

    setState(() => _isSubmitting = true);

    try {
      final feedback = _feedbackController.text.trim();

      // 1) Mark task as closed with rating
      await FirebaseService.tasksManagementRef
          .doc(widget.tasksManagementId)
          .update({
        'status': 'closed',
        'user_comment': feedback,
        'rating': _userRating.toString(),
        'completion_date': DateTime.now().toString(),
        'updated_at': DateTime.now().toString(),
      });

      // 2) Update artisan profile with rating and increment job count
      await _updateArtisanRatingAndJobCount(
        serviceProviderId: widget.serviceProviderId,
        newRating: _userRating,
      );

      // 3) Also update futureBooking status if exists
      final tmDoc = await FirebaseService.tasksManagementRef
          .doc(widget.tasksManagementId)
          .get();
      final futureBookingId =
          (tmDoc.data()?['future_booking_id'] ?? '').toString().trim();
      if (futureBookingId.isNotEmpty) {
        await FutureBookingService.futureBookingsRef
            .doc(futureBookingId)
            .update({
          'status': 'closed',
          'updated_at': DateTime.now().toString(),
        });
      }

      // 4) Notify artisan that client marked order as complete
      try {
        final ratingText = _userRating > 0
            ? ' Rating: ${_userRating.toStringAsFixed(1)}/5.'
            : '';
        await FutureBookingService.sendNotificationToArtisan(
          artisanId: widget.serviceProviderId,
          bookingId: futureBookingId.isNotEmpty
              ? futureBookingId
              : widget.tasksManagementId,
          message:
              'Client has marked the order as complete.$ratingText Thank you for your service!',
        );
      } catch (_) {
        // Best-effort
      }

      if (!mounted) return;
      Get.snackbar(
        'Success',
        'Thank you for your feedback!',
        backgroundColor: Colors.green,
        colorText: Colors.white,
      );

      widget.onRatingSubmitted();
    } catch (e) {
      debugPrint('_submitRating error: $e');
      if (!mounted) return;
      Get.snackbar(
        'Error',
        'Could not submit rating. Please try again.',
        backgroundColor: Colors.red,
        colorText: Colors.white,
      );
    } finally {
      if (mounted) {
        setState(() => _isSubmitting = false);
      }
    }
  }

  /// Update artisan profile: add rating to array, recalculate average, increment job count
  Future<void> _updateArtisanRatingAndJobCount({
    required String serviceProviderId,
    required double newRating,
  }) async {
    final spId = serviceProviderId.trim();
    if (spId.isEmpty) return;

    try {
      final spRef =
          FirebaseFirestore.instance.collection('serviceProvider').doc(spId);
      final spDoc = await spRef.get();
      if (!spDoc.exists) {
        debugPrint('Service provider doc not found: $spId');
        return;
      }

      final data = spDoc.data() ?? <String, dynamic>{};

      // Get existing ratings array (or create new)
      final ratingsRaw = data['ratings'];
      List<double> ratings = [];
      if (ratingsRaw is List) {
        ratings = ratingsRaw
            .map((e) {
              if (e is num) return e.toDouble();
              final parsed = double.tryParse(e.toString());
              return parsed;
            })
            .where((e) => e != null)
            .cast<double>()
            .toList();
      }

      // Add new rating
      ratings.add(newRating);

      // Calculate new average
      final avg = ratings.reduce((a, b) => a + b) / ratings.length;

      // Increment job count
      final jobsDone =
          ((data['total_jobs_done'] ?? data['jobs_completed'] ?? 0) is num
                  ? (data['total_jobs_done'] ?? data['jobs_completed'] ?? 0)
                  : int.tryParse(
                      (data['total_jobs_done'] ?? data['jobs_completed'] ?? '0')
                          .toString())) +
              1;

      await spRef.update({
        'ratings': ratings,
        'average_rating': avg,
        'total_jobs_done': jobsDone,
        'jobs_completed': jobsDone, // Some backends use this field
        'updated_at': DateTime.now().toString(),
      });

      debugPrint(
          'Updated artisan $spId: avg=$avg, jobs=$jobsDone, ratings=${ratings.length}');
    } catch (e) {
      debugPrint('_updateArtisanRatingAndJobCount error: $e');
      // Don't throw - rating submission should succeed even if profile update fails
    }
  }

  @override
  Widget build(BuildContext context) {
    return ElevatedButton.icon(
      onPressed: () => _showRatingDialog(context),
      icon: const Icon(Icons.rate_review),
      label: const Text('View Work & Rate Service'),
      style: ElevatedButton.styleFrom(
        backgroundColor: const Color(0xFFc5a520),
        foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      ),
    );
  }

  Future<void> _showRatingDialog(BuildContext context) async {
    final urls = await _loadImageUrls();
    final beforeUrl = urls['before'] ?? '';
    final afterUrl = urls['after'] ?? '';

    // Load AI quality score if available
    int? qualityScore;
    String? qualityRec;
    try {
      final tmDoc = await FirebaseService.tasksManagementRef
          .doc(widget.tasksManagementId).get();
      final d = tmDoc.data() ?? {};
      qualityScore = (d['quality_score'] is num) ? (d['quality_score'] as num).toInt() : null;
      qualityRec = (d['quality_recommendation'] ?? '').toString();
    } catch (_) {}

    if (!context.mounted) return;

    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: Row(
          children: [
            const Icon(Icons.check_circle, color: Colors.green),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Work Complete',
                style: GoogleFonts.roboto(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Before & After Photos:',
                style: GoogleFonts.roboto(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 10),
              // Images
              Row(
                children: [
                  Expanded(
                    child: Column(
                      children: [
                        GestureDetector(
                          onTap: beforeUrl.isNotEmpty
                              ? () => Get.to(
                                  () => AttachmentView(imagePath: beforeUrl))
                              : () => Get.snackbar('No Image',
                                  'Before work photo not available'),
                          child: Container(
                            height: 100,
                            decoration: BoxDecoration(
                              color: Colors.grey.shade200,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: Colors.grey.shade400),
                            ),
                            child: beforeUrl.isNotEmpty
                                ? ClipRRect(
                                    borderRadius: BorderRadius.circular(8),
                                    child: Image.network(
                                      beforeUrl,
                                      fit: BoxFit.cover,
                                      width: double.infinity,
                                      loadingBuilder:
                                          (context, child, progress) {
                                        if (progress == null) return child;
                                        return const Center(
                                          child: CircularProgressIndicator(),
                                        );
                                      },
                                      errorBuilder: (_, __, ___) =>
                                          const Center(
                                        child: Icon(Icons.image_not_supported),
                                      ),
                                    ),
                                  )
                                : const Center(
                                    child: Column(
                                      mainAxisAlignment:
                                          MainAxisAlignment.center,
                                      children: [
                                        Icon(Icons.image_not_supported,
                                            size: 32),
                                        SizedBox(height: 4),
                                        Text('No image',
                                            style: TextStyle(fontSize: 10)),
                                      ],
                                    ),
                                  ),
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text('Before Work',
                            style: GoogleFonts.roboto(fontSize: 11)),
                        if (beforeUrl.isNotEmpty)
                          TextButton.icon(
                            onPressed: () => Get.to(
                                () => AttachmentView(imagePath: beforeUrl)),
                            icon: const Icon(Icons.open_in_new, size: 14),
                            label: const Text('View',
                                style: TextStyle(fontSize: 10)),
                            style: TextButton.styleFrom(
                              padding: const EdgeInsets.all(2),
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      children: [
                        GestureDetector(
                          onTap: afterUrl.isNotEmpty
                              ? () => Get.to(
                                  () => AttachmentView(imagePath: afterUrl))
                              : () => Get.snackbar(
                                  'No Image', 'After work photo not available'),
                          child: Container(
                            height: 100,
                            decoration: BoxDecoration(
                              color: Colors.grey.shade200,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: Colors.grey.shade400),
                            ),
                            child: afterUrl.isNotEmpty
                                ? ClipRRect(
                                    borderRadius: BorderRadius.circular(8),
                                    child: Image.network(
                                      afterUrl,
                                      fit: BoxFit.cover,
                                      width: double.infinity,
                                      loadingBuilder:
                                          (context, child, progress) {
                                        if (progress == null) return child;
                                        return const Center(
                                          child: CircularProgressIndicator(),
                                        );
                                      },
                                      errorBuilder: (_, __, ___) =>
                                          const Center(
                                        child: Icon(Icons.image_not_supported),
                                      ),
                                    ),
                                  )
                                : const Center(
                                    child: Column(
                                      mainAxisAlignment:
                                          MainAxisAlignment.center,
                                      children: [
                                        Icon(Icons.image_not_supported,
                                            size: 32),
                                        SizedBox(height: 4),
                                        Text('No image',
                                            style: TextStyle(fontSize: 10)),
                                      ],
                                    ),
                                  ),
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text('After Work',
                            style: GoogleFonts.roboto(fontSize: 11)),
                        if (afterUrl.isNotEmpty)
                          TextButton.icon(
                            onPressed: () => Get.to(
                                () => AttachmentView(imagePath: afterUrl)),
                            icon: const Icon(Icons.open_in_new, size: 14),
                            label: const Text('View',
                                style: TextStyle(fontSize: 10)),
                            style: TextButton.styleFrom(
                              padding: const EdgeInsets.all(2),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              // ── AI Quality Score Badge ──
              if (qualityScore != null) ...[
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: qualityScore >= 7
                        ? Colors.green.shade50
                        : qualityScore >= 4
                            ? Colors.orange.shade50
                            : Colors.red.shade50,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: qualityScore >= 7
                          ? Colors.green
                          : qualityScore >= 4
                              ? Colors.orange
                              : Colors.red,
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        qualityScore >= 7
                            ? Icons.verified
                            : qualityScore >= 4
                                ? Icons.info_outline
                                : Icons.warning_amber,
                        color: qualityScore >= 7
                            ? Colors.green
                            : qualityScore >= 4
                                ? Colors.orange
                                : Colors.red,
                        size: 20,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'AI Quality Score: $qualityScore/10'
                          '${qualityRec == "auto_approve" ? " — Verified ✓" : qualityRec == "flag_issue" ? " — Review needed" : ""}',
                          style: GoogleFonts.roboto(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
              ],
              const Divider(),
              const SizedBox(height: 8),
              Text(
                'Are you satisfied with the work?',
                style: GoogleFonts.roboto(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                'Rate the service:',
                style: GoogleFonts.roboto(fontSize: 13),
              ),
              const SizedBox(height: 6),
              RatingBar.builder(
                initialRating: _userRating,
                minRating: 1,
                direction: Axis.horizontal,
                itemCount: 5,
                itemSize: 32,
                itemPadding: const EdgeInsets.symmetric(horizontal: 2.0),
                itemBuilder: (context, _) => const Icon(
                  Icons.star,
                  color: Colors.amber,
                ),
                onRatingUpdate: (rating) {
                  setState(() => _userRating = rating);
                },
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _feedbackController,
                maxLines: 3,
                decoration: InputDecoration(
                  labelText: 'Feedback (optional)',
                  labelStyle: GoogleFonts.roboto(fontSize: 12),
                  border: const OutlineInputBorder(),
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              Get.snackbar(
                'Job Not Completed',
                'You can rate the service later when satisfied.',
                backgroundColor: Colors.orange,
                colorText: Colors.white,
              );
            },
            child: const Text('Not Satisfied - Close'),
          ),
          ElevatedButton.icon(
            onPressed: _isSubmitting
                ? null
                : () async {
                    if (_userRating < 1) {
                      Get.snackbar(
                        'Rating Required',
                        'Please provide a rating before submitting.',
                        backgroundColor: Colors.orange,
                        colorText: Colors.white,
                      );
                      return;
                    }
                    await _submitRating();
                    if (context.mounted) {
                      Navigator.pop(context);
                    }
                  },
            icon: _isSubmitting
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Icon(Icons.check_circle),
            label: Text(
                _isSubmitting ? 'Submitting...' : 'Confirm & Complete Job'),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.green,
              foregroundColor: Colors.white,
            ),
          ),
        ],
      ),
    );
  }
}
