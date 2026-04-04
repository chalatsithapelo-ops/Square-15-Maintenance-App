import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

/// Unified refund service for all payment methods and booking types.
///
/// Supports:
///  - Wallet refunds (normal + future bookings)
///  - PayFast refund API calls
///  - Commission clawback when refunds are processed
///  - Admin-initiated refunds via Firestore refund_requests collection
class RefundService {
  static final _tasksRef =
      FirebaseFirestore.instance.collection('tasksManagement');
  static final _futureBookingsRef =
      FirebaseFirestore.instance.collection('futureBookings');
  static final _usersRef = FirebaseFirestore.instance.collection('users');
  static final _transactionsRef =
      FirebaseFirestore.instance.collection('transactionLogs');
  static final _commissionsRef =
      FirebaseFirestore.instance.collection('commissions');
  static final _partnersRef =
      FirebaseFirestore.instance.collection('corporate_partners');
  static final _refundRequestsRef =
      FirebaseFirestore.instance.collection('refund_requests');

  // ─────────────────────────────────────────────────────────────────
  // Refund for NORMAL bookings (tasksManagement)
  // ─────────────────────────────────────────────────────────────────

  /// Process a wallet refund for a normal (non-future) booking.
  ///
  /// Idempotent — checks `wallet_refunded` flag.
  static Future<RefundResult> refundNormalBooking({
    required String taskManagementId,
    required String reason,
    String? initiatedBy,
  }) async {
    final id = taskManagementId.trim();
    if (id.isEmpty) return RefundResult.fail('Missing task ID');

    try {
      final tmSnap = await _tasksRef.doc(id).get();
      if (!tmSnap.exists) return RefundResult.fail('Task not found');

      final tmData = tmSnap.data() ?? {};
      final paymentStatus =
          (tmData['payment_status'] ?? '').toString().toLowerCase();
      if (paymentStatus != 'paid' && paymentStatus != 'deposit_paid') {
        return RefundResult.fail('No payment recorded on this task');
      }

      // Check if already refunded
      final alreadyRefunded = _isYes(tmData['wallet_refunded']) ||
          tmData['wallet_refunded'] == true ||
          (tmData['refund_status'] ?? '').toString().toLowerCase() ==
              'refunded';
      if (alreadyRefunded) {
        return RefundResult(
            success: true,
            method: 'already_refunded',
            amount: 0,
            message: 'Already refunded');
      }

      final paymentMethod =
          (tmData['payment_method'] ?? tmData['payment'] ?? '')
              .toString()
              .toLowerCase();
      final userId = (tmData['user_id'] ?? tmData['userId'] ?? '')
          .toString()
          .trim();

      // Find the original transaction to get the amount
      double refundAmount = _toDouble(tmData['cost']) ??
          _toDouble(tmData['total_cost']) ??
          0.0;

      // Look up original transaction for exact amount
      try {
        final txSnap = await _transactionsRef
            .where('tasks_management_id', isEqualTo: id)
            .where('subtype', isEqualTo: 'service_payment')
            .where('status', isEqualTo: 'success')
            .limit(1)
            .get();
        if (txSnap.docs.isNotEmpty) {
          final txAmount =
              _toDouble(txSnap.docs.first.data()['amount']);
          if (txAmount != null && txAmount > 0) {
            refundAmount = txAmount;
          }
        }
      } catch (_) {}

      if (refundAmount <= 0) {
        return RefundResult.fail('Could not determine refund amount');
      }

      if (paymentMethod == 'wallet') {
        return await _refundToWallet(
          docRef: _tasksRef.doc(id),
          docType: 'tasksManagement',
          userId: userId,
          amount: refundAmount,
          reason: reason,
          taskManagementId: id,
          initiatedBy: initiatedBy,
        );
      } else {
        // PayFast / BNPL — create a refund request for admin processing
        return await _createRefundRequest(
          docId: id,
          docType: 'tasksManagement',
          userId: userId,
          amount: refundAmount,
          paymentMethod: paymentMethod,
          reason: reason,
          initiatedBy: initiatedBy,
        );
      }
    } catch (e) {
      debugPrint('refundNormalBooking error: $e');
      return RefundResult.fail('Error: $e');
    }
  }

  // ─────────────────────────────────────────────────────────────────
  // Refund for FUTURE bookings
  // ─────────────────────────────────────────────────────────────────

