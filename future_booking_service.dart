import 'dart:convert';
import 'dart:math';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:maintenanceapp/model/future_booking_model.dart';
import 'package:maintenanceapp/services/backend_fcm_service.dart';
import 'package:maintenanceapp/services/rfq_ai_service.dart';
import 'package:uuid/uuid.dart';

class FutureBookingService {
  static String _canonicalToken(String t) {
    var s = t.trim().toLowerCase();
    if (s.isEmpty) return '';
    s = s.replaceAll(RegExp(r'[^a-z0-9]'), '');
    if (s.isEmpty) return '';

    // Lightweight normalization for common maintenance intents.
    if (s.startsWith('unblock') ||
        s.startsWith('block') ||
        s.startsWith('clog')) {
      return 'unblock';
    }
    if (s.startsWith('toilet') || s == 'loo') return 'toilet';
    if (s.startsWith('drain')) return 'drain';
    if (s.startsWith('sink') || s.startsWith('basin')) return 'sink';
    // Bathtub synonyms: map various forms to a single canonical token 'bath'
    if (s.contains('bathtub') || s.contains('bath') || s.contains('tub')) {
      return 'bath';
    }
    // Installation verbs
    if (s.contains('installation') ||
        s == 'install' ||
        s.startsWith('install')) {
      return 'install';
    }
    if (s.startsWith('geyser') || s.startsWith('heater')) return 'geyser';
    if (s.endsWith('ing') && s.length > 5) s = s.substring(0, s.length - 3);
    if (s.endsWith('ed') && s.length > 4) s = s.substring(0, s.length - 2);
    if (s.endsWith('s') && s.length > 4) s = s.substring(0, s.length - 1);
    return s;
  }

  static Set<String> _tokens(String s) {
    final raw = s
        .toLowerCase()
        .split(RegExp(r'[^a-z0-9]+'))
        .map(_canonicalToken)
        .where((t) => t.isNotEmpty && t.length >= 3)
        .toSet();
    return raw;
  }

  static int _matchScore({required String hint, required String taskName}) {
    final h = hint.trim().toLowerCase();
    final n = taskName.trim().toLowerCase();
    if (h.isEmpty || n.isEmpty) return 0;

    var score = 0;
    if (n.contains(h) || h.contains(n)) score += 12;

    final ht = _tokens(h);
    final nt = _tokens(n);
    final overlap = ht.intersection(nt).length;
    score += overlap * 4;

    // Extra bump for high-signal intents.
    if (ht.contains('unblock') && nt.contains('unblock')) score += 8;
    if (ht.contains('toilet') && nt.contains('toilet')) score += 6;
    if (ht.contains('drain') && nt.contains('drain')) score += 4;
    if (ht.contains('sink') && nt.contains('sink')) score += 4;
    if (ht.contains('geyser') && nt.contains('geyser')) score += 4;

    return score;
  }

  static Future<Map<String, dynamic>?> _inferTaskFromHint({
    required String hint,
    String? categoryId,
  }) async {
    final cleanHint = hint.trim();
    if (cleanHint.isEmpty) return null;

    try {
      Future<Map<String, dynamic>?> pickBest(Query<Map<String, dynamic>> query,
          {required int limit}) async {
        final snap = await query.limit(limit).get();
        if (snap.docs.isEmpty) return null;

        Map<String, dynamic>? best;
        var bestScore = 0;
        for (final d in snap.docs) {
          final data = d.data();
          final name = (data['name'] ?? '').toString().trim();
          if (name.isEmpty) continue;
          final s = _matchScore(hint: cleanHint, taskName: name);
          if (s <= 0) continue;
          if (s > bestScore) {
            bestScore = s;
            final id = (data['id'] ?? '').toString().trim();
            best = {
              'id': id.isNotEmpty ? id : d.id,
              'name': name,
              'cost':
                  _toAmount(data['cost'] ?? data['price'] ?? data['amount']),
            };
          }
        }
        return best;
      }

      final tasks = FirebaseFirestore.instance.collection('tasks');
      final cId = (categoryId ?? '').trim();

      // First try within the category (when provided).
      if (cId.isNotEmpty) {
        final bestInCategory = await pickBest(
          tasks.where('categoryId', isEqualTo: cId),
          limit: 800,
        );
        if (bestInCategory != null) return bestInCategory;
      }

      // Fallback: scan a bounded slice of all tasks.
      return await pickBest(tasks, limit: 1500);
    } catch (_) {
      return null;
    }
  }

  static double? _toAmount(dynamic v) {
    if (v == null) return null;
    if (v is num) return v.toDouble();
    final s = v.toString().trim();
    if (s.isEmpty) return null;
    final cleaned = s.replaceAll(RegExp(r'[^0-9.\-]'), '');
    return double.tryParse(cleaned);
  }

  static Future<double?> _resolveTaskCostFromTasksCollection(
    String taskId,
  ) async {
    final t = taskId.trim();
    if (t.isEmpty) return null;

    try {
      final q = await FirebaseFirestore.instance
          .collection('tasks')
          .where('id', isEqualTo: t)
          .limit(1)
          .get();
      if (q.docs.isNotEmpty) {
        final data = q.docs.first.data();
        final amount = _toAmount(
          data['cost'] ?? data['price'] ?? data['amount'] ?? data['unit_price'],
        );
        if (amount != null && amount > 0) return amount;
      }
    } catch (_) {}

    // Fallback: treat taskId as doc id.
    try {
      final doc =
          await FirebaseFirestore.instance.collection('tasks').doc(t).get();
      if (doc.exists) {
        final data = doc.data() ?? <String, dynamic>{};
        final amount = _toAmount(
          data['cost'] ?? data['price'] ?? data['amount'] ?? data['unit_price'],
        );
        if (amount != null && amount > 0) return amount;
      }
    } catch (_) {}

    return null;
  }

  static void _dispatchLog(String message) {
    // Use print (not debugPrint) so it always shows in release logs.
    // Keep ASCII-only to avoid terminal encoding issues.
    print('[dispatch] $message');
  }

  static final futureBookingsRef =
      FirebaseFirestore.instance.collection('futureBookings');
  static final tasksManagementRef =
      FirebaseFirestore.instance.collection('tasksManagement');
  static final transactionLogsRef =
      FirebaseFirestore.instance.collection('transactionLogs');
    static final taskRef = FirebaseFirestore.instance.collection('tasks');
  static final serviceProviderRef =
      FirebaseFirestore.instance.collection('serviceProvider');
  static final userTasksRef =
      FirebaseFirestore.instance.collection('userTasks');
  static final userRef = FirebaseFirestore.instance.collection('users');
  static final notificationsRef =
      FirebaseFirestore.instance.collection('notifications');
  static final adminRef = FirebaseFirestore.instance.collection('admin');

  static String _shortId(String id, {int length = 8}) {
    final trimmed = id.trim();
    if (trimmed.isEmpty) return '';
    final safeLen = length.clamp(4, 32);
    return trimmed.length <= safeLen
        ? trimmed.toUpperCase()
        : trimmed.substring(0, safeLen).toUpperCase();
  }

  /// Stable order number derived from bookingId.
  ///
  /// This remains consistent even if the underlying tasksManagement id changes
  /// due to reassignment.
  static String generateOrderNo(String bookingId) {
    final short = _shortId(bookingId);
    if (short.isEmpty) return '';
    return 'ORD-$short';
  }

  /// Stable RFQ number derived from bookingId.
  static String generateRfqNo(String bookingId) {
    final short = _shortId(bookingId);
    if (short.isEmpty) return '';
    return 'RFQ-$short';
  }

  static bool _isYes(dynamic v) {
    if (v == null) return false;
    if (v is bool) return v;
    final s = v.toString().trim().toLowerCase();
    return s == 'yes' || s == 'y' || s == '1' || s == 'true';
  }

  static double? _toDouble(dynamic v) {
    if (v == null) return null;
    if (v is num) return v.toDouble();
    final s = v.toString().trim();
    if (s.isEmpty) return null;
    // tolerate currency symbols
    final cleaned = s.replaceAll(RegExp(r'[^0-9.\-]'), '');
    return double.tryParse(cleaned);
  }

  static String _moneyString(double v) {
    // Keep wallet balances as strings (legacy schema) but normalized.
    return v.toStringAsFixed(2);
  }

  static Future<void> _enrichProfitFromTasksManagement({
    required String txId,
    required String tasksManagementId,
    required double fallbackClientTotal,
  }) async {
    final tmId = tasksManagementId.trim();
    final id = txId.trim();
    if (tmId.isEmpty || id.isEmpty) return;

    try {
      final jobsSnap = await tasksManagementRef.doc(tmId).collection('jobs').get();
      final jobs = jobsSnap.docs
          .map((d) => (d.data() as Map<String, dynamic>? ?? <String, dynamic>{}))
          .toList();

      double clientTotal = fallbackClientTotal;
      double outsourcedTotal = 0.0;
      int lineItemsCount = 0;
      if (jobs.isNotEmpty) {
        lineItemsCount = jobs.length;
        clientTotal = 0.0;

        final taskIds = <String>{};
        for (final j in jobs) {
          final tid = (j['task_id'] ?? j['taskId'] ?? j['task'] ?? '').toString().trim();
          if (tid.isNotEmpty) taskIds.add(tid);
        }

        final ratesByTaskId = <String, Map<String, double>>{};
        final taskIdList = taskIds.toList();
        for (var i = 0; i < taskIdList.length; i += 10) {
          final chunk = taskIdList.sublist(i, (i + 10) > taskIdList.length ? taskIdList.length : (i + 10));
          if (chunk.isEmpty) continue;

          final snap = await taskRef.where('id', whereIn: chunk).get();
          for (final doc in snap.docs) {
            final data = (doc.data() as Map<String, dynamic>? ?? <String, dynamic>{});
            final id = (data['id'] ?? doc.id).toString().trim();
            if (id.isEmpty) continue;

            final clientRate = _toDouble(data['clientRate'] ?? data['client_rate'] ?? data['cost'] ?? data['price']) ?? 0.0;
            final outsourcedRate = _toDouble(data['outsourcedRate'] ?? data['outsourced_rate'] ?? data['outsourced_cost']) ?? 0.0;
            ratesByTaskId[id] = {
              'clientRate': clientRate,
              'outsourcedRate': outsourcedRate,
            };
          }
        }

        for (final j in jobs) {
          final jobCost = _toDouble(j['cost']) ?? 0.0;
          final area = _toDouble(j['area']) ?? 0.0;
          clientTotal += jobCost;

          final tid = (j['task_id'] ?? j['taskId'] ?? j['task'] ?? '').toString().trim();
          final rates = ratesByTaskId[tid];
          if (rates == null) continue;

          final outsourcedRate = rates['outsourcedRate'] ?? 0.0;
          if (outsourcedRate <= 0) continue;
          outsourcedTotal += (area > 0) ? (outsourcedRate * area) : outsourcedRate;
        }
      }

      final profit = clientTotal - outsourcedTotal;
      final profitMarginPercent = clientTotal > 0 ? (profit / clientTotal) * 100.0 : 0.0;

      await transactionLogsRef.doc(id).set({
        'client_total': _moneyString(clientTotal),
        'outsourced_total': _moneyString(outsourcedTotal),
        'profit': _moneyString(profit),
        'profit_margin_percent': profitMarginPercent.toStringAsFixed(2),
        'line_items_count': lineItemsCount,
        'schema_version': 2,
      }, SetOptions(merge: true));
    } catch (e) {
      debugPrint('_enrichProfitFromTasksManagement error: $e');
    }
  }

  /// Deduct wallet immediately once an artisan confirms a booking.
  ///
  /// This is intentionally idempotent (safe to call multiple times).
  static Future<bool> deductWalletOnBookingConfirmation({
    required String bookingId,
  }) async {
    final id = bookingId.trim();
    if (id.isEmpty) return false;

    final bookingDocRef = futureBookingsRef.doc(id);
    final txId = const Uuid().v4();
    final now = DateTime.now().toString();

    String tasksManagementIdForEnrichment = '';
    double amountForEnrichment = 0.0;

    try {
      final ok = await FirebaseFirestore.instance.runTransaction((tx) async {
        final bookingSnap = await tx.get(bookingDocRef);
        if (!bookingSnap.exists) return false;

        final bookingData = bookingSnap.data() ?? <String, dynamic>{};

        // Only act on real (non-RFQ) bookings.
        if (_isYes(bookingData['is_rfq'])) return false;

        final alreadyDeducted = _isYes(bookingData['wallet_deducted']) ||
            bookingData['wallet_deducted'] == true;
        if (alreadyDeducted) return true;

        final status =
            (bookingData['status'] ?? '').toString().trim().toLowerCase();
        // The booking becomes payable once the artisan has accepted. Some flows
        // use 'confirmed', others use 'pending_payment'.
        if (status != 'confirmed' && status != 'pending_payment') {
          return false;
        }

        final userId = (bookingData['user_id'] ?? '').toString().trim();
        if (userId.isEmpty) return false;

        final amount = _toDouble(bookingData['wallet_deduct_amount']) ??
            _toDouble(bookingData['cost']);
        if (amount == null || amount <= 0) {
          tx.update(bookingDocRef, {
            'wallet_deducted': 'no',
            'wallet_deduct_status': 'no_amount',
            'wallet_deduct_attempted_at': now,
          });
          return false;
        }

        final userDocRef = userRef.doc(userId);
        final userSnap = await tx.get(userDocRef);
        final userData = userSnap.data() ?? <String, dynamic>{};

        final currentBalance = _toDouble(userData['balance']) ?? 0.0;
        if (currentBalance < amount) {
          tx.update(bookingDocRef, {
            'wallet_deducted': 'no',
            'wallet_deduct_status': 'insufficient_funds',
            'wallet_deduct_attempted_at': now,
            'wallet_deduct_amount': amount,
          });
          return false;
        }

        final newBalance = currentBalance - amount;

        amountForEnrichment = amount;

        tx.update(userDocRef, {
          'balance': _moneyString(newBalance),
        });

        tx.update(bookingDocRef, {
          'wallet_deducted': 'yes',
          'wallet_deduct_status': 'deducted',
          'wallet_deduct_amount': amount,
          'wallet_deducted_at': now,
          'wallet_deduct_txn_id': txId,
          'payment_status': 'paid',
          'payment_method': 'wallet',
          'payment_paid_at': now,
          // Once paid, treat the booking as accepted for both apps.
          'status': 'accepted',
          'wallet_refunded': 'no',
          'updated_at': now,
        });

        // Keep tasksManagement in sync so the user isn't prompted to pay again.
        final tasksManagementId =
            (bookingData['tasks_management_id'] ?? '').toString().trim();
        tasksManagementIdForEnrichment = tasksManagementId;
        if (tasksManagementId.isNotEmpty) {
          tx.set(
            tasksManagementRef.doc(tasksManagementId),
            {
              'payment_status': 'paid',
              'payment_method': 'wallet',
              'payment': 'wallet',
              'status': 'accepted',
              'updated_at': now,
            },
            SetOptions(merge: true),
          );
        }

        tx.set(transactionLogsRef.doc(txId), {
          'id': txId,
          'amount': _moneyString(amount),
          'transaction_at': now,
          'status': 'success',
          'booking_id': id,
          'tasks_management_id': tasksManagementId,
          'task_id': (bookingData['task_id'] ?? '').toString(),
          'task_name': (bookingData['task_name'] ?? '').toString(),
          'transaction_by': userId,
          'user_id': userId,
          'type': 'wallet',
          'subtype': 'future_booking_hold',
          'direction': 'out',
          'cash_movement': false,
          'profit': '0.00',
          'schema_version': 2,
          'balance': _moneyString(newBalance),
          'balance_after': _moneyString(newBalance),
          'previous_balance': _moneyString(currentBalance),
        });

        return true;
      });

      if (ok && tasksManagementIdForEnrichment.isNotEmpty) {
        // Best-effort enrichment; never block the user flow.
        () async {
          await _enrichProfitFromTasksManagement(
            txId: txId,
            tasksManagementId: tasksManagementIdForEnrichment,
            fallbackClientTotal: amountForEnrichment,
          );
        }();
      }

      return ok;
    } catch (e) {
      debugPrint('deductWalletOnBookingConfirmation error: $e');
      return false;
    }
  }

