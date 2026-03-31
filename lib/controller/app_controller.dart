import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_easyloading/flutter_easyloading.dart';
import 'package:geolocator/geolocator.dart';
import 'package:get/get.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:image_cropper/image_cropper.dart';
import 'package:image_picker/image_picker.dart';
import 'package:maintenanceapp/model/artisan_task_model.dart';
import 'package:maintenanceapp/model/category_model.dart';
import 'package:maintenanceapp/model/job_images_model.dart';
import 'package:maintenanceapp/model/job_model.dart';
import 'package:maintenanceapp/services/backend_fcm_service.dart';
import 'package:maintenanceapp/model/notification_model.dart';
import 'package:maintenanceapp/model/request_model.dart';
import 'package:maintenanceapp/model/task_management_model.dart';
import 'package:maintenanceapp/model/task_model.dart';
import 'package:maintenanceapp/model/user_model.dart';
import 'package:maintenanceapp/screens/home/waiting_screen.dart';
import 'package:maintenanceapp/services/firestore_services/firebase_services.dart';
import 'package:maintenanceapp/services/future_booking_service.dart';
import 'package:http/http.dart' as http;
import 'package:maintenanceapp/services/map_service.dart';
import 'package:maintenanceapp/services/payment_credentials.dart';
import 'package:maintenanceapp/services/storage_services.dart';
import 'package:maintenanceapp/services/corporate_partner_service.dart';
import 'package:maintenanceapp/services/loyalty_service.dart';
import 'package:maintenanceapp/services/booking_funnel_service.dart';
import 'package:maintenanceapp/services/retargeting_service.dart';
import 'package:maintenanceapp/services/deposit_service.dart';
import 'package:maintenanceapp/utils/helper.dart';
import 'package:maintenanceapp/utils/splash_timer.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'package:image/image.dart' as img;

class AppController extends GetxController {
  final categoriesRef = FirebaseFirestore.instance.collection('categories');
  final userRef = FirebaseFirestore.instance.collection('users');
  final serviceProviderRef =
      FirebaseFirestore.instance.collection('serviceProvider');
  final taskRef = FirebaseFirestore.instance.collection('tasks');
  final tasksManagementRef =
      FirebaseFirestore.instance.collection('tasksManagement');
  final transactionLogRef =
      FirebaseFirestore.instance.collection('transactionLogs');
  final providerAccountsRef =
      FirebaseFirestore.instance.collection('providerAccounts');
  final requestsRef = FirebaseFirestore.instance.collection('requests');
  final adminAccounts = FirebaseFirestore.instance.collection('adminAccounts');
  final artisanTaskImages =
      FirebaseFirestore.instance.collection('artisanTasksImages');
  final realTimeDatabaseRef = FirebaseDatabase.instance.ref();

  FirebaseService firebaseService = FirebaseService();

  var isLogin = false.obs;
  var userType = "".obs;
  var userEmail = "".obs;
  var userId = "".obs;
  var userPassword = "".obs;
  var userBalance = "".obs;
  UserModel? userData;
  var userName = "".obs;
  var userImage = "".obs;
  var currentIndex = 0.obs;
  var subCategoryList = <CategoryModel>[].obs;
  var taskList = <TaskModel>[].obs;
  var artisanTasksList = <ArtisanTaskModel>[].obs;
  var isLoading = false.obs;
  var filterApplied = true.obs;
  // Caching to avoid re-fetching the same category repeatedly (improves perceived load speed).
  final Map<String, List<TaskModel>> _tasksByCategoryCache = <String, List<TaskModel>>{};
  final Map<String, List<ArtisanTaskModel>> _artisanTasksByCategoryCache = <String, List<ArtisanTaskModel>>{};
  final Map<String, DateTime> _tasksCacheAt = <String, DateTime>{};
  final Duration _tasksCacheTtl = const Duration(seconds: 10);  // Reduced for testing

  final RxString currentTaskCategoryId = ''.obs;
  var isUploading = false.obs;
  File? imgUser;

  //Task Management -- Job Calculation

  var listOfJobs = <JobModel>[].obs;
  var selectedTaskNameList = <String>[].obs;
  var selectedTaskIdList = <String>[].obs;
  List<List<JobImagesModel>> jobImagesList = [];
  late TextEditingController descriptionController;
  var lastSelectedProviderName = "".obs;
  var lastSelectedProviderId = "".obs;

  var totalTaskCost = 0.0.obs;
  var taskCost = 0.0.obs;
  //camera calculation
  var selectedSubCategory = "".obs;
  var imageLength = "".obs;
  var imageWidth = "".obs;
  var wallLength = "".obs;
  var wallWidth = "".obs;
  var areaInSqMeter = "".obs;
  Rx<XFile?> imageFile = Rx<XFile?>(null);

  //camera calculation Additional
  var additionalCost = 0.0.obs;
  var imageLengthAdditional = "".obs;
  var imageWidthAdditional = "".obs;
  var wallLengthAdditional = "".obs;
  var wallWidthAdditional = "".obs;
  var areaInSqMeterAdditional = "".obs;
  Rx<XFile?> imageFileAdditional = Rx<XFile?>(null);

  var serviceOnCurrentLocation = true.obs;
  var pickedLat = "".obs;
  var pickedLng = "".obs;
  final TextEditingController addressController = TextEditingController();

  var isManual = false.obs;

  var cameraOpeningCategoriesList =
      ['painting', 'tiling', 'tilling', 'celling', 'ceiling'].obs;

  //payment Integration
  var webUrl = "".obs;
  // var isWithdraw = false.obs;
  var isPaymentUsingPayFast = false.obs;
  // isPaymentUsingPayFlex removed — replaced by isPaymentUsingBnpl (multi-provider)
  var isPaymentUsingBnpl = false.obs;
  /// Tracks the active payment method: 'wallet', 'payFast', or 'bnpl'.
  var activePaymentMethod = 'wallet'.obs;

  var newTaskIdForOrder = "".obs;
  var timeUp = false.obs;
  var remainingTime = 30.obs;
  var remainingTimeString = "30".obs;
  var isOrderApproveOrReject = false.obs;
  var shouldNavigate = false.obs;
  late BitmapDescriptor originMarker;

  Rx<XFile?> imageProvider = Rx<XFile?>(null);

  var userLat = ''.obs;
  var userLng = ''.obs;

  final MapService _mapService = MapService();

  Timer? _reminderTimer;

  @override
  void onInit() {
    // TODO: implement onInit
    super.onInit();

    descriptionController = TextEditingController();
    getCredentials().then((value) {
      Future.delayed(const Duration(seconds: 1), () {
        if (isLogin.value == true) {
          debugPrint("Already Login");
          if (userType.value == "user") {
            getUser(id: userId.value);
          }

          _startReminderPolling();

          // else{
          //   getServiceProvider(id: userId.value);
          // }
        } else {
          debugPrint("Not Login");
        }
      });
    });
    setMarkerLocation();
  }

  void _startReminderPolling() {
    if (_reminderTimer != null) return;
    if (userId.value.trim().isEmpty) return;

    Future<void> tick() async {
      try {
        if (userType.value == 'user') {
          await FutureBookingService.sendReminderNotificationsForUser(
            userId: userId.value,
          );
        } else {
          await FutureBookingService.sendReminderNotificationsForArtisan(
            artisanId: userId.value,
          );
        }
      } catch (_) {
        // Non-fatal: reminders should never break the app flow.
      }
    }

    // Run once immediately, then periodically.
    tick();
    _reminderTimer = Timer.periodic(const Duration(minutes: 15), (_) => tick());
  }

  @override
  void onClose() {
    _reminderTimer?.cancel();
    _reminderTimer = null;
    super.onClose();
  }

  Future<void> getCurrentPosition(context) async {
    // _marker.clear();
    final hasPermission = await _handleLocationPermission(context);
    if (!hasPermission) return;

    final location = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high);
    // if(mounted){
    userLat.value = location.latitude.toString();
    userLng.value = location.longitude.toString();
    debugPrint("user_lat ${userLat.value}");
    debugPrint("user_lng ${userLng.value}");

    // Sync position to Firestore so dispatch and admin can see the real location.
    if (userId.value.isNotEmpty) {
      try {
        await updateMyCurrentPositionToFirebase(
          lat: userLat.value,
          lng: userLng.value,
        );
        debugPrint("📍 Location synced to Firestore");
      } catch (e) {
        debugPrint("📍 Location sync failed: $e");
      }
    }
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

