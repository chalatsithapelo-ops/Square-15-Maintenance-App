import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:maintenanceapp/controller/app_controller.dart';

/// Tracks user presence (online/offline + last_seen) in Firestore.
///
/// Call [PresenceService.initialize] once from the splash screen after
/// Firebase + GetX are ready.  It installs a [WidgetsBindingObserver]
/// that flips `is_online` when the app moves to/from the foreground.
class PresenceService with WidgetsBindingObserver {
  PresenceService._();
  static PresenceService? _instance;

  static void initialize() {
    if (_instance != null) return;
    _instance = PresenceService._();
    WidgetsBinding.instance.addObserver(_instance!);
    _instance!._setOnline(true);
  }

  static void dispose() {
    if (_instance == null) return;
    WidgetsBinding.instance.removeObserver(_instance!);
    _instance = null;
  }

  // ── lifecycle callbacks ──────────────────────────────────────────────
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        _setOnline(true);
        break;
      case AppLifecycleState.paused:
      case AppLifecycleState.inactive:
      case AppLifecycleState.detached:
      case AppLifecycleState.hidden:
        _setOnline(false);
        break;
    }
  }

  // ── helpers ──────────────────────────────────────────────────────────
  void _setOnline(bool online) {
    final userId = _currentUserId;
    if (userId.isEmpty) return;

    final data = <String, dynamic>{
      'is_online': online,
      'last_seen': FieldValue.serverTimestamp(),
    };

    final firestore = FirebaseFirestore.instance;
    // Fire-and-forget — we don't want to block the UI.
    firestore.collection('users').doc(userId).update(data).catchError((_) {});
    firestore
        .collection('serviceProvider')
        .doc(userId)
        .update(data)
        .catchError((_) {});
  }

  String get _currentUserId {
    String uid = '';
    try {
      uid = Get.find<AppController>().userId.value;
    } catch (_) {}
    if (uid.trim().isEmpty) {
      uid = FirebaseAuth.instance.currentUser?.uid ?? '';
    }
    return uid.trim();
  }
}