  /// Refund wallet balance when a booking is cancelled or deemed overdue.
  ///
  /// Idempotent: will not double-refund.
  static Future<bool> refundWalletForBooking({
    required String bookingId,
    required String reason,
  }) async {
    final id = bookingId.trim();
    if (id.isEmpty) return false;

    final bookingDocRef = futureBookingsRef.doc(id);
    final txId = const Uuid().v4();
    final now = DateTime.now().toString();

    try {
      return await FirebaseFirestore.instance.runTransaction((tx) async {
        final bookingSnap = await tx.get(bookingDocRef);
        if (!bookingSnap.exists) return false;

        final bookingData = bookingSnap.data() ?? <String, dynamic>{};

        final wasDeducted = _isYes(bookingData['wallet_deducted']) ||
            bookingData['wallet_deducted'] == true;
        if (!wasDeducted) return false;

        final alreadyRefunded = _isYes(bookingData['wallet_refunded']) ||
            bookingData['wallet_refunded'] == true;
        if (alreadyRefunded) return true;

        final userId = (bookingData['user_id'] ?? '').toString().trim();
        if (userId.isEmpty) return false;

        final amount = _toDouble(bookingData['wallet_deduct_amount']) ??
            _toDouble(bookingData['wallet_deducted_amount']) ??
            _toDouble(bookingData['wallet_deduct_amount']) ??
            _toDouble(bookingData['cost']);
        if (amount == null || amount <= 0) return false;

        final userDocRef = userRef.doc(userId);
        final userSnap = await tx.get(userDocRef);
        final userData = userSnap.data() ?? <String, dynamic>{};
        final currentBalance = _toDouble(userData['balance']) ?? 0.0;

        final newBalance = currentBalance + amount;
        tx.update(userDocRef, {
          'balance': _moneyString(newBalance),
        });

        tx.update(bookingDocRef, {
          'wallet_refunded': 'yes',
          'wallet_refund_reason': reason,
          'wallet_refund_amount': amount,
          'wallet_refunded_at': now,
          'wallet_refund_txn_id': txId,
          'updated_at': now,
        });

        tx.set(transactionLogsRef.doc(txId), {
          'id': txId,
          'amount': _moneyString(amount),
          'transaction_at': now,
          'status': 'success',
          'booking_id': id,
          'tasks_management_id': (bookingData['tasks_management_id'] ?? '').toString().trim(),
          'task_id': (bookingData['task_id'] ?? '').toString(),
          'task_name': (bookingData['task_name'] ?? '').toString(),
          'transaction_by': userId,
          'user_id': userId,
          'type': 'wallet',
          'subtype': 'future_booking_refund',
          'direction': 'out',
          'cash_movement': false,
          'profit': '0.00',
          'schema_version': 2,
          'reason': reason,
          'balance': _moneyString(newBalance),
          'balance_after': _moneyString(newBalance),
          'previous_balance': _moneyString(currentBalance),
        });

        return true;
      });
    } catch (e) {
      debugPrint('refundWalletForBooking error: $e');
      return false;
    }
  }

  /// Client cancels a booking.
  ///
  /// This is intentionally idempotent and safe to call multiple times.
  /// It updates the booking status, closes the bridged tasksManagement doc (if any),
  /// and performs a best-effort wallet refund if a wallet hold was deducted.
  static Future<bool> clientCancelBooking({
    required String bookingId,
    String reason = 'client_cancelled',
  }) async {
    final id = bookingId.trim();
    if (id.isEmpty) return false;

    try {
      final now = DateTime.now().toString();
      final snap = await futureBookingsRef.doc(id).get();
      if (!snap.exists) return false;
      final data = snap.data() ?? <String, dynamic>{};

      final status = (data['status'] ?? '').toString().trim().toLowerCase();
      if (status == 'cancelled' || status == 'canceled' || status == 'closed') {
        return true;
      }

      final tmId = (data['tasks_management_id'] ?? '').toString().trim();

      await futureBookingsRef.doc(id).set(
        {
          'status': 'cancelled',
          'cancelled_by_client': 'yes',
          'cancel_reason': reason,
          'cancelled_by_client_at': now,
          'updated_at': now,
        },
        SetOptions(merge: true),
      );

      if (tmId.isNotEmpty) {
        try {
          await tasksManagementRef.doc(tmId).set(
            {
              'status': 'closed',
              'closed_date': now,
              'closed_reason': 'client_cancelled',
              'updated_at': now,
            },
            SetOptions(merge: true),
          );
        } catch (_) {
          // Best-effort: booking cancellation must still succeed.
        }
      }

      // Best-effort refund for wallet holds.
      () async {
        await refundWalletForBooking(
          bookingId: id,
          reason: 'client_cancelled:$reason',
        );
      }();

      final userId = (data['user_id'] ?? '').toString().trim();
      final artisanId = (data['service_provider_id'] ?? '').toString().trim();

      if (userId.isNotEmpty) {
        try {
          await sendNotificationToUser(
            userId: userId,
            title: 'Booking cancelled',
            type: 'future_booking_cancelled',
            message: 'Your booking has been cancelled.',
            data: {
              'booking_id': id,
              'tasks_management_id': tmId,
            },
          );
        } catch (_) {}
      }

      if (artisanId.isNotEmpty && artisanId.toLowerCase() != 'admin') {
        try {
          await sendNotificationToArtisan(
            artisanId: artisanId,
            bookingId: id,
            message: 'A client cancelled the booking.',
            isReassignment: false,
          );
        } catch (_) {}
      }

      return true;
    } catch (e) {
      debugPrint('clientCancelBooking error: $e');
      return false;
    }
  }

  /// Reschedule a booking (client or admin initiated).
  ///
  /// Updates both futureBookings and the bridged tasksManagement doc (if any).
  /// This does not force a status change; it simply updates the schedule.
  static Future<bool> rescheduleBooking({
    required String bookingId,
    required String scheduledDate,
    required String scheduledTime,
    String requestedBy = 'client',
    String reason = 'rescheduled',
  }) async {
    final id = bookingId.trim();
    final date = scheduledDate.trim();
    final time = scheduledTime.trim();
    if (id.isEmpty || date.isEmpty || time.isEmpty) return false;

    try {
      final now = DateTime.now().toString();
      final snap = await futureBookingsRef.doc(id).get();
      if (!snap.exists) return false;
      final data = snap.data() ?? <String, dynamic>{};

      final tmId = (data['tasks_management_id'] ?? '').toString().trim();
      final previousDate = (data['scheduled_date'] ?? '').toString().trim();
      final previousTime = (data['scheduled_time'] ?? '').toString().trim();

      await futureBookingsRef.doc(id).set(
        {
          'scheduled_date': date,
          'scheduled_time': time,
          'rescheduled': 'yes',
          'rescheduled_at': now,
          'rescheduled_by': requestedBy,
          'rescheduled_reason': reason,
          'previous_scheduled_date': previousDate,
          'previous_scheduled_time': previousTime,
          'updated_at': now,
        },
        SetOptions(merge: true),
      );

      if (tmId.isNotEmpty) {
        try {
          await tasksManagementRef.doc(tmId).set(
            {
              'scheduled_date': date,
              'scheduled_time': time,
              'updated_at': now,
            },
            SetOptions(merge: true),
          );
        } catch (_) {
          // Best-effort.
        }
      }

      final userId = (data['user_id'] ?? '').toString().trim();
      final artisanId = (data['service_provider_id'] ?? '').toString().trim();

      if (userId.isNotEmpty) {
        try {
          await sendNotificationToUser(
            userId: userId,
            title: 'Booking rescheduled',
            type: 'future_booking_rescheduled',
            message: 'Your booking has been rescheduled to $date at $time.',
            data: {
              'booking_id': id,
              'tasks_management_id': tmId,
            },
          );
        } catch (_) {}
      }

      if (artisanId.isNotEmpty && artisanId.toLowerCase() != 'admin') {
        try {
          await sendNotificationToArtisan(
            artisanId: artisanId,
            bookingId: id,
            message:
                'Booking was rescheduled to $date at $time (was $previousDate $previousTime).',
            isReassignment: false,
          );
        } catch (_) {}
      }

      return true;
    } catch (e) {
      debugPrint('rescheduleBooking error: $e');
      return false;
    }
  }

  static Future<void> _maybeRefundOverdueBooking({
    required Map<String, dynamic> bookingData,
    required FutureBookingModel booking,
    required DateTime scheduledDateTime,
    required DateTime now,
  }) async {
    try {
      // Only consider overdue bookings one day after scheduled time.
      if (now.isBefore(scheduledDateTime.add(const Duration(days: 1)))) return;

      final status =
          (bookingData['status'] ?? '').toString().trim().toLowerCase();
      if (status == 'completed') return;

      final wasDeducted = _isYes(bookingData['wallet_deducted']) ||
          bookingData['wallet_deducted'] == true;
      if (!wasDeducted) return;

      final alreadyRefunded = _isYes(bookingData['wallet_refunded']) ||
          bookingData['wallet_refunded'] == true;
      if (alreadyRefunded) return;

      // If there is evidence of completion or before/after images, do not refund.
      final tmId = (bookingData['tasks_management_id'] ?? '').toString().trim();
      if (tmId.isNotEmpty) {
        try {
          final tmSnap = await tasksManagementRef.doc(tmId).get();
          if (tmSnap.exists) {
            final tmData = tmSnap.data() ?? <String, dynamic>{};
            final tmStatus =
                (tmData['status'] ?? '').toString().trim().toLowerCase();
            if (tmStatus == 'completed') return;
            final artisanImages =
                (tmData['artisan_images'] ?? '').toString().trim();
            if (artisanImages.isNotEmpty && artisanImages != '0') return;
            final completionDate =
                (tmData['completion_date'] ?? tmData['completionDate'] ?? '')
                    .toString()
                    .trim();
            if (completionDate.isNotEmpty) return;
          }
        } catch (_) {
          // If we cannot read TM doc, do not refund automatically.
          return;
        }
      }

      await refundWalletForBooking(
        bookingId: booking.id ?? '',
        reason: 'overdue_no_completion_24h',
      );
    } catch (e) {
      debugPrint('_maybeRefundOverdueBooking error: $e');
    }
  }

  static String _providerListenerIdFromProviderDoc(
    DocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    // IMPORTANT: The app consistently queries by the provider document id
    // (e.g. `.where('service_provider_id', isEqualTo: appController.userId.value)`
    // and `serviceProviderRef.doc(serviceProviderId)`), so prefer `doc.id`.
    final docId = doc.id.toString().trim();
    if (docId.isNotEmpty) return docId;

    final data = doc.data();
    if (data == null) return doc.id;
    const keys = <String>['user_id', 'uid', 'userId', 'docId', 'provider_id'];
    for (final k in keys) {
      final v = (data[k] ?? '').toString().trim();
      if (v.isNotEmpty) return v;
    }
    return doc.id;
  }

