import 'dart:convert';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:geocoding/geocoding.dart';
import 'package:geolocator/geolocator.dart';
import 'package:get/get.dart';
import 'package:http/http.dart';
import 'package:image_picker/image_picker.dart';
import 'package:maintenanceapp/model/notification_model.dart';
import 'package:maintenanceapp/model/task_management_model.dart';
import 'package:maintenanceapp/model/future_booking_model.dart';
import 'package:maintenanceapp/services/firestore_services/firebase_services.dart';
import 'package:maintenanceapp/services/future_booking_service.dart';
import 'package:maintenanceapp/services/storage_services.dart';
import 'package:maintenanceapp/services/ai_photo_diagnosis_service.dart';
import 'package:maintenanceapp/screens/service_provider_panel/artisan_flag_issue_screen.dart';
import 'package:maintenanceapp/utils/helper.dart';
import 'package:maintenanceapp/utils/splash_timer.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../screens/service_provider_panel/models/artisan_tasks_images.dart';

class ServiceProviderController extends GetxController {
  FirebaseService firebaseService = FirebaseService();
  var currentRequest = "".obs;
  var isError = false.obs;
  var isLoading = false.obs;
  var isUploading = false.obs;
  var showNotedField = false.obs;
  var requestList = <TaskManagementModel>[].obs;
  var isActive = false.obs;
  var withDrawAmount = "".obs;

  /// Whether background job-request announcements are enabled.
  /// Defaults to true so artisans hear new-job sounds out of the box.
  var announcementsEnabled = true.obs;

  /// IDs already seen so only NEW requests generate a notification.
  final Set<String> _knownRequestIds = {};

  /// Worker that fires local notifications for new requests when the toggle is on.
  Worker? _announcementsWorker;

  Rx<XFile?> imageProvider = Rx<XFile?>(null);
  var isBeforeWorkImage = false.obs;
  // var userAddress = "".obs;

  //Music Player
  late AudioPlayer audioPlayer;
  var downloadFileOfMusic = "".obs;
  bool _isRinging = false;

  @override
  void onInit() {
    // TODO: implement onInit
    super.onInit();
    audioPlayer = AudioPlayer();
    // Keep ringing until the artisan accepts/rejects or no pending requests.
    audioPlayer.setReleaseMode(ReleaseMode.loop);
    audioPlayer.setVolume(1.0);
    getMusicFile();
  }

  Future<void> getMusicFile() async {
    FirebaseStorage storage = FirebaseStorage.instance;
    String folderPath = 'app_sound';
    Reference folderReference = storage.ref().child(folderPath);
    try {
      ListResult listResult = await folderReference.list();
      if (listResult.items.isNotEmpty) {
        var file = listResult.items.first.name;
        var downloadRef = storage.ref().child('$folderPath/$file');
        downloadFileOfMusic.value = await downloadRef.getDownloadURL();
        // debugPrint("File $file");
        // debugPrint("Download ${downloadFileOfMusic.value}");
      }
    } catch (e) {
      debugPrint('Error getting files: $e');
    }
  }

  void playMusic() {
    if (_isRinging) return;
    _isRinging = true;
    debugPrint("Play Music.......");
    _doPlayMusic();
  }

  Future<void> _doPlayMusic() async {
    // Prefer remote-configured ringtone, fall back to bundled asset.
    final url = downloadFileOfMusic.value.trim();

    // 1) Try remote URL
    if (url.isNotEmpty) {
      try {
        await audioPlayer.play(UrlSource(url));
        debugPrint('[playMusic] UrlSource playing OK');
        return;
      } catch (e) {
        debugPrint('[playMusic] UrlSource failed: $e — trying asset');
      }
    }

    // 2) Try the bundled asset (full Flutter asset key)
    try {
      await audioPlayer.play(AssetSource('assets/sounds/sound.mp3'));
      debugPrint('[playMusic] AssetSource (assets/sounds/) playing OK');
      return;
    } catch (e) {
      debugPrint('[playMusic] AssetSource assets/sounds/ failed: $e');
    }

    // 3) Try without the assets/ prefix (some audioplayers versions need this)
    try {
      await audioPlayer.play(AssetSource('sounds/sound.mp3'));
      debugPrint('[playMusic] AssetSource (sounds/) playing OK');
      return;
    } catch (e) {
      debugPrint('[playMusic] AssetSource sounds/ failed: $e');
    }

    // 4) Last resort: try BytesSource from the raw resource
    debugPrint('[playMusic] All audio play attempts failed — resetting _isRinging');
    _isRinging = false;
  }