  Future<bool> sendDepositRequest({required String amount}) async {
    if (isUploading.value) return false;
    if (imageProvider.value == null) {
      Get.showSnackbar(const GetSnackBar(
        backgroundColor: Colors.red,
        duration: Duration(seconds: 4),
        snackPosition: SnackPosition.TOP,
        title: 'Missing attachment',
        message: 'Please add proof of payment first.',
      ));
      return false;
    }

    isUploading.value = true;
    try {
      final id = const Uuid().v4();
      
      debugPrint('[sendDepositRequest] Starting upload for request $id');
      debugPrint('[sendDepositRequest] File path: ${imageProvider.value!.path}');
      debugPrint('[sendDepositRequest] File size: ${await File(imageProvider.value!.path).length()} bytes');
      
      String link = '';
      try {
        link = await StorageServices.uploadImageToFirebase(
          path: 'users_payment_requests',
          imageFile: File(imageProvider.value!.path),
          id: id,
        ).timeout(
          const Duration(seconds: 60),
          onTimeout: () {
            throw Exception('Upload timed out after 60 seconds. Please check your internet connection and try again.');
          },
        );
      } catch (uploadError) {
        debugPrint('[sendDepositRequest] Storage upload error: $uploadError');
        debugPrint('[sendDepositRequest] Error type: ${uploadError.runtimeType}');
        // Provide more specific error messages
        final errStr = uploadError.toString();
        if (errStr.contains('permission') || errStr.contains('unauthorized')) {
          throw Exception('Storage permission denied. Please contact support.');
        } else if (errStr.contains('quota')) {
          throw Exception('Storage quota exceeded. Please contact support.');
        } else {
          // Pass through the actual error rather than masking it as "network error"
          rethrow;
        }
      }

      if (link.trim().isEmpty) {
        throw Exception('Upload returned empty URL. Please try again.');
      }

      debugPrint('[sendDepositRequest] Upload successful: $link');

      // Persist the canonical Storage object path too, so the Admin app can always resolve
      // the proof directly via FirebaseStorage (even if URL/token formats change).
      final attachmentPath = 'users_payment_requests/$id.jpg';
      final attachmentBucket = FirebaseStorage.instance.ref().child(attachmentPath).bucket.toString();

      final requestData = RequestModel(
        status: "pending",
        requestBy: userId.value,
        id: id,
        description: "",
        updatedAt: "",
        attachment: link,
        amount: amount,
        createdAt: DateTime.now().toString(),
      );

      await requestsRef
          .doc(id)
          .set({
            ...requestData.toMap(),
            'attachment_path': attachmentPath,
            'attachment_bucket': attachmentBucket,
          })
          .timeout(const Duration(seconds: 30));

      debugPrint('[sendDepositRequest] Request saved to Firestore');

      // Clear the image after successful upload
      imageProvider.value = null;

      Get.showSnackbar(const GetSnackBar(
        backgroundColor: Colors.green,
        duration: Duration(seconds: 4),
        snackPosition: SnackPosition.TOP,
        title: 'Success',
        message: 'Request sent to Admin',
      ));

      return true;
    } catch (e) {
      debugPrint('[sendDepositRequest] ERROR: $e');
      String errorMessage = 'Failed to submit proof of payment.';
      
      // Extract meaningful error message
      final errorStr = e.toString();
      if (e is FirebaseException) {
        final code = (e.code).toString();
        final msg = (e.message ?? '').toString();
        errorMessage = 'Upload failed ($code). ${msg.isNotEmpty ? msg : errorStr}';
      }
      if (errorStr.contains('Exception:')) {
        errorMessage = errorStr.replaceAll('Exception:', '').trim();
      } else if (errorStr.contains('Error:')) {
        errorMessage = errorStr.replaceAll('Error:', '').trim();
      } else {
        errorMessage = '$errorMessage Error: $errorStr';
      }
      
      Get.showSnackbar(GetSnackBar(
        backgroundColor: Colors.red,
        duration: const Duration(seconds: 6),
        snackPosition: SnackPosition.TOP,
        title: 'Upload Failed',
        message: errorMessage,
      ));

      return false;
    } finally {
      isUploading.value = false;
    }
  }

  Future<void> setMarkerLocation() async {
    originMarker = await BitmapDescriptor.fromAssetImage(
        const ImageConfiguration(), 'assets/images/provider.png');
  }

  Future<void> getCredentials() async {
    debugPrint("get Preferences");
    final SharedPreferences pref = await SharedPreferences.getInstance();
    var email = pref.get('email');
    var password = pref.get('password');
    var id = pref.get('id');
    var type = pref.get('type');
    bool? login = pref.getBool('isLogin');

    userEmail.value = email.toString();
    userPassword.value = password.toString();
    isLogin.value = login ?? false;
    userId.value = id.toString();
    userType.value = type.toString();

    debugPrint("email=$userEmail");
    // Password deliberately not logged
    debugPrint("isLogin=$isLogin");
    debugPrint("userType=$userType");
    debugPrint("userId=$userId");
  }

  ///using Firebase FireStore
  Future<void> updateMyCurrentPositionToFirebase(
      {required String lat, required String lng}) async {
    var value = await isServiceProvider(userId.value);

    if (value) {
      debugPrint("Updating provider data because of value is $value");
      final doc = await serviceProviderRef.doc(userId.value).get();
      if (!doc.exists) return;
      await serviceProviderRef.doc(userId.value).update({
        'lat': lat,
        'lng': lng,
      });
    } else {
      debugPrint("Updating user data because of value is $value");
      final doc = await userRef.doc(userId.value).get();
      if (!doc.exists) return;
      await userRef.doc(userId.value).update({
        'lat': lat,
        'lng': lng,
      });
    }
  }

  Future<LatLng?> getOtherUserLocation({required String id}) async {
    debugPrint("Getting other user location...........");
    LatLng? position;
    try {
      var value = await isServiceProvider(id);
      if (value) {
        DocumentSnapshot dc = await serviceProviderRef.doc(id).get();
        if (dc.exists) {
          position = LatLng(double.parse(dc["lat"]), double.parse(dc["lng"]));
          return position;
        }
        return position;
      } else {
        DocumentSnapshot dc = await userRef.doc(id).get();
        if (dc.exists) {
          position = LatLng(double.parse(dc["lat"]), double.parse(dc["lng"]));
          return position;
        }
        return position;
      }
    } catch (e) {
      debugPrint("getOtherUserLocation $e");
    }
    return null;
  }

  ///using Firebase RealTime Database
  Future<void> updateMyCurrentPositionToFirebaseRealTime(
      {required String lat, required String lng}) async {
    debugPrint("updating location.....!");
    DatabaseReference ref = FirebaseDatabase.instance.ref("locations");

    await ref.update({
      "$userId": {
        "name": "${userData!.name}",
        "location": {"lat": lat, "lng": lng}
      },
    }).catchError((error) {
      debugPrint('Error updating latitude and longitude: $error');
    });
  }

  Future<void> saveLastLocationOfCurrentUser(
      {required String lat, required String lng}) async {
    var value = await isServiceProvider(userId.value);
    if (value) {
      serviceProviderRef.doc(userId.value).update({
        "lat": lat,
        "lng": lng,
      }).catchError((error) {
        debugPrint("saveLastLocationOfCurrentUserForArtisan $error");
      });
    } else {
      userRef.doc(userId.value).update({
        "lat": lat,
        "lng": lng,
      }).catchError((error) {
        debugPrint("saveLastLocationOfCurrentUser $error");
      });
    }
  }

  Future<void> saveLoginCredentials(
      {required String type,
      required String id,
      required String email,
      required String password,
      required bool isLogin}) async {
    debugPrint("Saved Preferences");
    final SharedPreferences pref = await SharedPreferences.getInstance();
    pref.setString('email', email);
    // Password no longer stored locally for security
    pref.setBool('isLogin', isLogin);
    pref.setString('id', id);
    pref.setString('type', type);
  }

  Future<void> clearCredentials() async {
    debugPrint("Remove Preferences");
    final SharedPreferences pref = await SharedPreferences.getInstance();
    pref.setString('email', "");
    // password key cleared for migration; no longer stored
    pref.remove('password');
    pref.setBool('isLogin', false);
    pref.setString('id', "");
    pref.setString('type', "");
  }

  Future<List<String>> captureImage() async {
    isLoading.value = true;
    imageFile.value = await ImagePicker().pickImage(source: ImageSource.camera);
    if (imageFile.value != null) {
      imageFile.value = await cropImage(imagePath: imageFile.value!);
      final File file = File(imageFile.value!.path);
      isLoading.value = false;
      return await calculateBillByImage(file: file);
    } else {
      isLoading.value = false;
      return ["0", "0"];
    }
  }

  Future<XFile> cropImage({required XFile imagePath}) async {
    CroppedFile? croppedImage = await ImageCropper().cropImage(
      sourcePath: imagePath.path,
      // aspectRatioPresets: [
      //   CropAspectRatioPreset.square,
      //   CropAspectRatioPreset.ratio3x2,
      //   CropAspectRatioPreset.original,
      //   CropAspectRatioPreset.ratio4x3,
      //   CropAspectRatioPreset.ratio16x9
      // ],
      compressQuality: 100,
      compressFormat: ImageCompressFormat.png,
      uiSettings: [
        AndroidUiSettings(
            toolbarTitle: 'Crop Image',
            toolbarColor: Helper.secondaryColor,
            toolbarWidgetColor: Colors.white,
            initAspectRatio: CropAspectRatioPreset.original,
            lockAspectRatio: false,
            activeControlsWidgetColor: Helper.primaryColor),
      ],
    );

    if (croppedImage != null) {
      debugPrint("Image Cropped");
      return imagePath = XFile(croppedImage.path);
    } else {
      return imagePath;
    }
  }

