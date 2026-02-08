import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:get/get.dart';
import 'package:loading_animation_widget/loading_animation_widget.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:maintenanceapp/controller/app_controller.dart';
import 'package:maintenanceapp/controller/service_provider_controller.dart';
import 'package:maintenanceapp/services/config_service.dart';
import 'package:maintenanceapp/services/fcm_background_handler.dart';
import 'package:maintenanceapp/services/future_booking_scheduler.dart';
import 'package:maintenanceapp/services/notification_services.dart';
import 'package:maintenanceapp/services/presence_service.dart';

import '../utils/splash_timer.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({
    super.key,
  });

  @override
  _SplashScreenState createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  String _versionLabel = '';
  bool _bootstrapped = false;

  Future<void> _bootstrap() async {
    if (_bootstrapped) return;
    try {
      await Firebase.initializeApp();
    } catch (_) {
      // Best-effort: if already initialized.
    }

    // App Check DISABLED.
    // On Huawei devices (no Google Play Services / Play Integrity),
    // activating App Check — even with PlayIntegrity provider — attaches
    // invalid tokens to every Firebase request, causing Storage uploads
    // (and potentially Firestore writes) to fail with misleading
    // "network" or "object-not-found" errors.
    // Re-enable only after confirming all target devices support Play Integrity
    // and App Check enforcement is turned on in Firebase Console.
    // try {
    //   await FirebaseAppCheck.instance.activate(
    //     androidProvider:
    //         kDebugMode ? AndroidProvider.debug : AndroidProvider.playIntegrity,
    //     appleProvider: kDebugMode ? AppleProvider.debug : AppleProvider.appAttest,
    //   );
    // } catch (_) {}
    print('[AppCheck] Skipped – disabled for Huawei compatibility');

    try {
      ConfigService.initialize();
    } catch (_) {
      // ignore
    }

    if (!Get.isRegistered<AppController>()) {
      Get.put(AppController());
    }
    if (!Get.isRegistered<ServiceProviderController>()) {
      Get.put(ServiceProviderController());
    }

    try {
      FirebaseMessaging.onBackgroundMessage(
        firebaseMessagingBackgroundHandler,
      );
    } catch (_) {
      // ignore
    }

    try {
      NotificationService.requestPermission();
      // Ensure local notification channel is created + foreground messages are surfaced.
      NotificationService.initializeNotification(context);

      FirebaseMessaging.onMessage.listen((RemoteMessage message) {
        try {
          if (!mounted) return;
          if (message.notification == null) return;
          NotificationService.displayNotification(context, message: message);
        } catch (_) {
          // ignore
        }
      });

      NotificationService.startTokenSyncListener();
      NotificationService.syncFcmTokenForCurrentLogin();
    } catch (_) {
      // ignore
    }

    try {
      PresenceService.initialize();
    } catch (_) {
      // ignore
    }

    try {
      FutureBookingScheduler.initialize();
    } catch (_) {
      // ignore
    }

    _bootstrapped = true;
  }

  Future<void> _loadVersion() async {
    try {
      final pkg = await PackageInfo.fromPlatform();
      if (!mounted) return;
      setState(() {
        _versionLabel = 'v${pkg.version}+${pkg.buildNumber}';
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _versionLabel = 'vunknown+0';
      });
    }
  }

  @override
  void initState() {
    super.initState();
    () async {
      await _bootstrap();
      if (!mounted) return;
      splashTimer(context);
      _loadVersion();
    }();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: SizedBox(
          height: MediaQuery.of(context).size.height * 1,
          width: MediaQuery.of(context).size.width * 1,
          child: Stack(
            fit: StackFit.expand,
            children: [
              Center(
                child: Image.asset('assets/images/flash sceen.png'),
              ),
              Align(
                alignment: Alignment.bottomRight,
                child: Padding(
                  padding: const EdgeInsets.only(right: 12, bottom: 12),
                  child: Text(
                    _versionLabel,
                    style: const TextStyle(
                      fontSize: 12,
                      color: Color(0xff35540C),
                    ),
                  ),
                ),
              ),
              Align(
                  alignment: Alignment.bottomCenter,
                  child: FractionalTranslation(
                      translation: const Offset(0.0, -1),
                      child: LoadingAnimationWidget.fourRotatingDots(
                          color: const Color(0xff35540C), size: 60)))
            ],
          ),
        ),
      ),
    );
  }
}
