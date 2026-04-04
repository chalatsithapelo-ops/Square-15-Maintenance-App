import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_easyloading/flutter_easyloading.dart';
import 'package:get/get.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:maintenanceapp/controller/app_controller.dart';
import 'package:maintenanceapp/screens/service_provider_panel/service_provider_request_screen.dart';
import 'package:maintenanceapp/services/firestore_services/firebase_services.dart';
import 'package:maintenanceapp/services/future_booking_service.dart';
import 'package:maintenanceapp/services/promo_code_service.dart';
import 'package:maintenanceapp/services/loyalty_service.dart';
import 'package:maintenanceapp/services/upsell_service.dart';
import 'package:maintenanceapp/services/booking_funnel_service.dart';
import 'package:maintenanceapp/services/retargeting_service.dart';
import 'package:maintenanceapp/services/bnpl_service.dart';
import 'package:maintenanceapp/services/trust_service.dart';
import 'package:maintenanceapp/services/deposit_service.dart';
import 'package:maintenanceapp/screens/home/profile/chat_support/Support_chat.dart';
import 'package:maintenanceapp/model/promo_code_model.dart';
import 'package:maintenanceapp/model/upsell_addon_model.dart';
import 'package:maintenanceapp/model/loyalty_points_model.dart';
import 'package:maintenanceapp/utils/common_widget.dart';
import 'package:maintenanceapp/utils/constant.dart';
import 'package:maintenanceapp/utils/dotted_line.dart';
import 'package:maintenanceapp/utils/primary_button.dart';

import 'google_map/location_picker_screen.dart';

class PaymentDetail extends StatefulWidget {
  final String provider;
  final String providerId;
  const PaymentDetail({super.key,
    required this.provider,
    required this.providerId});

  @override
  State<PaymentDetail> createState() => _PaymentDetailState();
}

class _PaymentDetailState extends State<PaymentDetail> {


  File? image;
  File? additionalImage;
  final AppController appController = Get.find();
  late TextEditingController lengthControllerAdditional ;
  late TextEditingController widthControllerAdditional ;
  List<TextEditingController> descriptionControllerList = [];

  String _resolvedProviderId = '';
  String _resolvedProviderName = '';
  bool _resolvingProvider = false;
  int _resolveAttempts = 0;
  static const int _maxResolveAttempts = 6;

  // --- Promo Code ---
  final TextEditingController _promoController = TextEditingController();
  PromoCodeModel? _appliedPromo;
  String? _promoError;
  double _promoDiscount = 0.0;
  bool _validatingPromo = false;

  // --- Loyalty Points ---
  LoyaltyPointsModel? _loyaltyBalance;
  final bool _redeemingPoints = false;
  int _pointsToRedeem = 0;
  double _loyaltyDiscount = 0.0;

  // --- Upsell Add-ons ---
  List<UpsellAddonModel> _availableAddons = [];
  final Set<String> _selectedAddonIds = {};
  double _addonTotal = 0.0;

  // --- Off-peak / First-job auto discount ---
  double _autoDiscount = 0.0;
  String? _autoDiscountLabel;

  // --- Deposit Model (Strategy 3) ---
  bool _useDeposit = false; // true = pay 35% now, 65% after job

  // --- Trust Data (Strategies 4, 5, 6) ---
  Map<String, dynamic> _platformStats = {};
  Map<String, dynamic> _artisanProfile = {};
  String? _partnerName;

  bool _requestSent = false;

  Future<File?> getPhoto(BuildContext context, ImageSource source, {bool isAdditional = false}) async {
    XFile? pickedFile = await ImagePicker().pickImage(source: source);
    if(pickedFile !=null){
      return File(pickedFile.path);
    }
    return null;

  }