  Future<List<String>> calculateBillByImage({required File file}) async {
    final img.Image? decodedImage = img.decodeImage(file.readAsBytesSync());
    if (decodedImage != null) {
      imageLength.value = decodedImage.height.toString();
      imageWidth.value = decodedImage.width.toString();

      // Do something with the dimensions (e.g., convert to feet)
      var length = (int.parse(imageLength.value) / 10.764).toStringAsFixed(2);
      var width = (int.parse(imageWidth.value) / 10.764).toStringAsFixed(2);
      // Print or use the dimensions as needed
      print('Image Height: ${imageLength.value} pixels');
      print('Image Width: ${imageWidth.value} pixels');
      print('Wall Length: $length feet');
      print('Wall Width: $width feet');

      List<String> randomNumbers = takeRandomLengthWidth(length, width);
      return [randomNumbers[0], randomNumbers[1]];
      // wallLength.value = randomNumbers[0];
      // wallWidth.value = randomNumbers[1];
      // print('Wall Length: ${wallLength.value} feet');
      // print('Wall Width: ${wallWidth.value} feet');
    } else {
      return ["0", "0"];
    }
  }

  List<String> takeRandomLengthWidth(String height, String width) {
    try {
      Random random = Random();
      double he = double.parse(height);
      double wi = double.parse(width);
      // Calculate 80% of the height and 60% of width
      double maxLength = 0.04 * he;
      double minLength = 0.006 * he;
      double maxWidth = 0.02 * wi;
      double minWidth = 0.004 * wi;

      // Generate random height between 2% and 10% of height
      String randomHeight =
          (random.nextDouble() * (maxLength - minLength) + minLength)
              .toStringAsFixed(2);
      // Generate random width between 1% and 7%% of height
      String randomWidth =
          (random.nextDouble() * (maxWidth - minWidth) + minWidth)
              .toStringAsFixed(2);

      return [randomHeight, randomWidth];
    } catch (e) {
      print("Error parsing input: $e");
      return ["0", "0"]; // Return a default value or handle the error as needed
    }
  }

  Future<void> getImageDetails() async {
    final File capturedFile = File(imageFile.value!.path);
    final img.Image? decodedImage =
        img.decodeImage(capturedFile.readAsBytesSync());
    if (decodedImage != null) {
      imageLength.value = decodedImage.height.toString();
      imageWidth.value = decodedImage.width.toString();

      // Do something with the dimensions (e.g., convert to feet)
      wallLength.value = (int.parse(imageLength.value) / 100).toString();
      wallWidth.value = (int.parse(imageWidth.value) / 100).toString();

      // Print or use the dimensions as needed
      print('Image Width: ${imageLength.value} pixels');
      print('Image Height: ${imageWidth.value} pixels');
      print('Wall Length: ${wallLength.value} feet');
      print('Wall Width: ${wallWidth.value} feet');
    }
  }

  void calculateJobBill(
      {required double wallLength,
      required double wallWidth,
      required double selectedTaskCost,
      File? imageFile,
      required String taskId,
      bool isInCameraOpening = true,
      required String taskName}) {
    var id = const Uuid().v4();
    JobModel jobModel = JobModel();
    if (isInCameraOpening) {
      List<double> result =
          calculateTotalCost(wallLength, wallWidth, selectedTaskCost);
      appController.taskCost.value = result[0];
      appController.totalTaskCost.value = result[0];
      appController.areaInSqMeter.value = result[1].toString();
      jobModel = JobModel(
        id: id,
        height: wallLength.toString(),
        width: wallWidth.toString(),
        cost: result[0].toStringAsFixed(2),
        area: result[1].toString(),
        image: imageFile?.path.toString(),
        taskId: taskId,
        description: "",
      );
    } else {
      jobModel = JobModel(
        id: id,
        height: wallLength.toString(),
        width: wallWidth.toString(),
        cost: selectedTaskCost.toStringAsFixed(2),
        area: "0",
        image: imageFile?.path.toString(),
        taskId: taskId,
        description: "",
      );
    }

    listOfJobs.add(jobModel);
    selectedTaskIdList.add(jobModel.taskId!);
    selectedTaskNameList.add(taskName);
    debugPrint("****************************************");
    debugPrint("length ${listOfJobs.length}");
    debugPrint("****************************************");
    calculateTotalBillForRequest();
  }

  calculateTotalBillForRequest() {
    appController.totalTaskCost.value = 0.0;
    for (var e in listOfJobs) {
      appController.totalTaskCost.value =
          appController.totalTaskCost.value + double.parse(e.cost!);
    }
    debugPrint("length of taskName list ${selectedTaskNameList.length}");
  }

  void attachJobImages(
      {required int index, required File file, required String jobId}) {
    var id = const Uuid().v4();
    debugPrint("index $index");
    JobImagesModel jobImagesModel = JobImagesModel(
      id: id,
      imagePath: file.path.toString(),
      jobId: jobId,
    );
    if (index == jobImagesList.length) {
      debugPrint("adding index");
      jobImagesList.add([]);
    }

    jobImagesList[index].add(jobImagesModel);
    debugPrint("image Attached ${jobImagesList.length}");
    debugPrint("image inner ${jobImagesList[index].length}");
  }

  List<double> calculateTotalCost(double wallLengthInMeter,
      double wallWidthInMeter, double ratePerSquareMeter) {
    double wallAreaInSquareMeters = wallLengthInMeter * wallWidthInMeter;
    // areaInSqMeter.value = wallAreaInSquareMeters.toStringAsFixed(2);
    double totalCost = wallAreaInSquareMeters * ratePerSquareMeter;
    return [totalCost, double.parse(wallAreaInSquareMeters.toStringAsFixed(2))];
  }

  double squareFeetToSquareMeters(double squareFeet) {
    return squareFeet / 10.764;
  }

  bool existInList(String input) {
    final inputWords = input.split(' ');

    for (final word in inputWords) {
      debugPrint("here ${word.toLowerCase()}");
      if (cameraOpeningCategoriesList.contains(word.toLowerCase())) {
        return true;
      }
    }
    return false;
  }

  Future<void> getSubCategoryRecord({required String id}) async {
    try {
      isLoading.value = true;
      subCategoryList.clear();
      firebaseService.subCategoryQuery(id: id).listen((data) {
        subCategoryList.assignAll(data);
        isLoading.value = false;
        debugPrint("sub category ${subCategoryList.length}");
      });
    } catch (e) {
      isLoading.value = false;
      debugPrint("getSubCategoryRecord $e");
    }
  }