  /// Process a refund for a future booking.
  /// For wallet payments, refunds immediately.
  /// For card payments, creates a refund request.
  static Future<RefundResult> refundFutureBooking({
    required String bookingId,
    required String reason,
    String? initiatedBy,
  }) async {
    final id = bookingId.trim();
    if (id.isEmpty) return RefundResult.fail('Missing booking ID');

    try {
      final snap = await _futureBookingsRef.doc(id).get();
      if (!snap.exists) return RefundResult.fail('Booking not found');

      final data = snap.data() ?? {};

      final alreadyRefunded = _isYes(data['wallet_refunded']) ||
          data['wallet_refunded'] == true ||
          (data['refund_status'] ?? '').toString().toLowerCase() == 'refunded';
      if (alreadyRefunded) {
        return RefundResult(
            success: true,
            method: 'already_refunded',
            amount: 0,
            message: 'Already refunded');
      }

      final paymentMethod =
          (data['payment_method'] ?? '').toString().toLowerCase();
      final userId =
          (data['user_id'] ?? '').toString().trim();

      double refundAmount = _toDouble(data['wallet_deduct_amount']) ??
          _toDouble(data['wallet_deducted_amount']) ??
          _toDouble(data['payment_amount']) ??
          _toDouble(data['cost']) ??
          0.0;

      if (refundAmount <= 0) {
        return RefundResult.fail('Could not determine refund amount');
      }

      final wasWalletDeducted = _isYes(data['wallet_deducted']) ||
          data['wallet_deducted'] == true;

      if (wasWalletDeducted || paymentMethod == 'wallet') {
        return await _refundToWallet(
          docRef: _futureBookingsRef.doc(id),
          docType: 'futureBookings',
          userId: userId,
          amount: refundAmount,
          reason: reason,
          taskManagementId:
              (data['tasks_management_id'] ?? '').toString().trim(),
          bookingId: id,
          initiatedBy: initiatedBy,
        );
      } else {
        return await _createRefundRequest(
          docId: id,
          docType: 'futureBookings',
          userId: userId,
          amount: refundAmount,
          paymentMethod: paymentMethod,
          reason: reason,
          initiatedBy: initiatedBy,
        );
      }
    } catch (e) {
      debugPrint('refundFutureBooking error: $e');
      return RefundResult.fail('Error: $e');
    }
  }

  // ─────────────────────────────────────────────────────────────────
  // Wallet refund (atomic)
  // ─────────────────────────────────────────────────────────────────

  static Future<RefundResult> _refundToWallet({
    required DocumentReference docRef,
    required String docType,
    required String userId,
    required double amount,
    required String reason,
    String taskManagementId = '',
    String bookingId = '',
    String? initiatedBy,
  }) async {
    if (userId.isEmpty) return RefundResult.fail('Missing user ID');
    if (amount <= 0) return RefundResult.fail('Invalid amount');

    final txId = const Uuid().v4();
    final now = DateTime.now().toString();

    try {
      return await FirebaseFirestore.instance.runTransaction((tx) async {
        final docSnap = await tx.get(docRef);
        if (!docSnap.exists) return RefundResult.fail('Document not found');

        final userDocRef = _usersRef.doc(userId);
        final userSnap = await tx.get(userDocRef);
        final userData = userSnap.data() ?? {};
        final currentBalance = _toDouble(userData['balance']) ?? 0.0;
        final newBalance = currentBalance + amount;

        // Update user balance
        tx.update(userDocRef, {
          'balance': _moneyString(newBalance),
        });

        // Mark document as refunded
        tx.update(docRef, {
          'wallet_refunded': 'yes',
          'wallet_refund_reason': reason,
          'wallet_refund_amount': amount,
          'wallet_refunded_at': now,
          'wallet_refund_txn_id': txId,
          'refund_status': 'refunded',
          'refund_method': 'wallet',
          'updated_at': now,
        });

        // Create refund transaction log
        tx.set(_transactionsRef.doc(txId), {
          'id': txId,
          'amount': _moneyString(amount),
          'transaction_at': now,
          'status': 'success',
          'booking_id': bookingId,
          'tasks_management_id': taskManagementId,
          'transaction_by': initiatedBy ?? userId,
          'user_id': userId,
          'type': 'wallet',
          'subtype': 'refund',
          'direction': 'in',
          'cash_movement': false,
          'profit': '0.00',
          'schema_version': 2,
          'reason': reason,
          'balance': _moneyString(newBalance),
          'balance_after': _moneyString(newBalance),
          'previous_balance': _moneyString(currentBalance),
          'refund_source': docType,
        });

        return RefundResult(
          success: true,
          method: 'wallet',
          amount: amount,
          transactionId: txId,
          message:
              'R${amount.toStringAsFixed(2)} refunded to wallet',
        );
      });
    } catch (e) {
      debugPrint('_refundToWallet error: $e');
      return RefundResult.fail('Wallet refund failed: $e');
    }
  }

  // ─────────────────────────────────────────────────────────────────
  // Create refund request (for PayFast/BNPL — admin processes)
  // ─────────────────────────────────────────────────────────────────