  @override
  void initState() {
    // TODO: implement initState
    super.initState();
    lengthControllerAdditional = TextEditingController();
    widthControllerAdditional = TextEditingController();
    descriptionControllerList = List.generate(appController.listOfJobs.length, (index) => TextEditingController());

    // Start with whatever was passed from the previous screen.
    _resolvedProviderId = widget.providerId;
    _resolvedProviderName = widget.provider;

    // Restore legacy behavior: resolve nearest online artisan before sending request.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _resolveNearestOnlineArtisan();
      _loadLoyaltyBalance();
      _loadAvailableAddons();
      _checkAutoDiscounts();
      _loadTrustData();
    });
  }

  Future<DocumentSnapshot<Map<String, dynamic>>?> _resolveProviderDocByAnyId(String anyId) async {
    final id = anyId.trim();
    if (id.isEmpty) return null;

    try {
      final direct = await FirebaseService.providerRef.doc(id).get();
      if (direct.exists) return direct;
    } catch (_) {}

    const fields = <String>[
      'docId',
      'user_id',
      'uid',
      'userId',
      'provider_id',
      'service_provider_id',
    ];

    for (final field in fields) {
      try {
        final snap = await FirebaseService.providerRef.where(field, isEqualTo: id).limit(1).get();
        if (snap.docs.isNotEmpty) return snap.docs.first;
      } catch (_) {}
    }

    return null;
  }

  String _extractProviderUserIdFromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data();
    if (data == null) return '';

    const keys = <String>[
      'user_id',
      'uid',
      'userId',
      'docId',
      'provider_id',
      'service_provider_id',
    ];
    for (final k in keys) {
      final v = (data[k] ?? '').toString().trim();
      if (v.isNotEmpty) return v;
    }
    return '';
  }

  Future<void> _retryResolveNearestOnlineArtisan() async {
    if (!mounted) return;
    if (_resolvingProvider) return;
    if (_resolveAttempts >= _maxResolveAttempts) return;
    await Future.delayed(const Duration(milliseconds: 900));
    if (!mounted) return;
    _resolveNearestOnlineArtisan();
  }

  Future<void> _resolveNearestOnlineArtisan() async {
    if (_resolvingProvider) return;
    if (!mounted) return;

    _resolveAttempts += 1;

    final jobTaskId = appController.listOfJobs
        .map((j) => (j.taskId ?? '').toString().trim())
        .firstWhere((t) => t.isNotEmpty, orElse: () => '');
    if (jobTaskId.isEmpty) {
      await _retryResolveNearestOnlineArtisan();
      return;
    }

    final String lat = appController.serviceOnCurrentLocation.value
        ? appController.userLat.value
        : appController.pickedLat.value;
    final String lng = appController.serviceOnCurrentLocation.value
        ? appController.userLng.value
        : appController.pickedLng.value;

    // If we don't have a usable location, fall back to whatever was passed.
    if ((double.tryParse(lat) ?? 0) == 0 || (double.tryParse(lng) ?? 0) == 0) {
      await _retryResolveNearestOnlineArtisan();
      return;
    }

    setState(() {
      _resolvingProvider = true;
    });

    try {
      final now = DateTime.now();
      final scheduledDate = DateFormat('yyyy-MM-dd').format(now);
      final scheduledTime = DateFormat('HH:mm:ss').format(now);

      final artisanId = await FutureBookingService.findAvailableArtisanByLocation(
        taskId: jobTaskId,
        scheduledDate: scheduledDate,
        scheduledTime: scheduledTime,
        userLat: lat,
        userLng: lng,
      );

      if (artisanId == null || artisanId.trim().isEmpty) {
        return;
      }

      final providerDoc = await _resolveProviderDocByAnyId(artisanId);
      final providerName = providerDoc != null && providerDoc.exists
          ? (providerDoc.data()?['name']?.toString())
          : null;

      // IMPORTANT: the artisan-side app listens by artisan *user id* (AppController.userId)
      // and filters tasksManagement.service_provider_id by that value.
      String notifyProviderUserId = artisanId;
      if (providerDoc != null && providerDoc.exists) {
        final extracted = _extractProviderUserIdFromDoc(providerDoc);
        if (extracted.isNotEmpty) {
          notifyProviderUserId = extracted;
        }
      }

      if (!mounted) return;
      setState(() {
        _resolvedProviderId = notifyProviderUserId;
        _resolvedProviderName = (providerName ?? '').trim().isNotEmpty
            ? providerName!.toString()
            : _resolvedProviderId;
      });

      // Keep controller state consistent in case other screens read it.
      appController.lastSelectedProviderId.value = _resolvedProviderId;
      appController.lastSelectedProviderName.value = _resolvedProviderName;
    } catch (e) {
      debugPrint('PaymentDetail _resolveNearestOnlineArtisan error: $e');
    } finally {
      if (mounted) {
        setState(() {
          _resolvingProvider = false;
        });
      }
    }
  }

  @override
  void dispose() {
    lengthControllerAdditional.dispose();
    widthControllerAdditional.dispose();
    _promoController.dispose();

    // If user leaves without sending request, track as abandonment
    if (!_requestSent) {
      final uid = appController.userId.value;
      final categoryId = appController.currentTaskCategoryId.value;
      final total = appController.totalTaskCost.value;
      if (uid.isNotEmpty && total > 0) {
        BookingFunnelService.logEvent(
          userId: uid,
          eventType: 'quote_abandoned',
          categoryId: categoryId,
          quotedAmount: total,
        );
        final sessionId = BookingFunnelService.currentSessionId;
        RetargetingService.queueRetargeting(
          userId: uid,
          sessionId: sessionId,
          categoryName: null,
          quotedAmount: total,
        );
      }
    }

    super.dispose();
  }

  // --- Promo code validation ---
  Future<void> _validatePromoCode() async {
    final code = _promoController.text.trim();
    if (code.isEmpty) return;
    setState(() { _validatingPromo = true; _promoError = null; });
    try {
      final total = appController.totalTaskCost.value;
      final categoryId = appController.currentTaskCategoryId.value;
      final promo = await PromoCodeService.validatePromoCode(
        code: code,
        userId: appController.userId.value,
        jobAmount: total,
        categoryId: categoryId,
      );
      if (!mounted) return;
      if (promo != null) {
        final discount = promo.calculateDiscount(total);
        setState(() {
          _appliedPromo = promo;
          _promoDiscount = discount;
          _promoError = null;
        });
      } else {
        setState(() {
          _appliedPromo = null;
          _promoDiscount = 0;
          _promoError = 'Invalid or expired code';
        });
      }
    } catch (e) {
      if (mounted) setState(() { _promoError = 'Error validating code'; });
    } finally {
      if (mounted) setState(() { _validatingPromo = false; });
    }
  }

  void _removePromo() {
    setState(() {
      _appliedPromo = null;
      _promoDiscount = 0;
      _promoError = null;
      _promoController.clear();
    });
  }

  // --- Loyalty points ---
  Future<void> _loadLoyaltyBalance() async {
    final uid = appController.userId.value;
    if (uid.isEmpty) return;
    final bal = await LoyaltyService.getBalance(uid);
    if (mounted) {
      setState(() { _loyaltyBalance = bal; });
    }
  }

  void _togglePointsRedemption(bool redeem) {
    if (!redeem || _loyaltyBalance == null) {
      setState(() { _pointsToRedeem = 0; _loyaltyDiscount = 0; });
      return;
    }
    final available = _loyaltyBalance!.totalPoints ?? 0;
    final total = appController.totalTaskCost.value - _promoDiscount - _autoDiscount;
    // Max redeemable: up to 50% of total
    final maxRand = total * 0.5;
    final maxPoints = (maxRand * LoyaltyService.pointsToRandRatio).round();
    final pts = available < maxPoints ? available : maxPoints;
    final rand = pts / LoyaltyService.pointsToRandRatio;
    setState(() { _pointsToRedeem = pts; _loyaltyDiscount = rand; });
  }

  // --- Upsell add-ons ---
  Future<void> _loadAvailableAddons() async {
    final categoryId = appController.currentTaskCategoryId.value;
    if (categoryId.isEmpty) return;
    final addons = await UpsellService.getAddonsForCategory(categoryId);
    if (mounted) setState(() { _availableAddons = addons; });
  }

  void _toggleAddon(String addonId, double price) {
    setState(() {
      if (_selectedAddonIds.contains(addonId)) {
        _selectedAddonIds.remove(addonId);
        _addonTotal -= price;
      } else {
        _selectedAddonIds.add(addonId);
        _addonTotal += price;
      }
    });
  }

  // --- Auto discounts (first job, off-peak) ---
  Future<void> _checkAutoDiscounts() async {
    final uid = appController.userId.value;
    if (uid.isEmpty) return;
    try {
      final firstJobPromo = await PromoCodeService.getFirstJobDiscount(uid);
      if (firstJobPromo != null) {
        final total = appController.totalTaskCost.value;
        final discount = firstJobPromo.calculateDiscount(total);
        if (discount > 0 && mounted) {
          setState(() { _autoDiscount = discount; _autoDiscountLabel = 'First Job Discount'; });
        }
        return;
      }
      final offPeakPromo = await PromoCodeService.getOffPeakDiscount();
      if (offPeakPromo != null) {
        final total = appController.totalTaskCost.value;
        final discount = offPeakPromo.calculateDiscount(total);
        if (discount > 0 && mounted) {
          setState(() { _autoDiscount = discount; _autoDiscountLabel = 'Off-Peak Discount'; });
        }
      }
    } catch (_) {}
  }

  Future<void> _loadTrustData() async {
    try {
      final stats = await TrustService.getPlatformStats();
      if (mounted) setState(() => _platformStats = stats);
    } catch (_) {}

    try {
      final providerId = _resolvedProviderId.isNotEmpty
          ? _resolvedProviderId
          : widget.providerId;
      if (providerId.isNotEmpty) {
        final profile = await TrustService.getArtisanProfile(providerId);
        if (mounted) setState(() => _artisanProfile = profile);
      }
    } catch (_) {}

    try {
      final partnerId = appController.userData?.referredByPartnerId;
      if (partnerId != null && partnerId.isNotEmpty) {
        final name = await TrustService.getPartnerEndorsement(partnerId);
        if (name != null && mounted) setState(() => _partnerName = name);
      }
    } catch (_) {}
  }

  /// The amount the client actually pays now (deposit or full).
  double get _payableNow {
    if (_useDeposit) {
      return DepositService.calculateDeposit(_finalTotal)['deposit']!;
    }
    return _finalTotal;
  }

  double get _finalTotal {
    final base = appController.totalTaskCost.value;
    return (base + _addonTotal - _promoDiscount - _autoDiscount - _loyaltyDiscount)
        .clamp(0, double.infinity);
  }

  Widget _discountRow(String label, double amount, Color color) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(children: [
        Icon(Icons.local_offer, size: 14, color: color),
        const SizedBox(width: 4),
        Text('$label: ', style: GoogleFonts.lato(fontSize: 12, color: color)),
        Text('-R${amount.toStringAsFixed(2)}',
            style: GoogleFonts.lato(fontSize: 12, color: color, fontWeight: FontWeight.bold)),
      ]),
    );
  }

  Widget _statBadge(IconData icon, String value, String label, Color color) {
    return Column(children: [
      Icon(icon, color: color, size: 20),
      const SizedBox(height: 2),
      Text(value, style: GoogleFonts.lato(fontWeight: FontWeight.bold, fontSize: 13, color: color)),
      Text(label, style: GoogleFonts.lato(fontSize: 9, color: Colors.grey.shade600)),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    final height = MediaQuery.of(context).size.height;

    debugPrint("height $height");

    debugPrint("length of controller ${descriptionControllerList.length}");
    return SafeArea(
      top: false,
      child: Scaffold(
        body: SizedBox(
          height: height,
          width: width,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment:  MainAxisAlignment.spaceBetween,
              children: [
                Container(
                    width: double.infinity,
                    height: height*0.2,
                    padding: const EdgeInsets.only(left: 20,right: 20),
                    decoration: const BoxDecoration(
                      borderRadius: BorderRadius.only(bottomLeft: Radius.circular(40),bottomRight: Radius.circular(40)),
                      gradient: LinearGradient(
                        begin: Alignment.centerLeft,
                        end: Alignment.centerRight,
                        colors: [
                          Color(0xFFe5c958), // #e5c958
                          Color(0xFFc5a520), // #c5a520
                        ],
                      ),
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            GestureDetector(
                              onTap: ()=> Get.back(),
                              child: Icon(Icons.arrow_back,color: Colors.white,size: width*0.08,),
                            ),
                            Text("Payment Details",style: GoogleFonts.lato(
                                fontWeight: FontWeight.w400,
                                fontSize: width*0.06,
                                color: Colors.white
                            )),
                            Container(),
                          ],
                        ),
                      ],
                    )
                ),
                SizedBox(height: height*0.01),
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Artisan Info: ',style: GoogleFonts.lato(color: Colors.black,
                          fontWeight: FontWeight.bold,
                          fontSize: width*0.05)),
                      SizedBox(height: height * 0.01),
                      card(
                        title: 'Name',
                        value: _resolvingProvider
                            ? 'Finding nearest artisan...'
                            : (_resolvedProviderName.isNotEmpty
                                ? _resolvedProviderName
                                : widget.provider),
                        width: width,
                      ),
                      SizedBox(height: height * 0.01),
                      CustomPaint(
                        size: Size(width, height * 0.01),
                        painter: DottedLinePainter(Colors.amber.shade400),
                      ),
                      SizedBox(height: height * 0.01),
                      Text('Task Info: ', style: GoogleFonts.lato(color: Colors.black,
                          fontWeight: FontWeight.bold,
                          fontSize: width*0.05)),
                      SizedBox(height: height * 0.01),
                      Obx(()=> appController.listOfJobs.isNotEmpty
                          ? SizedBox(
                            height: height <= 640.0 ? height * 0.5 : height * 0.4,
                            child: ListView.builder(
                              physics: const BouncingScrollPhysics(),
                              scrollDirection: Axis.horizontal,
                              padding: const EdgeInsets.only(left: 16, top: 16),
                              shrinkWrap: true,
                              itemCount: appController.listOfJobs.length,
                              itemBuilder: (BuildContext context, index){
                                final job = appController.listOfJobs[index];
                                return Stack(
                                  clipBehavior: Clip.none,
                                  alignment: Alignment.topLeft,
                                  children: [
                                    Container(
                                      width: width * 0.55,
                                      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
                                      margin: const EdgeInsets.only(right: 16),
                                      decoration: BoxDecoration(
                                        color: Colors.white,
                                        border: Border.all(color: Colors.grey),
                                        borderRadius: BorderRadius.circular(5),
                                      ),
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          StreamBuilder(
                                            stream: FirebaseService.taskRef.doc(job.taskId).snapshots(),
                                            builder: (context, snapshot) {
                                              if (!snapshot.hasData) {
                                                return const SizedBox();
                                              }
                                              else {
                                                if(snapshot.data!.data() == null){
                                                  return Center(child: noText(text: 'N/A', align: TextAlign.start));
                                                }
                                                else {
                                                  return Text(snapshot.data!.data()!["name"] ?? "N/A",textAlign: TextAlign.start,
                                                    style: GoogleFonts.lato(color: Colors.black, fontWeight: FontWeight.w600));
                                                }

                                              }
                                            },
                                          ),
                                          Row(
                                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                            children: [
                                              Column(
                                                crossAxisAlignment: CrossAxisAlignment.start,
                                                children: [
                                                  job.height == "0.0" && job.width == "0.0"? const Row() :
                                                  Text("Height * Width", style: GoogleFonts.lato(color: Colors.black, fontSize: 12)),
                                                  job.area == "0" ? const SizedBox() :
                                                  Text("Area (in Sq. Meter)", style: GoogleFonts.lato(color: Colors.black, fontSize: 12)),
                                                  Text("Cost", style: GoogleFonts.lato(color: Colors.black, fontSize: 12)),
                                                ],
                                              ),
                                              Column(
                                                crossAxisAlignment: CrossAxisAlignment.end,
                                                children: [
                                                  job.height == "0.0" && job.width == "0.0"? const Row() :
                                                  Text("${job.height} * ${job.width}", style: GoogleFonts.lato(color: Colors.black, fontWeight: FontWeight.w600, fontSize: 12)),
                                                  job.area == "0" ? const SizedBox() :
                                                  Text("${job.area}", style: GoogleFonts.lato(color: Colors.black, fontWeight: FontWeight.w600, fontSize: 12)),
                                                  Text("R${job.cost}", style: GoogleFonts.lato(color: Colors.black, fontWeight: FontWeight.w600, fontSize: 12)),

                                                ],
                                              ),
                                            ],
                                          ),
                                          const SizedBox(height: 5),
                                          Card(
                                            elevation: 2,
                                            color: Colors.white,
                                            child: TextField(
                                              controller: descriptionControllerList[index],
                                              cursorColor: Colors.black,
                                              style: GoogleFonts.lato(fontWeight: FontWeight.normal),
                                              decoration: InputDecoration(
                                                labelText: 'Description',
                                                labelStyle: GoogleFonts.lato(
                                                    color: const Color(0xffACADB9),
                                                    fontSize: 12),
                                                border: InputBorder.none,
                                                focusedBorder: const OutlineInputBorder(
                                                  borderSide: BorderSide(color: Colors.white),
                                                ),
                                                filled: true,
                                                fillColor: Colors.white,
                                                prefixIcon: const Icon(
                                                  Icons.description,
                                                  color: Color(0xffACADB9),
                                                  size: 18,
                                                ),
                                                contentPadding: const EdgeInsets.symmetric(
                                                    horizontal: 5.0),
                                              ),
                                            ),
                                          ),
                                          const SizedBox(height: 5),
                                          Row(
                                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                            children: [
                                              GestureDetector(
                                                onTap: () async {
                                                  // appController.jobImagesList.clear();
                                                  image = null;
                                                  image = await getPhoto(context, ImageSource.camera);
                                                  if(image != null){
                                                    debugPrint("image ${image!.path}");
                                                    appController.attachJobImages(index: index, file: image!, jobId: job.id!);
                                                  }else{
                                                    debugPrint("idr aa gya");
                                                  }
                                                  setState(() {});
                                                },
                                                child: Container(
                                                  padding: const EdgeInsets.all(10),
                                                  decoration: BoxDecoration(
                                                      color: const Color(0xFFc5a520).withOpacity(0.2),
                                                      borderRadius: BorderRadius.circular(5),
                                                      border: Border.all(color: const Color(0xFFc5a520))
                                                  ),
                                                  child: const Icon(Icons.camera_alt_rounded, color:Color(0xFFc5a520)),
                                                ),
                                              ),
                                              GestureDetector(
                                                onTap: () async {
                                                  image = null;
                                                  image = await getPhoto(context, ImageSource.gallery);
                                                  if(image != null){
                                                    debugPrint("image ${image!.path}");
                                                    appController.attachJobImages(index: index, file: image!, jobId: job.id!);
                                                  }else{
                                                    debugPrint("idr aa gya");
                                                  }
                                                  setState(() {});
                                                },
                                                child: Container(
                                                  padding: const EdgeInsets.all(10),
                                                  decoration: BoxDecoration(
                                                      color: Colors.green.shade100,
                                                      borderRadius: BorderRadius.circular(5),
                                                      border: Border.all(color: Colors.green.shade900)
                                                  ),
                                                  child: Icon(Icons.photo, color: Colors.green.shade900),
                                                ),
                                              ),
                                            ],
                                          ),
                                          const Spacer(),
                                          appController.jobImagesList.isNotEmpty
                                              ? SizedBox(
                                                width: width * 0.4,
                                                height: width * 0.4 / 2,
                                                child: appController.jobImagesList.length > index
                                                    ? ListView.builder(
                                                      physics: const BouncingScrollPhysics(),
                                                      scrollDirection: Axis.horizontal,
                                                      shrinkWrap: true,
                                                      itemCount: appController.jobImagesList[index].length,
                                                      itemBuilder: (context, idx){
                                                        final jobImagesItem = appController.jobImagesList[index][idx];
                                                      return Stack(
                                                        clipBehavior: Clip.none,
                                                        alignment: Alignment.center,
                                                        children: [
                                                          Opacity(
                                                            opacity: 0.6,
                                                            child: Padding(
                                                              padding: const EdgeInsets.symmetric(horizontal: 4),
                                                              child: CommonWidget.buildImageFullSize(path: jobImagesItem.imagePath!,
                                                                  width: width * 0.5 / 2, height: width * 0.5 / 2,
                                                                  isLocal: true),
                                                            ),
                                                          ),
                                                          Positioned(
                                                            child: GestureDetector(
                                                              onTap: (){
                                                                debugPrint("clicked");
                                                                appController.jobImagesList[index].removeAt(idx);
                                                                setState(() {});
                                                              },
                                                              child: Container(
                                                                padding: const EdgeInsets.all(8),
                                                                decoration: BoxDecoration(
                                                                    color: Colors.red.shade500,
                                                                    borderRadius: BorderRadius.circular(50),
                                                                  ),
                                                                child: const Icon(Icons.remove_circle_outline, color: Colors.white)),
                                                            ),
                                                          )
                                                        ],
                                                      );
                                                    })
                                                    : Text('Image not attached yet',
                                                    style: GoogleFonts.lato(color: Colors.grey)),
                                              )
                                              : Text('Add Min. 3 images for each job',
                                              style: GoogleFonts.lato(color: Colors.grey)),

                                        ],
                                      ),
                                    ),
                                    Positioned(
                                      top: -10, left: -10,
                                      child: GestureDetector(
                                        onTap: (){
                                          debugPrint("clicked");
                                          appController.listOfJobs.removeAt(index);
                                          appController.selectedTaskNameList.removeAt(index);
                                          if(appController.jobImagesList.isNotEmpty){
                                            appController.jobImagesList[index].clear();
                                          }
                                          appController.calculateTotalBillForRequest();
                                        },
                                        child: Container(
                                            decoration: BoxDecoration(
                                              color: Colors.red.shade500,
                                              borderRadius: BorderRadius.circular(50),
                                            ),
                                            child: const Icon(Icons.highlight_remove, color: Colors.white)),
                                      ),
                                    )
                                  ],
                                );
                              },
                            ),
                          )
                          : Center(child: Text('', style: GoogleFonts.lato(color: Colors.black, fontSize: 12)))
                      ),


                      SizedBox(height: height * 0.01),
                      Obx(()=> card(
                          title: 'Subtotal',
                          value: "R${appController.totalTaskCost.value.toStringAsFixed(2)}",
                          width: width)),

                      // --- Price Anchoring: Market Rate Comparison ---
                      Obx(() {
                        final base = appController.totalTaskCost.value;
                        if (base <= 0) return const SizedBox.shrink();
                        final marketRate = (base * 1.35).toStringAsFixed(2);
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Row(children: [
                            Icon(Icons.trending_down, color: Colors.green.shade700, size: 18),
                            const SizedBox(width: 6),
                            Text('Market avg: ', style: GoogleFonts.lato(fontSize: 12, color: Colors.grey.shade600)),
                            Text('R$marketRate',
                                style: GoogleFonts.lato(
                                    fontSize: 12,
                                    color: Colors.grey.shade500,
                                    decoration: TextDecoration.lineThrough)),
                            const SizedBox(width: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: Colors.green.shade50,
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text('You save ~35%',
                                  style: GoogleFonts.lato(
                                      fontSize: 11,
                                      color: Colors.green.shade700,
                                      fontWeight: FontWeight.bold)),
                            ),
                          ]),
                        );
                      }),

                      // --- Auto Discount (First Job / Off-Peak) ---
                      if (_autoDiscount > 0 && _autoDiscountLabel != null)
                        _discountRow(_autoDiscountLabel!, _autoDiscount, Colors.blue.shade700),

                      // --- Promo Code Input ---
                      SizedBox(height: height * 0.01),
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Colors.grey.shade50,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: Colors.grey.shade300),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Promo Code', style: GoogleFonts.lato(fontWeight: FontWeight.bold, fontSize: 13)),
                            const SizedBox(height: 6),
                            if (_appliedPromo != null)
                              Row(children: [
                                Icon(Icons.check_circle, color: Colors.green.shade700, size: 18),
                                const SizedBox(width: 6),
                                Expanded(child: Text(
                                  '${_appliedPromo!.code} applied — R${_promoDiscount.toStringAsFixed(2)} off',
                                  style: GoogleFonts.lato(color: Colors.green.shade700, fontSize: 12),
                                )),
                                GestureDetector(
                                  onTap: _removePromo,
                                  child: Icon(Icons.close, size: 18, color: Colors.red.shade400),
                                ),
                              ])
                            else
                              Row(children: [
                                Expanded(
                                  child: TextField(
                                    controller: _promoController,
                                    style: GoogleFonts.lato(fontSize: 13),
                                    decoration: InputDecoration(
                                      hintText: 'Enter promo code',
                                      hintStyle: GoogleFonts.lato(fontSize: 12, color: Colors.grey),
                                      isDense: true,
                                      contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(6)),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                SizedBox(
                                  height: 36,
                                  child: ElevatedButton(
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: const Color(0xFFc5a520),
                                      padding: const EdgeInsets.symmetric(horizontal: 14),
                                    ),
                                    onPressed: _validatingPromo ? null : _validatePromoCode,
                                    child: _validatingPromo
                                        ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                                        : Text('Apply', style: GoogleFonts.lato(fontSize: 12, color: Colors.white)),
                                  ),
                                ),
                              ]),
                            if (_promoError != null)
                              Padding(
                                padding: const EdgeInsets.only(top: 4),
                                child: Text(_promoError!, style: GoogleFonts.lato(color: Colors.red, fontSize: 11)),
                              ),
                          ],
                        ),
                      ),

                      // --- Loyalty Points Redemption ---
                      if (_loyaltyBalance != null && (_loyaltyBalance!.totalPoints ?? 0) >= 100)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: Colors.amber.shade50,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: Colors.amber.shade300),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(children: [
                                  Icon(Icons.stars, color: Colors.amber.shade700, size: 20),
                                  const SizedBox(width: 6),
                                  Text('Loyalty Points', style: GoogleFonts.lato(fontWeight: FontWeight.bold, fontSize: 13)),
                                  const Spacer(),
                                  Text('${_loyaltyBalance!.totalPoints} pts available',
                                      style: GoogleFonts.lato(fontSize: 11, color: Colors.amber.shade800)),
                                ]),
                                const SizedBox(height: 6),
                                Row(children: [
                                  Expanded(child: Text(
                                    _pointsToRedeem > 0
                                        ? 'Redeem $_pointsToRedeem pts = R${_loyaltyDiscount.toStringAsFixed(2)} off'
                                        : 'Use points for a discount (100 pts = R10)',
                                    style: GoogleFonts.lato(fontSize: 12),
                                  )),
                                  Switch(
                                    value: _pointsToRedeem > 0,
                                    activeColor: Colors.amber.shade700,
                                    onChanged: _togglePointsRedemption,
                                  ),
                                ]),
                              ],
                            ),
                          ),
                        ),

                      // --- Upsell Add-ons ---
                      if (_availableAddons.isNotEmpty) ...[
                        SizedBox(height: height * 0.01),
                        Text('Recommended Add-ons', style: GoogleFonts.lato(fontWeight: FontWeight.bold, fontSize: 13)),
                        const SizedBox(height: 4),
                        ..._availableAddons.map((addon) {
                          final selected = _selectedAddonIds.contains(addon.id);
                          final price = addon.discountedPrice;
                          return Card(
                            margin: const EdgeInsets.only(bottom: 4),
                            child: CheckboxListTile(
                              dense: true,
                              value: selected,
                              activeColor: const Color(0xFFc5a520),
                              onChanged: (_) => _toggleAddon(addon.id ?? '', price),
                              title: Text(addon.name ?? '', style: GoogleFonts.lato(fontSize: 12, fontWeight: FontWeight.w600)),
                              subtitle: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  if (addon.description != null)
                                    Text(addon.description!, style: GoogleFonts.lato(fontSize: 11, color: Colors.grey.shade600)),
                                  Row(children: [
                                    if ((addon.discountPercent ?? 0) > 0) ...[
                                      Text('R${addon.basePrice?.toStringAsFixed(0)}',
                                          style: GoogleFonts.lato(fontSize: 11, decoration: TextDecoration.lineThrough, color: Colors.grey)),
                                      const SizedBox(width: 4),
                                    ],
                                    Text('R${price.toStringAsFixed(2)}',
                                        style: GoogleFonts.lato(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.green.shade700)),
                                  ]),
                                ],
                              ),
                            ),
                          );
                        }),
                      ],

                      // --- Discounts applied breakdown ---
                      if (_promoDiscount > 0)
                        _discountRow('Promo (${_appliedPromo?.code})', _promoDiscount, Colors.green.shade700),
                      if (_loyaltyDiscount > 0)
                        _discountRow('Loyalty Points', _loyaltyDiscount, Colors.amber.shade800),
                      if (_addonTotal > 0)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 2),
                          child: Row(children: [
                            Text('Add-ons: ', style: GoogleFonts.lato(fontSize: 12)),
                            Text('+R${_addonTotal.toStringAsFixed(2)}',
                                style: GoogleFonts.lato(fontSize: 12, color: Colors.orange.shade800, fontWeight: FontWeight.bold)),
                          ]),
                        ),

                      // --- Final Total ---
                      SizedBox(height: height * 0.005),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                        decoration: BoxDecoration(
                          color: const Color(0xFF35540C).withOpacity(0.1),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: const Color(0xFF35540C)),
                        ),
                        child: Obx(() => Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text('Total to Pay', style: GoogleFonts.lato(fontWeight: FontWeight.bold, fontSize: 15)),
                            Text('R${_finalTotal.toStringAsFixed(2)}',
                                style: GoogleFonts.lato(fontWeight: FontWeight.bold, fontSize: 16, color: const Color(0xFF35540C))),
                          ],
                        )),
                      ),

                      // ── Strategy 3: Deposit Payment Toggle ─────────────
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Builder(builder: (_) {
                          final total = _finalTotal;
                          final amounts = DepositService.calculateDeposit(total);
                          return Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(10),
                              color: _useDeposit ? Colors.teal.shade50 : Colors.grey.shade50,
                              border: Border.all(
                                color: _useDeposit ? Colors.teal.shade400 : Colors.grey.shade300,
                              ),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(children: [
                                  Icon(Icons.account_balance_wallet_outlined,
                                      color: Colors.teal.shade700, size: 20),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text('Payment Option',
                                        style: GoogleFonts.lato(
                                            fontWeight: FontWeight.bold,
                                            fontSize: 13,
                                            color: Colors.teal.shade800)),
                                  ),
                                ]),
                                const SizedBox(height: 8),
                                // Full payment option
                                GestureDetector(
                                  onTap: () => setState(() => _useDeposit = false),
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                                    decoration: BoxDecoration(
                                      borderRadius: BorderRadius.circular(6),
                                      color: !_useDeposit ? const Color(0xFF35540C).withOpacity(0.1) : Colors.white,
                                      border: Border.all(
                                        color: !_useDeposit ? const Color(0xFF35540C) : Colors.grey.shade300,
                                      ),
                                    ),
                                    child: Row(children: [
                                      Icon(
                                        !_useDeposit ? Icons.radio_button_checked : Icons.radio_button_off,
                                        color: !_useDeposit ? const Color(0xFF35540C) : Colors.grey,
                                        size: 18,
                                      ),
                                      const SizedBox(width: 8),
                                      Expanded(child: Text('Pay full amount upfront',
                                          style: GoogleFonts.lato(fontSize: 12))),
                                      Text('R${total.toStringAsFixed(2)}',
                                          style: GoogleFonts.lato(
                                              fontWeight: FontWeight.bold,
                                              fontSize: 12,
                                              color: const Color(0xFF35540C))),
                                    ]),
                                  ),
                                ),
                                const SizedBox(height: 6),
                                // Deposit option
                                GestureDetector(
                                  onTap: () => setState(() => _useDeposit = true),
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                                    decoration: BoxDecoration(
                                      borderRadius: BorderRadius.circular(6),
                                      color: _useDeposit ? Colors.teal.shade50 : Colors.white,
                                      border: Border.all(
                                        color: _useDeposit ? Colors.teal.shade600 : Colors.grey.shade300,
                                      ),
                                    ),
                                    child: Column(
                                      children: [
                                        Row(children: [
                                          Icon(
                                            _useDeposit ? Icons.radio_button_checked : Icons.radio_button_off,
                                            color: _useDeposit ? Colors.teal.shade700 : Colors.grey,
                                            size: 18,
                                          ),
                                          const SizedBox(width: 8),
                                          Expanded(child: Text('Pay 35% deposit now',
                                              style: GoogleFonts.lato(fontSize: 12))),
                                          Text('R${amounts['deposit']!.toStringAsFixed(2)}',
                                              style: GoogleFonts.lato(
                                                  fontWeight: FontWeight.bold,
                                                  fontSize: 12,
                                                  color: Colors.teal.shade700)),
                                        ]),
                                        if (_useDeposit) ...[
                                          const SizedBox(height: 6),
                                          Row(children: [
                                            const SizedBox(width: 26),
                                            Icon(Icons.schedule, size: 14, color: Colors.teal.shade600),
                                            const SizedBox(width: 4),
                                            Text(
                                              'Remaining R${amounts['balance']!.toStringAsFixed(2)} due after job completion',
                                              style: GoogleFonts.lato(
                                                  fontSize: 10,
                                                  color: Colors.teal.shade600,
                                                  fontStyle: FontStyle.italic),
                                            ),
                                          ]),
                                        ],
                                      ],
                                    ),
                                  ),
                                ),
                                if (_useDeposit) ...[
                                  const SizedBox(height: 6),
                                  Text(
                                    'Your balance is securely held and only due once you confirm the work is done.',
                                    style: GoogleFonts.lato(fontSize: 10, color: Colors.teal.shade500),
                                  ),
                                ],
                              ],
                            ),
                          );
                        }),
                      ),

                      // ── Strategy 4: Social Proof ───────────────────────
                      if (_platformStats.isNotEmpty) ...[
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(8),
                              color: Colors.purple.shade50,
                              border: Border.all(color: Colors.purple.shade200),
                            ),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.spaceAround,
                              children: [
                                _statBadge(
                                  Icons.check_circle_outline,
                                  '${_platformStats['jobs_completed'] ?? 0}',
                                  'Jobs Done',
                                  Colors.green.shade700,
                                ),
                                _statBadge(
                                  Icons.star,
                                  '${_platformStats['average_rating'] ?? '4.8'}',
                                  'Avg Rating',
                                  Colors.amber.shade700,
                                ),
                                _statBadge(
                                  Icons.verified,
                                  '${_platformStats['verified_artisans'] ?? 0}',
                                  'Artisans',
                                  Colors.blue.shade700,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],

                      // ── Strategy 5: Artisan Transparency Card ──────────
                      if (_artisanProfile.isNotEmpty) ...[
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(10),
                              color: Colors.white,
                              border: Border.all(color: Colors.grey.shade300),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.grey.shade200,
                                  blurRadius: 4,
                                  spreadRadius: 1,
                                ),
                              ],
                            ),
                            child: Row(children: [
                              // Artisan photo
                              CircleAvatar(
                                radius: 24,
                                backgroundColor: Colors.grey.shade200,
                                backgroundImage: (_artisanProfile['imageUrl'] ?? '').toString().isNotEmpty
                                    ? NetworkImage(_artisanProfile['imageUrl'])
                                    : null,
                                child: (_artisanProfile['imageUrl'] ?? '').toString().isEmpty
                                    ? Icon(Icons.person, color: Colors.grey.shade400, size: 28)
                                    : null,
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(children: [
                                      Flexible(
                                        child: Text(
                                          _artisanProfile['name'] ?? 'Artisan',
                                          style: GoogleFonts.lato(
                                              fontWeight: FontWeight.bold,
                                              fontSize: 13),
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                      if (_artisanProfile['isVerified'] == true) ...[
                                        const SizedBox(width: 4),
                                        Icon(Icons.verified, color: Colors.blue.shade600, size: 16),
                                      ],
                                    ]),
                                    const SizedBox(height: 2),
                                    Row(children: [
                                      Icon(Icons.star, color: Colors.amber, size: 14),
                                      Text(' ${_artisanProfile['rating'] ?? '5.0'}',
                                          style: GoogleFonts.lato(fontSize: 11, fontWeight: FontWeight.w600)),
                                      Text(' (${_artisanProfile['ratingCount'] ?? 0} reviews)',
                                          style: GoogleFonts.lato(fontSize: 10, color: Colors.grey)),
                                      const SizedBox(width: 8),
                                      Icon(Icons.build_circle_outlined, color: Colors.grey, size: 14),
                                      Text(' ${_artisanProfile['jobsCompleted'] ?? 0} jobs',
                                          style: GoogleFonts.lato(fontSize: 10, color: Colors.grey)),
                                    ]),
                                    if ((_artisanProfile['memberSince'] ?? '').toString().isNotEmpty)
                                      Text('Member for ${_artisanProfile['memberSince']}',
                                          style: GoogleFonts.lato(fontSize: 10, color: Colors.grey.shade500)),
                                  ],
                                ),
                              ),
                            ]),
                          ),
                        ),
                      ],

                      // ── Strategy 6: Partner Endorsement Badge ──────────
                      if (_partnerName != null) ...[
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(8),
                              gradient: LinearGradient(
                                colors: [const Color(0xFFc5a520).withOpacity(0.1), const Color(0xFFc5a520).withOpacity(0.05)],
                              ),
                              border: Border.all(color: const Color(0xFFc5a520)),
                            ),
                            child: Row(children: [
                              Icon(Icons.business, color: const Color(0xFFc5a520), size: 20),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  'Trusted by $_partnerName',
                                  style: GoogleFonts.lato(
                                      fontWeight: FontWeight.w600,
                                      fontSize: 12,
                                      color: const Color(0xFFc5a520)),
                                ),
                              ),
                              Icon(Icons.handshake_outlined, color: const Color(0xFFc5a520), size: 16),
                            ]),
                          ),
                        ),
                      ],

                      // ── Help Center Button (replaces WhatsApp) ─────────
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: GestureDetector(
                          onTap: () => Get.to(() => const ChatSupportScreen(),
                              transition: Transition.fadeIn),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(8),
                              color: Colors.grey.shade50,
                              border: Border.all(color: Colors.grey.shade300),
                            ),
                            child: Row(children: [
                              Icon(Icons.headset_mic, color: Colors.grey.shade700, size: 18),
                              const SizedBox(width: 8),
                              Text('Need help? Chat with our support team',
                                  style: GoogleFonts.lato(
                                      fontSize: 11,
                                      color: Colors.grey.shade700,
                                      fontWeight: FontWeight.w500)),
                              const Spacer(),
                              Icon(Icons.arrow_forward_ios, size: 12, color: Colors.grey.shade400),
                            ]),
                          ),
                        ),
                      ),

                      // --- BNPL Instalment Preview ---
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Builder(builder: (_) {
                          final total = _finalTotal;
                          final eligible = BnplService.eligibleProviders(total).isNotEmpty;
                          final instalment = total / 4.0;
                          return Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(10),
                              gradient: LinearGradient(
                                colors: eligible
                                    ? [Colors.blue.shade50, Colors.blue.shade100]
                                    : [Colors.grey.shade100, Colors.grey.shade200],
                              ),
                              border: Border.all(
                                color: eligible
                                    ? Colors.blue.shade300
                                    : Colors.grey.shade400,
                              ),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(children: [
                                  Icon(Icons.credit_score,
                                      color: eligible
                                          ? Colors.blue.shade700
                                          : Colors.grey.shade600,
                                      size: 22),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      'Buy Now, Pay Later — interest-free instalments',
                                      style: GoogleFonts.lato(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w700,
                                        color: eligible
                                            ? Colors.blue.shade800
                                            : Colors.grey.shade700,
                                      ),
                                    ),
                                  ),
                                  if (eligible)
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 6, vertical: 2),
                                      decoration: BoxDecoration(
                                        color: Colors.green.shade100,
                                        borderRadius: BorderRadius.circular(8),
                                      ),
                                      child: Text('0% Interest',
                                          style: GoogleFonts.lato(
                                            fontSize: 9,
                                            fontWeight: FontWeight.w700,
                                            color: Colors.green.shade800,
                                          )),
                                    ),
                                ]),
                                if (eligible) ...[
                                  const SizedBox(height: 10),
                                  Row(
                                    mainAxisAlignment:
                                        MainAxisAlignment.spaceEvenly,
                                    children: List.generate(4, (i) {
                                      final labels = [
                                        'Today',
                                        '2 wks',
                                        '4 wks',
                                        '6 wks',
                                      ];
                                      return Column(
                                        children: [
                                          Container(
                                            width: 26,
                                            height: 26,
                                            decoration: BoxDecoration(
                                              shape: BoxShape.circle,
                                              color: i == 0
                                                  ? Colors.blue.shade600
                                                  : Colors.blue.shade200,
                                            ),
                                            child: Center(
                                              child: Text('${i + 1}',
                                                  style: GoogleFonts.lato(
                                                    fontSize: 11,
                                                    fontWeight: FontWeight.bold,
                                                    color: i == 0
                                                        ? Colors.white
                                                        : Colors.blue.shade800,
                                                  )),
                                            ),
                                          ),
                                          const SizedBox(height: 3),
                                          Text(labels[i],
                                              style: GoogleFonts.lato(
                                                fontSize: 9,
                                                color: Colors.blue.shade600,
                                              )),
                                          Text(
                                            'R${instalment.toStringAsFixed(0)}',
                                            style: GoogleFonts.lato(
                                              fontSize: 10,
                                              fontWeight: FontWeight.w600,
                                              color: Colors.blue.shade800,
                                            ),
                                          ),
                                        ],
                                      );
                                    }),
                                  ),
                                  const SizedBox(height: 6),
                                  Text(
                                    'PayJustNow, MoreTyme, Happy Pay & Mobicred available at checkout.',
                                    style: GoogleFonts.lato(
                                      fontSize: 10,
                                      color: Colors.blue.shade500,
                                      fontStyle: FontStyle.italic,
                                    ),
                                  ),
                                ] else ...[
                                  const SizedBox(height: 6),
                                  Text(
                                    total < 50
                                        ? 'Available for orders R50+'
                                        : 'Available for orders up to R50,000',
                                    style: GoogleFonts.lato(
                                      fontSize: 10,
                                      color: Colors.grey.shade600,
                                      fontStyle: FontStyle.italic,
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          );
                        }),
                      ),

                      // --- Price Match Promise ---
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Row(children: [
                          Icon(Icons.verified_outlined, color: Colors.green.shade600, size: 16),
                          const SizedBox(width: 4),
                          Text('Price Match Promise: Found it cheaper? We\'ll match it.',
                              style: GoogleFonts.lato(fontSize: 10, color: Colors.green.shade700)),
                        ]),
                      ),

                      SizedBox(height: height * 0.01),
                      CustomPaint(
                        size: Size(width, height * 0.01),
                        painter: DottedLinePainter(Colors.blue.shade400),
                      ),
                      SizedBox(height: height * 0.01),
                      // Row(
                      //   mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      //   children: [
                      //     Expanded(
                      //       child: PrimaryButton(
                      //         fontSize: 14,
                      //         radius: 5,
                      //         title: 'AI Advice for Material',
                      //         onPressed: ()=> Get.to(()=> const ChatBot(), transition: Transition.fadeIn),
                      //       ),
                      //     ),
                      //     const SizedBox(width: 10),
                      //     Expanded(
                      //       child: PrimaryButton(
                      //         fontSize: 14,
                      //         radius: 5,
                      //         title: 'Nearest Material Store',
                      //         onPressed: (){
                      //           Get.to(()=> const WebViewPage(), transition: Transition.fadeIn);
                      //         },
                      //       ),
                      //     ),
                      //   ],
                      // ),
                      // SizedBox(height: height*0.01),
                      Text('Other Info: ',style: GoogleFonts.lato(color: Colors.black,
                          fontWeight: FontWeight.bold,
                          fontSize: width*0.05)),
                      SizedBox(height: height*0.01,),
                      card(title: 'Date', value: DateFormat('dd/MMM/yyyy').format(DateTime.now()), width: width),
                      SizedBox(height: height*0.02),
                      Text('Do you want Service on your current location?', style: GoogleFonts.lato(fontSize: width*0.035)),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Row(
                            children: [
                              Text('Yes', style: GoogleFonts.lato(
                                  fontSize: width * 0.035
                              )),
                              Obx(()=> Checkbox(
                                  activeColor: kPrimaryColor,
                                  value: appController.serviceOnCurrentLocation.value,
                                  onChanged: (value){
                                    appController.serviceOnCurrentLocation.value = !appController.serviceOnCurrentLocation.value;
                                  })),
                            ],
                          ),
                          SizedBox(width: width * 0.1),
                          Row(
                            children: [
                              Text('No', style: GoogleFonts.lato(
                                  fontSize: width * 0.035
                              )),
                              Obx(()=> Checkbox(
                                  activeColor: kPrimaryColor,
                                  value: !appController.serviceOnCurrentLocation.value,
                                  onChanged: (value){
                                    appController.serviceOnCurrentLocation.value = !appController.serviceOnCurrentLocation.value;
                                  })),
                            ],
                          ),
                        ],
                      ),

                      Obx(()=> !appController.serviceOnCurrentLocation.value
                          ? Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('Add Location', style: GoogleFonts.lato(
                                fontWeight: FontWeight.w600
                              )),
                              Row(
                                children: [
                                  Expanded(
                                    child: Card(
                                      elevation: 2,
                                      color: Colors.white,
                                      child: TextField(
                                        readOnly: true,
                                        controller: appController.addressController,
                                        cursorColor: Colors.black,
                                        style: GoogleFonts.lato(fontWeight: FontWeight.normal),
                                        decoration: InputDecoration(
                                          labelText: 'Please pick your location',
                                          labelStyle: GoogleFonts.lato(
                                              fontSize: 12,
                                              color: const Color(0xffACADB9)),
                                          border: InputBorder.none,
                                          focusedBorder: const OutlineInputBorder(
                                            borderSide: BorderSide(color: Colors.white),
                                          ),
                                          filled: true,
                                          fillColor: Colors.white,
                                          prefixIcon: Icon(
                                            Icons.location_on,
                                            color: const Color(0xffACADB9),
                                            size: width * 0.07,
                                          ),
                                          contentPadding: const EdgeInsets.symmetric(
                                              horizontal: 5.0),
                                        ),
                                      ),
                                    ),
                                  ),
                                  GestureDetector(
                                    // onTap: ()=> Get.to(()=> const GoogleMapPickLocation()),
                                    onTap: () async {
                                      final result = await Get.to(()=> LocationPickerScreen(
                                          initialLat: double.parse(appController.pickedLat.value == ""
                                              ? appController.userLat.value
                                              : appController.pickedLat.value),
                                          initialLng: double.parse(appController.pickedLng.value == ""
                                              ? appController.userLng.value
                                              : appController.pickedLng.value),
                                          initialAddress: ""));

                                      // Check if the result is not null and read the values
                                      if (result != null) {
                                        appController.pickedLat.value = result['latitude'].toString();
                                        appController.pickedLng.value = result['longitude'].toString();
                                        appController.addressController.text = result['address'].toString();
                                      }
                                    },
                                    child: Container(
                                      margin: const EdgeInsets.only(left: 5),
                                      padding: const EdgeInsets.all(10),
                                      decoration: BoxDecoration(
                                          color: const Color(0xFFc5a520).withOpacity(0.2),
                                          borderRadius: BorderRadius.circular(5),
                                          border: Border.all(color: const Color(0xFFc5a520))
                                      ),
                                      child: const Icon(Icons.add_location, color:Color(0xFFc5a520)),
                                    ),
                                  ),
                                ],
                              )
                            ],
                          )
                          : const SizedBox()),

                      SizedBox(height: height * 0.02),

                      // ── Strategy 1: Escrow Trust Framing ───────────────
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(8),
                          color: Colors.green.shade50,
                          border: Border.all(color: Colors.green.shade600),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(children: [
                              Icon(Icons.lock_outline, color: Colors.green.shade700, size: 20),
                              const SizedBox(width: 6),
                              Text('Your Money is Protected',
                                  style: GoogleFonts.lato(
                                      color: Colors.green.shade800,
                                      fontWeight: FontWeight.bold,
                                      fontSize: 13)),
                            ]),
                            const SizedBox(height: 6),
                            Text(
                              'Your payment is held in a secure escrow account. '
                              'The artisan does NOT receive your money until you '
                              'confirm you are satisfied with the completed work. '
                              'You are always in control.',
                              style: GoogleFonts.lato(
                                  color: Colors.green.shade700,
                                  fontWeight: FontWeight.normal,
                                  fontSize: width * 0.03),
                            ),
                          ],
                        ),
                      ),

                      const SizedBox(height: 8),

                      // ── Strategy 2: Money-Back Guarantee Badge ─────────
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(8),
                          gradient: LinearGradient(
                            colors: [Colors.blue.shade50, Colors.blue.shade100],
                          ),
                          border: Border.all(color: Colors.blue.shade300),
                        ),
                        child: Row(children: [
                          Icon(Icons.verified_user, color: Colors.blue.shade700, size: 24),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('100% Money-Back Guarantee',
                                    style: GoogleFonts.lato(
                                        fontWeight: FontWeight.bold,
                                        fontSize: 12,
                                        color: Colors.blue.shade800)),
                                Text('Not satisfied? Full refund. No questions asked within 24 hours.',
                                    style: GoogleFonts.lato(
                                        fontSize: 10,
                                        color: Colors.blue.shade600)),
                              ],
                            ),
                          ),
                        ]),
                      ),

                      const SizedBox(height: 8),

                      // ── Strategy 10: Cancellation Freedom ──────────────
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(8),
                          color: Colors.orange.shade50,
                          border: Border.all(color: Colors.orange.shade300),
                        ),
                        child: Row(children: [
                          Icon(Icons.cancel_outlined, color: Colors.orange.shade700, size: 18),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'Free cancellation before artisan dispatch. Full refund within 2 hours of payment.',
                              style: GoogleFonts.lato(
                                  fontSize: 10,
                                  color: Colors.orange.shade700),
                            ),
                          ),
                        ]),
                      ),
                      SizedBox(height: height*0.02),
                      GestureDetector(
                        onTap: () async {
                          debugPrint("test ${appController.listOfJobs.length}");
                          debugPrint("test ${appController.jobImagesList.length}");
                          for(int i=0; i < appController.listOfJobs.length; i++){
                            debugPrint("value ");
                          }
                          // appController.jobImagesList.any((job){
                          //   debugPrint("value ${job.length}");
                          //   return job.isEmpty;
                          // });

                          if(descriptionControllerList.any((element) => element.text.isEmpty)){
                            EasyLoading.showError("Description is required for each job!", duration: const Duration(seconds: 3));
                            return;
                          }
                          else if (
                          appController.jobImagesList.isEmpty ||
                              appController.jobImagesList.length != appController.listOfJobs.length ||
                              appController.jobImagesList.any((images) => images.length < 3)
                          ) {
                            EasyLoading.showError(
                              "Add minimum 3 images for each job!",
                              duration: const Duration(seconds: 3),
                            );
                            return;
                          }
                          else if(!appController.serviceOnCurrentLocation.value && appController.addressController.text == ""){
                            EasyLoading.showError("Location Address is required", duration: const Duration(seconds: 3));
                            return;
                          }
                          else{
                            // var address = await MapService().getAddressFromGoogleAPI(
                            //     double.parse(appController.userLat.toString()),
                            //     double.parse(appController.userLng.toString()));
                            // debugPrint("address $address");
                            // return;
                            showDialog(
                                context: context,
                                builder: (BuildContext context) {
                                  return AlertDialog(
                                    // title: Text(
                                    //   "NOTE: Material needs to be on-site when the artisan arrive.",
                                    //   style: GoogleFonts.lato(color: Colors.red,fontWeight: FontWeight.bold, fontSize: 14),
                                    // ),
                                    // title: Text(
                                    //   "Proceed with your order request",
                                    //   style: GoogleFonts.lato(fontWeight: FontWeight.bold, fontSize: 14),
                                    // ),
                                    content: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        PrimaryButton(
                                          title: _useDeposit
                                              ? 'Proceed — Pay R${_payableNow.toStringAsFixed(2)} Deposit'
                                              : 'Proceed',
                                          radius: 5,
                                          fontSize: 14,
                                          onPressed: () async {
                                            Navigator.of(context).pop();
                                            appController.isOrderApproveOrReject.value = false;
                                            appController.timeUp.value = false;
                                            debugPrint("Idr aa gya.....");
                                            final targetProviderId = _resolvedProviderId.trim().isNotEmpty
                                                ? _resolvedProviderId
                                                : widget.providerId;
                                            if (targetProviderId.trim().isEmpty) {
                                              EasyLoading.showError(
                                                'No available artisan found right now. Please try again.',
                                                duration: const Duration(seconds: 3),
                                              );
                                              return;
                                            }
                                            await appController.sendRequestToServiceProvider(
                                                provideId: targetProviderId,
                                                descriptionList: descriptionControllerList,
                                                useDeposit: _useDeposit);
                                            _requestSent = true;

                                          },
                                        ),
                                        // const SizedBox(height: 5),
                                        // PrimaryButton(
                                        //   fontSize: 14,
                                        //   radius: 5,
                                        //   title: 'Material Store',
                                        //   onPressed: ()=> Get.to(()=> const WebViewPage(), transition: Transition.fadeIn),
                                        // ),
                                        // const SizedBox(height: 5),
                                        // PrimaryButton(
                                        //   fontSize: 14,
                                        //   radius: 5,
                                        //   title: 'AI Advice',
                                        //   onPressed: (){
                                        //     Get.to(()=> const ChatBot(), transition: Transition.fadeIn);
                                        //   },
                                        // ),
                                      ],
                                    ),
                                  );
                                });

                          }
                        },
                        child: Container(
                          alignment: AlignmentDirectional.center,
                          height: height * 0.07,
                          margin: EdgeInsets.only(bottom: 20),
                          width: double.infinity,
                          decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(5),
                              color: const Color(0xff35540C)
                          ),
                          child: Text('Send Request', style: GoogleFonts.lato(
                              fontSize: width*0.045,
                              color: Colors.white,
                              fontWeight: FontWeight.bold)),
                        ),
                      ),
                    ],
                  ),
                ),

              ],
            ),
          ),
        ),
      ),
    );
  }
  Future<void> showChoiceDialog(BuildContext context, {bool isAdditional = false}) {
    return showDialog(
        context: context,
        builder: (BuildContext context) {
          return AlertDialog(
            title: const Text(
              "Choose option",
            ),
            content: SingleChildScrollView(
              child: ListBody(
                children: [
                  const Divider(height: 1
                    // color: Colors.blue,
                  ),
                  ListTile(
                    onTap: () {
                      Navigator.pop(context);
                      getPhoto(context, ImageSource.gallery, isAdditional: isAdditional);
                    },
                    title: const Text("Gallery"),
                    leading: const Icon(
                      Icons.account_box,
                      // color: Colors.blue,
                    ),
                  ),
                  const Divider(height: 1
                    // color: Colors.blue,
                  ),
                  ListTile(
                    onTap: () {
                      Navigator.pop(context);
                        getPhoto(context, ImageSource.camera, isAdditional: isAdditional);
                    },
                    title: const Text("Camera"),
                    leading: const Icon(
                      Icons.camera,
                      // color: Colors.blue,
                    ),
                  ),
                ],
              ),
            ),
          );
        });
  }

}
Widget card({required String title, required String value, required double width}) =>  Row(
  mainAxisAlignment: MainAxisAlignment.spaceBetween,
  children: [
    Text("$title: ",style: GoogleFonts.lato(color: Colors.black,
        fontWeight: FontWeight.w600,
        fontSize: width*0.035)),
    Text(value,style: GoogleFonts.lato(color: Colors.black,
        fontWeight: FontWeight.normal,
        fontSize: width*0.035)),
  ],
);