  Future<void> getTaskRecord({required String id}) async {
    try {
      final categoryId = id.toString().trim();
      debugPrint('[getTaskRecord] RECEIVED id parameter: "$id"');
      debugPrint('[getTaskRecord] TRIMMED categoryId: "$categoryId"');
      
      currentTaskCategoryId.value = categoryId;
      
      if (categoryId.isEmpty) {
        debugPrint('[getTaskRecord] ERROR: categoryId is EMPTY!');
        return;
      }

      // Serve from cache when fresh.
      final cachedAt = _tasksCacheAt[categoryId];
      final cachedTasks = _tasksByCategoryCache[categoryId];
      final cachedArtisanTasks = _artisanTasksByCategoryCache[categoryId];
      final now = DateTime.now();
      final cacheIsFresh = cachedAt != null && now.difference(cachedAt) <= _tasksCacheTtl;
      
      print('[getTaskRecord] Cache check: cachedAt=$cachedAt, cacheIsFresh=$cacheIsFresh, cachedTasks=${cachedTasks?.length}, cachedArtisan=${cachedArtisanTasks?.length}');
      
      if (cacheIsFresh && cachedTasks != null && cachedArtisanTasks != null) {
        taskList.assignAll(cachedTasks);
        artisanTasksList.assignAll(cachedArtisanTasks);
        currentTaskCategoryId.value = categoryId;
        filterApplied.value = true;
        isLoading.value = false;
        print('[getTaskRecord] ⚠️ SERVING FROM CACHE: Tasks=${cachedTasks.length}, ArtisanTasks=${cachedArtisanTasks.length}');
        debugPrint('[getTaskRecord] Served from cache. Tasks: \\${cachedTasks.length}, ArtisanTasks: \\${cachedArtisanTasks.length}');
        return;
      }
      
      print('[getTaskRecord] Cache MISS or STALE - will fetch from Firestore');

      isLoading.value = true;
      filterApplied.value = false;
      taskList.clear();
      artisanTasksList.clear();

      bool isPublishedLike(dynamic value) {
        final s = (value ?? '').toString().trim().toLowerCase();
        if (s.isEmpty) return true;
        return s == 'publish' || s == 'published' || s == 'active' || s == '1';
      }

      // The passed ID might be:
      // 1. A Firestore document ID (UUID pattern like "64ef88b8-...")
      // 2. A legacy categories.id field value
      // Try both the passed value and any matching category doc.
      final candidateCategoryIds = <String>{categoryId};
      
      // If it looks like a Firestore doc ID (UUID pattern), try to get the category
      if (categoryId.contains('-') && categoryId.length > 30) {
        try {
          final catDoc = await FirebaseService.categoryRef.doc(categoryId).get();
          if (catDoc.exists) {
            final legacyId = (catDoc.data()?['id'] ?? '').toString().trim();
            if (legacyId.isNotEmpty && legacyId != categoryId) {
              candidateCategoryIds.add(legacyId);
            }
            debugPrint('[getTaskRecord] Firestore category doc exists, added legacy id: $legacyId');
          }
        } catch (e) {
          debugPrint('[getTaskRecord] Could not fetch category doc: $e');
        }
      }
      
      // Also try reverse lookup: find category where id field matches
      try {
        final catSnap = await FirebaseService.categoryRef
            .where('id', isEqualTo: categoryId)
            .limit(1)
            .get();
        if (catSnap.docs.isNotEmpty) {
          final docId = catSnap.docs.first.id;
          if (docId != categoryId) {
            candidateCategoryIds.add(docId);
            debugPrint('[getTaskRecord] Found category doc via id field, added doc ID: $docId');
          }
        }
      } catch (e) {
        debugPrint('[getTaskRecord] Reverse lookup failed: $e');
      }
      
      debugPrint('[getTaskRecord] Will query tasks using IDs: $candidateCategoryIds');

      // One-shot fetches are significantly faster and avoid multiple listeners.
      // Support multiple schemas: categoryId/category_id and subCategoryId variants.
      final taskDocsById = <String, QueryDocumentSnapshot<Map<String, dynamic>>>{};

      final fields = <String>[
        'categoryId',
        'category_id',
        'subCategoryId',
        'sub_category_id',
        'subcategoryId',
        'subcategory_id',
      ];

      // FETCH ALL TASKS - no where clause to avoid index/security issues
      print('[getTaskRecord] ===== FETCHING ALL TASKS (NO FILTERS) =====');
      debugPrint('[getTaskRecord] ===== FETCHING ALL TASKS (NO FILTERS) =====');
      try {
        final allTasksSnap = await FirebaseService.taskRef.get();
        print('[getTaskRecord] Fetched ${allTasksSnap.docs.length} total tasks from Firestore');
        debugPrint('[getTaskRecord] Fetched ${allTasksSnap.docs.length} total tasks from Firestore');
        
        // Filter locally
        for (final d in allTasksSnap.docs) {
          final data = d.data();
          
          // Check if this task matches any of our candidate category IDs
          bool matches = false;
          for (final cid in candidateCategoryIds) {
            for (final f in fields) {
              final fieldValue = (data[f] ?? '').toString().trim();
              if (fieldValue == cid) {
                matches = true;
                print('[getTaskRecord] MATCH: ${d.id} has $f=$fieldValue');
                debugPrint('[getTaskRecord] MATCH: ${d.id} has $f=$fieldValue');
                break;
              }
            }
            if (matches) break;
          }
          
          if (matches) {
            final status = data['status'];
            final name = data['name'];
            print('[getTaskRecord]   ✓ Task ${d.id}: status=$status, name=$name');
            debugPrint('[getTaskRecord]   ✓ Task ${d.id}: status=$status, name=$name');
            taskDocsById[d.id] = d;
          }
        }
      } catch (e) {
        print('[getTaskRecord] FATAL: Could not fetch tasks: $e');
        debugPrint('[getTaskRecord] FATAL: Could not fetch tasks: $e');
      }

      final taskSnapDocs = taskDocsById.values.toList();
      print('[getTaskRecord] Total unique tasks found: ${taskSnapDocs.length}');
      debugPrint('[getTaskRecord] Total unique tasks found: ${taskSnapDocs.length}');

      // Deduplicate tasks by normalised name to prevent showing e.g. two
      // "Plumbing" cards that come from different Firestore documents.
      final seenTaskNames = <String>{};
      final uniqueTaskDocs = <QueryDocumentSnapshot<Map<String, dynamic>>>[];
      for (final d in taskSnapDocs) {
        final name = (d.data()['name'] ?? d.data()['title'] ?? d.data()['task_name'] ?? '')
            .toString()
            .trim()
            .toLowerCase();
        if (name.isNotEmpty && seenTaskNames.contains(name)) {
          debugPrint('[getTaskRecord] SKIPPING duplicate task name "$name" docId=${d.id}');
          continue;
        }
        if (name.isNotEmpty) seenTaskNames.add(name);
        uniqueTaskDocs.add(d);
      }
      debugPrint('[getTaskRecord] After name-dedup: ${uniqueTaskDocs.length} unique tasks');

      final tasks = uniqueTaskDocs.map((d) {
        final data = <String, dynamic>{...d.data()};
        // Support both schemas:
        // - tasks documents may have a legacy `id` field
        // - other collections may reference the Firestore doc id
        data['doc_id'] = d.id;
        data['id'] = (data['id'] ?? '').toString().trim().isEmpty ? d.id : data['id'];
        return TaskModel.fromDocument(data);
      }).toList();

      taskList.assignAll(tasks);

      if (tasks.isEmpty) {
        debugPrint('[getTaskRecord] WARNING: No tasks loaded for categoryId=$categoryId');
      }

      // userTasks.task_id can refer to Task doc-id OR legacy TaskModel.id.
      final taskIds = <String>{
        for (final t in tasks) (t.id ?? '').toString().trim(),
        for (final t in tasks) (t.docId ?? '').toString().trim(),
      }.where((s) => s.isNotEmpty).toList();

      final List<ArtisanTaskModel> artisanTasks = <ArtisanTaskModel>[];
      final seenDocIds = <String>{};   // ← prevent same Firestore doc from dual query
      // Firestore whereIn limit is 10, so chunk.
      for (var i = 0; i < taskIds.length; i += 10) {
        final chunk = taskIds.sublist(i, (i + 10) > taskIds.length ? taskIds.length : (i + 10));
        final snaps = <QuerySnapshot<Map<String, dynamic>>>[];
        try {
          snaps.add(await FirebaseService.artisanTasks.where('task_id', whereIn: chunk).get());
        } catch (_) {}
        try {
          snaps.add(await FirebaseService.artisanTasks.where('taskId', whereIn: chunk).get());
        } catch (_) {}

        for (final snap in snaps) {
          for (final d in snap.docs) {
            if (seenDocIds.contains(d.id)) continue;   // ← skip duplicate doc
            seenDocIds.add(d.id);
            final data = <String, dynamic>{...d.data()};
            if (!isPublishedLike(data['status'])) continue;
            data['id'] = (data['id'] ?? '').toString().trim().isEmpty ? d.id : data['id'];
            artisanTasks.add(ArtisanTaskModel.fromDocument(data));
          }
        }
      }

      // Deduplicate artisan tasks so each TASK appears only ONCE in the grid.
      // Step 1: Keep only one artisan-task per taskId (first wins).
      final seenTids = <String>{};
      final dedupedByTid = <ArtisanTaskModel>[];
      for (final a in artisanTasks) {
        final tid = (a.taskId ?? '').toString().trim();
        if (tid.isEmpty || seenTids.contains(tid)) continue;
        seenTids.add(tid);
        dedupedByTid.add(a);
      }

      // Step 2: Further dedup by resolved task NAME (handles different task
      // docs with identical names, e.g. two "Install toilet and cistern").
      final seenNames = <String>{};
      final deduped = <ArtisanTaskModel>[];
      for (final a in dedupedByTid) {
        final tid = (a.taskId ?? '').toString().trim();
        // Resolve to a TaskModel to get the display name
        final t = tasks.cast<TaskModel?>().firstWhere(
          (t) =>
              (t?.id ?? '').toString().trim() == tid ||
              (t?.docId ?? '').toString().trim() == tid,
          orElse: () => null,
        );
        final name = (t?.name ?? '').toString().trim().toLowerCase();
        if (name.isNotEmpty && seenNames.contains(name)) {
          debugPrint('[getTaskRecord] SKIPPING artisan-task with duplicate name "$name" tid=$tid');
          continue;
        }
        if (name.isNotEmpty) seenNames.add(name);
        deduped.add(a);
      }

      artisanTasksList.assignAll(deduped);

      _tasksByCategoryCache[categoryId] = List<TaskModel>.from(tasks);
      _artisanTasksByCategoryCache[categoryId] = List<ArtisanTaskModel>.from(deduped);
      _tasksCacheAt[categoryId] = DateTime.now();

      filterApplied.value = true;
      isLoading.value = false;
    } catch (e) {
      isLoading.value = false;
      filterApplied.value = true;
      debugPrint("getTaskRecord $e");
    }
    // finally{
    //   isLoading.value = false;
    //   filterApplied.value = true;
    //   debugPrint("finally here");
    // }
  }