  static Future<RefundResult> _createRefundRequest({
    required String docId,
    required String docType,
    required String userId,
    required double amount,
    required String paymentMethod,
    required String reason,
    String? initiatedBy,
  }) async {
    final requestId = const Uuid().v4();
    final now = DateTime.now().toString();

    try {
      // Check for duplicate request
      final existing = await _refundRequestsRef
          .where('source_doc_id', isEqualTo: docId)
          .where('status', whereIn: ['pending', 'approved', 'processed'])
          .limit(1)
          .get();
      if (existing.docs.isNotEmpty) {
        return RefundResult(
          success: true,
          method: 'pending_admin_review',
          amount: amount,
          message: 'Refund request already submitted — pending admin review',
        );
      }

      // Look up user info
      String userName = '';
      String userEmail = '';
      try {
        final userDoc = await _usersRef.doc(userId).get();
        final ud = userDoc.data() ?? {};
        userName = (ud['name'] ?? ud['userName'] ?? '').toString();
        userEmail = (ud['email'] ?? '').toString();
      } catch (_) {}

      await _refundRequestsRef.doc(requestId).set({
        'id': requestId,
        'source_doc_id': docId,
        'source_doc_type': docType,
        'user_id': userId,
        'user_name': userName,
        'user_email': userEmail,
        'amount': amount,
        'payment_method': paymentMethod,
        'reason': reason,
        'status': 'pending',
        'initiated_by': initiatedBy ?? userId,
        'created_at': now,
        'updated_at': now,
      });

      return RefundResult(
        success: true,
        method: 'pending_admin_review',
        amount: amount,
        message:
            'Refund request submitted (R${amount.toStringAsFixed(2)} via $paymentMethod). '
            'Admin will process within 3–5 business days.',
      );
    } catch (e) {
      debugPrint('_createRefundRequest error: $e');
      return RefundResult.fail('Failed to submit refund request: $e');
    }
  }

  // ─────────────────────────────────────────────────────────────────
  // Commission clawback
  // ─────────────────────────────────────────────────────────────────

  /// Reverse any partner commission linked to a refunded task.
  static Future<void> clawbackCommission({
    required String taskManagementId,
    String? bookingId,
  }) async {
    try {
      // Find commissions for this task
      QuerySnapshot<Map<String, dynamic>> commSnap;
      commSnap = await _commissionsRef
          .where('task_management_id', isEqualTo: taskManagementId)
          .get();

      if (commSnap.docs.isEmpty && bookingId != null && bookingId.isNotEmpty) {
        commSnap = await _commissionsRef
            .where('booking_id', isEqualTo: bookingId)
            .get();
      }

      if (commSnap.docs.isEmpty) return;

      final db = FirebaseFirestore.instance;
      final now = DateTime.now().toString();

      // Use a transaction to prevent double-clawback race conditions
      await db.runTransaction((tx) async {
        for (final doc in commSnap.docs) {
          // Re-read inside transaction for consistency
          final freshSnap = await tx.get(doc.reference);
          if (!freshSnap.exists) continue;
          final data = freshSnap.data() ?? {};
          final status = (data['status'] ?? '').toString().toLowerCase();
          if (status == 'clawed_back') continue;

          final commAmount = _toDouble(data['commission_amount']) ?? 0.0;
          final partnerId = (data['partner_id'] ?? '').toString().trim();

          tx.update(doc.reference, {
            'status': 'clawed_back',
            'clawed_back_at': now,
            'previous_status': status,
          });

          if (partnerId.isNotEmpty && commAmount > 0) {
            tx.update(_partnersRef.doc(partnerId), {
              'pending_payout': FieldValue.increment(-commAmount),
              'total_earned': FieldValue.increment(-commAmount),
              'updated_at': now,
            });
          }
        }
      });
      debugPrint(
          '[RefundService] Clawed back ${commSnap.docs.length} commission(s) '
          'for task=$taskManagementId');
    } catch (e) {
      debugPrint('[RefundService] clawbackCommission error: $e');
    }
  }

  // ─────────────────────────────────────────────────────────────────
  // Admin: process a refund request
  // ─────────────────────────────────────────────────────────────────

