import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/services.dart';
import 'package:googleapis_auth/auth_io.dart';

class AdminNotificationService {
  static final _usersRef = FirebaseFirestore.instance.collection('users');
  static final _serviceProviderRef =
      FirebaseFirestore.instance.collection('serviceProvider');
  static final _notificationsRef =
      FirebaseFirestore.instance.collection('notifications');

  static Future<void> sendNotificationToUser({
    required String userId,
    required String title,
    required String message,
    String? bookingId,
    String type = 'rfq',
  }) async {
    try {
      final userDoc = await _usersRef.doc(userId).get();
      if (!userDoc.exists) return;

        final data = userDoc.data() ?? <String, dynamic>{};
        final token = ((data['fcm_token'] ?? data['deviceToken'] ?? '')
            .toString())
          .trim();

      if (token.isNotEmpty) {
        await sendFCMNotification(
          token: token,
          title: title,
          body: message,
          data: {
            'type': type,
            if (bookingId != null) 'booking_id': bookingId,
          },
        );
      }

      await _notificationsRef.add({
        'user_id': userId,
        'user_type': 'user',
        'title': title,
        'message': message,
        if (bookingId != null) 'booking_id': bookingId,
        'type': type,
        'read': false,
        'view': false,
        'created_at': DateTime.now().toString(),
      });
      print('[AdminNotif] Notification doc written for user $userId');
    } catch (e) {
      print('[AdminNotif] sendNotificationToUser ERROR: $e');
    }
  }

  static Future<void> sendNotificationToArtisan({
    required String artisanId,
    required String title,
    required String message,
    required String bookingId,
    String type = 'future_booking',
  }) async {
    try {
      final artisanDoc = await _serviceProviderRef.doc(artisanId).get();
      if (!artisanDoc.exists) {
        print('[AdminNotif] artisan doc NOT FOUND for $artisanId');
        return;
      }

      final data = artisanDoc.data() ?? <String, dynamic>{};
      final token = ((data['fcm_token'] ?? data['deviceToken'] ?? '')
              .toString())
          .trim();

      if (token.isNotEmpty) {
        print('[AdminNotif] Sending FCM to artisan $artisanId token=${token.substring(0, 10)}...');
        await sendFCMNotification(
          token: token,
          title: title,
          body: message,
          data: {
            'type': type,
            'booking_id': bookingId,
          },
        );
      } else {
        print('[AdminNotif] artisan $artisanId has NO FCM token — skipping push');
      }

      await _notificationsRef.add({
        'user_id': artisanId,
        'user_type': 'artisan',
        'title': title,
        'message': message,
        'booking_id': bookingId,
        'type': type,
        'read': false,
        'view': false,
        'created_at': DateTime.now().toString(),
      });
      print('[AdminNotif] Notification doc written for artisan $artisanId');
    } catch (e) {
      print('[AdminNotif] sendNotificationToArtisan ERROR: $e');
    }
  }

  static Future<void> sendFCMNotification({
    required String token,
    required String title,
    required String body,
    Map<String, dynamic>? data,
  }) async {
    try {
      final serviceAccount = json
          .decode(await rootBundle.loadString('assets/firebase-adminsdk.json'));
      final credentials = ServiceAccountCredentials.fromJson(serviceAccount);

      final client = await clientViaServiceAccount(
        credentials,
        ['https://www.googleapis.com/auth/firebase.messaging'],
      );

      final projectId = serviceAccount['project_id'];

      final response = await client.post(
        Uri.parse(
            'https://fcm.googleapis.com/v1/projects/$projectId/messages:send'),
        headers: {
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'message': {
            'token': token,
            'notification': {
              'title': title,
              'body': body,
            },
            'data': data ?? <String, dynamic>{},
            'android': {
              'priority': 'high',
            },
            'apns': {
              'headers': {
                'apns-priority': '10',
              },
            },
          }
        }),
      );

      client.close();

      if (response.statusCode != 200) {
        print('[AdminNotif] FCM FAILED (${response.statusCode}): ${response.body}');
      } else {
        print('[AdminNotif] FCM sent OK to token=${token.substring(0, 10)}...');
      }
    } catch (e) {
      print('[AdminNotif] sendFCMNotification ERROR: $e');
    }
  }
}