  static Future<String?> _createTasksManagementRequestForFutureBooking({
    required String bookingId,
    required String userId,
    required String artisanId,
    required String taskId,
    required List<String> jobIds,
    required Map<String, double> taskCostsById,
    required String scheduledDate,
    required String scheduledTime,
    required bool serviceOnCurrentLocation,
    required String providedAddress,
    required String otherLat,
    required String otherLng,
    required String userLat,
    required String userLng,
    required List<String> workImageUrls,
    required String description,
  }) async {
    try {
      var effectiveTaskId = taskId.trim();
      var effectiveJobIds = jobIds.where((id) => id.trim().isNotEmpty).toList();

      // Keep order numbers consistent across futureBookings and tasksManagement.
      // If the booking already has an order_no (numeric), always reuse it (especially for reassignments).
      // If it's missing or non-numeric, allocate a numeric one and write it back.
      String? bookingOrderNo;
      try {
        final snap = await futureBookingsRef.doc(bookingId).get();
        final data = snap.data();
        final raw = (data?['order_no'] ?? '').toString().trim();
        if (raw.isNotEmpty) {
          bookingOrderNo = raw;
        }
      } catch (_) {
        // ignore: fall back to generated/counter order number
      }

      // If caller didn't provide job ids, attempt to infer from description.
      if (effectiveJobIds.isEmpty) {
        final inferred =
            await _inferTaskFromHint(hint: description, categoryId: null);
        final inferredId = (inferred?['id'] ?? '').toString().trim();
        final inferredCost = inferred?['cost'] is num
            ? (inferred?['cost'] as num).toDouble()
            : double.tryParse((inferred?['cost'] ?? '').toString());

        if (inferredId.isNotEmpty) {
          effectiveJobIds = <String>[inferredId];
          if (effectiveTaskId.isEmpty) {
            effectiveTaskId = inferredId;
          }
          _dispatchLog(
              'inferred task during tasksManagement create: id=$inferredId cost=${inferredCost ?? 0}');
        }
      }

      // If we have a task id but no job ids, treat task id as the sole job.
      if (effectiveJobIds.isEmpty && effectiveTaskId.isNotEmpty) {
        effectiveJobIds = <String>[effectiveTaskId];
      }

      final providerDoc = await _getServiceProviderDocByAnyId(artisanId);
      // Be resilient: even if provider doc can't be fetched (rules / legacy ids),
      // still create the request using the assigned artisan id.
      final providerListenerId = (providerDoc != null && providerDoc.exists)
          ? _providerListenerIdFromProviderDoc(providerDoc)
          : artisanId.trim();
      if (providerListenerId.trim().isEmpty) return null;
      final String tmId = const Uuid().v4();
      final now = DateTime.now().toString();
      final firstImage = workImageUrls.isNotEmpty ? workImageUrls.first : null;
      final secondImage = workImageUrls.length >= 2 ? workImageUrls[1] : null;

      // Generate a simple sequential numeric order number for artisan/client display.
      // This uses the same counter doc used by the main app order flow.
      // NOTE: We only allocate a new sequence if the booking does not already have a numeric order_no.
      final FirebaseFirestore fireStore = FirebaseFirestore.instance;
      final DocumentReference<Map<String, dynamic>> counterRef =
          fireStore.collection('metadata').doc('counters');
      int? orderSeq;

      final hasNumericOrderNo = bookingOrderNo != null &&
          RegExp(r'^\d+$').hasMatch(bookingOrderNo.trim());

      if (!hasNumericOrderNo) {
        try {
          await fireStore.runTransaction((tx) async {
            final snapshot = await tx.get(counterRef);
            int current = 0;
            if (snapshot.exists) {
              final data = snapshot.data();
              final taskCounter =
                  data?['taskManagementCounter'] as Map<String, dynamic>?;
              if (taskCounter != null && taskCounter['nextOrderNo'] != null) {
                final raw = taskCounter['nextOrderNo'];
                if (raw is int) {
                  current = raw;
                } else {
                  current = int.tryParse(raw.toString()) ?? 0;
                }
              }
            }
            final next = current + 1;
            tx.set(
                counterRef,
                {
                  'taskManagementCounter': {
                    'nextOrderNo': next,
                  },
                },
                SetOptions(merge: true));
            orderSeq = next;
          });
        } catch (_) {
          orderSeq = null;
        }
      }

      final resolvedOrderNo = hasNumericOrderNo
          ? bookingOrderNo.trim()
          : (orderSeq != null
              ? orderSeq.toString()
              : generateOrderNo(bookingId));

      // Prefer the best-known address string for display/logs.
      // For current location flows, callers may pass a reverse-geocoded address.
      final trimmedProvided = providedAddress.trim();
      final effectiveAddress = trimmedProvided.isNotEmpty
          ? trimmedProvided
          : (serviceOnCurrentLocation ? 'Client current location' : 'N/A');

      // Store the actual coordinates: if current location, use userLat/userLng; otherwise use otherLat/otherLng
      final effectiveLat = serviceOnCurrentLocation ? userLat : otherLat;
      final effectiveLng = serviceOnCurrentLocation ? userLng : otherLng;

      final resolvedTaskCosts = Map<String, double>.from(taskCostsById);
      for (final jobTaskId in effectiveJobIds) {
        final current = resolvedTaskCosts[jobTaskId] ?? 0.0;
        if (current > 0) continue;
        final fetched = await _resolveTaskCostFromTasksCollection(jobTaskId);
        if (fetched != null && fetched > 0) {
          resolvedTaskCosts[jobTaskId] = fetched;
        }
      }

      final totalCost = resolvedTaskCosts.values.fold<double>(
        0.0,
        (sum, cost) => sum + cost,
      );

      await tasksManagementRef.doc(tmId).set({
        'id': tmId,
        // Keep consistent with the linked futureBookings order_no.
        'order_no': resolvedOrderNo,
        'order_seq': orderSeq,
        'accept': '',
        'status': 'pending',
        'user_id': userId,
        'service_provider_id': providerListenerId,
        'task_id': effectiveTaskId,
        'cost': totalCost > 0 ? totalCost.toStringAsFixed(2) : 'TBD',
        'payment': '',
        'payment_status': '',
        'rating': '',
        'fee': '',
        'area': '',
        'artisan_images': '0',
        'artisan_image_doc_id': '',
        'attachment': firstImage ?? '',
        'additional_attachment': secondImage ?? '',
        // Preserve all client-uploaded images for the artisan.
        'image_urls': workImageUrls,
        'additional_description': '',
        'creation_date': now,
        'updated_at': now,
        'updated_by': userId,
        'description': description,
        'service_on_location': serviceOnCurrentLocation ? 'yes' : 'no',
        'provided_address': effectiveAddress,
        'other_lat': effectiveLat,
        'other_lng': effectiveLng,
        // Bridge metadata
        'source': 'future_booking',
        'future_booking_id': bookingId,
        'scheduled_date': scheduledDate,
        'scheduled_time': scheduledTime,
      });

      // Ensure futureBookings uses the same (numeric) order number as tasksManagement.
      if (!hasNumericOrderNo || bookingOrderNo.trim() != resolvedOrderNo) {
        try {
          await futureBookingsRef.doc(bookingId).set(
            {
              'order_no': resolvedOrderNo,
            },
            SetOptions(merge: true),
          );
        } catch (_) {
          // Non-fatal.
        }
      }
      for (final jobTaskId in effectiveJobIds) {
        final jobDocId = const Uuid().v4();
        final jobCost = resolvedTaskCosts[jobTaskId] ?? 0.0;
        await tasksManagementRef
            .doc(tmId)
            .collection('jobs')
            .doc(jobDocId)
            .set({
          'id': jobDocId,
          'task_id': jobTaskId,
          'height': '',
          'width': '',
          'area': '',
          'cost': jobCost > 0 ? jobCost.toStringAsFixed(2) : '0',
          'description': description,
          'image': firstImage,
        });
      }

      return tmId;
    } catch (e) {
      debugPrint(
          'Error creating tasksManagement bridge for booking=$bookingId: $e');
      return null;
    }
  }

  static Future<String?> resolveOrCreateTasksManagementIdForBooking({
    required String bookingId,
  }) async {
    final id = bookingId.trim();
    if (id.isEmpty) return null;

    try {
      final bookingSnap = await futureBookingsRef.doc(id).get();
      if (!bookingSnap.exists) return null;
      final data = bookingSnap.data() ?? <String, dynamic>{};

      final existingTmId =
          (data['tasks_management_id'] ?? '').toString().trim();
      if (existingTmId.isNotEmpty) {
        try {
          final tmSnap = await tasksManagementRef.doc(existingTmId).get();
          if (tmSnap.exists) {
            final tmData = tmSnap.data() ?? <String, dynamic>{};
            final tmOrderNo = (tmData['order_no'] ?? '').toString().trim();
            if (tmOrderNo.isNotEmpty && RegExp(r'^\d+$').hasMatch(tmOrderNo)) {
              await futureBookingsRef.doc(id).set(
                {
                  'order_no': tmOrderNo,
                },
                SetOptions(merge: true),
              );
            }
            return existingTmId;
          }
        } catch (_) {
          // fall through
        }
      }

      // Try to find an existing tasksManagement doc by bridge metadata.
      try {
        final qs = await tasksManagementRef
            .where('source', isEqualTo: 'future_booking')
            .where('future_booking_id', isEqualTo: id)
            .limit(1)
            .get();
        if (qs.docs.isNotEmpty) {
          final tmId = qs.docs.first.id;
          try {
            final tmData = qs.docs.first.data() as Map<String, dynamic>?;
            final tmOrderNo = (tmData?['order_no'] ?? '').toString().trim();
            final patch = <String, dynamic>{
              'tasks_management_id': tmId,
            };
            if (tmOrderNo.isNotEmpty && RegExp(r'^\d+$').hasMatch(tmOrderNo)) {
              patch['order_no'] = tmOrderNo;
            }
            await futureBookingsRef.doc(id).set(patch, SetOptions(merge: true));
          } catch (_) {
            await futureBookingsRef.doc(id).set(
              {
                'tasks_management_id': tmId,
              },
              SetOptions(merge: true),
            );
          }
          return tmId;
        }
      } catch (_) {
        // fall through
      }

      // Create a new bridge doc.
      final userId = (data['user_id'] ?? '').toString().trim();
      final artisanId = (data['service_provider_id'] ?? '').toString().trim();
      if (userId.isEmpty || artisanId.isEmpty) return null;

      final tmId = await _createTasksManagementRequestForFutureBooking(
        bookingId: id,
        userId: userId,
        artisanId: artisanId,
        taskId: (data['task_id'] ?? '').toString(),
        jobIds: ((data['job_ids'] ?? data['jobIds']) as List?)
                ?.map((e) => e.toString())
                .toList() ??
            const <String>[],
        taskCostsById: const <String, double>{},
        scheduledDate: (data['scheduled_date'] ?? '').toString(),
        scheduledTime: (data['scheduled_time'] ?? '').toString(),
        serviceOnCurrentLocation: (data['is_service_on_current_location'] ??
                    data['isServiceOnCurrentLocation'] ??
                    'no')
                .toString()
                .trim()
                .toLowerCase() ==
            'yes',
        providedAddress:
            (data['user_provided_address'] ?? data['userProvidedAddress'] ?? '')
                .toString(),
        otherLat: (data['other_lat'] ?? '').toString(),
        otherLng: (data['other_lng'] ?? '').toString(),
        userLat: (data['user_lat'] ?? '').toString(),
        userLng: (data['user_lng'] ?? '').toString(),
        workImageUrls: ((data['work_images'] ?? data['workImages']) as List?)
                ?.map((e) => e.toString())
                .toList() ??
            const <String>[],
        description: (data['description'] ?? '').toString(),
      );

      if (tmId != null && tmId.trim().isNotEmpty) {
        await futureBookingsRef.doc(id).set(
          {
            'tasks_management_id': tmId,
          },
          SetOptions(merge: true),
        );
      }

      return (tmId ?? '').trim().isEmpty ? null : tmId!.trim();
    } catch (e) {
      debugPrint('resolveOrCreateTasksManagementIdForBooking error: $e');
      return null;
    }
  }

