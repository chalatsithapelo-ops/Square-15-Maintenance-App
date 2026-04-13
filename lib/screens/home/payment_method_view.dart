import 'dart:async';
import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:maintenanceapp/controller/app_controller.dart';
import 'package:maintenanceapp/controller/service_provider_controller.dart';
import 'package:maintenanceapp/model/task_management_model.dart';
import 'bottomnavigationbar/bottombar.dart';
import 'package:webview_flutter/webview_flutter.dart';

class PaymentMethodView extends StatefulWidget {
  final TaskManagementModel? taskManagementModel;
  /// Optional override for the amount actually charged (e.g. deposit or balance).
  /// When null, uses taskManagementModel.cost.
  final String? chargeAmount;
  const PaymentMethodView({super.key, this.taskManagementModel, this.chargeAmount});

  @override
  _PaymentMethodViewState createState() => _PaymentMethodViewState();
}

class _PaymentMethodViewState extends State<PaymentMethodView> {
  final AppController appController = Get.find();
  final ServiceProviderController serviceProviderController = Get.find();

  late final WebViewController _controller;
  bool _paymentHandled = false;
  bool _isLoading = true;
  Timer? _timeoutTimer;

  @override
  void initState() {
    super.initState();

    // Safety timeout: if no success/cancel detected in 5 minutes, show retry option
    _timeoutTimer = Timer(const Duration(minutes: 5), () {
      if (!_paymentHandled && mounted) {
        Get.showSnackbar(GetSnackBar(
          backgroundColor: Colors.orange.shade800,
          duration: const Duration(seconds: 10),
          snackPosition: SnackPosition.TOP,
          title: 'Payment Taking Long?',
          message: 'If you completed payment, please wait. Otherwise tap Back to retry.',
        ));
      }
    });

    if (Platform.isAndroid) {
      // Modern webview uses hybrid composition by default
    }

    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0x00000000))
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (String url) {
            if (mounted) setState(() => _isLoading = true);
          },
          onPageFinished: (String url) async {
            if (mounted) setState(() => _isLoading = false);
            if (_paymentHandled) return;
            debugPrint("Page loaded: $url");

            // Detect Ozow result via URL pattern (backend redirects here)
            final uri = Uri.tryParse(url);
            final status = uri?.queryParameters['status'] ?? '';

            if (url.contains('/api/payment/ozow-result') && status == 'cancel') {
              _paymentHandled = true;
              debugPrint('Ozow cancel detected');
              Get.showSnackbar(GetSnackBar(
                backgroundColor: Colors.orange.shade800,
                duration: const Duration(seconds: 3),
                snackPosition: SnackPosition.TOP,
                title: 'Payment Cancelled',
                message: 'You can retry from your bookings page.',
              ));
              Future.delayed(const Duration(seconds: 2), () {
                if (mounted) Get.offAll(() => const BottomNavigatorExample());
              });
            } else if (url.contains('/api/payment/ozow-result') && status == 'success') {
              _paymentHandled = true;
              debugPrint('Ozow success detected');
              final actualCost = widget.chargeAmount ?? widget.taskManagementModel?.cost ?? '0';
              final taskId = widget.taskManagementModel?.id ?? '';
              if (taskId.isEmpty) {
                debugPrint('Ozow success but no taskManagementModel ID — skipping save');
                return;
              }
              // Check if deposit/balance logic is needed
              Future<void> onOzowSuccess() async {
                final tmSnap = await FirebaseFirestore.instance
                    .collection('tasksManagement').doc(taskId).get();
                final tmData = tmSnap.data() ?? {};
                if (tmData['payment_type'] == 'deposit' &&
                    tmData['deposit_paid'] == true &&
                    tmData['balance_paid'] != true) {
                  final now = DateTime.now().toString();
                  await FirebaseFirestore.instance
                      .collection('tasksManagement').doc(taskId).update({
                    'balance_paid': true,
                    'balance_paid_at': now,
                  });
                  // Also update futureBookings to keep collections in sync
                  final fbId = (tmData['future_booking_id'] ?? '').toString().trim();
                  final fbDocId = fbId.isNotEmpty ? fbId : taskId;
                  try {
                    await FirebaseFirestore.instance
                        .collection('futureBookings').doc(fbDocId).update({
                      'balance_paid': true,
                      'balance_paid_at': now,
                      'payment_status': 'paid',
                      'updated_at': now,
                    });
                  } catch (_) {}
                }
              }
              onOzowSuccess().then((_) {
                return appController.savePaymentStatus(
                  cost: actualCost,
                  taskManagementId: taskId,
                  status: 'success',
                );
              }).then((_) {
                Future.delayed(const Duration(seconds: 2), () {
                  appController.currentIndex.value = 2;
                  Get.offAll(() => const BottomNavigatorExample());
                });
              }).catchError((e) {
                debugPrint('Ozow save error: $e');
                if (mounted) {
                  Get.showSnackbar(GetSnackBar(
                    backgroundColor: Colors.red.shade900,
                    duration: const Duration(seconds: 6),
                    snackPosition: SnackPosition.TOP,
                    title: 'Payment Recorded — Sync Error',
                    message: 'Your payment was received but could not sync. It will be verified automatically. Please contact support if your booking is not updated.',
                  ));
                  Future.delayed(const Duration(seconds: 4), () {
                    appController.currentIndex.value = 2;
                    Get.offAll(() => const BottomNavigatorExample());
                  });
                }
              });
            } else if (url.contains('/api/payment/ozow-result') && status == 'pending') {
              _paymentHandled = true;
              debugPrint('Ozow pending detected (EFT)');
              Get.showSnackbar(GetSnackBar(
                backgroundColor: Colors.blue.shade800,
                duration: const Duration(seconds: 6),
                snackPosition: SnackPosition.TOP,
                title: 'EFT Payment Pending',
                message: 'Your EFT payment is being processed. You\'ll receive a notification once it\'s confirmed.',
              ));
              Future.delayed(const Duration(seconds: 4), () {
                if (mounted) {
                  appController.currentIndex.value = 2;
                  Get.offAll(() => const BottomNavigatorExample());
                }
              });
            } else if (url.contains('/api/payment/ozow-result') && status == 'error') {
              _paymentHandled = true;
              debugPrint('Ozow error detected');
              Get.showSnackbar(GetSnackBar(
                backgroundColor: Colors.red.shade900,
                duration: const Duration(seconds: 4),
                snackPosition: SnackPosition.TOP,
                title: 'Payment Error',
                message: 'There was an error processing your payment. Please try again.',
              ));
              Future.delayed(const Duration(seconds: 3), () {
                if (mounted) Get.back();
              });
            }
          },
          onWebResourceError: (WebResourceError error) {
            debugPrint('WebView error: ${error.description}');
            if (!_paymentHandled && mounted) {
              setState(() => _isLoading = false);
            }
          },
        ),
      )
      ..loadRequest(Uri.parse(appController.webUrl.value));
  }

  @override
  void dispose() {
    _timeoutTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFFc5a520),
        foregroundColor: Colors.white,
        title: const Text('Complete Payment'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () {
            if (!_paymentHandled) {
              showDialog(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: const Text('Cancel Payment?'),
                  content: const Text(
                    'If you leave now, your payment will not be completed. '
                    'You can retry from your bookings page.',
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.of(ctx).pop(),
                      child: const Text('Stay'),
                    ),
                    TextButton(
                      onPressed: () {
                        Navigator.of(ctx).pop();
                        Get.back();
                      },
                      child: const Text('Leave', style: TextStyle(color: Colors.red)),
                    ),
                  ],
                ),
              );
            } else {
              Get.back();
            }
          },
        ),
      ),
      body: SafeArea(
        child: Stack(
          children: [
            WebViewWidget(controller: _controller),
            if (_isLoading)
              const Center(
                child: CircularProgressIndicator(
                  color: Color(0xFFc5a520),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
