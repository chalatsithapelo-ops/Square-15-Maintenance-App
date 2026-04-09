import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

/// Lightweight error reporting service that logs user-facing errors
/// to Firestore so admin can see and fix them in real time.
///
/// Writes to two collections:
/// - `error_logs` — structured error entries for monitoring
/// - `Notifications` — admin alerts that appear in the admin inbox
class ErrorReportingService {
  ErrorReportingService._();

  static final _firestore = FirebaseFirestore.instance;

  /// Report a user-facing error to admin.
  ///
  /// [errorType] — category: 'payment_error', 'image_upload_error',
  ///   'booking_error', 'media_download_error', 'transcription_error', etc.
  /// [description] — human-readable description of what went wrong.
  /// [source] — originating platform: 'client_app', 'ai_text_chat',
  ///   'ai_voice_agent', 'whatsapp_bot'.
  /// [errorDetails] — raw error message / stack trace (for debugging).
  /// [bookingId] — related booking if applicable.
  /// [severity] — 'low', 'medium', 'high', 'critical'.
  static Future<void> reportError({
    required String errorType,
    required String description,
    required String source,
    String? errorDetails,
    String? bookingId,
    String severity = 'medium',
  }) async {
    try {
      final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
      final errorId = _firestore.collection('error_logs').doc().id;

      // 1. Write structured error log
      await _firestore.collection('error_logs').doc(errorId).set({
        'id': errorId,
        'error_type': errorType,
        'description': description,
        'source': source,
        'error_details': errorDetails ?? '',
        'booking_id': bookingId ?? '',
        'user_id': uid,
        'severity': severity,
        'status': 'open',
        'created_at': FieldValue.serverTimestamp(),
      });

      // 2. Create admin notification so it appears in real-time popup alerts
      await _firestore.collection('Notifications').add({
        'title': _severityIcon(severity) + ' ' + _errorTypeLabel(errorType),
        'body': description,
        'type': 'error_report',
        'error_id': errorId,
        'booking_id': bookingId ?? '',
        'target': 'admin',
        'user_type': 'admin',
        'read': false,
        'timestamp': FieldValue.serverTimestamp(),
        'created_at': FieldValue.serverTimestamp(),
      });

      debugPrint('[ErrorReporting] Reported $errorType ($severity): $description');
    } catch (e) {
      // Last resort — don't let error reporting itself crash the app
      debugPrint('[ErrorReporting] Failed to report error: $e');
    }
  }

  /// Auto-create a support case from a detected error (higher severity).
  static Future<String?> reportErrorAsSupportCase({
    required String errorType,
    required String description,
    required String source,
    String? errorDetails,
    String? bookingId,
    String severity = 'high',
  }) async {
    try {
      final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
      final caseId =
          _firestore.collection('customer_support_cases').doc().id;

      // 1. Create support case
      await _firestore
          .collection('customer_support_cases')
          .doc(caseId)
          .set({
        'id': caseId,
        'user_id': uid,
        'subject': _errorTypeLabel(errorType),
        'description':
            '$description\n\nAuto-detected by: $source\nError: ${errorDetails ?? 'N/A'}',
        'booking_id': bookingId ?? '',
        'status': 'open',
        'priority': severity == 'critical' ? 'high' : 'normal',
        'source': source,
        'auto_generated': true,
        'error_type': errorType,
        'created_at': FieldValue.serverTimestamp(),
      });

      // 2. Also log to error_logs
      await reportError(
        errorType: errorType,
        description: description,
        source: source,
        errorDetails: errorDetails,
        bookingId: bookingId,
        severity: severity,
      );

      return caseId;
    } catch (e) {
      debugPrint('[ErrorReporting] Failed to create support case: $e');
      return null;
    }
  }

  static String _severityIcon(String severity) {
    switch (severity) {
      case 'critical':
        return '🔴';
      case 'high':
        return '🟠';
      case 'medium':
        return '🟡';
      default:
        return '🔵';
    }
  }

  static String _errorTypeLabel(String errorType) {
    switch (errorType) {
      case 'payment_error':
        return 'Payment Error';
      case 'image_upload_error':
        return 'Image Upload Failed';
      case 'booking_error':
        return 'Booking Creation Failed';
      case 'media_download_error':
        return 'Media Download Failed';
      case 'transcription_error':
        return 'Voice Transcription Failed';
      case 'rfq_quote_error':
        return 'RFQ Quote Generation Failed';
      case 'artisan_dispatch_error':
        return 'Artisan Dispatch Failed';
      case 'wallet_error':
        return 'Wallet Transaction Failed';
      case 'network_error':
        return 'Network/API Error';
      default:
        return 'System Error: $errorType';
    }
  }
}