  /// Create a future booking and send the same notifications as the manual flow.
  ///
  /// This is the single source of truth used by BOTH:
  /// - manual UI flow (CreateFutureBookingScreen)
  /// - AI flow (AIAgentService)
  ///
  /// Returns a map containing:
  /// - bookingId: String
  /// - isRFQ: bool
  /// - assignedArtisanId: String?
  static Future<Map<String, dynamic>> createBookingAndNotify({
    required String userId,
    required List<String> jobIds,
    required Map<String, String> taskNamesById,
    required Map<String, double> taskCostsById,
    required String scheduledDate, // yyyy-MM-dd
    required String scheduledTime, // HH:mm:ss
    required bool serviceOnCurrentLocation,
    required String userLat,
    required String userLng,
    required String providedAddress,
    required String otherLat,
    required String otherLng,
    required List<String> workImageUrls,
    required String description,
    required String? categoryId,
    required String? categoryName,
    required String materialsResponsibility, // 'client' | 'artisan'
    Map<String, dynamic>? aiQuote,
    bool isRFQRequested = false,
    String rfqReason = '',
    String createdBy = 'manual',
    String? aiSessionId,
    String? aiTranscript,
  }) async {
    final String bookingId = const Uuid().v4();
    final hasPhotos = workImageUrls.isNotEmpty;

    final effectiveTaskNamesById = Map<String, String>.from(taskNamesById);
    final effectiveTaskCostsById = Map<String, double>.from(taskCostsById);
    var effectiveJobIds = jobIds.where((e) => e.trim().isNotEmpty).toList();

    // Voice/AI flows sometimes send photos + description but no explicit task id.
    // Try infer a matching priced task from the catalog so artisans don't see RTBD.
    if (effectiveJobIds.isEmpty && !isRFQRequested) {
      final hint = description.trim().isNotEmpty
          ? description
          : ((categoryName ?? '').trim().isNotEmpty ? categoryName! : '');
      final inferred =
          await _inferTaskFromHint(hint: hint, categoryId: categoryId);
      final inferredId = (inferred?['id'] ?? '').toString().trim();
      final inferredName = (inferred?['name'] ?? '').toString().trim();
      final inferredCost = inferred?['cost'] is num
          ? (inferred?['cost'] as num).toDouble()
          : double.tryParse((inferred?['cost'] ?? '').toString());

      if (inferredId.isNotEmpty) {
        effectiveJobIds = <String>[inferredId];
        if (inferredName.isNotEmpty) {
          effectiveTaskNamesById[inferredId] = inferredName;
        }
        if (inferredCost != null && inferredCost > 0) {
          effectiveTaskCostsById[inferredId] = inferredCost;
        }
        _dispatchLog(
            'inferred task for empty jobIds: id=$inferredId name=$inferredName cost=${inferredCost ?? 0}');
      }
    }

    // Resolve missing/zero costs from the tasks catalog so we don't create RTBD orders.
    if (!isRFQRequested && effectiveJobIds.isNotEmpty) {
      for (final id in effectiveJobIds) {
        final current = effectiveTaskCostsById[id] ?? 0.0;
        if (current > 0) continue;
        final resolved = await _resolveTaskCostFromTasksCollection(id);
        if (resolved != null && resolved > 0) {
          effectiveTaskCostsById[id] = resolved;
        }
      }
    }

    final String taskId =
        effectiveJobIds.isNotEmpty ? effectiveJobIds.first : '';
    final String taskName = effectiveJobIds
        .map((id) => effectiveTaskNamesById[id])
        .whereType<String>()
        .join(', ');
    final double totalCost =
        effectiveTaskCostsById.values.fold(0.0, (sum, cost) => sum + cost);

    // Hard block any non-RFQ booking with unknown/zero pricing.
    if (!isRFQRequested && (effectiveJobIds.isEmpty || totalCost <= 0)) {
      throw StateError(
          'Missing priced service selection. Select a priced service or request an RFQ.');
    }

    bool isRFQ = isRFQRequested;
    String effectiveRfqReason = rfqReason;

    String? assignedArtisanId;
    String? tasksManagementId;

    if (!isRFQ) {
      final String resolvedLat = serviceOnCurrentLocation ? userLat : otherLat;
      final String resolvedLng = serviceOnCurrentLocation ? userLng : otherLng;

      assignedArtisanId = await findAvailableArtisanByLocation(
        taskId: taskId,
        scheduledDate: scheduledDate,
        scheduledTime: scheduledTime,
        userLat: resolvedLat,
        userLng: resolvedLng,
        categoryId: categoryId,
        categoryName: categoryName,
      );

      // Last-resort for Voice AI: if strict matching yields no artisan,
      // still assign the nearest active/published artisan so they receive the request.
      if ((assignedArtisanId == null || assignedArtisanId.trim().isEmpty) &&
          (createdBy.trim().toLowerCase() == 'voice_ai' ||
           createdBy.trim().toLowerCase() == 'lizzy' ||
           createdBy.trim().toLowerCase() == 'ai_agent')) {
        try {
          final cLat = double.tryParse(resolvedLat) ?? 0.0;
          final cLng = double.tryParse(resolvedLng) ?? 0.0;
          if (cLat != 0.0 && cLng != 0.0) {
            assignedArtisanId = await _findNearestActiveArtisanFallback(
              clientLat: cLat,
              clientLng: cLng,
              scheduledDate: scheduledDate,
              scheduledTime: scheduledTime,
              categoryId: categoryId,
              categoryName: categoryName,
            );
          }
        } catch (_) {
          // Non-fatal: keep as pending_assignment if fallback fails.
        }
      }

      _dispatchLog(
          'booking draft id=$bookingId task=$taskId selectedArtisanId=${(assignedArtisanId ?? '').trim().isEmpty ? 'NONE' : assignedArtisanId}');

      // If no artisan matches, keep this as an Order (not RFQ) and allow admin
      // to manually assign.
    }

    // Ensure RFQ bookings always include an AI draft quote for admin review.
    Map<String, dynamic>? resolvedAiQuote = aiQuote;
    String? aiQuoteError;
    if (isRFQ && (resolvedAiQuote == null || resolvedAiQuote.isEmpty)) {
      final safeCategoryName = (categoryName ?? '').trim();
      if (safeCategoryName.isNotEmpty) {
        try {
          resolvedAiQuote = await RFQAIService.generateQuotation(
            categoryId: categoryId,
            categoryName: safeCategoryName,
            problemDescription: description,
            additionalNotes: '',
            imageUrls: workImageUrls,
          );
        } catch (e) {
          // Non-fatal: booking must still be created even if draft quote fails.
          aiQuoteError = e.toString();
        }
      }
    }

    var assignedSuccessfully = !isRFQ &&
        (assignedArtisanId != null) &&
        assignedArtisanId.trim().isNotEmpty;

    print(
        '[ARTISAN_ASSIGNMENT] Initial: assignedArtisanId=$assignedArtisanId assignedSuccessfully=$assignedSuccessfully isRFQ=$isRFQ jobIds.isEmpty=${jobIds.isEmpty}');

    // If no artisan found but we have photos and a valid categoryName/categoryId,
    // try one more time with RELAXED criteria - just find ANY active published artisan
    // in that category, ignoring tasks and schedules for now (admin can reassign if needed)
    if (assignedArtisanId == null &&
        !isRFQ &&
        hasPhotos &&
        ((categoryName != null && categoryName.trim().isNotEmpty) ||
            (categoryId != null && categoryId.trim().isNotEmpty))) {
      print(
          '[ai_artisan_fallback] No artisan found with strict criteria; trying relaxed search');
      try {
        QuerySnapshot<Map<String, dynamic>> allArtisans;
        final query = serviceProviderRef.where('status', isEqualTo: 'publish');
        allArtisans = await query.limit(1).get();

        // If strict Firestore filter yields nothing (common when status values
        // differ by case/legacy), fall back to a broader scan.
        if (allArtisans.docs.isEmpty) {
          allArtisans = await serviceProviderRef.limit(50).get();
        }

        if (allArtisans.docs.isNotEmpty) {
          for (final doc in allArtisans.docs) {
            final data = doc.data();
            if (_isPublished(data['status']) && _isArtisanActive(data)) {
              assignedArtisanId = doc.id;
              print(
                  '[ai_artisan_fallback] Found artisan=$assignedArtisanId via relaxed search');
              break;
            }
          }
        }

        // If still not found, scan a larger slice of the full collection.
        if (assignedArtisanId == null) {
          allArtisans = await serviceProviderRef.limit(200).get();
          for (final doc in allArtisans.docs) {
            final data = doc.data();
            if (_isPublished(data['status']) && _isArtisanActive(data)) {
              assignedArtisanId = doc.id;
              print(
                  '[ai_artisan_fallback] Found artisan=$assignedArtisanId from expanded full scan');
              break;
            }
          }
        }
      } catch (e) {
        print('[ai_artisan_fallback] Relaxed search failed: $e');
      }
    }

    // Re-check assignedSuccessfully after relaxed search
    assignedSuccessfully = !isRFQ &&
        (assignedArtisanId != null) &&
        assignedArtisanId.trim().isNotEmpty;

    print(
        '[ARTISAN_ASSIGNMENT] Final: assignedArtisanId=$assignedArtisanId assignedSuccessfully=$assignedSuccessfully');

    final computedStatus = isRFQ
        ? 'rfq_pending'
        : (assignedSuccessfully ? 'pending' : 'pending_assignment');

    _dispatchLog(
        'booking decision id=$bookingId isRFQ=$isRFQ assignedSuccessfully=$assignedSuccessfully status=$computedStatus');

    // Fetch client details for display in admin
    String clientName = 'Unknown';
    String clientPhone = '';
    String clientEmail = '';
    try {
      final userDoc = await FirebaseFirestore.instance.collection('users').doc(userId).get();
      if (userDoc.exists) {
        final userData = userDoc.data() ?? {};
        clientName = (userData['name'] ?? userData['userName'] ?? userData['full_name'] ?? 'Unknown').toString();
        clientPhone = (userData['contact'] ?? userData['phone'] ?? userData['mobile'] ?? '').toString();
        clientEmail = (userData['email'] ?? '').toString();
      }
    } catch (_) {}

    final FutureBookingModel booking = FutureBookingModel(
      id: bookingId,
      userId: userId,
      serviceProviderId: isRFQ
          ? 'admin'
          : (assignedSuccessfully ? assignedArtisanId : 'admin'),
      taskId: taskId,
      taskName: taskName,
      scheduledDate: scheduledDate,
      scheduledTime: scheduledTime,
      createdAt: DateTime.now().toString(),
      status: isRFQ
          ? 'rfq_pending'
          : (assignedSuccessfully ? 'pending' : 'pending_assignment'),
      cost: isRFQ
          ? (totalCost > 0 ? totalCost.toString() : 'TBD')
          : (totalCost > 0 ? totalCost.toString() : 'TBD'),
      description: description,
      userConfirmed: 'yes',
      artisanConfirmed: 'pending',
      oneDayReminderSent: 'no',
      oneHourReminderSent: 'no',
      reassignedCount: '0',
      originalServiceProviderId: isRFQ
          ? 'admin'
          : (assignedSuccessfully ? assignedArtisanId : 'admin'),
      jobIds: effectiveJobIds,
      isServiceOnCurrentLocation: serviceOnCurrentLocation ? 'yes' : 'no',
      // Always store the best-known address string for display.
      // For current location flows, this may be reverse-geocoded by the caller.
      userProvidedAddress: providedAddress.trim(),
      userLat: userLat,
      userLng: userLng,
      otherLat: serviceOnCurrentLocation ? '' : otherLat,
      otherLng: serviceOnCurrentLocation ? '' : otherLng,
      workImages: workImageUrls,
      isRFQ: isRFQ ? 'yes' : 'no',
      rfqReason: isRFQ ? effectiveRfqReason : '',
      categoryId: categoryId,
      categoryName: categoryName,
    );

    final Map<String, dynamic> bookingMap = booking.toMap();
    // Reliable ordering for admin UI: keep legacy created_at string, but also
    // store a server timestamp.
    bookingMap['created_at_ts'] = FieldValue.serverTimestamp();
    bookingMap['created_by'] = createdBy;
    bookingMap['order_type'] = isRFQ ? 'rfq' : 'order';
    bookingMap['materials_responsibility'] = materialsResponsibility;
    
    // RFQ status field for admin filtering - set to pending_admin_review for new RFQs
    if (isRFQ) {
      bookingMap['rfq_status'] = 'pending_admin_review';
    }
    
    // Client details for admin display
    bookingMap['client_name'] = clientName;
    bookingMap['client_phone'] = clientPhone;
    bookingMap['client_email'] = clientEmail;
    bookingMap['client_id'] = userId;

    // Image field normalization across client/admin schemas.
    final normalizedImages = workImageUrls
        .map((e) => e.toString().trim())
        .where((e) => e.isNotEmpty)
        .toList();
    bookingMap['work_images'] = normalizedImages;
    bookingMap['workImages'] = normalizedImages;
    bookingMap['image_urls'] = normalizedImages;
    bookingMap['imageUrls'] = normalizedImages;
    bookingMap['has_photos'] = normalizedImages.isNotEmpty ? 'yes' : 'no';

    // Identity normalization:
    // - user_id is the legacy app user id (often from SharedPreferences)
    // - userId is a common camelCase variant
    // - uid is FirebaseAuth uid (when available)
    // Keeping all three improves compatibility with existing queries and legacy data.
    bookingMap['userId'] = userId;
    final authUid = FirebaseAuth.instance.currentUser?.uid;
    if (authUid != null && authUid.trim().isNotEmpty) {
      bookingMap['uid'] = authUid.trim();
    }

    // Stable traceability identifiers
    // - order_no must match tasksManagement.order_no (numeric) for non-RFQ orders.
    //   We set it after tasksManagement is created (or leave empty if unassigned).
    // - rfq_no is used for RFQ-only flows before conversion.
    bookingMap['order_no'] = '';
    bookingMap['rfq_no'] = isRFQ ? generateRfqNo(bookingId) : '';
    final scheduledAt =
        _tryParseScheduledDateTime(scheduledDate, scheduledTime);
    if (scheduledAt != null) {
      bookingMap['scheduled_at'] = Timestamp.fromDate(scheduledAt);
    }
    if (resolvedAiQuote != null && resolvedAiQuote.isNotEmpty) {
      bookingMap['ai_quote'] = resolvedAiQuote;
    }
    if (aiQuoteError != null && aiQuoteError.isNotEmpty) {
      bookingMap['ai_quote_error'] = aiQuoteError;
    }
    if (aiSessionId != null && aiSessionId.isNotEmpty) {
      bookingMap['ai_session_id'] = aiSessionId;
    }
    if (aiTranscript != null && aiTranscript.isNotEmpty) {
      bookingMap['ai_transcript'] = aiTranscript;
    }

    await futureBookingsRef.doc(bookingId).set(bookingMap);

    _dispatchLog(
        'booking saved id=$bookingId status=$computedStatus provider=${bookingMap['service_provider_id']}');

    print(
        '[BOOKING_FLOW] isRFQ=$isRFQ assignedSuccessfully=$assignedSuccessfully assignedArtisanId=$assignedArtisanId');

    if (!isRFQ && assignedSuccessfully) {
      print(
          '[BOOKING_FLOW] Creating tasks management for artisan assignment...');
      tasksManagementId = await _createTasksManagementRequestForFutureBooking(
        bookingId: bookingId,
        userId: userId,
        artisanId: assignedArtisanId,
        taskId: taskId,
        jobIds: effectiveJobIds,
        taskCostsById: effectiveTaskCostsById,
        scheduledDate: scheduledDate,
        scheduledTime: scheduledTime,
        serviceOnCurrentLocation: serviceOnCurrentLocation,
        providedAddress: providedAddress,
        otherLat: otherLat,
        otherLng: otherLng,
        userLat: userLat,
        userLng: userLng,
        workImageUrls: workImageUrls,
        description: description,
      );

      _dispatchLog(
          'tasksManagement create bookingId=$bookingId artisanId=$assignedArtisanId result=${(tasksManagementId ?? '').trim().isEmpty ? 'NONE' : tasksManagementId}');

      if (tasksManagementId != null && tasksManagementId.trim().isNotEmpty) {
        await futureBookingsRef.doc(bookingId).update({
          'tasks_management_id': tasksManagementId,
        });

        _dispatchLog(
            'tasksManagement linked bookingId=$bookingId tasksManagementId=$tasksManagementId');
      }
    }

    if (isRFQ) {
      // ── Auto-assign RFQ to artisans when:
      //   1. Client buys materials themselves (materialsResponsibility == 'client')
      //   2. Total amount is under R30,000
      // In this case, publish directly to relevant artisans instead of routing
      // to admin. Only escalate to admin if 3 artisans reject the job.
      final double rfqAmount = totalCost > 0
          ? totalCost
          : _extractAiQuoteTotal(resolvedAiQuote);
      final bool clientBuysMaterials =
          materialsResponsibility.trim().toLowerCase() == 'client';
      final bool underAutoAssignThreshold = rfqAmount > 0 && rfqAmount < 30000;

      print('[RFQ_AUTO] clientBuysMaterials=$clientBuysMaterials amount=$rfqAmount underThreshold=$underAutoAssignThreshold');

      if (clientBuysMaterials && underAutoAssignThreshold) {
        // Auto-assign: find up to 3 relevant artisans and publish the RFQ
        final String resolvedLat = serviceOnCurrentLocation ? userLat : otherLat;
        final String resolvedLng = serviceOnCurrentLocation ? userLng : otherLng;

        List<String> assignedArtisanIds = [];
        try {
          assignedArtisanIds = await _findMultipleAvailableArtisans(
            categoryId: categoryId,
            categoryName: categoryName,
            scheduledDate: scheduledDate,
            scheduledTime: scheduledTime,
            userLat: resolvedLat,
            userLng: resolvedLng,
            maxArtisans: 3,
          );
        } catch (e) {
          print('[RFQ_AUTO] Failed to find artisans: $e');
        }

        if (assignedArtisanIds.isNotEmpty) {
          // Update booking with auto-assigned artisans
          await futureBookingsRef.doc(bookingId).update({
            'rfq_status': 'rfq_published_to_artisans',
            'rfq_assigned_artisan_ids': assignedArtisanIds,
            'rfq_auto_assigned': true,
            'rfq_auto_assign_reason': 'client_buys_materials_under_30k',
            'rfq_artisan_rejection_count': 0,
            'rfq_artisan_rejections': [],
            'status': 'rfq_assigned',
          });

          // Notify each artisan
          for (final artId in assignedArtisanIds) {
            try {
              await sendNotificationToArtisan(
                artisanId: artId,
                bookingId: bookingId,
                message: 'New RFQ job available for $categoryName — '
                    'client provides materials, estimated R${rfqAmount.toStringAsFixed(0)}. '
                    'Review and accept or decline.',
              );
            } catch (e) {
              print('[RFQ_AUTO] Failed to notify artisan $artId: $e');
            }
          }

          await sendNotificationToUser(
            userId: userId,
            message: 'Your quotation request has been sent to '
                '${assignedArtisanIds.length} available artisan(s). '
                'You will be notified when an artisan accepts.',
          );

          print('[RFQ_AUTO] Published to ${assignedArtisanIds.length} artisans');
        } else {
          // No artisans found — fall back to admin review
          print('[RFQ_AUTO] No artisans found, escalating to admin');
          await sendNotificationToAdmin(
            bookingId: bookingId,
            message: 'New RFQ (client provides materials, R${rfqAmount.toStringAsFixed(0)}) — '
                'no artisans could be auto-assigned for $categoryName: $taskName',
          );
          await sendNotificationToUser(
            userId: userId,
            message: 'Your request is being reviewed by admin to find the best available artisan',
          );
        }
      } else {
        // Standard RFQ flow: route to admin
        await sendNotificationToAdmin(
          bookingId: bookingId,
          message: effectiveRfqReason == 'no_artisan_available'
              ? 'Booking $bookingId requires manual assignment - no available artisans'
              : 'New RFQ request for $categoryName: $taskName',
        );

        // Inform customer that admin will review
        await sendNotificationToUser(
          userId: userId,
          message:
              'Your request is being reviewed by admin to find the best available artisan',
        );
      }
    } else {
      if (assignedSuccessfully) {
        print(
            '[BOOKING_FLOW] Sending notification to assigned artisan=$assignedArtisanId');
        await sendNotificationToArtisan(
          artisanId: assignedArtisanId,
          bookingId: bookingId,
          message:
              'New booking request for $scheduledDate at $scheduledTime for $categoryName',
        );
        print('[BOOKING_FLOW] Notification sent to artisan');
      } else {
        print(
            '[BOOKING_FLOW] No artisan assigned, sending notification to admin');
        await sendNotificationToAdmin(
          bookingId: bookingId,
          title: 'Booking Assignment Needed',
          type: 'booking_assignment_needed',
          message: 'Booking $bookingId needs manual artisan assignment',
          data: {
            'order_type': 'order',
          },
        );

        await sendNotificationToUser(
          userId: userId,
          message:
              'Your booking is being assigned to the nearest available artisan',
        );
      }
    }

    return {
      'bookingId': bookingId,
      'isRFQ': isRFQ,
      'assignedArtisanId': assignedArtisanId,
      'tasksManagementId': tasksManagementId,
    };
  }

