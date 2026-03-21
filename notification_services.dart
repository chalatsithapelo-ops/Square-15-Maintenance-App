import 'dart:async';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:get/get.dart';
import 'package:maintenanceapp/controller/app_controller.dart';
import 'package:maintenanceapp/providers/position_provider.dart';
import 'package:maintenanceapp/screens/service_provider_panel/Serviceprovider/notification_screen.dart';
import 'package:maintenanceapp/utils/navigation.dart';
import 'package:provider/provider.dart';

class NotificationService {
  static final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
      FlutterLocalNotificationsPlugin();

  static StreamSubscription<String>? _tokenRefreshSub;

  static Future<String?> _safeGetToken() async {
    try {
      final token = await FirebaseMessaging.instance
          .getToken()
          .timeout(const Duration(seconds: 6));
      if (token == null || token.trim().isEmpty) return null;
      return token;
    } catch (_) {
      return null;
    }
  }

  static Future<void> syncFcmTokenForCurrentLogin() async {
    final token = await _safeGetToken();
    if (token == null) return;

    String userId = '';
    try {
      userId = Get.find<AppController>().userId.value;
    } catch (_) {
      userId = '';
    }
    if (userId.trim().isEmpty) {
      userId = (FirebaseAuth.instance.currentUser?.uid ?? '').toString();
    }
    userId = userId.trim();
    if (userId.isEmpty) return;

    final firestore = FirebaseFirestore.instance;

    Future<void> tryUpdate(String collection) async {
      try {
        final docRef = firestore.collection(collection).doc(userId);
        final doc = await docRef.get();
        if (!doc.exists) return;
        await docRef.update({
          'deviceToken': token,
          'fcm_token': token,
          'fcm_token_updated_at': FieldValue.serverTimestamp(),
          'is_online': true,
          'last_seen': FieldValue.serverTimestamp(),
        });
      } catch (_) {
        // ignore
      }
    }

    // Update whichever profile doc exists for this login.
    await tryUpdate('users');
    await tryUpdate('serviceProvider');
  }

  static void startTokenSyncListener() {
    _tokenRefreshSub?.cancel();
    _tokenRefreshSub = FirebaseMessaging.instance.onTokenRefresh.listen((token) async {
      if (token.trim().isEmpty) return;
      String userId = '';
      try {
        userId = Get.find<AppController>().userId.value;
      } catch (_) {
        userId = '';
      }
      if (userId.trim().isEmpty) {
        userId = (FirebaseAuth.instance.currentUser?.uid ?? '').toString();
      }
      userId = userId.trim();
      if (userId.isEmpty) return;

      final firestore = FirebaseFirestore.instance;
      Future<void> tryUpdate(String collection) async {
        try {
          final docRef = firestore.collection(collection).doc(userId);
          final doc = await docRef.get();
          if (!doc.exists) return;
          await docRef.update({
            'deviceToken': token,
            'fcm_token': token,
            'fcm_token_updated_at': FieldValue.serverTimestamp(),
          });
        } catch (_) {
          // ignore
        }
      }

      await tryUpdate('users');
      await tryUpdate('serviceProvider');
    });
  }

  /// Clear FCM token from Firestore on explicit sign-out.
  ///
  /// This ensures that once a user signs out they stop receiving push
  /// notifications.  Users who merely close the app (without signing
  /// out) keep their token intact and continue receiving pushes.
  static Future<void> clearFcmTokenOnSignOut() async {
    String userId = '';
    try {
      userId = Get.find<AppController>().userId.value;
    } catch (_) {
      userId = '';
    }
    if (userId.trim().isEmpty) {
      userId = (FirebaseAuth.instance.currentUser?.uid ?? '').toString();
    }
    userId = userId.trim();
    if (userId.isEmpty) return;

    final firestore = FirebaseFirestore.instance;
    final clearData = <String, dynamic>{
      'deviceToken': '',
      'fcm_token': '',
      'is_online': false,
      'last_seen': FieldValue.serverTimestamp(),
    };

    Future<void> tryClear(String collection) async {
      try {
        final docRef = firestore.collection(collection).doc(userId);
        final doc = await docRef.get();
        if (!doc.exists) return;
        await docRef.update(clearData);
      } catch (_) {
        // ignore
      }
    }

    await tryClear('users');
    await tryClear('serviceProvider');

    // Also cancel the local token-refresh listener.
    _tokenRefreshSub?.cancel();
    _tokenRefreshSub = null;
  }