  /// Admin approves and processes a refund request.
  /// For wallet refunds, credits the user immediately.
  /// For PayFast/BNPL, marks as processed (admin does EFT/API manually).
  static Future<RefundResult> adminProcessRefundRequest({
    required String requestId,
    required String adminUserId,
    String method = 'wallet',
  }) async {
    try {
      final reqSnap = await _refundRequestsRef.doc(requestId).get();
      if (!reqSnap.exists) return RefundResult.fail('Request not found');

      final reqData = reqSnap.data() ?? {};
      final status = (reqData['status'] ?? '').toString().toLowerCase();
      if (status != 'pending') {
        return RefundResult.fail('Request is already $status');
      }

      final userId = (reqData['user_id'] ?? '').toString().trim();
      final amount = _toDouble(reqData['amount']) ?? 0.0;
      final sourceDocId =
          (reqData['source_doc_id'] ?? '').toString().trim();
      final sourceDocType =
          (reqData['source_doc_type'] ?? '').toString().trim();
      final reason = (reqData['reason'] ?? '').toString();

      if (amount <= 0) return RefundResult.fail('Invalid amount');

      final now = DateTime.now().toString();
      RefundResult result;

      if (method == 'wallet') {
        // Refund to wallet
        final docRef = sourceDocType == 'futureBookings'
            ? _futureBookingsRef.doc(sourceDocId)
            : _tasksRef.doc(sourceDocId);

        result = await _refundToWallet(
          docRef: docRef,
          docType: sourceDocType,
          userId: userId,
          amount: amount,
          reason: 'admin_approved_refund:$reason',
          taskManagementId:
              sourceDocType == 'tasksManagement' ? sourceDocId : '',
          bookingId:
              sourceDocType == 'futureBookings' ? sourceDocId : '',
          initiatedBy: adminUserId,
        );
      } else {
        // PayFast/BNPL — admin processed externally, just mark it
        final txId = const Uuid().v4();
        await _transactionsRef.doc(txId).set({
          'id': txId,
          'amount': _moneyString(amount),
          'transaction_at': now,
          'status': 'success',
          'tasks_management_id': sourceDocType == 'tasksManagement' ? sourceDocId : '',
          'booking_id': sourceDocType == 'futureBookings' ? sourceDocId : '',
          'transaction_by': adminUserId,
          'user_id': userId,
          'type': method,
          'subtype': 'refund',
          'direction': 'in',
          'cash_movement': true,
          'profit': '0.00',
          'schema_version': 2,
          'reason': 'admin_approved_refund:$reason',
          'refund_source': sourceDocType,
          'refund_request_id': requestId,
        });

        // Mark source document as refunded
        final docRef = sourceDocType == 'futureBookings'
            ? _futureBookingsRef.doc(sourceDocId)
            : _tasksRef.doc(sourceDocId);
        await docRef.update({
          'refund_status': 'refunded',
          'refund_method': method,
          'refund_amount': amount,
          'refunded_at': now,
          'refund_txn_id': txId,
          'updated_at': now,
        });

        result = RefundResult(
          success: true,
          method: method,
          amount: amount,
          transactionId: txId,
          message: 'Refund processed via $method',
        );
      }

      // Update the request document
      await _refundRequestsRef.doc(requestId).update({
        'status': result.success ? 'processed' : 'failed',
        'processed_at': now,
        'processed_by': adminUserId,
        'refund_method': method,
        'result_message': result.message,
        'updated_at': now,
      });

      // Clawback commission
      if (result.success) {
        final tmId = sourceDocType == 'tasksManagement'
            ? sourceDocId
            : (reqData['tasks_management_id'] ?? '').toString().trim();
        if (tmId.isNotEmpty) {
          await clawbackCommission(
            taskManagementId: tmId,
            bookingId:
                sourceDocType == 'futureBookings' ? sourceDocId : null,
          );
        }
      }

      return result;
    } catch (e) {
      debugPrint('adminProcessRefundRequest error: $e');
      return RefundResult.fail('Processing failed: $e');
    }
  }

  /// Admin rejects a refund request.
  static Future<void> adminRejectRefundRequest({
    required String requestId,
    required String adminUserId,
    String rejectionReason = '',
  }) async {
    final now = DateTime.now().toString();
    await _refundRequestsRef.doc(requestId).update({
      'status': 'rejected',
      'rejected_at': now,
      'rejected_by': adminUserId,
      'rejection_reason': rejectionReason,
      'updated_at': now,
    });
  }

  // ─────────────────────────────────────────────────────────────────
  // Helpers
  // ─────────────────────────────────────────────────────────────────

  static bool _isYes(dynamic v) =>
      v != null && v.toString().trim().toLowerCase() == 'yes';

  static double? _toDouble(dynamic v) {
    if (v == null) return null;
    if (v is num) return v.toDouble();
    final d = double.tryParse(v.toString());
    return d;
  }

  static String _moneyString(double v) => v.toStringAsFixed(2);
}

/// Result of a refund operation.
class RefundResult {
  final bool success;
  final String method;
  final double amount;
  final String? transactionId;
  final String message;

  RefundResult({
    required this.success,
    required this.method,
    required this.amount,
    this.transactionId,
    required this.message,
  });

  factory RefundResult.fail(String message) => RefundResult(
        success: false,
        method: 'none',
        amount: 0,
        message: message,
      );
}
