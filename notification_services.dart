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
    //tz.initializeTimeZones();




    // 🔹 Create the same channel mentioned in AndroidManifest.xml
    const AndroidNotificationChannel channel = AndroidNotificationChannel(
      'high_importance_channel', // must match manifest
      'High Importance Notifications', // human-readable name
      description: 'This channel is used for important notifications.',
      importance: Importance.high,
      playSound: true,
      enableVibration: true,
    );


    final FlutterLocalNotificationsPlugin fln = FlutterLocalNotificationsPlugin();
    await fln.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(channel);
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

  static void displayNotification(context,
      {required RemoteMessage message}) async {
    final id = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    var androidPlatformChannelSpecifics =
        const AndroidNotificationDetails(
            'high_importance_channel', // must match manifest
            'High Importance Notifications', // human-readable name
            channelDescription: 'your channel description',
            // sound: Provider.of<PositionProvider>(context, listen: false)
            //             .notificationType ==
            //         "Order Request"
            //     ? const RawResourceAndroidNotificationSound(
            //         'assets/sounds/sound')
            //     : const RawResourceAndroidNotificationSound(
            //         'assets/sounds/sound_small'),
            importance: Importance.max,
            priority: Priority.high);

    var darwinNotificationDetails = const DarwinNotificationDetails();
    var platformChannelSpecifics = NotificationDetails(
        android: androidPlatformChannelSpecifics,
        iOS: darwinNotificationDetails);

    await flutterLocalNotificationsPlugin.show(
      id,
      message.notification!.title,
      message.notification!.body,
      platformChannelSpecifics,
      payload: "",
    );
  }
}
