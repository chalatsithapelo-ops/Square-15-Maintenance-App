import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

/// Tracks artisan penalties for suspicious behavior such as:
/// - Client cancels after artisan is on-site (potential pressure/extortion)
/// - Artisan demands extra payment outside the app
/// - Consistently poor artisan behavior
///
/// Admin reviews flagged cases in the admin app.
class ArtisanPenaltyService {
  static final _firestore = FirebaseFirestore.instance;
  static final penaltiesRef = _firestore.collection('artisan_penalties');

  /// Flag a suspicious on-site cancellation.
  /// Called when a client cancels AFTER artisan status is 'progress' (on-site).
  static Future<void> flagOnSiteCancellation({
    required String taskManagementId,
    required String artisanId,
    required String clientId,
    String? reason,
  }) async {
    try {
      await penaltiesRef.add({
        'task_id': taskManagementId,
        'artisan_id': artisanId,
        'client_id': clientId,
        'type': 'on_site_cancellation',
        'reason': reason ?? '',
        'status': 'pending_review', // pending_review, reviewed, dismissed, penalized
        'created_at': DateTime.now().toString(),
        'reviewed_at': null,
        'reviewed_by': null,
        'penalty_action': null, // warning, suspension, termination
        'notes': '',
      });
    } catch (e) {
      debugPrint('[ArtisanPenaltyService] flagOnSiteCancellation error: $e');
    }
  }

  /// Flag artisan for demanding off-app payment.
  static Future<void> flagOffAppPayment({
    required String taskManagementId,
    required String artisanId,
    required String clientId,
    String? details,
  }) async {
    try {
      await penaltiesRef.add({
        'task_id': taskManagementId,
        'artisan_id': artisanId,
        'client_id': clientId,
        'type': 'off_app_payment_demand',
        'reason': details ?? '',
        'status': 'pending_review',
        'created_at': DateTime.now().toString(),
        'reviewed_at': null,
        'reviewed_by': null,
        'penalty_action': null,
        'notes': '',
      });
    } catch (e) {
      debugPrint('[ArtisanPenaltyService] flagOffAppPayment error: $e');
    }
  }

  /// Flag artisan for receiving a bad review (rating <= 2).
  static Future<void> flagBadReview({
    required String taskManagementId,
    required String artisanId,
    required String clientId,
    required double rating,
    String? feedback,
  }) async {
    try {
      await penaltiesRef.add({
        'task_id': taskManagementId,
        'artisan_id': artisanId,
        'client_id': clientId,
        'type': 'bad_review',
        'reason': 'Client rated ${rating.toStringAsFixed(1)}/5${feedback != null && feedback.isNotEmpty ? ': $feedback' : ''}',
        'status': 'pending_review',
        'created_at': DateTime.now().toString(),
        'reviewed_at': null,
        'reviewed_by': null,
        'penalty_action': null,
        'notes': '',
      });
    } catch (e) {
      debugPrint('[ArtisanPenaltyService] flagBadReview error: $e');
    }
  }

  /// Get the number of pending penalties for an artisan.
  static Future<int> getPenaltyCount(String artisanId) async {
    try {
      final snap = await penaltiesRef
          .where('artisan_id', isEqualTo: artisanId)
          .where('status', isEqualTo: 'penalized')
          .count()
          .get();
      return snap.count ?? 0;
    } catch (e) {
      debugPrint('[ArtisanPenaltyService] getPenaltyCount error: $e');
      return 0;
    }
  }

  /// Stream of all pending review cases (for admin).
  static Stream<QuerySnapshot> streamPendingReviews() {
    return penaltiesRef
        .where('status', isEqualTo: 'pending_review')
        .orderBy('created_at', descending: true)
        .snapshots();
  }

  /// Admin reviews and takes action on a penalty case.
  static Future<void> reviewPenalty({
    required String penaltyId,
    required String reviewedBy,
    required String action, // 'dismissed', 'warning', 'suspension', 'termination'
    String? notes,
  }) async {
    try {
      await penaltiesRef.doc(penaltyId).update({
        'status': action == 'dismissed' ? 'dismissed' : 'penalized',
        'penalty_action': action,
        'reviewed_at': DateTime.now().toString(),
        'reviewed_by': reviewedBy,
        'notes': notes ?? '',
      });
    } catch (e) {
      debugPrint('[ArtisanPenaltyService] reviewPenalty error: $e');
    }
  }
}
