import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_easyloading/flutter_easyloading.dart';
import 'package:get/get.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:maintenanceapp/controller/app_controller.dart';
import 'package:maintenanceapp/model/task_management_model.dart';
import 'package:maintenanceapp/screens/home/payment_method_view.dart';
import 'package:maintenanceapp/screens/home/bnpl_checkout_view.dart';
import 'package:maintenanceapp/services/bnpl_service.dart';
import 'package:maintenanceapp/services/deposit_service.dart';
import 'package:maintenanceapp/services/promo_code_service.dart';
import 'package:maintenanceapp/utils/primary_button.dart';
import 'package:uuid/uuid.dart';

/// Shared payment method selector used by both normal bookings and future bookings.
///
/// This must stay consistent across the app: wallet OR card (PayFast).
class ModelBottomSheet extends StatefulWidget {
  final TaskManagementModel record;
  const ModelBottomSheet({super.key, required this.record});

  @override
  State<ModelBottomSheet> createState() => _ModelBottomSheetState();
}

class _ModelBottomSheetState extends State<ModelBottomSheet> {
  final AppController appController = Get.find();
  List<BnplProvider> _availableBnpl = [];
  bool _checkingBnpl = true;
  bool _isDepositTask = false;
  double _depositAmount = 0;
  double _balanceAmount = 0;
  bool _paymentProcessing = false;
  final TextEditingController _promoController = TextEditingController();
  double _promoDiscount = 0;
  String? _promoId;
  String _promoMessage = '';
  bool _promoValidating = false;

  @override
  void initState() {
    super.initState();
    _checkBnplEligibility();
    _checkDepositStatus();
  }

  @override
  void dispose() {
    _promoController.dispose();
    super.dispose();
  }

