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
  var announcementsEnabled = false.obs;

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

    // Prefer remote-configured ringtone, but always fall back to bundled asset
    // so release builds still ring even if Firebase Storage is blocked.
    final url = downloadFileOfMusic.value.trim();
    if (url.isNotEmpty) {
      audioPlayer.play(UrlSource(url)).catchError((_) {
        return audioPlayer.play(AssetSource('assets/sounds/sound.mp3'));
      });
      return;
    }
    audioPlayer.play(AssetSource('assets/sounds/sound.mp3'));
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
          source == 'future_booking' && futureBookingId.isNotEmpty;

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
      });

      if (isFutureBookingBridge) {
        if (accept == '1') {
          await FutureBookingService.futureBookingsRef
              .doc(futureBookingId)
              .update({
            'artisan_confirmed': 'yes',
            // Once the artisan accepts, the next step is client payment.
            'status': 'pending_payment',
            'updated_at': DateTime.now().toString(),
          });

          // Deduct wallet immediately once the booking is confirmed.
          final paidViaWallet =
              await FutureBookingService.deductWalletOnBookingConfirmation(
            bookingId: futureBookingId,
          );

          fireAndForget(
            FutureBookingService.sendNotificationToUser(
              userId: to,
              message:
                  'Your artisan has confirmed the booking for ${(tmData['scheduled_date'] ?? '').toString()}',
            ),
            label: 'user_confirmed',
          );

          if (!paidViaWallet) {
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
            prefs.getBool('announcements_enabled') ?? false;
      }
    } catch (_) {
      try {
        final prefs = await SharedPreferences.getInstance();
        announcementsEnabled.value =
            prefs.getBool('announcements_enabled') ?? false;
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
        'account_type': "PayFast",
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
        'account_type': "PayFast",
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