  //Payment
  Future<String> initiatePayment(
      {required String cost, String? id, String? key}) async {
    debugPrint("payment");
    webUrl.value = "";
    String web = '';

    // If credentials are provided explicitly, use direct PayFast call
    final mId = id ?? PaymentCredential.merchantId;
    final mKey = key ?? PaymentCredential.merchantKey;

    if (mId.isNotEmpty && mKey.isNotEmpty) {
      var body = {
        'merchant_id': mId,
        'merchant_key': mKey,
        'amount': cost,
        'item_name': "Payment (PayFast)",
      };

      final url = Uri.parse('https://www.payfast.co.za/eng/process');
      final response = await http.post(
        url,
        body: body,
        headers: {
          'Accept': 'application/json',
        },
      );

      if (response.statusCode == 302) {
        final redirectedUrl = response.headers['location'];
        if (redirectedUrl != null) {
          debugPrint("PayFast redirect received");
          return redirectedUrl;
        }
      }
    }

    // Fallback: use backend server to initiate payment (avoids empty credentials)
    try {
      final backendUrl = 'https://square15-livekit-backend.onrender.com';
      final token = await FirebaseAuth.instance.currentUser?.getIdToken();
      final response = await http.post(
        Uri.parse('$backendUrl/api/payment/initiate'),
        headers: {
          'Content-Type': 'application/json',
          if (token != null) 'Authorization': 'Bearer $token',
        },
        body: jsonEncode({
          'amount': cost,
          'item_name': 'Payment (PayFast)',
        }),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data['ok'] == true && data['payfast_url'] != null) {
          final payfastUrl = data['payfast_url'];
          final paymentData = data['payment_data'] as Map<String, dynamic>;
          // Post to PayFast with server-provided credentials
          final pfResponse = await http.post(
            Uri.parse(payfastUrl),
            body: paymentData.map((k, v) => MapEntry(k, v.toString())),
            headers: {'Accept': 'application/json'},
          );
          if (pfResponse.statusCode == 302) {
            final redirectedUrl = pfResponse.headers['location'];
            if (redirectedUrl != null) {
              debugPrint("PayFast redirect received (via backend)");
              return redirectedUrl;
            }
          }
        }
      }
      debugPrint("Backend payment initiation failed: ${response.statusCode}");
    } catch (e) {
      debugPrint("Backend payment error: $e");
    }

