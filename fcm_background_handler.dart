import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Notification types that should use the loud order-request sound.
const _orderRequestTypes = {
  'Order Request',
  'order_request',
  'rfq_broadcast',
  'rfq_assignment',
  'future_booking',
  'booking_request',
  'new_booking',
};

Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await Firebase.initializeApp();
  } catch (_) {
    // Best-effort: avoid crashing the background isolate if Firebase was already initialized.
  }

  debugPrint('[BG-FCM] title=${message.notification?.title}  data=${message.data}');

  // Show a local notification so the user hears the sound and sees a
  // heads-up banner even when the app is in the background.
  try {
    final fln = FlutterLocalNotificationsPlugin();

    const initAndroid = AndroidInitializationSettings('@mipmap/ic_launcher');
    const initSettings = InitializationSettings(android: initAndroid);
    await fln.initialize(initSettings);

    final notifType = (message.data['type'] ?? '').toString();
    final isOrderRequest = _orderRequestTypes.contains(notifType);

    // Create the appropriate channel
    final channelId = isOrderRequest ? 'order_request_channel' : 'high_importance_channel';
    final channelName = isOrderRequest ? 'Order Requests' : 'High Importance Notifications';
    final soundFile = isOrderRequest ? 'sound' : 'sound_small';

    final channel = AndroidNotificationChannel(
      channelId,
      channelName,
      importance: Importance.max,
      playSound: true,
      enableVibration: true,
      sound: RawResourceAndroidNotificationSound(soundFile),
    );

    await fln
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(channel);

    final androidDetails = AndroidNotificationDetails(
      channelId,
      channelName,
      importance: Importance.max,
      priority: Priority.high,
      playSound: true,
      enableVibration: true,
      sound: RawResourceAndroidNotificationSound(soundFile),
    );

    final title = message.notification?.title ?? message.data['title'] ?? 'Square15';
    final body = message.notification?.body ?? message.data['body'] ?? '';

    if (title.isNotEmpty || body.isNotEmpty) {
      await fln.show(
        DateTime.now().millisecondsSinceEpoch ~/ 1000,
        title,
        body,
        NotificationDetails(android: androidDetails),
      );
    }
  } catch (e) {
    debugPrint('[BG-FCM] local notification error: $e');
  }
}