  static Future<void> requestPermission() async {
    final messaging = FirebaseMessaging.instance;

    if (Platform.isAndroid) {
      // Android 13+ needs a runtime permission prompt.
      try {
        await flutterLocalNotificationsPlugin
            .resolvePlatformSpecificImplementation<
                AndroidFlutterLocalNotificationsPlugin>()
            ?.requestNotificationsPermission();
      } catch (_) {
        // ignore
      }

      // Still call this (no-op on Android), keeps behavior consistent.
      try {
        await messaging.requestPermission(
          alert: true,
          badge: true,
          sound: true,
        );
      } catch (_) {
        // ignore
      }
    } else {
      // iOS
      try {
        await messaging.setForegroundNotificationPresentationOptions(
          alert: true,
          badge: true,
          sound: true,
        );
      } catch (_) {
        // ignore
      }
    }
  }

  static void initializeNotification(BuildContext context) async {
    // 🔹 General notification channel (default sound)
    const AndroidNotificationChannel generalChannel = AndroidNotificationChannel(
      'high_importance_channel', // must match manifest
      'High Importance Notifications',
      description: 'This channel is used for important notifications.',
      importance: Importance.high,
      playSound: true,
      enableVibration: true,
      sound: RawResourceAndroidNotificationSound('sound_small'),
    );

    // 🔹 Order request channel (loud custom sound for artisan requests)
    const AndroidNotificationChannel orderRequestChannel = AndroidNotificationChannel(
      'order_request_channel',
      'Order Requests',
      description: 'Loud notification sound for new order/booking requests.',
      importance: Importance.max,
      playSound: true,
      enableVibration: true,
      sound: RawResourceAndroidNotificationSound('sound'),
    );

    final FlutterLocalNotificationsPlugin fln = FlutterLocalNotificationsPlugin();
    final androidPlugin = fln.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    await androidPlugin?.createNotificationChannel(generalChannel);
    await androidPlugin?.createNotificationChannel(orderRequestChannel);
    await FirebaseMessaging.instance.setForegroundNotificationPresentationOptions(
      alert: true,
      badge: true,
      sound: true,
    );


    ///Ios Initialization
    final DarwinInitializationSettings initializationSettingsIOS = DarwinInitializationSettings(
            requestSoundPermission: true,
            requestBadgePermission: true,
            requestAlertPermission: true);

    ///Android Initialization
    const AndroidInitializationSettings initializationSettingsAndroid = AndroidInitializationSettings("@mipmap/ic_launcher");

    final InitializationSettings initializationSettings = InitializationSettings(
      iOS: initializationSettingsIOS,
      android: initializationSettingsAndroid,
    );

    await flutterLocalNotificationsPlugin.initialize(initializationSettings, onDidReceiveNotificationResponse:
        (NotificationResponse notificationResponse) async {
      navigateToPage(
          context: context,
          pageName: NotificationPageView(
              type: Provider.of<PositionProvider>(context, listen: false)
                  .notificationType));
    });
  }

  ///Ios Permission
  void requestIOSPermissions() {
    flutterLocalNotificationsPlugin.resolvePlatformSpecificImplementation<
            IOSFlutterLocalNotificationsPlugin>()
        ?.requestPermissions(
          alert: true,
          badge: true,
          sound: true,
        );
  }

  /// Notification types that should use the loud order-request sound.
  static const _orderRequestTypes = {
    'Order Request',
    'order_request',
    'rfq_broadcast',
    'rfq_assignment',
    'future_booking',
    'booking_request',
    'new_booking',
  };

  static void displayNotification(context,
      {required RemoteMessage message}) async {
    final id = DateTime.now().millisecondsSinceEpoch ~/ 1000;

    // Determine notification type from data or PositionProvider
    String notifType = '';
    try {
      notifType = (message.data['type'] ?? '').toString();
    } catch (_) {}
    if (notifType.isEmpty) {
      try {
        notifType = Provider.of<PositionProvider>(context, listen: false)
            .notificationType ?? '';
      } catch (_) {}
    }

    final bool isOrderRequest = _orderRequestTypes.contains(notifType);

    final androidPlatformChannelSpecifics = AndroidNotificationDetails(
      isOrderRequest ? 'order_request_channel' : 'high_importance_channel',
      isOrderRequest ? 'Order Requests' : 'High Importance Notifications',
      channelDescription: isOrderRequest
          ? 'Loud notification sound for new order/booking requests.'
          : 'This channel is used for important notifications.',
      sound: RawResourceAndroidNotificationSound(
        isOrderRequest ? 'sound' : 'sound_small',
      ),
      importance: Importance.max,
      priority: Priority.high,
      playSound: true,
      enableVibration: true,
    );

    var darwinNotificationDetails = const DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
    );
    var platformChannelSpecifics = NotificationDetails(
        android: androidPlatformChannelSpecifics,
        iOS: darwinNotificationDetails);

    final title = message.notification?.title ?? message.data['title'] ?? 'Square15';
    final body = message.notification?.body ?? message.data['body'] ?? '';

    await flutterLocalNotificationsPlugin.show(
      id,
      title,
      body,
      platformChannelSpecifics,
      payload: notifType,
    );
  }
}