    return web;
  }

  Future<void> savePaymentStatus(
      {required String cost,
      required String taskManagementId,
      required String status}) async {
    // Idempotency: check if a successful payment already exists for this task
    try {
      final existingTx = await FirebaseService.transactionRef
          .where('tasks_management_id', isEqualTo: taskManagementId)
          .where('subtype', isEqualTo: 'service_payment')
          .where('status', isEqualTo: 'success')
          .limit(1)
          .get();
      if (existingTx.docs.isNotEmpty) {
        debugPrint('[savePaymentStatus] Payment already recorded for $taskManagementId — skipping duplicate');
        return;
      }
    } catch (e) {
      debugPrint('[savePaymentStatus] idempotency check failed: $e');
    }

    //deduct balance value
    var remainingBalance = "";
    if (!isPaymentUsingPayFast.value && !isPaymentUsingBnpl.value) {
      DocumentSnapshot dc =
          await FirebaseService.userRef.doc(userId.value).get();
      if (dc.exists) {
        debugPrint("Current ${dc["balance"]}");
        userBalance.value = dc["balance"];
        remainingBalance =
            (double.parse(userBalance.value) - double.parse(cost)).toString();
      } else {
        remainingBalance =
            (double.parse(userBalance.value) - double.parse(cost)).toString();
      }
    }

    final tmSnap =
        await FirebaseService.tasksManagementRef.doc(taskManagementId).get();
    final tmData = tmSnap.data() ?? <String, dynamic>{};
    final source = (tmData['source'] ?? '').toString().trim().toLowerCase();
    final futureBookingId =
        (tmData['future_booking_id'] ?? '').toString().trim();
    final isFutureBookingBridge =
        source == 'future_booking' && futureBookingId.isNotEmpty;

    final now = DateTime.now().toString();
    final String paymentMethod;
    if (isPaymentUsingBnpl.value) {
      paymentMethod = 'bnpl';
    } else if (isPaymentUsingPayFast.value) {
      paymentMethod = 'payFast';
    } else {
      paymentMethod = 'wallet';
    }
    final bool cashMovement =
        isPaymentUsingPayFast.value || isPaymentUsingBnpl.value;

    double toDouble(dynamic v) {
      if (v == null) return 0.0;
      if (v is num) return v.toDouble();
      return double.tryParse(v.toString()) ?? 0.0;
    }

    String money(double v) => v.toStringAsFixed(2);

    // Best-effort profit calculation from tasksManagement/jobs and task rates.
    // Never block payment success if this fails.
    double clientTotal = toDouble(cost);
    double outsourcedTotal = 0.0;
    double profit = 0.0;
    double profitMarginPercent = 0.0;
    int lineItemsCount = 0;

    try {
      final jobsSnap = await FirebaseService.tasksManagementRef
          .doc(taskManagementId)
          .collection('jobs')
          .get();

      final jobs = jobsSnap.docs
          .map((d) => (d.data() as Map<String, dynamic>? ?? <String, dynamic>{}))
          .toList();

      if (jobs.isNotEmpty) {
        lineItemsCount = jobs.length;
        clientTotal = 0.0;

        final taskIds = <String>{};
        for (final j in jobs) {
          final tid = (j['task_id'] ?? j['taskId'] ?? j['task'] ?? '').toString().trim();
          if (tid.isNotEmpty) taskIds.add(tid);
        }

        final ratesByTaskId = <String, Map<String, double>>{};

        final taskIdList = taskIds.toList();
        for (var i = 0; i < taskIdList.length; i += 10) {
          final chunk = taskIdList.sublist(i, (i + 10) > taskIdList.length ? taskIdList.length : (i + 10));
          if (chunk.isEmpty) continue;

          final snap = await FirebaseService.taskRef.where('id', whereIn: chunk).get();
          for (final doc in snap.docs) {
            final data = (doc.data() as Map<String, dynamic>? ?? <String, dynamic>{});
            final id = (data['id'] ?? doc.id).toString().trim();
            if (id.isEmpty) continue;

            final clientRate = toDouble(data['clientRate'] ?? data['client_rate'] ?? data['cost'] ?? data['price']);
            final outsourcedRate = toDouble(data['outsourcedRate'] ?? data['outsourced_rate'] ?? data['outsourced_cost']);
            ratesByTaskId[id] = {
              'clientRate': clientRate,
              'outsourcedRate': outsourcedRate,
            };
          }
        }

        for (final j in jobs) {
          final jobCost = toDouble(j['cost']);
          final area = toDouble(j['area']);
          clientTotal += jobCost;

          final tid = (j['task_id'] ?? j['taskId'] ?? j['task'] ?? '').toString().trim();
          final rates = ratesByTaskId[tid];
          if (rates == null) continue;

          final outsourcedRate = rates['outsourcedRate'] ?? 0.0;
          if (outsourcedRate <= 0) continue;

          // Heuristic: if we have a measured area, rates are per m^2.
          // Otherwise treat rate as flat for that job.
          outsourcedTotal += (area > 0) ? (outsourcedRate * area) : outsourcedRate;
        }
      }

      profit = clientTotal - outsourcedTotal;
      if (clientTotal > 0) {
        profitMarginPercent = (profit / clientTotal) * 100.0;
      }
    } catch (e) {
      debugPrint('[savePaymentStatus] profit calc failed: $e');
    }

    // Check if this task uses the deposit model
    final bool isDepositPayment = tmData['payment_type'] == 'deposit' &&
        tmData['balance_paid'] != true;
    // Balance payment: deposit task where balance was just marked paid
    final bool isBalancePayment = tmData['payment_type'] == 'deposit' &&
        tmData['balance_paid'] == true;

    final Map<String, dynamic> taskManagementData = {
      'payment_status': isDepositPayment ? 'deposit_paid' : 'paid',
      'payment_method': paymentMethod,
      // Keep legacy field name used across the app.
      'payment': paymentMethod,
      // Mark deposit as paid when processing deposit payment
      if (isDepositPayment) 'deposit_paid': true,
      if (isDepositPayment) 'deposit_paid_at': now,
      // For future bookings, payment means the order is now accepted (not in-progress).
      // Don't overwrite status during balance payments (artisan already completed work).
      if (!isBalancePayment) 'status': isFutureBookingBridge ? 'accepted' : 'progress',
      // Ensure chat / accepted UI works consistently.
      if (isFutureBookingBridge) 'accept': '1',
      'updated_at': now,
      'updated_by': userId.value,
    };
    var transactionId = const Uuid().v4();
    final Map<String, dynamic> transactionData = {
      'id': transactionId,
      'amount': cost,
      'transaction_at': now,
      'status': status,
      'task_id': taskManagementId,
      'tasks_management_id': taskManagementId,
      if (isFutureBookingBridge) 'booking_id': futureBookingId,
      'task_name': "",
      'transaction_by': userId.value,
      'type': paymentMethod,
      'subtype': 'service_payment',
      'direction': 'in',
      'cash_movement': cashMovement,
      'source': paymentMethod,
      'client_total': money(clientTotal),
      'outsourced_total': money(outsourcedTotal),
      'profit': money(profit),
      'profit_margin_percent': profitMarginPercent.toStringAsFixed(2),
      'line_items_count': lineItemsCount,
      'schema_version': 2,
    };
    final Map<String, dynamic> userData = {
      'balance': remainingBalance,
    };

    try {
      await FirebaseService.transactionRef
          .doc(transactionId)
          .set(transactionData);
      try {
        await FirebaseService.tasksManagementRef
            .doc(taskManagementId)
            .update(taskManagementData);
        debugPrint('[savePaymentStatus] tasksManagement $taskManagementId updated with payment_status=paid');
      } catch (updateErr) {
        // Fallback: .update() fails when the doc doesn't exist. Use .set(merge) instead.
        debugPrint('[savePaymentStatus] .update() failed ($updateErr), falling back to .set(merge)');
        await FirebaseService.tasksManagementRef
            .doc(taskManagementId)
            .set(taskManagementData, SetOptions(merge: true));
        debugPrint('[savePaymentStatus] tasksManagement $taskManagementId set(merge) succeeded');
      }

      // --- Corporate Partner Commission ---
      try {
        await CorporatePartnerService.recordCommissionForPayment(
          userId: userId.value,
          taskManagementId: taskManagementId,
          jobAmount: clientTotal,
          bookingId: isFutureBookingBridge ? futureBookingId : null,
        );
      } catch (commErr) {
        debugPrint('[savePaymentStatus] Commission recording skipped: $commErr');
      }

      // --- Loyalty Points: award points for this payment ---
      try {
        await LoyaltyService.awardJobPoints(
          userId: userId.value,
          taskManagementId: taskManagementId,
          jobAmount: clientTotal,
        );
      } catch (loyaltyErr) {
        debugPrint('[savePaymentStatus] Loyalty points skipped: $loyaltyErr');
      }

      // --- Booking Funnel: mark session completed ---
      try {
        await BookingFunnelService.markSessionCompleted(userId: userId.value);
      } catch (funnelErr) {
        debugPrint('[savePaymentStatus] Funnel tracking skipped: $funnelErr');
      }

      // --- Retargeting: cancel any pending retargeting for this user ---
      try {
        await RetargetingService.cancelForUser(userId.value);
      } catch (retargetErr) {
        debugPrint('[savePaymentStatus] Retargeting cancel skipped: $retargetErr');
      }

      if (isFutureBookingBridge) {
        try {
          await FutureBookingService.futureBookingsRef.doc(futureBookingId).update({
            'payment_status': 'paid',
            'payment_amount': cost,
            'payment_method': paymentMethod,
            'payment_paid_at': now,
            // Once paid, the order is accepted and should sync across apps.
            'status': 'accepted',
            'updated_at': now,
          });

          // If this is an RFQ booking, set the correct rfq_status.
          try {
            final fbSnap = await FutureBookingService.futureBookingsRef
                .doc(futureBookingId)
                .get();
            final fb = fbSnap.data() ?? <String, dynamic>{};
            final isRfq = (fb['is_rfq'] ?? '').toString().toLowerCase() == 'yes' ||
                (fb['order_type'] ?? '').toString().toLowerCase() == 'rfq' ||
                (fb['rfq_status'] ?? '').toString().toLowerCase().startsWith('rfq_') ||
                (fb['rfq_status'] ?? '').toString().toLowerCase() == 'accepted_converted';
            if (isRfq) {
              // If artisan already accepted, mark as active order; otherwise waiting assignment.
              final artisanConfirmed =
                  (fb['artisan_confirmed'] ?? '').toString().toLowerCase();
              final oldRfqStatus =
                  (fb['rfq_status'] ?? '').toString().toLowerCase();
              final artisanAccepted = artisanConfirmed == 'yes' ||
                  oldRfqStatus == 'accepted_converted';

              await FutureBookingService.futureBookingsRef
                  .doc(futureBookingId)
                  .set({
                'rfq_status': artisanAccepted
                    ? 'rfq_order_active'
                    : 'rfq_approved_waiting_assignment',
                'rfq_paid_at': now,
              }, SetOptions(merge: true));
            }
          } catch (_) {
            // Best-effort.
          }

          // Notify the artisan that payment was received so they can start work.
          try {
            final fb = (await FutureBookingService.futureBookingsRef
                    .doc(futureBookingId)
                    .get())
                .data() ?? <String, dynamic>{};
            final artisanId =
                (fb['service_provider_id'] ?? '').toString().trim();
            if (artisanId.isNotEmpty) {
              await FutureBookingService.sendNotificationToArtisan(
                artisanId: artisanId,
                bookingId: futureBookingId,
                message:
                    'The client has completed payment for your accepted job. '
                    'You can now proceed with the booking.',
              );
            }
          } catch (_) {
            // Best-effort.
          }
        } catch (_) {
          // Best-effort; do not block the UI if this update fails.
        }
      } else {
        // Regular (non-future-booking) payment — notify the artisan.
        try {
          final artisanId =
              (tmData['service_provider_id'] ?? '').toString().trim();
          if (artisanId.isNotEmpty) {
            await FutureBookingService.sendNotificationToArtisan(
              artisanId: artisanId,
              bookingId: taskManagementId,
              message:
                  'The client has completed payment. '
                  'You can now proceed with the job.',
            );
          }
        } catch (_) {
          // Best-effort.
        }
      }

      if (!isPaymentUsingPayFast.value && !isPaymentUsingBnpl.value) {
        await FirebaseService.userRef.doc(userId.value).update(userData);
        getUser(id: userId.value);
      }

      Get.showSnackbar(const GetSnackBar(
          backgroundColor: Colors.green,
          duration: Duration(seconds: 1),
          snackPosition: SnackPosition.TOP,
          title: 'Success',
          message: 'Transaction Successful'));
    } catch (e) {
      debugPrint("savePaymentStatus $e");
      if (status == 'success') {
        final Map<String, dynamic> transactionData = {
          'id': transactionId,
          'amount': cost,
          'transaction_at': now,
          'status': 'failed',
          'task_id': taskManagementId,
          'tasks_management_id': taskManagementId,
          if (isFutureBookingBridge) 'booking_id': futureBookingId,
          'task_name': "",
          'transaction_by': userId.value,
          'type': paymentMethod,
          'subtype': 'service_payment',
          'direction': 'in',
          'cash_movement': true,
          'source': paymentMethod,
          'client_total': money(clientTotal),
          'outsourced_total': money(outsourcedTotal),
          'profit': money(profit),
          'profit_margin_percent': profitMarginPercent.toStringAsFixed(2),
          'line_items_count': lineItemsCount,
          'schema_version': 2,
        };
        await FirebaseService.transactionRef
            .doc(transactionId)
            .set(transactionData);
        Get.showSnackbar(const GetSnackBar(
            backgroundColor: Colors.red,
            duration: Duration(seconds: 2),
            snackPosition: SnackPosition.TOP,
            title: 'Failed',
            message: 'Transaction Record Not Saved'));
      }
    }
  }

  // Future<void> sendRequestToServiceProvider({required String provideId, required List<TextEditingController> descriptionList}) async {
  //   try {
  //     EasyLoading.show(status: 'Fetching Artisan details....!');
  //     debugPrint("Provider ID $provideId");
  //     var id = const Uuid().v4();
  //     newTaskIdForOrder.value = id;
  //     TaskManagementModel taskRecord = TaskManagementModel(
  //       id: id,
  //       status: "",
  //       accept: "",
  //       closedDate: "",
  //       completionDate: "",
  //       payment: "",
  //       paymentStatus: "",
  //       rating: "",
  //       userComment: "",
  //       cost: totalTaskCost.value.toStringAsFixed(2),
  //       userId: userId.value,
  //       creationDate: DateTime.now().toString(),
  //       serviceProviderId: provideId,
  //       taskId: "",
  //       fee: "",
  //       updatedAt: DateTime.now().toString(),
  //       updatedBy: userId.value,
  //       areaSqMeter: areaInSqMeter.value,
  //       attachment: "",
  //       additionalAttachment: "",
  //       description: "",
  //       additionalDescription: "",
  //       artisanImages: "0",
  //       artisanImageDocId: "",
  //       isServiceOnCurrentLocation: serviceOnCurrentLocation.value ? '1' : '0',
  //       userProvidedAddress: addressController.text,
  //       otherLat: pickedLat.value,
  //       otherLng: pickedLng.value,
  //     );
  //     debugPrint("task ${taskRecord.toString()}");
  //     await FirebaseService.tasksManagementRef.doc(id).set(taskRecord.toMap());
  //     EasyLoading.dismiss();
  //     EasyLoading.show(status: 'Saving your task information....!');
  //     for(int i = 0; i< listOfJobs.length; i++){
  //       var e = listOfJobs[i];
  //       if(e.image != null){
  //         var url = await StorageServices.uploadImageToFirebase(path: 'task_attachments', imageFile: File(e.image!), id: e.id!);
  //         e.image = url;
  //       }
  //       e.description = descriptionList[i].text.trim();
  //       await FirebaseService.tasksManagementRef.doc(id).collection('jobs').doc(e.id).set(e.toMap());
  //     }
  //     EasyLoading.dismiss();
  //     EasyLoading.show(status: 'Sending your request....!');
  //     for(var element in jobImagesList){
  //       for(var e in element){
  //         var url = await StorageServices.uploadImageToFirebase(path: 'job_images', imageFile: File(e.imagePath!), id: e.id!);
  //         e.imagePath = url;
  //         await FirebaseService.tasksManagementRef.doc(id).collection('images').doc(e.id).set(e.toMap());
  //       }
  //     }
  //     EasyLoading.dismiss();
  //     listOfJobs.clear();
  //     jobImagesList.clear();
  //   } catch (e) {
  //     Get.showSnackbar(const GetSnackBar(
  //       backgroundColor: Colors.red,
  //       duration: Duration(seconds: 2),
  //       snackPosition: SnackPosition.TOP,
  //       title: 'Failed',
  //       message: 'Request sending failed',
  //     ));
  //     debugPrint("sendRequestToServiceProvider $e");
  //   }
  // }

  Future<void> sendRequestToServiceProvider({
    required String provideId,
    required List<TextEditingController> descriptionList,
    bool useDeposit = false,
  }) async {
    try {
      EasyLoading.show(status: 'Fetching Artisan details....!');
      debugPrint("Provider ID $provideId");

      final fireStore = FirebaseFirestore.instance;
      final counterRef = fireStore.collection('metadata').doc('counters');
      var address = "";
      await fireStore.runTransaction((tx) async {
        // 🔹 Step 1: Read current counter value from the nested map
        final snapshot = await tx.get(counterRef);

        int currentOrderNo = 0;

        if (snapshot.exists) {
          final data = snapshot.data();
          final taskCounter =
              data?['taskManagementCounter'] as Map<String, dynamic>?;

          if (taskCounter != null && taskCounter.containsKey('nextOrderNo')) {
            currentOrderNo = taskCounter['nextOrderNo'] as int;
          }
        }

        final nextOrderNo = currentOrderNo + 1;

        // 🔹 Step 2: Update only the nested field
        tx.update(
            counterRef, {'taskManagementCounter.nextOrderNo': nextOrderNo});

        // 🔹 STEP 3: Prepare new task data
        final id = const Uuid().v4();
        newTaskIdForOrder.value = id;

        if (serviceOnCurrentLocation.value) {
          final lat = double.tryParse(userLat.toString()) ?? 0.0;
          final lng = double.tryParse(userLng.toString()) ?? 0.0;
          address = await _mapService.getAddressFromGoogleAPI(lat, lng);
          debugPrint("address $address");

          // Never block order creation due to geocoding/API-key issues.
          if (address.trim().isEmpty) {
            address = lat != 0.0 && lng != 0.0
                ? 'Current location ($lat, $lng)'
                : 'Current location';
          }
        } else {
          address = addressController.text.toString();
        }
        TaskManagementModel taskRecord = TaskManagementModel(
          id: id,
          orderNo: currentOrderNo.toString(), // ✅ added
          status: "",
          accept: "",
          closedDate: "",
          completionDate: "",
          payment: "",
          paymentStatus: "",
          rating: "",
          userComment: "",
          cost: totalTaskCost.value.toStringAsFixed(2),
          userId: userId.value,
          creationDate: DateTime.now().toString(),
          serviceProviderId: provideId,
          taskId: "",
          fee: "",
          updatedAt: DateTime.now().toString(),
          updatedBy: userId.value,
          areaSqMeter: areaInSqMeter.value,
          attachment: "",
          additionalAttachment: "",
          description: "",
          additionalDescription: "",
          artisanImages: "0",
          artisanImageDocId: "",
          isServiceOnCurrentLocation:
              serviceOnCurrentLocation.value ? '1' : '0',
          userProvidedAddress: address,
          otherLat: serviceOnCurrentLocation.value
              ? userLat.toString()
              : pickedLat.value,
          otherLng: serviceOnCurrentLocation.value
              ? userLng.toString()
              : pickedLng.value,
        );

        debugPrint("taskRecord ${taskRecord.toMap().toString()}");
        debugPrint("taskRecord $id");
        // 🔹 STEP 4: Save task record
        tx.set(FirebaseService.tasksManagementRef.doc(id), taskRecord.toMap());

        // You can safely upload jobs & images **after** transaction
      });
      if (address == "") return;
      EasyLoading.dismiss();
      EasyLoading.show(status: 'Saving your task information....!');

      // Save deposit fields if deposit mode selected
      if (useDeposit) {
        try {
          await DepositService.saveDepositFields(
            taskManagementId: newTaskIdForOrder.value,
            totalCost: totalTaskCost.value,
          );
        } catch (e) {
          debugPrint('Deposit fields save error: $e');
        }
      }

      // 🔹 STEP 5: Save related jobs
      for (int i = 0; i < listOfJobs.length; i++) {
        var e = listOfJobs[i];
        if (e.image != null) {
          var url = await StorageServices.uploadImageToFirebase(
            path: 'task_attachments',
            imageFile: File(e.image!),
            id: e.id!,
          );
          e.image = url;
        }
        e.description = descriptionList[i].text.trim();
        await FirebaseService.tasksManagementRef
            .doc(newTaskIdForOrder.value)
            .collection('jobs')
            .doc(e.id)
            .set(e.toMap());
      }

      EasyLoading.dismiss();
      EasyLoading.show(status: 'Sending your request....!');

      // 🔹 STEP 6: Save job images
      for (var element in jobImagesList) {
        for (var e in element) {
          var url = await StorageServices.uploadImageToFirebase(
            path: 'job_images',
            imageFile: File(e.imagePath!),
            id: e.id!,
          );
          e.imagePath = url;
          await FirebaseService.tasksManagementRef
              .doc(newTaskIdForOrder.value)
              .collection('images')
              .doc(e.id!)
              .set(e.toMap());
        }
      }

      EasyLoading.dismiss();
      listOfJobs.clear();
      jobImagesList.clear();

      EasyLoading.showSuccess('Order created successfully!');
      Get.to(() =>
          WaitingScreen(provideId: provideId, cost: "R${totalTaskCost.value}"));
    } catch (e, st) {
      debugPrint("sendRequestToServiceProvider $e\n$st");
      EasyLoading.dismiss();
      Get.showSnackbar(const GetSnackBar(
        backgroundColor: Colors.red,
        duration: Duration(seconds: 2),
        snackPosition: SnackPosition.TOP,
        title: 'Failed',
        message: 'Request sending failed',
      ));
    }
  }

  Future<void> sendNotification({
    required String to,
    required String from,
    String? accept,
  }) async {
    Map<String, Object> message = {};
    String toDeviceToken = "";

    debugPrint("to $to");
    final providerDoc = await _getServiceProviderDocByAnyId(to);
    final isArtisan = providerDoc != null;
    debugPrint("isArtisan $isArtisan");

    if (isArtisan) {
      // 🔹 Sending notification to service provider (artisan)
      final dc = providerDoc;
      if (!dc.exists) return;

      final data = dc.data();
      toDeviceToken = (data?['deviceToken'] ?? '').toString();
      if (toDeviceToken.trim().isEmpty) return;
      var body = "${userName.value} has requested a job";
      var title = "New Order Request";
      var type = "Order Request";

      message = {
        'notification': {'title': title, 'body': body},
        'data': {'image': '', 'type': type},
        'to': toDeviceToken,
      };

      NotificationModel notificationModel = NotificationModel(
        body: body,
        imageUrl: "",
        time: DateTime.now().toString(),
        title: title,
        type: type,
        view: false,
      );

      debugPrint("🎯 Sending to Artisan → $toDeviceToken");
      await pushCustomNotification(
        notificationModel: notificationModel,
        message: message,
        token: toDeviceToken,
      );
    } else {
      // 🔹 Sending notification to regular user
      DocumentSnapshot dc = await FirebaseService.userRef.doc(to).get();
      if (!dc.exists) return;

      toDeviceToken = (dc.data() as Map<String, dynamic>?)?['deviceToken']?.toString() ?? '';
      if (toDeviceToken.trim().isEmpty) return;
      var body = (accept == "1")
          ? "${userName.value} has accepted your order, please clear your payment to start."
          : "${userName.value} has rejected your order";

      var title = "Order ${accept == "1" ? "Accepted" : "Rejected"}";
      var type = title;

      message = {
        'notification': {'title': title, 'body': body},
        'data': {'image': '', 'type': type},
        'to': toDeviceToken,
      };

      NotificationModel notificationModel = NotificationModel(
        body: body,
        imageUrl: "",
        time: DateTime.now().toString(),
        title: title,
        type: type,
        view: false,
      );

      debugPrint("🎯 Sending to User → $toDeviceToken");
      await pushCustomNotification(
        notificationModel: notificationModel,
        message: message,
        token: toDeviceToken,
      );
    }
  }

  Future<void> pushCustomNotification({
    required NotificationModel notificationModel,
    required Map<String, Object> message,
    required String token,
  }) async {
    var id = const Uuid().v4();

    try {
      // ✅ 1. Save in Firestore
      await FirebaseFirestore.instance
          .collection('notifications')
          .doc(id)
          .set(notificationModel.toMap());

      // ✅ 2. Extract message values safely
      final notif = message['notification'] as Map<String, dynamic>;
      final data = message['data'] as Map<String, dynamic>;

      final title = notif['title'] ?? notificationModel.title ?? '';
      final body = notif['body'] ?? notificationModel.body ?? '';
      final type = data['type'] ?? notificationModel.type ?? 'general';
      final imageUrl = data['image'];

      // ✅ 3. Send via new FCM v1 API
      await sendFCMv1Notification(
        title: title,
        body: body,
        type: type,
        token: token,
        imageUrl: imageUrl is String && imageUrl.isNotEmpty ? imageUrl : null,
      );

      debugPrint("✅ Notification successfully sent to $token");
    } catch (e) {
      debugPrint("❌ pushCustomNotification error: $e");

      // Keep the notification in Firestore even if FCM send fails.
      // The user can still see it in the in-app notification screen.
    }
  }

  /// 🔹 Helper: Send FCM v1 notification via secure backend endpoint
  Future<void> sendFCMv1Notification({
    required String title,
    required String body,
    required String type,
    required String token,
    String? imageUrl,
  }) async {
    try {
      await BackendFcmService.sendNotification(
        token: token,
        title: title,
        body: body,
        data: {
          'type': type,
          if (imageUrl != null) 'image': imageUrl,
        },
      );
    } catch (e) {
      if (kDebugMode) debugPrint("❌ sendFCMv1Notification error: $e");
    }
  }

  Future<String> getTaskName({required String taskId}) async {
    var response = "";
    DocumentSnapshot taskDc = await FirebaseService.taskRef.doc(taskId).get();
    if (taskDc.exists) {
      response = taskDc["name"];
      return response;
    }
    return response;
  }

  Future<bool> isServiceProvider(String to) async {
    try {
      final providerDoc = await _getServiceProviderDocByAnyId(to);
      return providerDoc != null;
    } catch (e) {
      debugPrint('isServiceProvider: $e');
      return false;
    }
  }

  Future<DocumentSnapshot<Map<String, dynamic>>?> _getServiceProviderDocByAnyId(
      String anyId) async {
    final id = anyId.trim();
    if (id.isEmpty) return null;

    try {
      final direct = await FirebaseService.providerRef.doc(id).get();
      if (direct.exists) return direct;
    } catch (_) {}

    const fields = <String>[
      'user_id',
      'uid',
      'userId',
      'docId',
      'provider_id',
      'service_provider_id',
      'email',
    ];

    for (final field in fields) {
      try {
        final snap = await FirebaseService.providerRef
            .where(field, isEqualTo: id)
            .limit(1)
            .get();
        if (snap.docs.isNotEmpty) return snap.docs.first;
      } catch (_) {}
    }

    return null;
  }

  Future<void> markOrderAsCompleted(
      {required String taskManagementId,
      required String rating,
      required String feedback}) async {
    try {
      FirebaseService.tasksManagementRef.doc(taskManagementId).update({
        'status': 'completed',
        'user_comment': feedback,
        'rating': rating,
        'completion_date': DateTime.now().toString(),
        'updated_by': userId.value,
        'updated_at': DateTime.now().toString(),
      });

      // Award loyalty points for posting a review
      try {
        if (feedback.trim().isNotEmpty || rating.isNotEmpty) {
          await LoyaltyService.awardReviewPoints(
            userId: userId.value,
            taskManagementId: taskManagementId,
            rating: int.tryParse(rating),
          );
        }
      } catch (_) {}
    } catch (e) {
      debugPrint("markOrderAsCompleted $e");
    }
  }

  Future<void> getUser({required String id}) async {
    try {
      debugPrint("getting user info....!");
      DocumentSnapshot snp =
          await FirebaseFirestore.instance.collection("users").doc(id).get();
      userData = UserModel.fromJson(snp);
      userName.value = userData?.name ?? "";
      userImage.value = userData?.image ?? "";
      userBalance.value = userData?.balance ?? "";
      debugPrint("Name ${userName.value}");
      debugPrint("balance ${userBalance.value}");
    } catch (e) {
      debugPrint("user not get $e");
    }
  }

  Future<void> updateProfileImage(BuildContext context,
      {required String userId}) {
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
                    onTap: () async {
                      Navigator.pop(context);
                      XFile? pickedFile = await ImagePicker()
                          .pickImage(source: ImageSource.gallery);
                      if (pickedFile != null) {
                        isUploading.value = true;
                        imgUser = File(pickedFile.path);
                        String url =
                            await StorageServices.uploadImageToFirebase(
                                path: 'users', id: userId, imageFile: imgUser!);
                        FirebaseService.userRef
                            .doc(userId)
                            .update({"image": url}).whenComplete(() {
                          debugPrint("Image updates");
                          getUser(id: userData!.uid!).then((value) {
                            isUploading.value = false;
                          });
                        });
                      }
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
                    onTap: () async {
                      Navigator.pop(context);
                      XFile? pickedFile = await ImagePicker()
                          .pickImage(source: ImageSource.camera);
                      if (pickedFile != null) {
                        isUploading.value = true;
                        imgUser = File(pickedFile.path);
                        String url =
                            await StorageServices.uploadImageToFirebase(
                                path: "users", id: userId, imageFile: imgUser!);
                        FirebaseService.userRef
                            .doc(userId)
                            .update({"image": url}).whenComplete(() {
                          debugPrint("Image updates");
                          getUser(id: userData!.uid!).then((value) {
                            isUploading.value = false;
                          });
                        });
                      }
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

  Future<void> updateUserProfile(
      {required String userId, required String name}) async {
    try {
      FirebaseService.userRef.doc(userId).update({"name": name}).then((value) {
        Get.showSnackbar(const GetSnackBar(
          backgroundColor: Colors.green,
          duration: Duration(seconds: 2),
          snackPosition: SnackPosition.TOP,
          title: 'Success',
          message: 'Profile Updated',
        ));
      });
    } catch (e) {
      debugPrint("updateUserProfile $e");
    }
  }

  Future<void> getServiceProvider({required String id}) async {
    try {
      debugPrint("getting Artisan info....!");
      DocumentSnapshot snp = await serviceProviderRef.doc(id).get();
      userData = UserModel.fromJson(snp);
      userName.value = userData == null ? "" : userData!.name!;
      userImage.value = userData == null ? "" : userData!.image!;
      userBalance.value = userData == null ? "" : userData!.balance!;
      debugPrint("Name ${userName.value}");
      debugPrint("image ${userImage.value}");
      debugPrint("balance ${userBalance.value}");
    } catch (e) {
      debugPrint("user not get $e");
    }
  }

  Future<void> saveProviderTransactionStatus(
      {required String taskName,
      required String cost,
      required String status}) async {
    //deduct balance value
    var remainingBalance = "";
    DocumentSnapshot dc =
        await FirebaseService.providerRef.doc(userId.value).get();
    if (dc.exists) {
      debugPrint("Current ${dc["balance"]}");
      userBalance.value = dc["balance"];
      remainingBalance =
          (double.parse(userBalance.value) - double.parse(cost)).toString();
    } else {
      remainingBalance =
          (double.parse(userBalance.value) - double.parse(cost)).toString();
    }

    var transactionId = const Uuid().v4();
    final Map<String, dynamic> transactionData = {
      'id': transactionId,
      'amount': cost,
      'transaction_at': DateTime.now().toString(),
      'status': status,
      'task_id': '',
      'task_name': taskName,
      'transaction_by': userId.value,
      'type': 'payFast'
    };
    final Map<String, dynamic> providerData = {
      'balance': remainingBalance,
    };

    try {
      FirebaseService.transactionRef
          .doc(transactionId)
          .set(transactionData)
          .then((value) {
        FirebaseService.providerRef
            .doc(userId.value)
            .update(providerData)
            .then((value) {
          getServiceProvider(id: userId.value);
          Get.showSnackbar(const GetSnackBar(
              backgroundColor: Colors.green,
              duration: Duration(seconds: 1),
              snackPosition: SnackPosition.TOP,
              title: 'Success',
              message: 'Withdraw Successful'));
        });
      });
    } catch (e) {
      debugPrint("savePaymentStatus $e");
      if (status == 'success') {
        final Map<String, dynamic> transactionData = {
          'id': transactionId,
          'amount': cost,
          'transaction_at': DateTime.now().toString(),
          'status': 'failed',
          'task_id': '',
          'task_name': taskName,
          'transaction_by': userId.value,
          'type': 'payFast'
        };
        FirebaseService.transactionRef
            .doc(transactionId)
            .set(transactionData)
            .then((_) {
          Get.showSnackbar(const GetSnackBar(
              backgroundColor: Colors.red,
              duration: Duration(seconds: 2),
              snackPosition: SnackPosition.TOP,
              title: 'Failed',
              message: 'Transaction Record Not Saved'));
        });
      }
    }
  }

  Future<void> timeUpOrderClose({required String id}) async {
    FirebaseService.tasksManagementRef.doc(id).update({"status": "closed"});
  }

  Future<void> deleteTask({required String id}) async {
    QuerySnapshot<Map<String, dynamic>> jobs = await appController
        .tasksManagementRef
        .doc(id)
        .collection('jobs')
        .where('image', isNotEqualTo: "")
        .get();
    if (jobs.docs.isNotEmpty) {
      for (var element in jobs.docs) {
        await StorageServices.deleteImage(
            id: element.id.toString(), path: 'task_attachments');
      }
    }
    QuerySnapshot<Map<String, dynamic>> imagesForTask = await appController
        .tasksManagementRef
        .doc(id)
        .collection('images')
        .get();
    if (imagesForTask.docs.isNotEmpty) {
      for (var element in imagesForTask.docs) {
        await StorageServices.deleteImage(
            id: element.id.toString(), path: 'job_images');
      }
    }

    await appController.tasksManagementRef.doc(id).delete();
  }

  //Extra
  Future<void> addNewColumnToFirebaseCollection(String time) async {
    FirebaseService.tasksManagementRef.get().then((snap) {
      for (var e in snap.docs) {
        FirebaseService.tasksManagementRef
            .doc(e.id)
            .update({"time_left": time});
      }
    });
  }
}