  /// Extract the total amount from an AI-generated quote map.
  /// Checks common field names: total, grand_total, totalCost, amount.
  static double _extractAiQuoteTotal(Map<String, dynamic>? quote) {
    if (quote == null || quote.isEmpty) return 0.0;
    for (final key in ['total', 'grand_total', 'totalCost', 'total_cost', 'amount', 'estimated_total']) {
      final v = quote[key];
      if (v == null) continue;
      if (v is num) return v.toDouble();
      final parsed = double.tryParse(v.toString().replaceAll(RegExp(r'[^0-9.]'), ''));
      if (parsed != null && parsed > 0) return parsed;
    }
    // Try nested: quote.summary.total or quote.totals.grand_total
    for (final nested in ['summary', 'totals', 'pricing']) {
      if (quote[nested] is Map) {
        final sub = quote[nested] as Map;
        for (final key in ['total', 'grand_total', 'totalCost', 'amount']) {
          final v = sub[key];
          if (v == null) continue;
          if (v is num) return v.toDouble();
          final parsed = double.tryParse(v.toString().replaceAll(RegExp(r'[^0-9.]'), ''));
          if (parsed != null && parsed > 0) return parsed;
        }
      }
    }
    return 0.0;
  }

  /// Find multiple available artisans for RFQ auto-assignment.
  /// Returns up to [maxArtisans] artisan IDs sorted by distance.
  static Future<List<String>> _findMultipleAvailableArtisans({
    String? categoryId,
    String? categoryName,
    required String scheduledDate,
    required String scheduledTime,
    required String userLat,
    required String userLng,
    int maxArtisans = 3,
  }) async {
    final double clientLat = double.tryParse(userLat) ?? 0.0;
    final double clientLng = double.tryParse(userLng) ?? 0.0;

    final artisansWithDistance = <Map<String, dynamic>>[];

    // Try to find artisans from the provider collection
    QuerySnapshot<Map<String, dynamic>> allArtisans;
    try {
      allArtisans = await serviceProviderRef
          .where('status', isEqualTo: 'publish')
          .limit(100)
          .get();
      if (allArtisans.docs.isEmpty) {
        allArtisans = await serviceProviderRef.limit(100).get();
      }
    } catch (e) {
      print('[RFQ_AUTO] Failed to query artisans: $e');
      return [];
    }

    final catNameLower = (categoryName ?? '').trim().toLowerCase();

    for (final doc in allArtisans.docs) {
      final data = doc.data();
      if (!_isPublished(data['status'])) continue;
      if (!_isArtisanActive(data)) continue;

      // Check category match if we have category info
      if (catNameLower.isNotEmpty) {
        final artisanCategory = (data['category'] ?? data['categoryName'] ?? data['service_category'] ?? '').toString().toLowerCase();
        final artisanSkills = (data['skills'] ?? data['services'] ?? '').toString().toLowerCase();
        final artisanCatId = (data['categoryId'] ?? data['category_id'] ?? '').toString();
        final matchesCategory = artisanCategory.contains(catNameLower) ||
            catNameLower.contains(artisanCategory) ||
            artisanSkills.contains(catNameLower) ||
            (categoryId != null && artisanCatId == categoryId);
        // If we can determine category, prefer matching artisans.
        // But still include non-matching if not enough found later.
        if (!matchesCategory && artisansWithDistance.length >= maxArtisans) {
          continue;
        }
      }

      // Check schedule availability
      try {
        final isAvailable = await checkArtisanAvailability(
          artisanId: doc.id,
          scheduledDate: scheduledDate,
          scheduledTime: scheduledTime,
        );
        if (!isAvailable) continue;
      } catch (_) {
        continue;
      }

      final coords = _extractLatLng(data);
      final lat = coords['lat'] ?? 0.0;
      final lng = coords['lng'] ?? 0.0;
      final distance = (clientLat != 0.0 && clientLng != 0.0 && lat != 0.0 && lng != 0.0)
          ? calculateDistance(clientLat, clientLng, lat, lng)
          : 9999.0;

      artisansWithDistance.add({
        'artisan_id': doc.id,
        'distance': distance,
      });
    }

    // Sort by distance (nearest first)
    artisansWithDistance.sort((a, b) =>
        (a['distance'] as double).compareTo(b['distance'] as double));

    // Return up to maxArtisans
    return artisansWithDistance
        .take(maxArtisans)
        .map((e) => e['artisan_id'] as String)
        .toList();
  }

  /// Calculate distance between two points using Haversine formula
  static double calculateDistance(
      double lat1, double lon1, double lat2, double lon2) {
    const double earthRadius = 6371; // km

    double dLat = _degreesToRadians(lat2 - lat1);
    double dLon = _degreesToRadians(lon2 - lon1);

    double a = sin(dLat / 2) * sin(dLat / 2) +
        cos(_degreesToRadians(lat1)) *
            cos(_degreesToRadians(lat2)) *
            sin(dLon / 2) *
            sin(dLon / 2);

    double c = 2 * atan2(sqrt(a), sqrt(1 - a));
    return earthRadius * c;
  }

  static double _degreesToRadians(double degrees) {
    return degrees * pi / 180;
  }

  static bool _isTruthy(dynamic value) {
    if (value == null) return false;
    if (value is bool) return value;
    if (value is num) return value != 0;
    if (value is String) {
      final s = value.trim().toLowerCase();
      // Support legacy flags used across the project.
      // - serviceProvider.active is often stored as 'y'/'n'
      // - other parts use 'yes'/'no', '1'/'0', or boolean strings
      return s == 'true' ||
          s == 'yes' ||
          s == 'y' ||
          s == '1' ||
          s == 'active' ||
          s == 'online' ||
          s == 'available' ||
          s == 'on';
    }
    return false;
  }

  static bool _isPublished(dynamic status) {
    // Many deployments don't store a publish-status field at all.
    // Treat missing/empty status as published.
    final raw = (status ?? '').toString().trim();
    if (raw.isEmpty) return true;
    final s = raw.toLowerCase();
    return s == 'publish' ||
        s == 'published' ||
        s == 'approved' ||
        s == 'approve';
  }

  static bool _isArtisanActive(Map<String, dynamic> artisanData) {
    // ── IMPORTANT ──────────────────────────────────────────────────────
    // Only the manual "Status" toggle (the `active` field, stored as
    // 'y'/'n') should gate dispatch.  Presence fields like `is_online`,
    // `online`, `status_online` etc. must NOT be checked here because
    // PresenceService sets `is_online = false` whenever the app is
    // backgrounded / closed.  Artisans who simply close the app (without
    // signing out or turning Status off) must still receive requests and
    // push notifications.
    // ────────────────────────────────────────────────────────────────────

    final active = artisanData['active'];
    if (active == null) return true; // field missing → default to active
    return _isTruthy(active);
  }

  static Future<DocumentSnapshot<Map<String, dynamic>>?>
      _getServiceProviderDocByAnyId(String idOrUid) async {
    final key = idOrUid.trim();
    if (key.isEmpty) return null;
    try {
      final doc = await serviceProviderRef.doc(key).get();
      if (doc.exists) return doc;
    } catch (_) {
      // ignore and try query fallbacks
    }

    Future<DocumentSnapshot<Map<String, dynamic>>?> tryField(
        String field) async {
      try {
        final snap = await serviceProviderRef
            .where(field, isEqualTo: key)
            .limit(1)
            .get();
        if (snap.docs.isEmpty) return null;
        return snap.docs.first;
      } catch (_) {
        return null;
      }
    }

    return await tryField('user_id') ??
        await tryField('uid') ??
        await tryField('userId') ??
        await tryField('provider_id');
  }

  static bool _artisanHasTask({
    required Map<String, dynamic> artisanData,
    required String taskId,
    String? categoryId,
    String? categoryName,
  }) {
    bool matchesTaskId(String? candidate) {
      final c = (candidate ?? '').toString().trim();
      return c.isNotEmpty && c == taskId;
    }

    final dynamic rawTaskList =
        artisanData['task_list'] ?? artisanData['tasks'];
    if (rawTaskList is List) {
      for (final t in rawTaskList) {
        if (t is String) {
          if (matchesTaskId(t)) return true;
        } else if (t is Map) {
          final map = t.map((k, v) => MapEntry(k.toString(), v));
          if (matchesTaskId(map['task_id']?.toString())) return true;
          if (matchesTaskId(map['taskId']?.toString())) return true;
          if (matchesTaskId(map['id']?.toString())) return true;
        }
      }
    }

    // Fallback: some provider docs store supported categories instead of task ids.
    if (categoryId != null && categoryId.trim().isNotEmpty) {
      final dynamic cats = artisanData['category_ids'] ??
          artisanData['categories'] ??
          artisanData['categoryId'] ??
          artisanData['category_id'];
      if (cats is String) {
        if (cats.trim() == categoryId.trim()) return true;
      } else if (cats is List) {
        for (final c in cats) {
          if (c != null && c.toString().trim() == categoryId.trim()) {
            return true;
          }
        }
      }
    }
    if (categoryName != null && categoryName.trim().isNotEmpty) {
      final prof =
          (artisanData['profession'] ?? artisanData['trade'] ?? '').toString();
      if (prof.trim().isNotEmpty &&
          prof.toLowerCase().contains(categoryName.toLowerCase().trim())) {
        return true;
      }
    }

    return false;
  }

  static Map<String, double> _extractLatLng(Map<String, dynamic> artisanData) {
    double? tryParse(dynamic v) {
      if (v == null) return null;
      if (v is num) return v.toDouble();
      return double.tryParse(v.toString());
    }

    // Common schemas: lat/lng, latitude/longitude, positionLat/positionLong,
    // and GeoPoint in location.
    double lat = tryParse(artisanData['lat']) ??
        tryParse(artisanData['latitude']) ??
        tryParse(artisanData['positionLat']) ??
        tryParse(artisanData['position_lat']) ??
        0.0;
    double lng = tryParse(artisanData['lng']) ??
        tryParse(artisanData['longitude']) ??
        tryParse(artisanData['positionLong']) ??
        tryParse(artisanData['positionLng']) ??
        tryParse(artisanData['position_long']) ??
        tryParse(artisanData['position_lng']) ??
        0.0;

    final loc = artisanData['location'];
    if ((lat == 0.0 || lng == 0.0) && loc is GeoPoint) {
      lat = loc.latitude;
      lng = loc.longitude;
    }
    return {'lat': lat, 'lng': lng};
  }