  Future<void> _validatePromo() async {
    final code = _promoController.text.trim();
    if (code.isEmpty) {
      setState(() => _promoMessage = 'Please enter a promo code');
      return;
    }
    setState(() {
      _promoValidating = true;
      _promoMessage = '';
    });
    try {
      final fullCost = double.tryParse(widget.record.cost?.toString() ?? '0') ?? 0;
      final promo = await PromoCodeService.validatePromoCode(
        code: code,
        userId: appController.userId.value,
        jobAmount: fullCost,
      );
      if (promo != null && mounted) {
        final discount = promo.discountType == 'percentage'
            ? fullCost * ((promo.discountValue ?? 0) / 100)
            : (promo.discountValue ?? 0);
        setState(() {
          _promoDiscount = discount > fullCost ? fullCost : discount;
          _promoId = promo.id;
          _promoMessage = 'Promo applied! ${promo.discountType == 'percentage' ? '${promo.discountValue?.toStringAsFixed(0)}% off' : 'R${promo.discountValue?.toStringAsFixed(2)} off'}';
        });
      } else if (mounted) {
        setState(() {
          _promoDiscount = 0;
          _promoId = null;
          _promoMessage = 'Invalid or expired promo code';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _promoMessage = 'Could not validate code');
      }
    } finally {
      if (mounted) setState(() => _promoValidating = false);
    }
  }

  Future<void> _checkDepositStatus() async {
    try {
      final info = await DepositService.getDepositInfo(widget.record.id ?? '');
      if (info != null && info['deposit_paid'] != true && mounted) {
        setState(() {
          _isDepositTask = true;
          _depositAmount = info['deposit_amount'] as double;
          _balanceAmount = info['balance_amount'] as double;
        });
      }
    } catch (_) {}
  }

  Future<void> _checkBnplEligibility() async {
    final cost = double.tryParse(widget.record.cost?.toString() ?? '0') ?? 0;
    final providers = await BnplService.getAvailableProviders(cost);
    if (mounted) {
      setState(() {
        _availableBnpl = providers;
        _checkingBnpl = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final fullCost = double.tryParse(widget.record.cost?.toString() ?? '0') ?? 0;
    final cost = _isDepositTask ? _depositAmount : fullCost;
    final instalment = fullCost / 4.0;

    return SafeArea(
      child: SingleChildScrollView(
        physics: const BouncingScrollPhysics(),
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Select Your Payment Method',
                style: GoogleFonts.lato(
                    fontWeight: FontWeight.w700, fontSize: 14)),
            if (_isDepositTask) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  color: Colors.teal.shade50,
                  border: Border.all(color: Colors.teal.shade400),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Deposit Payment',
                        style: GoogleFonts.lato(
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                            color: Colors.teal.shade800)),
                    const SizedBox(height: 4),
                    Text(
                      'Pay 35% deposit now (R${_depositAmount.toStringAsFixed(2)}). '
                      'The remaining R${_balanceAmount.toStringAsFixed(2)} is due after job completion.',
                      style: GoogleFonts.lato(fontSize: 11, color: Colors.teal.shade700),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 12),

            // ── Promo Code Entry ──
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _promoController,
                    textCapitalization: TextCapitalization.characters,
                    decoration: InputDecoration(
                      hintText: 'Promo code',
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                      suffixIcon: _promoDiscount > 0
                          ? const Icon(Icons.check_circle, color: Colors.green, size: 20)
                          : null,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  height: 40,
                  child: ElevatedButton(
                    onPressed: _promoValidating ? null : _validatePromo,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFc5a520),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                    ),
                    child: _promoValidating
                        ? const SizedBox(width: 16, height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                        : const Text('Apply', style: TextStyle(fontSize: 13)),
                  ),
                ),
              ],
            ),
            if (_promoMessage.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                _promoMessage,
                style: TextStyle(
                  fontSize: 12,
                  color: _promoDiscount > 0 ? Colors.green.shade700 : Colors.red.shade700,
                ),
              ),
            ],
            if (_promoDiscount > 0) ...[
              const SizedBox(height: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.green.shade50,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: Colors.green.shade300),
                ),
                child: Row(
                  children: [
                    Icon(Icons.local_offer, size: 16, color: Colors.green.shade700),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        'Discount: -R${_promoDiscount.toStringAsFixed(2)} → New total: R${(cost - _promoDiscount).toStringAsFixed(2)}',
                        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Colors.green.shade800),
                      ),
                    ),
                    GestureDetector(
                      onTap: () => setState(() {
                        _promoDiscount = 0;
                        _promoId = null;
                        _promoMessage = '';
                        _promoController.clear();
                      }),
                      child: const Icon(Icons.close, size: 16, color: Colors.grey),
                    ),
                  ],
                ),
              ),
            ],

            const SizedBox(height: 20),
            PrimaryButton(
              onPressed: () async {
                if (_paymentProcessing) return;
                setState(() => _paymentProcessing = true);
                appController.isPaymentUsingPayFast.value = false;
                appController.isPaymentUsingBnpl.value = false;
                appController.activePaymentMethod.value = 'wallet';
                EasyLoading.dismiss();
                EasyLoading.show(status: 'Please Wait...!');
                try {
                  final uid = appController.userId.value.trim();
                  if (uid.isEmpty) {
                    EasyLoading.dismiss();
                    Get.showSnackbar(GetSnackBar(
                      backgroundColor: Colors.red.shade900,
                      duration: const Duration(seconds: 3),
                      snackPosition: SnackPosition.TOP,
                      title: 'Error',
                      message: 'User session not found. Please log out and log back in.',
                    ));
                    setState(() => _paymentProcessing = false);
                    return;
                  }
                  await appController.getUser(id: uid);
                  // Fallback: if balance still empty/zero, read directly from Firestore
                  if (appController.userBalance.value.isEmpty ||
                      appController.userBalance.value == '0' ||
                      appController.userBalance.value == '0.0') {
                    try {
                      final doc = await FirebaseFirestore.instance
                          .collection('users')
                          .doc(uid)
                          .get();
                      final rawBal = (doc.data()?['balance'] ?? '').toString();
                      if (rawBal.isNotEmpty && rawBal != '0' && rawBal != '0.0') {
                        appController.userBalance.value = rawBal;
                      }
                    } catch (_) {}
                  }
                  final rawCost = _isDepositTask
                      ? _depositAmount
                      : double.tryParse(widget.record.cost?.toString() ?? '0') ?? 0;
                  final discountedCost = _promoDiscount > 0
                      ? (rawCost - _promoDiscount).clamp(0.0, double.infinity)
                      : rawCost;
                  final chargeAmount = discountedCost.toStringAsFixed(2);
                  if (discountedCost <= 0) {
                    EasyLoading.dismiss();
                    return;
                  }

                  final bal = double.tryParse(appController.userBalance.value);
                  if (bal != null && discountedCost <= bal) {
                    await appController.savePaymentStatus(
                      cost: chargeAmount,
                      taskManagementId: widget.record.id ?? '',
                      status: 'success',
                    );
                    // Record promo code redemption if used
                    if (_promoId != null && _promoDiscount > 0) {
                      PromoCodeService.recordRedemption(
                        promoId: _promoId!,
                        userId: appController.userId.value,
                        taskManagementId: widget.record.id ?? '',
                        jobAmount: rawCost,
                        discountAmount: _promoDiscount,
                      );
                    }
                    EasyLoading.dismiss();
                    Future.delayed(const Duration(milliseconds: 600), () {
                      if (Navigator.of(context).canPop()) {
                        Navigator.of(context).pop();
                      }
                    });
                  } else {
                    Get.showSnackbar(GetSnackBar(
                      backgroundColor: Colors.red.shade900,
                      duration: const Duration(seconds: 4),
                      snackPosition: SnackPosition.TOP,
                      title: 'Insufficient Wallet Balance',
                      message: 'Your balance is R${bal?.toStringAsFixed(2) ?? "0.00"} but R${discountedCost.toStringAsFixed(2)} is required. Please top up your wallet or use PayFast or Buy Now Pay Later instead.',
                    ));
                    EasyLoading.dismiss();
                    if (Navigator.of(context).canPop()) {
                      Navigator.of(context).pop();
                    }
                  }
                } catch (_) {
                  EasyLoading.dismiss();
                  if (mounted) setState(() => _paymentProcessing = false);
                }
              },
              title: _isDepositTask
                  ? 'Pay Deposit R${_depositAmount.toStringAsFixed(2)} Via Wallet'
                  : 'Pay Via Wallet',
            ),
            const SizedBox(height: 20),
            PrimaryButton(
              onPressed: () async {
                appController.isPaymentUsingPayFast.value = true;
                appController.isPaymentUsingBnpl.value = false;
                appController.activePaymentMethod.value = 'payFast';
                EasyLoading.show(status: 'Please Wait...!');
                try {
                  await appController.getUser(id: appController.userId.value);
                  final rawPayCost = _isDepositTask
                      ? _depositAmount
                      : double.tryParse(widget.record.cost?.toString() ?? '0') ?? 0;
                  final discountedPayCost = _promoDiscount > 0
                      ? (rawPayCost - _promoDiscount).clamp(0.0, double.infinity)
                      : rawPayCost;
                  final payFastCost = discountedPayCost.toStringAsFixed(2);
                  if (discountedPayCost > 0) {
                    appController.webUrl.value =
                        await appController.initiatePayment(cost: payFastCost);
                    if (appController.webUrl.value.isEmpty) {
                      EasyLoading.dismiss();
                      Get.showSnackbar(GetSnackBar(
                        backgroundColor: Colors.red.shade900,
                        duration: const Duration(seconds: 4),
                        snackPosition: SnackPosition.TOP,
                        title: 'Payment Error',
                        message: 'Could not connect to PayFast. Please try again or use wallet payment.',
                      ));
                      return;
                    }
                    Get.to(() => PaymentMethodView(
                        taskManagementModel: widget.record,
                        chargeAmount: payFastCost),
                        transition: Transition.fadeIn);
                  }
                } finally {
                  EasyLoading.dismiss();
                }
              },
              title: _isDepositTask
                  ? 'Pay Deposit R${_depositAmount.toStringAsFixed(2)} Via PayFast'
                  : 'Pay Via PayFast (credit or debit card)',
            ),

            // --- Buy-Now-Pay-Later Options ---
            if (_availableBnpl.isNotEmpty) ...[
              const SizedBox(height: 20),
              Text('Buy Now, Pay Later',
                  style: GoogleFonts.lato(
                      fontWeight: FontWeight.w700, fontSize: 14)),
              const SizedBox(height: 8),
              ..._availableBnpl.map((provider) {
                final info = BnplService.providerInfo[provider]!;
                final perInstalment = fullCost / info.instalments;
                return Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Container(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(12),
                      gradient: LinearGradient(
                        colors: [Colors.blue.shade50, Colors.blue.shade100],
                      ),
                      border: Border.all(color: Colors.blue.shade300),
                    ),
                    child: Material(
                      color: Colors.transparent,
                      borderRadius: BorderRadius.circular(12),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(12),
                        onTap: () => _initiateBnpl(provider),
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Icon(Icons.credit_score,
                                      color: Colors.blue.shade700, size: 24),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Text(
                                      'Pay with ${info.name}',
                                      style: GoogleFonts.lato(
                                        fontSize: 15,
                                        fontWeight: FontWeight.w700,
                                        color: Colors.blue.shade800,
                                      ),
                                    ),
                                  ),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 8, vertical: 3),
                                    decoration: BoxDecoration(
                                      color: Colors.green.shade100,
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                    child: Text('0% Interest',
                                        style: GoogleFonts.lato(
                                          fontSize: 10,
                                          fontWeight: FontWeight.w700,
                                          color: Colors.green.shade800,
                                        )),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 10),
                              Text(
                                '${info.tagline} of R${perInstalment.toStringAsFixed(2)}',
                                style: GoogleFonts.lato(
                                  fontSize: 13,
                                  color: Colors.blue.shade700,
                                ),
                              ),
                              const SizedBox(height: 8),
                              Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: List.generate(info.instalments > 4 ? 4 : info.instalments, (i) {
                                  final labels = info.instalments == 3
                                      ? ['Today', '2 weeks', '4 weeks']
                                      : ['Today', '1 month', '2 months', '3 months'];
                                  return Column(
                                    children: [
                                      Container(
                                        width: 28,
                                        height: 28,
                                        decoration: BoxDecoration(
                                          shape: BoxShape.circle,
                                          color: i == 0
                                              ? Colors.blue.shade600
                                              : Colors.blue.shade200,
                                        ),
                                        child: Center(
                                          child: Text('${i + 1}',
                                              style: GoogleFonts.lato(
                                                fontSize: 12,
                                                fontWeight: FontWeight.bold,
                                                color: i == 0
                                                    ? Colors.white
                                                    : Colors.blue.shade800,
                                              )),
                                        ),
                                      ),
                                      const SizedBox(height: 4),
                                      Text(i < labels.length ? labels[i] : '',
                                          style: GoogleFonts.lato(
                                            fontSize: 9,
                                            color: Colors.blue.shade600,
                                          )),
                                      Text('R${perInstalment.toStringAsFixed(0)}',
                                          style: GoogleFonts.lato(
                                            fontSize: 10,
                                            fontWeight: FontWeight.w600,
                                            color: Colors.blue.shade800,
                                          )),
                                    ],
                                  );
                                }),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              }),
            ] else if (_checkingBnpl) ...[
              const SizedBox(height: 20),
              Center(
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.blue.shade300,
                  ),
                ),
              ),
            ],

            const SizedBox(height: 100),
          ],
        ),
      ),
    );
  }

  Future<void> _initiateBnpl(BnplProvider provider) async {
    final info = BnplService.providerInfo[provider]!;
    EasyLoading.show(status: 'Setting up ${info.name}...');

    try {
      final cost = widget.record.cost;
      if (cost == null) {
        EasyLoading.dismiss();
        return;
      }

      final rawAmount = double.tryParse(cost.toString()) ?? 0;
      final amount = _promoDiscount > 0
          ? (rawAmount - _promoDiscount).clamp(0.0, double.infinity)
          : rawAmount;
      if (amount <= 0) {
        EasyLoading.dismiss();
        return;
      }

      await appController.getUser(id: appController.userId.value);

      final fullName = appController.userName.value.trim();
      final nameParts = fullName.split(' ');
      final firstName = nameParts.isNotEmpty ? nameParts.first : 'Customer';
      final lastName =
          nameParts.length > 1 ? nameParts.sublist(1).join(' ') : 'User';

      final orderId = 'SQ15-${const Uuid().v4().substring(0, 8).toUpperCase()}';

      final result = await BnplService.createOrder(
        provider: provider,
        amount: amount,
        orderId: orderId,
        consumerEmail: appController.userEmail.value.isNotEmpty
            ? appController.userEmail.value
            : '${appController.userId.value}@square15.co.za',
        consumerFirstName: firstName,
        consumerLastName: lastName,
        consumerPhone: appController.userData?.contact?.toString() ?? '',
        description:
            'Square 15 Maintenance - Job ${widget.record.id ?? ''}',
      );

      EasyLoading.dismiss();

      if (result == null) {
        Get.showSnackbar(GetSnackBar(
          backgroundColor: Colors.red.shade800,
          duration: const Duration(seconds: 4),
          snackPosition: SnackPosition.TOP,
          title: '${info.name} Unavailable',
          message:
              'Could not connect to ${info.name}. Please try another payment method.',
        ));
        return;
      }

      appController.isPaymentUsingPayFast.value = false;
      appController.isPaymentUsingBnpl.value = true;
      appController.activePaymentMethod.value = 'bnpl';

      Get.to(
        () => BnplCheckoutView(
          checkoutUrl: result.redirectUrl,
          bnplToken: result.token,
          orderId: result.orderId,
          provider: provider,
          taskManagementModel: widget.record,
        ),
        transition: Transition.fadeIn,
      );
    } catch (e) {
      EasyLoading.dismiss();
      debugPrint('[BNPL] initiate error: $e');
      Get.showSnackbar(GetSnackBar(
        backgroundColor: Colors.red.shade800,
        duration: const Duration(seconds: 3),
        snackPosition: SnackPosition.TOP,
        title: 'Error',
        message: 'Something went wrong. Please try again.',
      ));
    }
  }
}