  void stopMusic() {
    if (!_isRinging) return;
    _isRinging = false;
    debugPrint("Stop Music.......");
    audioPlayer.stop();
  }

  Future<void> showChoiceDialog(BuildContext context) {
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
                      getPhoto(context, ImageSource.gallery);
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
                      getPhoto(context, ImageSource.camera);
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

  getPhoto(BuildContext context, ImageSource source) async {
    XFile? pickedFile = await ImagePicker().pickImage(source: source);
    if (pickedFile != null) {
      imageProvider.value = pickedFile;
    }
  }

  Future<String> getAddressFromLatLng(
      double latitude, double longitude, context) async {
    try {
      final hasPermission = await _handleLocationPermission(context);
      debugPrint("Permission $hasPermission");
      if (!hasPermission) return "";
      List<Placemark> placeMarks =
          await placemarkFromCoordinates(latitude, longitude);
      if (placeMarks.isNotEmpty) {
        Placemark data = placeMarks[0];
        // debugPrint(data.toString());
        String address =
            '${data.name},${data.administrativeArea},${data.country}';
        // userAddress.value = address;
        // debugPrint("address $address");
        return address;
      }
    } catch (e) {
      debugPrint('Error: $e');
    }
    return '';
  }

  Future<bool> _handleLocationPermission(context) async {
    bool serviceEnabled;
    LocationPermission permission;

    serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text(
              'Location services are disabled. Please enable the services')));
      return false;
    }
    permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Location permissions are denied')));
        return false;
      }
    }
    if (permission == LocationPermission.deniedForever) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text(
              'Location permissions are permanently denied, we cannot request permissions.')));
      return false;
    }
    return true;
  }

  Future<void> getRequests({
    required String providerId,
    List<String> additionalProviderIds = const <String>[],
  }) async {
    try {
      isLoading.value = true;

      final ids = <String>{
        providerId.toString().trim(),
        for (final id in additionalProviderIds) id.toString().trim(),
      }.where((s) => s.isNotEmpty).toList();

      firebaseService.requestQueryForProviders(providerIds: ids).listen((data) {
        isLoading.value = false;
        requestList.assignAll(data);
        debugPrint("Requests ${requestList.length}");

        final hasPending =
            requestList.any((p) => (p.accept ?? '').trim().isEmpty);
        debugPrint("pending=$hasPending");
        if (hasPending) {
          playMusic();
        } else {
          stopMusic();
        }
      }, onError: (e) {
        isLoading.value = false;
        debugPrint("requestQueryForProviders stream error: $e");
      });
    } catch (e) {
      isLoading.value = false;
      debugPrint("getRequests $e");
    }
  }

  Future<void> responseToRequest({
    required String id,
    required String accept,
    required String to,
    required String from,
    String taskId = '',
  }) async {
    try {
      void fireAndForget(Future<void> f, {String label = 'notify'}) {
        // Never block accept/reject on network calls.
        // Ensure the future completes (or times out) so we don't keep UI loaders spinning.
        f.timeout(const Duration(seconds: 10)).catchError((e) {
          debugPrint('responseToRequest $label error: $e');
        });
      }

      final tmDoc = await FirebaseService.tasksManagementRef.doc(id).get();
      final tmData = tmDoc.data() ?? <String, dynamic>{};
      final source = (tmData['source'] ?? '').toString().trim().toLowerCase();
      final futureBookingId =
          (tmData['future_booking_id'] ?? '').toString().trim();
      final isFutureBookingBridge =
          (source == 'future_booking' || source == 'whatsapp' || source == 'whatsapp_rfq') && futureBookingId.isNotEmpty;

      if (isFutureBookingBridge && accept == '1') {
        final fbSnap = await FutureBookingService.futureBookingsRef
            .doc(futureBookingId)
            .get();
        final fbData = fbSnap.data() ?? <String, dynamic>{};

        final scheduledDate =
            (fbData['scheduled_date'] ?? tmData['scheduled_date'] ?? '')
                .toString();
        final scheduledTime =
            (fbData['scheduled_time'] ?? tmData['scheduled_time'] ?? '')
                .toString();

        final bookingProviderId =
            (fbData['service_provider_id'] ?? '').toString().trim();
        final artisanIdToCheck =
            bookingProviderId.isNotEmpty ? bookingProviderId : from;

        final ok = await FutureBookingService.checkArtisanAvailability(
          artisanId: artisanIdToCheck,
          scheduledDate: scheduledDate,
          scheduledTime: scheduledTime,
          excludeBookingId: futureBookingId,
        );

        if (!ok) {
          Get.showSnackbar(const GetSnackBar(
            backgroundColor: Colors.red,
            duration: Duration(seconds: 3),
            snackPosition: SnackPosition.TOP,
            title: 'Appointment clash',
            message: 'You already have an appointment around this time.',
          ));
          return;
        }
      }

      await FirebaseService.tasksManagementRef.doc(id).update({
        'accept': accept,
        'updated_at': DateTime.now().toString(),
        'updated_by': appController.userId.value,
        'status': accept == '1' ? 'pending_payment' : 'pending',
        if (accept == '1') 'service_provider_id': from,
        if (accept == '1') 'service_provider_name': appController.userName.value,
      });

      if (isFutureBookingBridge) {
        if (accept == '1') {
          // Read original booking to preserve RFQ flags for client visibility.
          final fbSnap2 = await FutureBookingService.futureBookingsRef
              .doc(futureBookingId)
              .get();
          final fbData2 = fbSnap2.data() ?? <String, dynamic>{};

          final Map<String, dynamic> fbPatch = {
            'artisan_confirmed': 'yes',
            // Once the artisan accepts, the next step is client payment.
            'status': 'pending_payment',
            'tasks_management_id': id,
            'service_provider_id': from,
            'updated_at': DateTime.now().toString(),
          };

          // Ensure RFQ-related flags stay on the booking for the client filter.
          final existingIsRfq =
              (fbData2['is_rfq'] ?? '').toString().trim().toLowerCase();
          final existingOrderType =
              (fbData2['order_type'] ?? '').toString().trim().toLowerCase();
          final tmOrderType =
              (tmData['order_type'] ?? '').toString().trim().toLowerCase();
          if (existingIsRfq.isEmpty && (tmOrderType == 'rfq' || existingOrderType == 'rfq')) {
            fbPatch['is_rfq'] = 'yes';
          }
          if (existingOrderType.isEmpty && tmOrderType == 'rfq') {
            fbPatch['order_type'] = 'rfq';
          }
          // Backfill order_no from tasksManagement if booking has none.
          final fbOrderNo =
              (fbData2['order_no'] ?? '').toString().trim();
          final tmOrderNo =
              (tmData['order_no'] ?? '').toString().trim();
          if (fbOrderNo.isEmpty && tmOrderNo.isNotEmpty) {
            fbPatch['order_no'] = tmOrderNo;
          }

          await FutureBookingService.futureBookingsRef
              .doc(futureBookingId)
              .set(fbPatch, SetOptions(merge: true));

          // Do NOT auto-deduct wallet here — let the client pay explicitly
          // so the artisan sees 'pending_payment' status until client pays.

          fireAndForget(
            FutureBookingService.sendNotificationToUser(
              userId: to,
              message:
                  'Your artisan has confirmed the booking for ${(tmData['scheduled_date'] ?? '').toString()}',
            ),
            label: 'user_confirmed',
          );

          fireAndForget(
            FutureBookingService.sendNotificationToUser(
              userId: to,
              title: 'Payment required',
              type: 'future_booking_payment_required',
              message:
                  'Your booking is confirmed. Please pay to confirm the order. Note: funds will be immediately refunded if the work is not done or if the artisan cancels without going to site.',
              data: {
                'booking_id': futureBookingId,
                'type': 'future_booking_payment_required',
              },
            ),
            label: 'payment_required',
          );

          // ── Notify WhatsApp client if booking originated from WhatsApp ──
          if (source == 'whatsapp' || source == 'whatsapp_rfq') {
            // Update the MAIN tasksManagement doc directly so the payment
            // handler can detect acceptance even if the webhook fails.
            fireAndForget(
              FirebaseService.tasksManagementRef.doc(futureBookingId).set({
                'accept': '1',
                'artisan_confirmed': 'yes',
                'status': 'pending_payment',
                'service_provider_id': from,
                'service_provider_name': appController.userName.value,
                'updated_at': DateTime.now().toString(),
              }, SetOptions(merge: true)),
              label: 'wa_main_doc_update',
            );
            fireAndForget(
              _notifyWhatsAppClient(futureBookingId, appController.userName.value),
              label: 'wa_artisan_accepted',
            );
          }
        } else if (accept == '0') {
          final fbSnap = await FutureBookingService.futureBookingsRef
              .doc(futureBookingId)
              .get();
          final fbData = fbSnap.data() ?? <String, dynamic>{};
          if (fbData.isNotEmpty) {
            final booking = FutureBookingModel.fromDocument(fbData);
            await FutureBookingService.reassignBooking(
              bookingId: futureBookingId,
              booking: booking,
            );
          }
        }
      } else {
        // Legacy order request flow
        appController.sendNotification(to: to, from: from, accept: accept);
      }

      stopMusic();
      Get.showSnackbar(GetSnackBar(
        backgroundColor: accept == "0" ? Colors.red : Colors.green,
        duration: const Duration(seconds: 2),
        snackPosition: SnackPosition.TOP,
        title: accept == "0" ? "Reject" : 'Success',
        message: accept == "0" ? 'Request Rejected' : 'Request Accepted',
      ));
    } catch (e, st) {
      debugPrint("responseToRequest error: $e\n$st");
      rethrow;
    }
  }

  /// Notify WhatsApp client via bot webhook when artisan accepts.
  static Future<void> _notifyWhatsAppClient(
      String bookingId, String artisanName) async {
    try {
      const botUrl =
          'https://square15-whatsapp-bot.onrender.com/api/artisan-accepted';
      final response = await post(
        Uri.parse(botUrl),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'bookingId': bookingId,
          'artisanName': artisanName,
        }),
      );
      debugPrint(
          '[wa-webhook] artisan-accepted response: ${response.statusCode}');
    } catch (e) {
      debugPrint('[wa-webhook] artisan-accepted error: $e');
    }
  }

  Future<void> updateServiceProviderProfile(
      {required String id, required String name, File? file}) async {
    isUploading.value = true;
    Map<String, dynamic> data = {"name": name};
    String url = '';
    if (file != null) {
      url = await StorageServices.uploadImageToFirebase(
          path: "service_providers", id: id, imageFile: file);
      data = {"name": name, "image": url};
    }
    FirebaseService.providerRef.doc(id).update(data).whenComplete(() {
      debugPrint("Image updates");
      isUploading.value = false;
    });
  }

  Future<void> setStatusForProfile(
      {required String id, required String status}) async {
    try {
      isLoading.value = true;
      FirebaseService.providerRef.doc(id).update({
        "active": status,
      }).then((value) {
        FirebaseService.taskRef
            .where('user_id', isEqualTo: id)
            .get()
            .then((snapshot) {
          for (var e in snapshot.docs) {
            FirebaseService.taskRef
                .doc(e.id)
                .update({"status": status == 'y' ? 'publish' : 'draft'});
          }
        });
      });
    } catch (e) {
      isLoading.value = false;
      debugPrint("getRequests $e");
    }
  }

  // ── Artisan Announcements Toggle ─────────────────────────────

  /// Load the persisted announcement setting and arm/disarm the listener.
  Future<void> loadAnnouncementSetting(String providerId) async {
    try {
      // Read from Firestore (authoritative) first, fall back to local prefs.
      final doc = await FirebaseService.providerRef.doc(providerId).get();
      final data = doc.data() ?? <String, dynamic>{};
      final remote = data['voice_announcements_enabled'];
      if (remote != null) {
        announcementsEnabled.value = remote == true || remote == 'true';
      } else {
        final prefs = await SharedPreferences.getInstance();
        announcementsEnabled.value =
            prefs.getBool('announcements_enabled') ?? true;
      }
    } catch (_) {
      try {
        final prefs = await SharedPreferences.getInstance();
        announcementsEnabled.value =
            prefs.getBool('announcements_enabled') ?? true;
      } catch (_) {}
    }

    // Seed known IDs so existing requests don't fire notifications.
    _knownRequestIds.clear();
    for (final r in requestList) {
      final id = r.id ?? r.taskId ?? '';
      if (id.isNotEmpty) _knownRequestIds.add(id);
    }

    _armAnnouncementsListener();
  }

  /// Toggle announcements on/off and persist to Firestore + local prefs.
  Future<void> setAnnouncementsEnabled({
    required String providerId,
    required bool enabled,
  }) async {
    announcementsEnabled.value = enabled;

    // Persist locally.
    try {
      final prefs = await SharedPreferences.getInstance();
      prefs.setBool('announcements_enabled', enabled);
    } catch (_) {}

    // Persist to Firestore on the provider doc.
    try {
      await FirebaseService.providerRef.doc(providerId).update({
        'voice_announcements_enabled': enabled,
      });
    } catch (e) {
      debugPrint('setAnnouncementsEnabled Firestore error: $e');
    }

    _armAnnouncementsListener();
  }

  /// Arms or disarms the GetX `ever` worker that fires local notifications
  /// for new job requests.
  void _armAnnouncementsListener() {
    _announcementsWorker?.dispose();
    _announcementsWorker = null;

    if (!announcementsEnabled.value) return;

    _announcementsWorker = ever<List<TaskManagementModel>>(
      requestList,
      (list) {
        if (!announcementsEnabled.value) return;

        for (final req in list) {
          final id = req.id ?? req.taskId ?? '';
          if (id.isEmpty) continue;
          if (_knownRequestIds.contains(id)) continue;

          _knownRequestIds.add(id);

          final accepted = (req.accept ?? '').trim();
          if (accepted.isNotEmpty) continue; // already handled

          // Fire a local notification.
          final category =
              (req.description ?? 'Maintenance').toString().trim();
          final address =
              (req.userProvidedAddress ?? '').toString().trim();

          _showAnnouncementNotification(
            title: 'New Job Request: $category',
            body: address.isNotEmpty
                ? 'You have a new request at $address. Open the app to respond.'
                : 'You have a new maintenance request. Open the app to accept or decline.',
          );

          // Also play the alarm tone for new requests
          playMusic();
        }
      },
    );
  }

  static final FlutterLocalNotificationsPlugin _notifPlugin =
      FlutterLocalNotificationsPlugin();

  void _showAnnouncementNotification({
    required String title,
    required String body,
  }) {
    final id = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    const android = AndroidNotificationDetails(
      'order_request_channel',
      'Job Announcements',
      channelDescription: 'Artisan job-request announcements',
      importance: Importance.max,
      priority: Priority.max,
      playSound: true,
      sound: RawResourceAndroidNotificationSound('sound'),
      enableVibration: true,
      enableLights: true,
      fullScreenIntent: true,
    );
    const platform = NotificationDetails(android: android);
    _notifPlugin.show(id, title, body, platform);
  }

  Future<void> saveAccountInformation(
      {required String id, required String key}) async {
    try {
      appController.providerAccountsRef.doc(appController.userId.value).set({
        'merchantKey': key,
        'merchantId': id,
        'provider_id': appController.userId.value,
        'created_at': DateTime.now().toString(),
        'updated_at': "",
        'account_type': "Ozow",
      }).then((_) {
        appController.serviceProviderRef
            .doc(appController.userId.value)
            .update({
          'accountLinked': "1",
        });
      });
    } catch (e) {
      debugPrint("saveAccountInformation $e");
    }
  }

  Future<void> updateAccountInformation(
      {required String id, required String key}) async {
    try {
      appController.providerAccountsRef.doc(appController.userId.value).update({
        'merchantKey': key,
        'merchantId': id,
        'updated_at': DateTime.now().toString(),
        'account_type': "Ozow",
      });
    } catch (e) {
      debugPrint("saveAccountInformation $e");
    }
  }

  Future<void> saveBeforeAndAfterImage(
      {required String to,
      required String taskId,
      required String notes,
      String? referId}) async {
    final toId = to.toString().trim();
    final tmId = taskId.toString().trim();
    final noteText = notes.toString().trim();

    if (toId.isEmpty) {
      throw Exception('Missing client id');
    }
    if (tmId.isEmpty) {
      throw Exception('Missing task id');
    }
    if (noteText.isEmpty) {
      throw Exception('Notes are required');
    }
    final picked = imageProvider.value;
    if (picked == null) {
      throw Exception('Select an image first');
    }

    isUploading.value = true;
    ArtisanTaskImages imageData = ArtisanTaskImages();
    Map<String, Object> message = {};

    final before = isBeforeWorkImage.value;
    var id = const Uuid().v4();

    try {
      var link = await StorageServices.uploadImageToFirebase(
          path: 'artisan_work_images', imageFile: File(picked.path), id: id);

      if (!before) {
        final ref = (referId ?? '').toString().trim();
        if (ref.isEmpty) {
          throw Exception('Upload Before Work image first');
        }
        id = ref;
      }

      await FirebaseService.tasksManagementRef.doc(tmId).update(
          {"artisan_images": before ? "1" : "2", "artisan_image_doc_id": id});

      //only use before work notes
      imageData = ArtisanTaskImages(
        id: id,
        taskManagementId: tmId,
        createAt: DateTime.now().toString(),
        updatedAt: "",
        beforeWork: link,
        afterWork: "",
        afterNotes: "",
        beforeNotes: noteText,
      );

      if (!before) {
        await FirebaseService.artisanTaskImages.doc(id).update({
          "updated_at": DateTime.now().toString(),
          "after_notes": noteText,
          "after_work": link,
        });

        // ── AI Quality Verification (compare before vs after photos) ──
        try {
          final beforeDoc = await FirebaseService.artisanTaskImages.doc(id).get();
          final beforeUrl = (beforeDoc.data()?['before_work'] ?? '').toString();
          if (beforeUrl.isNotEmpty) {
            final tmSnap = await FirebaseService.tasksManagementRef.doc(tmId).get();
            final taskDesc = (tmSnap.data()?['description'] ?? '').toString();
            final verification = await AIPhotoDiagnosisService.instance
                .verifyWorkQuality(
                  beforeImageUrl: beforeUrl,
                  afterImageUrl: link,
                  jobDescription: taskDesc,
                );
            // Store quality result on the task
            await FirebaseService.tasksManagementRef.doc(tmId).update({
              'quality_score': verification.qualityScore,
              'quality_recommendation': verification.recommendation,
              'quality_verified_at': DateTime.now().toIso8601String(),
            });
            debugPrint('[quality] score=${verification.qualityScore} rec=${verification.recommendation}');
          }
        } catch (e) {
          debugPrint('[quality] verification skipped: $e');
        }

        // Notify client: artisan finished work
        FutureBookingService.sendNotificationToUser(
          userId: toId,
          title: 'Work Completed',
          message: 'Your artisan has completed the work. Please review and mark the order as complete.',
          type: 'artisan_work_completed',
          data: {
            'type': 'artisan_work_completed',
            'task_management_id': tmId,
          },
        ).catchError((e) {
          debugPrint('After-work notification error: $e');
        });

        // ── Notify WhatsApp client of job completion ──
        try {
          final tmSnap2 = await FirebaseService.tasksManagementRef.doc(tmId).get();
          final src = (tmSnap2.data()?['source'] ?? '').toString().toLowerCase();
          if (src == 'whatsapp' || src == 'whatsapp_rfq') {
            // Fetch before photo URL for comparison images
            String beforeUrl = '';
            try {
              final imgDoc = await FirebaseService.artisanTaskImages.doc(id).get();
              beforeUrl = (imgDoc.data()?['before_work'] ?? '').toString();
            } catch (_) {}

            // Send after photo first
            post(
              Uri.parse('https://square15-whatsapp-bot.onrender.com/api/job-status-update'),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({
                'bookingId': tmId,
                'status': 'after_photo',
                'artisanName': appController.userName.value,
                'imageUrl': link,
              }),
            );

            // Then send completion with rating + payment prompt
            post(
              Uri.parse('https://square15-whatsapp-bot.onrender.com/api/job-status-update'),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({
                'bookingId': tmId,
                'status': 'completed',
                'artisanName': appController.userName.value,
              }),
            );
          }
        } catch (_) {}

        // Legacy notification fallback
        DocumentSnapshot dc = await FirebaseService.userRef.doc(toId).get();
        if (dc.exists) {
          var toDeviceToken = dc["deviceToken"];
          var title = "Order Completion Alert";
          var body = "Artisan completed the work, Now mark Order as complete";
          var type = "Order Completion";
          message = {
            'notification': {
              'title': title,
              'body': body,
            },
            'data': {
              'image': '',
              'type': "Order Completion",
            },
            'to': toDeviceToken,
          };
          NotificationModel notificationModel = NotificationModel(
              body: body,
              imageUrl: "",
              time: DateTime.now().toString(),
              title: title,
              type: type,
              view: false);
          debugPrint("To $toDeviceToken");
          debugPrint("body $body");
          debugPrint("title $title");
          debugPrint("type $type");
          await pushCustomNotification(
              notificationModel: notificationModel, message: message);
        }

        // Offer artisan to flag additional issues for upselling
        try {
          // Fetch category info from the task management doc
          final tmSnap = await FirebaseService.tasksManagementRef.doc(tmId).get();
          final tmData = tmSnap.data() ?? <String, dynamic>{};
          final categoryId = (tmData['category_id'] ?? '').toString().trim();
          final categoryName = (tmData['category_name'] ?? '').toString().trim();

          // Show balance reminder if deposit model with outstanding balance
          final isDeposit = tmData['payment_type'] == 'deposit';
          final balancePaid = tmData['balance_paid'] == true;
          if (isDeposit && !balancePaid) {
            final balanceAmount = double.tryParse(
                    (tmData['balance_amount'] ?? '0').toString()) ??
                0.0;
            if (balanceAmount > 0) {
              Get.snackbar(
                'Balance Reminder',
                'The client still owes R${balanceAmount.toStringAsFixed(2)} for this job. '
                    'They will be prompted to pay.',
                backgroundColor: Colors.orange,
                colorText: Colors.white,
                duration: const Duration(seconds: 6),
                snackPosition: SnackPosition.TOP,
              );
            }
          }

          Get.to(() => ArtisanFlagIssueScreen(
            taskManagementId: tmId,
            clientUserId: toId,
            categoryId: categoryId,
            categoryName: categoryName,
          ));
        } catch (_) {}
      } else {
        await FirebaseService.artisanTaskImages.doc(id).set(imageData.toMap());

        // Notify client: artisan arrived and started work
        FutureBookingService.sendNotificationToUser(
          userId: toId,
          title: 'Work Started',
          message: 'Your artisan has arrived at the site and started working.',
          type: 'artisan_started_work',
          data: {
            'type': 'artisan_started_work',
            'task_management_id': tmId,
          },
        ).catchError((e) {
          debugPrint('Before-work notification error: $e');
        });

        // ── Notify WhatsApp client of before-photo + work started ──
        try {
          final tmSnap3 = await FirebaseService.tasksManagementRef.doc(tmId).get();
          final src = (tmSnap3.data()?['source'] ?? '').toString().toLowerCase();
          if (src == 'whatsapp' || src == 'whatsapp_rfq') {
            post(
              Uri.parse('https://square15-whatsapp-bot.onrender.com/api/job-status-update'),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({
                'bookingId': tmId,
                'status': 'before_photo',
                'artisanName': appController.userName.value,
                'imageUrl': link,
              }),
            );
          }
        } catch (_) {}
      }

      showNotedField.value = false;
      imageProvider.value = null;
      isBeforeWorkImage.value = false;
    } finally {
      isUploading.value = false;
    }
  }

  Future<void> pushCustomNotification(
      {required NotificationModel notificationModel,
      required Map<String, Object> message}) async {
    var id = const Uuid().v4();
    await FirebaseFirestore.instance
        .collection('notifications')
        .doc(id)
        .set(notificationModel.toMap());
    var response = await post(Uri.parse('https://fcm.googleapis.com/fcm/send'),
        body: json.encode(message),
        headers: {
          'Content-Type': 'application/json',
          'accept': 'application/json',
          'Authorization': 'key=${Helper.fireBaseServerKey}',
        });
    try {
      var data = jsonDecode(response.body);
      if (response.statusCode == 200) {
        if (data["success"] == 1) {
          debugPrint("Notification send");
        } else if (data["failure"] == 1) {
          debugPrint("Notification Failed");
          await FirebaseFirestore.instance
              .collection('notifications')
              .doc(id)
              .delete();
        }
      }
    } on FormatException catch (e) {
      debugPrint('FCM response parse error (non-JSON body): $e');
    }
  }

  Future<void> addNewColumnToFirebaseCollection() async {
    FirebaseService.tasksManagementRef.get().then((snap) {
      for (var e in snap.docs) {
        FirebaseService.tasksManagementRef
            .doc(e.id)
            .update({"artisan_image_doc_id": ""});
      }
    });
  }

  @override
  void onClose() {
    _announcementsWorker?.dispose();
    _announcementsWorker = null;
    audioPlayer.dispose();
    super.onClose();
  }
}