  static DateTime? _tryParseScheduledDateTime(String date, dynamic timeValue) {
    final d = date.trim();
    if (d.isEmpty) return null;
    String t = (timeValue ?? '').toString().trim();
    if (t.isEmpty) return null;
    // Accept HH:mm or HH:mm:ss
    if (RegExp(r'^\d{2}:\d{2}$').hasMatch(t)) {
      t = '$t:00';
    }
    try {
      return DateTime.parse('$d $t');
    } catch (_) {
      return null;
    }
  }

  static DateTime? tryParseScheduledDateTimePublic(
    String date,
    dynamic timeValue,
  ) {
    return _tryParseScheduledDateTime(date, timeValue);
  }

  static DateTime? _tryParseAnyDateTime(dynamic value) {
    if (value == null) return null;
    if (value is DateTime) return value;
    if (value is Timestamp) return value.toDate();
    if (value is num) {
      final n = value.toInt();
      // seconds vs milliseconds
      final millis = n < 1000000000000 ? (n * 1000) : n;
      return DateTime.fromMillisecondsSinceEpoch(millis);
    }
    final s = value.toString().trim();
    if (s.isEmpty) return null;
    try {
      return DateTime.parse(s);
    } catch (_) {
      // tolerate common non-ISO date formats that show up in legacy writes
      for (final fmt in <String>[
        'dd/MM/yyyy HH:mm:ss',
        'dd/MM/yyyy HH:mm',
        'dd/MM/yyyy',
        'dd-MM-yyyy HH:mm:ss',
        'dd-MM-yyyy HH:mm',
        'dd-MM-yyyy',
        'yyyy/MM/dd HH:mm:ss',
        'yyyy/MM/dd HH:mm',
        'yyyy/MM/dd',
      ]) {
        try {
          return DateFormat(fmt).parse(s);
        } catch (_) {}
      }
      return null;
    }
  }

  /// Best-effort scheduled datetime parsing for futureBookings documents.
  ///
  /// Supports both:
  /// - a single datetime/timestamp field (preferred)
  /// - legacy scheduled_date + scheduled_time string fields
  static DateTime? tryParseScheduledDateTimeFromDocument(
    Map<String, dynamic> data,
  ) {
    final dtValue = data['scheduled_at'] ??
        data['scheduledAt'] ??
        data['scheduled_datetime'] ??
        data['scheduledDateTime'] ??
        data['scheduled_timestamp'] ??
        data['scheduledTimestamp'];
    final direct = _tryParseAnyDateTime(dtValue);
    if (direct != null) return direct;

    final date = (data['scheduled_date'] ?? data['scheduledDate'] ?? '')
        .toString()
        .trim();
    final time = (data['scheduled_time'] ?? data['scheduledTime'] ?? '')
        .toString()
        .trim();
    if (date.isEmpty || time.isEmpty) return null;
    return _tryParseScheduledDateTime(date, time);
  }

  static Future<Set<String>> _candidateArtisanIdsForTask(String taskId) async {
    final t = taskId.trim();
    if (t.isEmpty) return <String>{};
    try {
      // Be tolerant of inconsistent schemas and casing in Firestore.
      // Some deployments store status as 'Publish'/'published' and/or use 'taskId'.
      QuerySnapshot snap =
          await userTasksRef.where('task_id', isEqualTo: t).get();
      if (snap.docs.isEmpty) {
        try {
          snap = await userTasksRef.where('taskId', isEqualTo: t).get();
        } catch (_) {
          // ignore
        }
      }

      // Also check if this is a categoryId being used as taskId (generic fallback case)
      if (snap.docs.isEmpty) {
        try {
          final catSnap =
              await userTasksRef.where('category_id', isEqualTo: t).get();
          if (catSnap.docs.isNotEmpty) {
            snap = catSnap;
            _dispatchLog(
                '_candidateArtisanIdsForTask: found matches via category_id=$t');
          }
        } catch (_) {
          // ignore
        }
      }
      if (snap.docs.isEmpty) {
        try {
          final catSnap2 =
              await userTasksRef.where('categoryId', isEqualTo: t).get();
          if (catSnap2.docs.isNotEmpty) {
            snap = catSnap2;
            _dispatchLog(
                '_candidateArtisanIdsForTask: found matches via categoryId=$t');
          }
        } catch (_) {
          // ignore
        }
      }

      final ids = <String>{};
      for (final doc in snap.docs) {
        final data = doc.data() as Map<String, dynamic>;
        // Client-side status filtering (index-safe and case-insensitive).
        final status =
            data['status'] ?? data['state'] ?? data['publish_status'];
        if (status != null && !_isPublished(status)) {
          continue;
        }
        final candidates = <dynamic>[
          data['user_id'],
          data['artisan_id'],
          data['provider_id'],
          data['service_provider_id'],
          data['uid'],
        ];
        for (final c in candidates) {
          final id = (c ?? '').toString().trim();
          if (id.isNotEmpty) ids.add(id);
        }
      }
      _dispatchLog(
          '_candidateArtisanIdsForTask: taskId=$t found ${ids.length} candidates');
      return ids;
    } catch (e) {
      debugPrint('Error reading userTasks for task=$taskId: $e');
      return <String>{};
    }
  }

  /// Find available artisan based on location (nearest first)
  static Future<String?> findAvailableArtisanByLocation({
    required String taskId,
    required String scheduledDate,
    required String scheduledTime,
    required String userLat,
    required String userLng,
    String? excludeArtisanId,
    String? categoryId,
    String? categoryName,
  }) async {
    try {
      double clientLat = double.tryParse(userLat) ?? 0.0;
      double clientLng = double.tryParse(userLng) ?? 0.0;

      _dispatchLog(
          'findAvailableArtisanByLocation task=$taskId date=$scheduledDate time=$scheduledTime lat=$userLat lng=$userLng exclude=$excludeArtisanId');

      if (clientLat == 0.0 || clientLng == 0.0) {
        debugPrint('Invalid client location');
        return await findAvailableArtisan(
          taskId: taskId,
          scheduledDate: scheduledDate,
          scheduledTime: scheduledTime,
          excludeArtisanId: excludeArtisanId,
          categoryId: categoryId,
          categoryName: categoryName,
        );
      }

      List<Map<String, dynamic>> availableArtisansWithDistance = [];

      int excludedMissingDoc = 0;
      int excludedNotPublished = 0;
      int excludedNotActive = 0;
      int excludedNotAvailable = 0;
      int excludedExplicit = 0;

      // Prefer the canonical mapping: userTasks(task_id -> user_id).
      // This matches how the rest of the app stores which artisans do which tasks.
      final candidateIds = await _candidateArtisanIdsForTask(taskId);
      if (candidateIds.isNotEmpty) {
        _dispatchLog('candidateIds for task=$taskId: ${candidateIds.length}');
        for (final candidateId in candidateIds) {
          final providerDoc = await _getServiceProviderDocByAnyId(candidateId);
          if (providerDoc == null || !providerDoc.exists) {
            excludedMissingDoc++;
            _dispatchLog(
                'skip candidateId=$candidateId reason=no_provider_doc');
            continue;
          }
          final artisanId = providerDoc.id;
          if (excludeArtisanId != null &&
              (artisanId == excludeArtisanId ||
                  candidateId == excludeArtisanId)) {
            excludedExplicit++;
            _dispatchLog(
                'skip artisanId=$artisanId candidateId=$candidateId reason=excluded');
            continue;
          }

          final artisanData = providerDoc.data() as Map<String, dynamic>;

          if (!_isPublished(artisanData['status'])) {
            excludedNotPublished++;
            _dispatchLog(
                'skip artisanId=$artisanId reason=not_published status=${artisanData['status']}');
            continue;
          }
          if (!_isArtisanActive(artisanData)) {
            excludedNotActive++;
            _dispatchLog(
                'skip artisanId=$artisanId reason=not_active flags={isActive:${artisanData['isActive']},active:${artisanData['active']},is_active:${artisanData['is_active']},online:${artisanData['online']},is_online:${artisanData['is_online']},availability:${artisanData['availability']},available:${artisanData['available']},isAvailable:${artisanData['isAvailable']}}');
            continue;
          }

          final isAvailable = await checkArtisanAvailability(
            artisanId: artisanId,
            scheduledDate: scheduledDate,
            scheduledTime: scheduledTime,
          );
          if (!isAvailable) {
            excludedNotAvailable++;
            _dispatchLog('skip artisanId=$artisanId reason=schedule_conflict');
            continue;
          }

          final coords = _extractLatLng(artisanData);
          final artisanLat = coords['lat'] ?? 0.0;
          final artisanLng = coords['lng'] ?? 0.0;

          if (artisanLat == 0.0 || artisanLng == 0.0) {
            _dispatchLog(
                'artisanId=$artisanId has no valid coords (lat=$artisanLat lng=$artisanLng); using distance=9999');
          }

          final distance = (artisanLat != 0.0 && artisanLng != 0.0)
              ? calculateDistance(clientLat, clientLng, artisanLat, artisanLng)
              : 9999.0;

          availableArtisansWithDistance.add({
            'artisan_id': artisanId,
            'distance': distance,
          });
        }

        _dispatchLog(
            'candidate scan summary: eligible=${availableArtisansWithDistance.length} missingDoc=$excludedMissingDoc excluded=$excludedExplicit notPublished=$excludedNotPublished notActive=$excludedNotActive scheduleConflict=$excludedNotAvailable');
      } else {
        // Fallback to legacy provider-doc scanning if userTasks is empty.
        _dispatchLog(
            'candidateIds empty for task=$taskId; falling back to provider scan');
        QuerySnapshot artisansSnapshot = await serviceProviderRef
            .where('status', isEqualTo: 'publish')
            .get();
        if (artisansSnapshot.docs.isEmpty) {
          artisansSnapshot = await serviceProviderRef.get();
        }

        int scanned = 0;
        int excludedFallbackNotPublished = 0;
        int excludedFallbackNotActive = 0;
        int excludedFallbackNoTask = 0;
        int excludedFallbackNotAvailable = 0;
        for (var artisanDoc in artisansSnapshot.docs) {
          scanned++;
          String artisanId = artisanDoc.id;
          if (excludeArtisanId != null && artisanId == excludeArtisanId) {
            continue;
          }

          var artisanData = artisanDoc.data() as Map<String, dynamic>;
          if (!_isPublished(artisanData['status'])) {
            excludedFallbackNotPublished++;
            continue;
          }
          if (!_isArtisanActive(artisanData)) {
            excludedFallbackNotActive++;
            continue;
          }

          // Check if artisan has the required task/category
          final hasTask = _artisanHasTask(
            artisanData: artisanData,
            taskId: taskId,
            categoryId: categoryId,
            categoryName: categoryName,
          );

          // If category matching fails but we have a categoryName,
          // be lenient and accept any active artisan (admin can reassign if needed)
          final acceptAnyway = !hasTask &&
              categoryName != null &&
              categoryName.trim().isNotEmpty;

          if (!hasTask && !acceptAnyway) {
            excludedFallbackNoTask++;
            continue;
          }

          bool isAvailable = await checkArtisanAvailability(
            artisanId: artisanId,
            scheduledDate: scheduledDate,
            scheduledTime: scheduledTime,
          );
          if (!isAvailable) {
            excludedFallbackNotAvailable++;
            continue;
          }

          final coords = _extractLatLng(artisanData);
          final artisanLat = coords['lat'] ?? 0.0;
          final artisanLng = coords['lng'] ?? 0.0;

          if (artisanLat != 0.0 && artisanLng != 0.0) {
            double distance =
                calculateDistance(clientLat, clientLng, artisanLat, artisanLng);
            availableArtisansWithDistance.add({
              'artisan_id': artisanId,
              'distance': distance,
            });
          } else {
            availableArtisansWithDistance.add({
              'artisan_id': artisanId,
              'distance': 9999.0,
            });
          }
        }

        _dispatchLog(
            'fallback scan summary: scanned=$scanned eligible=${availableArtisansWithDistance.length} notPublished=$excludedFallbackNotPublished notActive=$excludedFallbackNotActive noTask=$excludedFallbackNoTask scheduleConflict=$excludedFallbackNotAvailable');
      }

      if (availableArtisansWithDistance.isEmpty) return null;

      // Sort by distance (nearest first)
      availableArtisansWithDistance
          .sort((a, b) => a['distance'].compareTo(b['distance']));

      String nearestArtisanId =
          availableArtisansWithDistance.first['artisan_id'];
      double nearestDistance = availableArtisansWithDistance.first['distance'];

      debugPrint(
          'Found nearest artisan: $nearestArtisanId at ${nearestDistance.toStringAsFixed(2)} km');

      _dispatchLog(
          'selected artisanId=$nearestArtisanId distance=${nearestDistance.toStringAsFixed(2)}km');

      return nearestArtisanId;
    } catch (e) {
      debugPrint('Error finding available artisan by location: $e');
      return null;
    }
  }

  static Future<String?> _findNearestActiveArtisanFallback({
    required double clientLat,
    required double clientLng,
    required String scheduledDate,
    required String scheduledTime,
    String? categoryId,
    String? categoryName,
    String? excludeArtisanId,
  }) async {
    Future<String?> pick(
        {required bool requireCategoryMatch,
        required bool enforceAvailability}) async {
      QuerySnapshot<Map<String, dynamic>> snap;
      try {
        snap = await serviceProviderRef
            .where('status', isEqualTo: 'publish')
            .limit(200)
            .get();
        if (snap.docs.isEmpty) {
          snap = await serviceProviderRef.limit(200).get();
        }
      } catch (_) {
        snap = await serviceProviderRef.limit(200).get();
      }

      String? bestId;
      double bestDistance = double.infinity;

      for (final doc in snap.docs) {
        final artisanId = doc.id.toString().trim();
        if (artisanId.isEmpty) continue;
        if (excludeArtisanId != null && excludeArtisanId.trim().isNotEmpty) {
          final ex = excludeArtisanId.trim();
          if (artisanId == ex) continue;
        }

        final data = doc.data();
        if (!_isPublished(data['status'])) continue;
        if (!_isArtisanActive(data)) continue;

        if (requireCategoryMatch &&
            ((categoryId != null && categoryId.trim().isNotEmpty) ||
                (categoryName != null && categoryName.trim().isNotEmpty))) {
          final hasCategory = _artisanHasTask(
            artisanData: data,
            taskId: '',
            categoryId: categoryId,
            categoryName: categoryName,
          );
          if (!hasCategory) continue;
        }

        if (enforceAvailability) {
          final ok = await checkArtisanAvailability(
            artisanId: artisanId,
            scheduledDate: scheduledDate,
            scheduledTime: scheduledTime,
          );
          if (!ok) continue;
        }

        final coords = _extractLatLng(data);
        final aLat = coords['lat'] ?? 0.0;
        final aLng = coords['lng'] ?? 0.0;
        if (aLat == 0.0 || aLng == 0.0) continue;

        final d = calculateDistance(clientLat, clientLng, aLat, aLng);
        if (d < bestDistance) {
          bestDistance = d;
          bestId = artisanId;
        }
      }

      return bestId;
    }

    // Prefer matching category and respecting availability.
    return await pick(requireCategoryMatch: true, enforceAvailability: true) ??
        // If none are "available", still pick nearest match so someone receives the request.
        await pick(requireCategoryMatch: true, enforceAvailability: false) ??
        // If no category match exists, fall back to any nearest active artisan.
        await pick(requireCategoryMatch: false, enforceAvailability: true) ??
        await pick(requireCategoryMatch: false, enforceAvailability: false);
  }

