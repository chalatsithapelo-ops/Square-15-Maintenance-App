import 'dart:async';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:maintenanceapp/controller/app_controller.dart';
import 'package:maintenanceapp/model/task_management_model.dart';
import 'package:maintenanceapp/services/bnpl_service.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'bottomnavigationbar/bottombar.dart';

/// WebView screen that loads a BNPL provider's hosted checkout.
///
/// After the consumer completes or cancels, the WebView detects the
/// redirect URL and either finalises payment or goes back.
class BnplCheckoutView extends StatefulWidget {
  final String checkoutUrl;
  final String bnplToken;
  final String orderId;
  final BnplProvider provider;
  final TaskManagementModel? taskManagementModel;

  const BnplCheckoutView({
    super.key,
    required this.checkoutUrl,
    required this.bnplToken,
    required this.orderId,
    required this.provider,
    this.taskManagementModel,
  });

  @override
  State<BnplCheckoutView> createState() => _BnplCheckoutViewState();
}

class _BnplCheckoutViewState extends State<BnplCheckoutView> {
  final AppController appController = Get.find();
  late final WebViewController _controller;
  bool _processing = false;
  bool _pageLoading = true;

  String get _providerName =>
      BnplService.providerInfo[widget.provider]!.name;

  @override
  void initState() {
    super.initState();

    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0x00000000))
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (_) {
            if (mounted) setState(() => _pageLoading = true);
          },
          onPageFinished: (String url) async {
            if (mounted) setState(() => _pageLoading = false);
            debugPrint('[BNPL-$_providerName] Page loaded: $url');
            await _checkRedirect(url);
          },
          onNavigationRequest: (NavigationRequest request) {
            debugPrint('[BNPL-$_providerName] Navigation: ${request.url}');
            _checkRedirect(request.url);
            return NavigationDecision.navigate;
          },
        ),
      )
      ..loadRequest(Uri.parse(
          widget.checkoutUrl.isNotEmpty
              ? widget.checkoutUrl
              : 'about:blank',
        ));

    if (widget.checkoutUrl.isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        Get.showSnackbar(GetSnackBar(
          backgroundColor: Colors.red.shade800,
          duration: const Duration(seconds: 3),
          snackPosition: SnackPosition.TOP,
          title: 'Error',
          message: '$_providerName checkout URL is unavailable. Please try again.',
        ));
        Future.delayed(const Duration(seconds: 2), () => Get.back());
      });
    }
  }

  Future<void> _checkRedirect(String url) async {
    if (_processing) return;

    final lower = url.toLowerCase();
    final providerId = BnplService.providerInfo[widget.provider]!.id.toLowerCase();

    final isConfirm = lower.contains('/bnpl/$providerId/confirm') ||
        lower.contains('/bnpl/confirm') ||
        lower.contains('status=approved') ||
        lower.contains('status=captured') ||
        lower.contains('confirmed=true');

    final isCancel = lower.contains('/bnpl/$providerId/cancel') ||
        lower.contains('/bnpl/cancel') ||
        lower.contains('status=cancelled') ||
        lower.contains('status=declined') ||
        lower.contains('cancelled=true');

    if (isConfirm) {
      await _handleApproval();
    } else if (isCancel) {
      _handleCancellation();
    }
  }

  Future<void> _handleApproval() async {
    if (_processing) return;
    setState(() => _processing = true);

    debugPrint('[BNPL-$_providerName] Order approved — capturing...');

    final captured = await BnplService.captureOrder(
        widget.provider, widget.bnplToken);

    await BnplService.updateOrderStatus(
      orderId: widget.orderId,
      status: captured ? 'captured' : 'approved',
    );

    if (!captured) {
      if (!mounted) return;
      Get.showSnackbar(GetSnackBar(
        backgroundColor: Colors.red.shade800,
        duration: const Duration(seconds: 4),
        snackPosition: SnackPosition.TOP,
        title: 'Payment Failed',
        message:
            '$_providerName could not capture payment. Please try again or use another method.',
      ));
      setState(() => _processing = false);
      return;
    }

    if (widget.taskManagementModel != null) {
      await appController.savePaymentStatus(
        cost: widget.taskManagementModel!.cost!,
        taskManagementId: widget.taskManagementModel!.id!,
        status: 'success',
      );
    }

    if (!mounted) return;

    final info = BnplService.providerInfo[widget.provider]!;
    Get.showSnackbar(GetSnackBar(
      backgroundColor: Colors.green.shade800,
      duration: const Duration(seconds: 3),
      snackPosition: SnackPosition.TOP,
      title: 'Payment Approved',
      message:
          'Your $_providerName payment has been approved! You\'ll pay in ${info.instalments} easy instalments.',
    ));

    Future.delayed(const Duration(seconds: 2), () {
      appController.currentIndex.value = 2;
      Get.offAll(() => const BottomNavigatorExample());
    });
  }

  void _handleCancellation() {
    if (_processing) return;
    setState(() => _processing = true);

    debugPrint('[BNPL-$_providerName] Order cancelled/declined');

    BnplService.updateOrderStatus(
      orderId: widget.orderId,
      status: 'cancelled',
    );

    Get.showSnackbar(GetSnackBar(
      backgroundColor: Colors.orange.shade800,
      duration: const Duration(seconds: 3),
      snackPosition: SnackPosition.TOP,
      title: 'Payment Cancelled',
      message: 'Your $_providerName application was not completed.',
    ));

    Future.delayed(const Duration(seconds: 1), () {
      Get.back();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 1,
        leading: IconButton(
          icon: const Icon(Icons.close, color: Colors.black87),
          onPressed: () {
            if (!_processing) {
              BnplService.updateOrderStatus(
                orderId: widget.orderId,
                status: 'abandoned',
              );
              Get.back();
            }
          },
        ),
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.credit_score, color: Colors.blue.shade700, size: 22),
            const SizedBox(width: 8),
            Text('$_providerName Checkout',
                style: GoogleFonts.lato(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: Colors.black87,
                )),
          ],
        ),
        centerTitle: true,
        bottom: _pageLoading
            ? const PreferredSize(
                preferredSize: Size.fromHeight(3),
                child: LinearProgressIndicator(minHeight: 3),
              )
            : null,
      ),
      body: _processing
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const CircularProgressIndicator(),
                  const SizedBox(height: 16),
                  Text('Processing your $_providerName payment...',
                      style: GoogleFonts.lato(fontSize: 14)),
                ],
              ),
            )
          : WebViewWidget(controller: _controller),
    );
  }
}