  /// Find available artisan for the scheduled date and time
  static Future<String?> findAvailableArtisan({
    required String taskId,
    required String scheduledDate,
    required String scheduledTime,
    String? excludeArtisanId,
    String? categoryId,
    String? categoryName,
  }) async {
    try {
      List<String> availableArtisans = [];

      _dispatchLog(
          'findAvailableArtisan task=$taskId date=$scheduledDate time=$scheduledTime exclude=$excludeArtisanId');

      int excludedMissingDoc = 0;
      int excludedNotPublished = 0;
      int excludedNotActive = 0;
      int excludedNotAvailable = 0;
      int excludedExplicit = 0;

      final candidateIds = await _candidateArtisanIdsForTask(taskId);
      if (candidateIds.isNotEmpty) {
        _dispatchLog('candidateIds for task=$taskId: ${candidateIds.length}');
        for (final candidateId in candidateIds) {
          final providerDoc = await _getServiceProviderDocByAnyId(candidateId);
          if (providerDoc == null || !providerDoc.exists) {
            excludedMissingDoc++;
            _dispatchLog(
                'skip candidateId=$candidateId reason=no_provider_doc');
            continue;
          }
          final artisanId = providerDoc.id;
          if (excludeArtisanId != null &&
              (artisanId == excludeArtisanId ||
                  candidateId == excludeArtisanId)) {
            excludedExplicit++;
            continue;
          }
          final artisanData = providerDoc.data() as Map<String, dynamic>;

          if (!_isPublished(artisanData['status'])) {
            excludedNotPublished++;
            continue;
          }
          if (!_isArtisanActive(artisanData)) {
            excludedNotActive++;
            continue;
          }

          final isAvailable = await checkArtisanAvailability(
            artisanId: artisanId,
            scheduledDate: scheduledDate,
            scheduledTime: scheduledTime,
          );
          if (isAvailable) {
            availableArtisans.add(artisanId);
          } else {
            excludedNotAvailable++;
          }
        }

        _dispatchLog(
            'candidate scan summary: eligible=${availableArtisans.length} missingDoc=$excludedMissingDoc excluded=$excludedExplicit notPublished=$excludedNotPublished notActive=$excludedNotActive scheduleConflict=$excludedNotAvailable');
      } else {
        _dispatchLog(
            'candidateIds empty for task=$taskId; falling back to provider scan');
        QuerySnapshot artisansSnapshot = await serviceProviderRef
            .where('status', isEqualTo: 'publish')
            .get();
        if (artisansSnapshot.docs.isEmpty) {
          artisansSnapshot = await serviceProviderRef.get();
        }

        int scanned = 0;
        int excludedFallbackNotPublished = 0;
        int excludedFallbackNotActive = 0;
        int excludedFallbackNoTask = 0;
        int excludedFallbackNotAvailable = 0;

        for (var artisanDoc in artisansSnapshot.docs) {
          scanned++;
          String artisanId = artisanDoc.id;
          if (excludeArtisanId != null && artisanId == excludeArtisanId) {
            continue;
          }

          var artisanData = artisanDoc.data() as Map<String, dynamic>;

          if (!_isPublished(artisanData['status'])) {
            excludedFallbackNotPublished++;
            continue;
          }
          if (!_isArtisanActive(artisanData)) {
            excludedFallbackNotActive++;
            continue;
          }

          final hasTask = _artisanHasTask(
            artisanData: artisanData,
            taskId: taskId,
            categoryId: categoryId,
            categoryName: categoryName,
          );
          if (!hasTask) {
            excludedFallbackNoTask++;
            continue;
          }

          bool isAvailable = await checkArtisanAvailability(
            artisanId: artisanId,
            scheduledDate: scheduledDate,
            scheduledTime: scheduledTime,
          );

          if (isAvailable) {
            availableArtisans.add(artisanId);
          } else {
            excludedFallbackNotAvailable++;
          }
        }

        _dispatchLog(
            'fallback scan summary: scanned=$scanned eligible=${availableArtisans.length} notPublished=$excludedFallbackNotPublished notActive=$excludedFallbackNotActive noTask=$excludedFallbackNoTask scheduleConflict=$excludedFallbackNotAvailable');
      }

      if (availableArtisans.isEmpty) return null;

      // Return the first available artisan (can be enhanced with rating/distance logic)
      _dispatchLog('selected artisanId=${availableArtisans.first}');
      return availableArtisans.first;
    } catch (e) {
      debugPrint('Error finding available artisan: $e');
      return null;
    }
  }

  /// Check if artisan is available at the scheduled time
  static Future<bool> checkArtisanAvailability({
    required String artisanId,
    required String scheduledDate,
    required String scheduledTime,
    String? excludeBookingId,
  }) async {
    try {
      // If schedule is missing/malformed, don't block dispatch.
      if (scheduledDate.trim().isEmpty || scheduledTime.trim().isEmpty) {
        return true;
      }

      // Index-safe query: single-field filter, then in-memory check.
      // Some environments may not have composite indexes configured.
      QuerySnapshot bookingsSnapshot = await futureBookingsRef
          .where('service_provider_id', isEqualTo: artisanId)
          .get();

      if (bookingsSnapshot.docs.isEmpty) return true;

      // Parse scheduled time (support HH:mm or HH:mm:ss)
      final requestedDateTime =
          _tryParseScheduledDateTime(scheduledDate, scheduledTime);
      if (requestedDateTime == null) {
        // If we can't parse the time, do not block dispatch.
        return true;
      }

      for (var booking in bookingsSnapshot.docs) {
        if (excludeBookingId != null &&
            excludeBookingId.trim().isNotEmpty &&
            booking.id == excludeBookingId.trim()) {
          continue;
        }
        var data = booking.data() as Map<String, dynamic>;
        final status = (data['status'] ?? '').toString().trim().toLowerCase();
        if (status != 'pending' && status != 'confirmed') continue;
        final isRfq = (data['is_rfq'] ?? '').toString().trim().toLowerCase();
        if (isRfq == 'yes') continue;
        final bookedDate = (data['scheduled_date'] ?? '').toString().trim();
        if (bookedDate != scheduledDate.trim()) continue;

        final bookedDateTime = _tryParseScheduledDateTime(
          scheduledDate,
          data['scheduled_time'],
        );
        if (bookedDateTime == null) {
          // Ignore malformed times; do not mark the artisan unavailable.
          continue;
        }

        // Check if times overlap (2-hour buffer)
        Duration difference =
            requestedDateTime.difference(bookedDateTime).abs();
        if (difference.inHours < 2) {
          return false; // Not available
        }
      }

      return true;
    } catch (e) {
      debugPrint('Error checking artisan availability: $e');
      // Availability should not block matching if Firestore throws (e.g. index).
      return true;
    }
  }

  /// Reassign booking to another available artisan
  static Future<bool> reassignBooking({
    required String bookingId,
    required FutureBookingModel booking,
  }) async {
    try {
      final bookingSnap = await futureBookingsRef.doc(bookingId).get();
      final bookingData = bookingSnap.data() ?? <String, dynamic>{};
      final previousTasksManagementId =
          (bookingData['tasks_management_id'] ?? '').toString().trim();

      // Get user location if service is at current location
      String userLat = '0';
      String userLng = '0';

      if (booking.isServiceOnCurrentLocation == 'yes') {
        DocumentSnapshot userDoc = await userRef.doc(booking.userId).get();
        if (userDoc.exists) {
          var userData = userDoc.data() as Map<String, dynamic>?;
          userLat = userData?['lat']?.toString() ?? '0';
          userLng = userData?['lng']?.toString() ?? '0';
        }
      } else {
        userLat = booking.otherLat ?? '0';
        userLng = booking.otherLng ?? '0';
      }

      String? newArtisanId = await findAvailableArtisanByLocation(
        taskId: booking.taskId!,
        scheduledDate: booking.scheduledDate!,
        scheduledTime: booking.scheduledTime!,
        userLat: userLat,
        userLng: userLng,
        excludeArtisanId: booking.serviceProviderId,
        categoryId: booking.categoryId,
        categoryName: booking.categoryName,
      );

      if (newArtisanId == null) {
        debugPrint(
            'No available artisan found for reassignment - escalating to admin');

        await futureBookingsRef.doc(bookingId).update({
          'status': 'pending_assignment',
          'is_rfq': 'no',
          'order_type': 'order',
          'service_provider_id': 'admin',
          'artisan_confirmed': 'pending',
          'updated_at': DateTime.now().toString(),
        });

        if (previousTasksManagementId.isNotEmpty) {
          await tasksManagementRef.doc(previousTasksManagementId).set({
            'status': 'closed',
            'closed_date': DateTime.now().toString(),
            'updated_at': DateTime.now().toString(),
          }, SetOptions(merge: true));
        }

        await sendNotificationToAdmin(
          bookingId: bookingId,
          title: 'Booking Reassignment Needed',
          type: 'booking_assignment_needed',
          message: 'Booking $bookingId needs manual reassignment',
          data: {
            'order_type': 'order',
          },
        );

        await sendNotificationToUser(
          userId: booking.userId!,
          message:
              'Your booking is being reassigned to another available artisan',
        );

        return true;
      }

      // Update booking with new artisan
      int reassignCount = int.parse(booking.reassignedCount ?? '0') + 1;

      await futureBookingsRef.doc(bookingId).update({
        'service_provider_id': newArtisanId,
        'artisan_confirmed': 'pending',
        'reassigned_count': reassignCount.toString(),
        'updated_at': DateTime.now().toString(),
      });

      if (previousTasksManagementId.isNotEmpty) {
        await tasksManagementRef.doc(previousTasksManagementId).set({
          'status': 'closed',
          'closed_date': DateTime.now().toString(),
          'updated_at': DateTime.now().toString(),
        }, SetOptions(merge: true));
      }

      final newTasksManagementId =
          await _createTasksManagementRequestForFutureBooking(
        bookingId: bookingId,
        userId: booking.userId!,
        artisanId: newArtisanId,
        taskId: booking.taskId ?? '',
        jobIds: booking.jobIds ?? <String>[],
        taskCostsById: const <String, double>{},
        scheduledDate: booking.scheduledDate ?? '',
        scheduledTime: booking.scheduledTime ?? '',
        serviceOnCurrentLocation: booking.isServiceOnCurrentLocation == 'yes',
        providedAddress: booking.userProvidedAddress ?? '',
        otherLat: booking.otherLat ?? '',
        otherLng: booking.otherLng ?? '',
        userLat: booking.userLat ?? '',
        userLng: booking.userLng ?? '',
        workImageUrls: booking.workImages ?? const <String>[],
        description: booking.description ?? '',
      );
      if (newTasksManagementId != null &&
          newTasksManagementId.trim().isNotEmpty) {
        await futureBookingsRef.doc(bookingId).update({
          'tasks_management_id': newTasksManagementId,
        });
      }

      // Send notification to new artisan
      await sendNotificationToArtisan(
        artisanId: newArtisanId,
        bookingId: bookingId,
        message:
            'New booking assigned for ${booking.scheduledDate} at ${booking.scheduledTime}',
        isReassignment: true,
      );

      // Notify customer about reassignment
      await sendNotificationToUser(
        userId: booking.userId!,
        message:
            'Your booking has been reassigned to another nearby artisan who will confirm shortly',
      );

      return true;
    } catch (e) {
      debugPrint('Error reassigning booking: $e');
      return false;
    }
  }

  /// Mark a future booking as started (artisan is going to site / work begins).
  ///
  /// This updates BOTH:
  /// - futureBookings/{bookingId}.status = in_progress
  /// - tasksManagement/{tasksManagementId}.status = in_progress (if bridged)
  static Future<bool> markBookingInProgress({
    required String bookingId,
    String? tasksManagementId,
  }) async {
    final id = bookingId.trim();
    if (id.isEmpty) return false;

    try {
      final now = DateTime.now().toString();
      final snap = await futureBookingsRef.doc(id).get();
      if (!snap.exists) return false;
      final data = snap.data() ?? <String, dynamic>{};

      final tmId = (tasksManagementId ?? '').toString().trim().isNotEmpty
          ? tasksManagementId!.trim()
          : (data['tasks_management_id'] ?? '').toString().trim();

      final resolvedTmId = tmId.isNotEmpty
          ? tmId
          : (await resolveOrCreateTasksManagementIdForBooking(bookingId: id) ??
              '');

      await futureBookingsRef.doc(id).set({
        'status': 'in_progress',
        'in_progress_at': now,
        'updated_at': now,
      }, SetOptions(merge: true));

      if (resolvedTmId.isNotEmpty) {
        // IMPORTANT: Existing app workflow uses tasksManagement.status == 'progress'
        // for in-progress jobs (tracking + chat visibility).
        await tasksManagementRef.doc(resolvedTmId).set({
          'status': 'progress',
          'accept': '1',
          'updated_at': now,
        }, SetOptions(merge: true));
      }

      final userId = (data['user_id'] ?? '').toString().trim();
      if (userId.isNotEmpty) {
        await sendNotificationToUser(
          userId: userId,
          title: 'Artisan on the way',
          type: 'future_booking_in_progress',
          message:
              'Your artisan is on the way. Your booking is now in progress.',
          data: {
            'booking_id': id,
            'tasks_management_id': resolvedTmId,
          },
        );
      }

      return true;
    } catch (e) {
      debugPrint('markBookingInProgress error: $e');
      return false;
    }
  }

  /// Artisan cancels the appointment; immediately triggers reassignment.
  ///
  /// Uses the existing reassignment pipeline (closes old tasksManagement,
  /// creates a new one, updates service_provider_id, notifies user/artisan).
  static Future<bool> artisanCancelAndReassign({
    required String bookingId,
    String reason = 'artisan_cancelled',
  }) async {
    final id = bookingId.trim();
    if (id.isEmpty) return false;

    try {
      final snap = await futureBookingsRef.doc(id).get();
      if (!snap.exists) return false;
      final data = snap.data() ?? <String, dynamic>{};
      if (data.isEmpty) return false;

      final booking = FutureBookingModel.fromDocument(data);
      booking.id ??= id;

      final now = DateTime.now().toString();
      await futureBookingsRef.doc(id).set({
        'cancelled_by_artisan': 'yes',
        'cancel_reason': reason,
        'cancelled_by_artisan_at': now,
        'updated_at': now,
      }, SetOptions(merge: true));

      final ok = await reassignBooking(bookingId: id, booking: booking);
      if (!ok) return false;

      final userId = (data['user_id'] ?? '').toString().trim();
      if (userId.isNotEmpty) {
        await sendNotificationToUser(
          userId: userId,
          title: 'Booking updated',
          type: 'future_booking_reassigned',
          message:
              'Your artisan is no longer available. We are assigning another artisan now.',
          data: {
            'booking_id': id,
          },
        );
      }

      return true;
    } catch (e) {
      debugPrint('artisanCancelAndReassign error: $e');
      return false;
    }
  }

  /// Send reminder notifications
  static Future<void> sendReminderNotifications() async {
    // Backwards compatible: keep the old method but do nothing unless explicitly
    // called by an admin context. Prefer sendReminderNotificationsForUser/Artisan.
    try {
      DateTime now = DateTime.now();

      // Get all active bookings that can receive reminders
      QuerySnapshot bookingsSnapshot = await futureBookingsRef.where('status',
          whereIn: [
            'pending',
            'confirmed',
            'pending_payment',
            'accepted',
            'pending_assignment'
          ]).get();

      for (var bookingDoc in bookingsSnapshot.docs) {
        var data = bookingDoc.data() as Map<String, dynamic>;
        FutureBookingModel booking = FutureBookingModel.fromDocument(data);

        final scheduledDateTime = _tryParseScheduledDateTime(
          booking.scheduledDate ?? '',
          booking.scheduledTime,
        );
        if (scheduledDateTime == null) continue;
        Duration timeUntil = scheduledDateTime.difference(now);

        // Send 1-day reminder
        if (timeUntil.inHours <= 24 &&
            timeUntil.inHours > 23 &&
            booking.oneDayReminderSent != 'yes') {
          await send1DayReminder(booking);
          await futureBookingsRef
              .doc(booking.id)
              .update({'one_day_reminder_sent': 'yes'});
        }

        // Send 1-hour reminder
        if (timeUntil.inHours <= 1 &&
            timeUntil.inMinutes > 30 &&
            booking.oneHourReminderSent != 'yes') {
          await send1HourReminder(booking);
          await futureBookingsRef
              .doc(booking.id)
              .update({'one_hour_reminder_sent': 'yes'});
        }
      }
    } catch (e) {
      debugPrint('Error sending reminder notifications: $e');
    }
  }

  static Future<void> sendReminderNotificationsForUser({
    required String userId,
  }) async {
    final uid = userId.trim();
    if (uid.isEmpty) return;
    return _sendReminderNotificationsForQuery(
      query: futureBookingsRef
          .where('user_id', isEqualTo: uid)
          .where('status', whereIn: [
        'pending',
        'confirmed',
        'pending_payment',
        'accepted',
        'pending_assignment',
      ]),
    );
  }

  static Future<void> sendReminderNotificationsForArtisan({
    required String artisanId,
  }) async {
    final aid = artisanId.trim();
    if (aid.isEmpty) return;
    return _sendReminderNotificationsForQuery(
      query: futureBookingsRef
          .where('service_provider_id', isEqualTo: aid)
          .where('status', whereIn: [
        'pending',
        'confirmed',
        'pending_payment',
        'accepted',
        'pending_assignment',
      ]),
    );
  }

  static Future<void> _sendReminderNotificationsForQuery({
    required Query query,
  }) async {
    try {
      final now = DateTime.now();
      final bookingsSnapshot = await query.get();

      for (final bookingDoc in bookingsSnapshot.docs) {
        final data = bookingDoc.data() as Map<String, dynamic>;
        final isRfq = (data['is_rfq'] ?? '').toString().trim().toLowerCase();
        if (isRfq == 'yes') continue;

        final booking = FutureBookingModel.fromDocument(data);
        final scheduledDateTime = _tryParseScheduledDateTime(
          booking.scheduledDate ?? '',
          booking.scheduledTime,
        );
        if (scheduledDateTime == null) continue;

        final timeUntil = scheduledDateTime.difference(now);

        if (timeUntil.inHours <= 24 &&
            timeUntil.inHours > 23 &&
            booking.oneDayReminderSent != 'yes') {
          await send1DayReminder(booking);
          await futureBookingsRef
              .doc(booking.id)
              .update({'one_day_reminder_sent': 'yes'});
        }

        if (timeUntil.inHours <= 1 &&
            timeUntil.inMinutes > 30 &&
            booking.oneHourReminderSent != 'yes') {
          await send1HourReminder(booking);
          await futureBookingsRef
              .doc(booking.id)
              .update({'one_hour_reminder_sent': 'yes'});
        }

        // Wallet restore rule: if the job is not completed and no before/after evidence
        // exists 1 day after the scheduled time, restore wallet.
        await _maybeRefundOverdueBooking(
          bookingData: data,
          booking: booking,
          scheduledDateTime: scheduledDateTime,
          now: now,
        );
      }
    } catch (e) {
      debugPrint('Error sending scoped reminder notifications: $e');
    }
  }

  static Future<void> send1DayReminder(FutureBookingModel booking) async {
    // Send to customer
    await sendNotificationToUser(
      userId: booking.userId!,
      message:
          'Reminder: Your booking is scheduled for tomorrow at ${booking.scheduledTime}. Please confirm your availability.',
    );

    // Send to artisan
    await sendNotificationToArtisan(
      artisanId: booking.serviceProviderId!,
      bookingId: booking.id!,
      message:
          'Reminder: You have a booking scheduled for tomorrow at ${booking.scheduledTime}. Please confirm your availability.',
    );
  }

  static Future<void> send1HourReminder(FutureBookingModel booking) async {
    // Send to customer
    await sendNotificationToUser(
      userId: booking.userId!,
      message:
          'Reminder: Your booking starts in 1 hour at ${booking.scheduledTime}.',
    );

    // Send to artisan
    await sendNotificationToArtisan(
      artisanId: booking.serviceProviderId!,
      bookingId: booking.id!,
      message:
          'Reminder: You have a booking in 1 hour at ${booking.scheduledTime}.',
    );
  }

  static Future<void> sendNotificationToUser({
    required String userId,
    required String message,
    String? title,
    String? type,
    Map<String, dynamic>? data,
  }) async {
    try {
      DocumentSnapshot userDoc = await userRef.doc(userId).get();
      if (!userDoc.exists) return;

      var userData = userDoc.data() as Map<String, dynamic>;
      final String fcmToken =
          ((userData['fcm_token'] ?? userData['deviceToken'] ?? '').toString())
              .trim();

      if (fcmToken.isNotEmpty) {
        final payload = <String, dynamic>{
          'type': (type ?? 'future_booking_reminder').toString(),
        };
        if (data != null) {
          payload.addAll(data);
        }

        await sendFCMNotification(
          token: fcmToken,
          title: (title?.trim().isNotEmpty ?? false)
              ? title!.trim()
              : 'Booking Reminder',
          body: message,
          data: payload,
        );
      }
    } catch (e) {
      debugPrint('Error sending notification to user: $e');
    }
  }

  static Future<void> sendNotificationToArtisan({
    required String artisanId,
    required String bookingId,
    required String message,
    bool isReassignment = false,
  }) async {
    try {
      print(
          '[NOTIFICATION] Attempting to send notification to artisan=$artisanId for booking=$bookingId');

      final providerDoc = await _getServiceProviderDocByAnyId(artisanId);
      if (providerDoc == null || !providerDoc.exists) {
        print(
            '[NOTIFICATION] ERROR: Artisan doc not found for artisanId=$artisanId');
        return;
      }

      print('[NOTIFICATION] Found artisan doc id=${providerDoc.id}');
      final artisanData = providerDoc.data() ?? <String, dynamic>{};
      final String fcmToken =
          ((artisanData['fcm_token'] ?? artisanData['deviceToken'] ?? '')
                  .toString())
              .trim();

      final tokenPreview = fcmToken.isEmpty
          ? 'EMPTY/MISSING'
          : 'Found (${fcmToken.substring(0, fcmToken.length < 20 ? fcmToken.length : 20)}...)';
      print('[NOTIFICATION] Artisan FCM token: $tokenPreview');

      if (fcmToken.isNotEmpty) {
        print('[NOTIFICATION] Sending FCM notification to artisan...');
        await sendFCMNotification(
          token: fcmToken,
          title: isReassignment
              ? 'New Booking Assignment'
              : 'Booking Notification',
          body: message,
          data: {
            'type': 'future_booking',
            'booking_id': bookingId,
          },
        );
        print('[NOTIFICATION] FCM notification sent successfully');
      } else {
        print(
            '[NOTIFICATION] WARNING: No FCM token found for artisan=$artisanId - notification will only be stored in database');
      }

      // Store notification in database for in-app display
      print('[NOTIFICATION] Storing notification in database...');
      final docRef = await notificationsRef.add({
        'user_id': artisanId,
        'user_type': 'artisan',
        'title':
            isReassignment ? 'New Booking Assignment' : 'Booking Notification',
        'message': message,
        'booking_id': bookingId,
        'type': 'future_booking',
        'read': false,
        'created_at': DateTime.now().toString(),
      });
      print(
          '[NOTIFICATION] Notification stored successfully with id=${docRef.id}');
    } catch (e, stackTrace) {
      print(
          '[NOTIFICATION] ERROR sending notification to artisan=$artisanId: $e');
      print('[NOTIFICATION] Stack trace: $stackTrace');
      debugPrint('Error sending notification to artisan: $e');
    }
  }

  static Future<void> sendNotificationToAdmin({
    required String bookingId,
    required String message,
    String title = 'RFQ Request',
    String type = 'rfq_request',
    Map<String, dynamic>? data,
  }) async {
    try {
      final adminDocs = <QueryDocumentSnapshot>[];

      // Primary: admins live in `users` with `isAdmin == true`.
      try {
        final snap =
            await userRef.where('isAdmin', isEqualTo: true).limit(10).get();
        adminDocs.addAll(snap.docs);
      } catch (_) {}

      // Legacy fallback: some projects have a separate `admin` collection.
      try {
        final snap = await adminRef.limit(10).get();
        adminDocs.addAll(snap.docs);
      } catch (_) {}

      final sentTokens = <String>{};
      var storedCount = 0;

      for (final adminDoc in adminDocs) {
        final adminData =
            (adminDoc.data() as Map<String, dynamic>?) ?? <String, dynamic>{};
        final token =
            ((adminData['fcm_token'] ?? adminData['deviceToken'] ?? '')
                    .toString())
                .trim();

        if (token.isNotEmpty && !sentTokens.contains(token)) {
          sentTokens.add(token);
          await sendFCMNotification(
            token: token,
            title: title,
            body: message,
            data: {
              'type': type,
              'booking_id': bookingId,
              ...?data,
            },
          );
        }

        // Store per-admin notification (in-app)
        await notificationsRef.add({
          'user_id': adminDoc.id,
          'user_type': 'admin',
          'title': title,
          'message': message,
          'booking_id': bookingId,
          'type': type,
          'read': false,
          'created_at': DateTime.now().toString(),
        });
        storedCount++;
      }

      // If no admins were found, still store a single generic admin notification.
      if (storedCount == 0) {
        await notificationsRef.add({
          'user_id': 'admin',
          'user_type': 'admin',
          'title': title,
          'message': message,
          'booking_id': bookingId,
          'type': type,
          'read': false,
          'created_at': DateTime.now().toString(),
        });
      }
    } catch (e) {
      debugPrint('Error sending notification to admin: $e');
    }
  }

  static Future<void> sendFCMNotification({
    required String token,
    required String title,
    required String body,
    Map<String, dynamic>? data,
  }) async {
    try {
      await BackendFcmService.sendNotification(
        token: token,
        title: title,
        body: body,
        data: data,
      );
    } catch (e) {
      if (kDebugMode) debugPrint('Error sending FCM notification: $e');
    }
  }

  /// Check for expired confirmations and reassign
  static Future<void> checkConfirmationDeadlines() async {
    try {
      DateTime now = DateTime.now();

      QuerySnapshot bookingsSnapshot =
          await futureBookingsRef.where('status', isEqualTo: 'pending').get();

      for (var bookingDoc in bookingsSnapshot.docs) {
        var data = bookingDoc.data() as Map<String, dynamic>;
        FutureBookingModel booking = FutureBookingModel.fromDocument(data);

        DateTime scheduledDateTime =
            DateTime.parse('${booking.scheduledDate} ${booking.scheduledTime}');
        Duration timeUntil = scheduledDateTime.difference(now);

        // If artisan hasn't confirmed 24 hours before scheduled time, reassign
        if (timeUntil.inHours < 24 && booking.artisanConfirmed != 'yes') {
          debugPrint(
              'Artisan did not confirm, reassigning booking ${booking.id}');
          await reassignBooking(bookingId: booking.id!, booking: booking);
        }
      }
    } catch (e) {
      debugPrint('Error checking confirmation deadlines: $e');
    }
  }
}
