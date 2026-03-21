import 'dart:async';
import 'dart:io';
import 'package:admain_maintence_app/model/push_notification_model.dart';
import 'package:admain_maintence_app/model/request_model.dart';
import 'package:admain_maintence_app/screen/category/model/category_model.dart';
import 'package:admain_maintence_app/screen/service_provider/model/service_provider_model.dart';
import 'package:admain_maintence_app/screen/service_provider/model/task_model.dart';
import 'package:admain_maintence_app/screen/task_page/task_save_model.dart';
import 'package:admain_maintence_app/services/storage_services.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:get/get.dart';
import 'package:image_picker/image_picker.dart';
import 'package:uuid/uuid.dart';
import 'package:http/http.dart' as http;
import 'package:webview_flutter/webview_flutter.dart';
import 'package:admain_maintence_app/services/backend_fcm_service.dart';

class AppController extends GetxController {

  final categoriesRef = FirebaseFirestore.instance.collection('categories');
  final userRef = FirebaseFirestore.instance.collection('users');
  final serviceProviderRef = FirebaseFirestore.instance.collection('serviceProvider');
  final taskRef = FirebaseFirestore.instance.collection('tasks');
  final userTaskRef = FirebaseFirestore.instance.collection('userTasks');
  final tasksManagementRef = FirebaseFirestore.instance.collection('tasksManagement');
  final transactionLogRef = FirebaseFirestore.instance.collection('transactionLogs');
  final serviceProviderAccounts = FirebaseFirestore.instance.collection('providerAccounts');
  final artisanTaskImages = FirebaseFirestore.instance.collection('artisanTasksImages');
  final requests = FirebaseFirestore.instance.collection('requests');
  final adminAccounts = FirebaseFirestore.instance.collection('adminAccounts');


  var currentIndex = 0.obs;

  // Used for deep-linking from Admin Inbox notifications into Bookings/RFQs.
  var selectedBookingId = ''.obs;

  var userAmount = "".obs;

  File? imgUser;
  var isUploading = false.obs;
  var userId = "".obs;
  var isServiceProvider = true.obs;
  var isLoading = false.obs;
  var isDataLoading = false.obs;

  var categoryList = <CategoryModel>[].obs;
  var selectedCategory = "".obs;
  var selectedCategoryID = "".obs;
  var selectedSubCategory = "".obs;
  var subCategoryList = <CategoryModel>[].obs;
  var isUpdatingCategory = false.obs;
  var isUpdating = false.obs;
  var categoryId = "".obs;
  var availableTaskList = <Task>[].obs;
  var savingTaskList = <Task>[].obs;
  var selectedTask = "".obs;



  var isUpdatingSubCategory = false.obs;
  var subCategoryId = "".obs;
  var dynamicListToAddTask = <Task>[].obs;

  var dynamicUserWiseTaskList = [].obs;

  var isUpdatingTask = false.obs;
  var updateTaskId = "".obs;


  //payment Integration
  var webUrl = "".obs;
  var transferAmount = ''.obs;

  var requestList = <RequestModel>[].obs;
  var bankAccountId = "".obs;

  double _toDouble(dynamic v) {
    if (v == null) return 0.0;
    if (v is num) return v.toDouble();
    return double.tryParse(v.toString()) ?? 0.0;
  }

  Future<void> approveDepositRequest({required String requestId}) async {
    final String effectiveRequestId = requestId.trim();
    if (effectiveRequestId.isEmpty) {
      throw Exception('Missing requestId');
    }

    final requestDoc = await requests.doc(effectiveRequestId).get();
    if (!requestDoc.exists) {
      throw Exception('Request not found');
    }

    final requestData = (requestDoc.data() ?? <String, dynamic>{});
    final status = (requestData['status'] ?? '').toString().toLowerCase();
    if (status != 'pending') {
      throw Exception('Request is not pending');
    }

    final targetUserId = (requestData['request_by'] ?? requestData['requestBy'] ?? '').toString().trim();
    if (targetUserId.isEmpty) {
      throw Exception('Request has no user');
    }

    final amount = _toDouble(requestData['amount']);
    if (amount <= 0) {
      throw Exception('Invalid amount');
    }

    final now = DateTime.now().toString();
    final batch = FirebaseFirestore.instance.batch();

    final userDocRef = userRef.doc(targetUserId);
    final userSnap = await userDocRef.get();
    final userData = (userSnap.data() ?? <String, dynamic>{});
    final currentBalance = _toDouble(userData['balance']);
    final newBalance = currentBalance + amount;

    batch.update(requests.doc(effectiveRequestId), {
      'status': 'approved',
      'updated_at': now,
      'approved_at': now,
      'approved_by': userId.value,
    });

    // Keep legacy schema as string if it was stored as string; otherwise set numeric.
    final existingBalanceIsString = userData['balance'] is String;
    batch.update(userDocRef, {
      'balance': existingBalanceIsString ? newBalance.toString() : newBalance,
      'updated_at': now,
    });

    // Resolve user name for traceability
    final userName = (userData['name'] ?? userData['displayName'] ?? userData['full_name'] ?? '').toString().trim();

    final txId = const Uuid().v4();
    batch.set(transactionLogRef.doc(txId), {
      'id': txId,
      'amount': amount.toString(),
      'status': 'approved',
      'transaction_at': now,
      'transaction_by': userId.value,
      'type': 'Wallet Top-up',
      'subtype': 'wallet_topup',
      'direction': 'in',
      'cash_movement': true,
      'profit': '0.00',
      'schema_version': 2,
      'user_id': targetUserId,
      'user_name': userName,
      'request_id': effectiveRequestId,
      'balance_after': newBalance.toStringAsFixed(2),
      'previous_balance': currentBalance.toStringAsFixed(2),
    });

    await batch.commit();

    // ── Send push notification to user about approved deposit ──
    try {
      final userToken = (userData['deviceToken'] ?? userData['fcm_token'] ?? '').toString().trim();
      if (userToken.isNotEmpty) {
        final notifTitle = 'Wallet Loaded';
        final notifBody = 'Your deposit of R${amount.toStringAsFixed(2)} has been approved. New balance: R${newBalance.toStringAsFixed(2)}';
        final notifModel = NotificationModel(
          body: notifBody,
          imageUrl: '',
          time: now,
          title: notifTitle,
          type: 'wallet_topup',
          view: false,
        );
        final notifMessage = <String, Object>{
          'notification': {'title': notifTitle, 'body': notifBody},
          'data': {'image': '', 'type': 'wallet_topup'},
          'to': userToken,
        };
        await pushCustomNotification(notificationModel: notifModel, message: notifMessage);
        debugPrint('✅ Deposit approval notification sent to user $targetUserId');
      } else {
        debugPrint('⚠️ No FCM token for user $targetUserId — notification skipped');
      }
    } catch (e) {
      debugPrint('⚠️ Failed to send deposit approval notification: $e');
    }
  }

  Future<void> rejectDepositRequest({required String requestId}) async {
    final String effectiveRequestId = requestId.trim();
    if (effectiveRequestId.isEmpty) {
      throw Exception('Missing requestId');
    }

    final requestDoc = await requests.doc(effectiveRequestId).get();
    if (!requestDoc.exists) {
      throw Exception('Request not found');
    }

    final requestData = (requestDoc.data() ?? <String, dynamic>{});
    final status = (requestData['status'] ?? '').toString().toLowerCase();
    if (status != 'pending') {
      throw Exception('Request is not pending');
    }

    final now = DateTime.now().toString();
    await requests.doc(effectiveRequestId).update({
      'status': 'rejected',
      'updated_at': now,
      'rejected_at': now,
      'rejected_by': userId.value,
    });

    // ── Send push notification to user about rejected deposit ──
    try {
      final targetUserId = (requestData['request_by'] ?? requestData['requestBy'] ?? '').toString().trim();
      final amount = _toDouble(requestData['amount']);
      if (targetUserId.isNotEmpty) {
        final userSnap = await userRef.doc(targetUserId).get();
        final userData = (userSnap.data() ?? <String, dynamic>{});
        final userToken = (userData['deviceToken'] ?? userData['fcm_token'] ?? '').toString().trim();
        if (userToken.isNotEmpty) {
          final notifTitle = 'Deposit Rejected';
          final notifBody = 'Your deposit request of R${amount.toStringAsFixed(2)} has been rejected. Please contact support for more information.';
          final notifModel = NotificationModel(
            body: notifBody,
            imageUrl: '',
            time: now,
            title: notifTitle,
            type: 'Deposit Rejected',
            view: false,
          );
          final notifMessage = <String, Object>{
            'notification': {'title': notifTitle, 'body': notifBody},
            'data': {'image': '', 'type': 'Deposit Rejected'},
            'to': userToken,
          };
          await pushCustomNotification(notificationModel: notifModel, message: notifMessage);
          debugPrint('✅ Deposit rejection notification sent to user $targetUserId');
        }
      }
    } catch (e) {
      debugPrint('⚠️ Failed to send deposit rejection notification: $e');
    }
  }

  @override
  void onInit() {
    // TODO: implement onInit
    super.onInit();

  }


  Future<void> addBankInfo({required String bankName,required String accountTitle,required String bankNo }) async{
    isLoading.value = true;
    var id = const Uuid().v4();
    adminAccounts.doc(id).set({
      "account_no": bankNo,
      "account_title": accountTitle,
      "bank_name":  bankName,
      "created_at": DateTime.now().toString(),
      "id": id,
      "status": "publish",
      "updated_at": "",
    }).whenComplete(() => isLoading.value = false);

  }

  Future<void> updateBankInfo({required String bankName,
    required String accountTitle,required String bankNo }) async{
    adminAccounts.doc(bankAccountId.value).update({
      "account_no": bankNo,
      "account_title": accountTitle,
      "bank_name":  bankName,
      "updated_at": DateTime.now().toString(),
    }).whenComplete((){
      bankAccountId.value = "";
      isUpdating.value = false;
      Get.showSnackbar(
          const GetSnackBar(
            backgroundColor: Colors.green,
            duration: Duration(seconds: 2),
            snackPosition: SnackPosition.TOP,
            title: 'Success',message:'Information updated',));
    });

  }

  Future<void> changeStatusOfBank({required status}) async{
    var result = status == "publish" ? "draft" : "publish";
    adminAccounts.doc(bankAccountId.value).update({
      "status": result,
      "updated_at": DateTime.now().toString(),
    }).whenComplete(() => bankAccountId.value = "");

  }


  ///General Functions

  Future<void> changeStatusOfTask({String? categoryId, String? subCategoryId, String? taskId, required String status}) async {
    try{
      var subCategoryList = <String>[];

      //if you are drafting category
      if(subCategoryId == ""){
        QuerySnapshot snap = await categoriesRef.where('parent_id', isEqualTo: categoryId).get();
        for(var e in snap.docs){
          // debugPrint(e.data().toString());
          subCategoryList.add(e["id"]);
        }

        // debugPrint("Sub Cat length ${subCategoryList.length}");
        for(int i=0; i< subCategoryList.length; i++){
          taskRef.where('categoryId', isEqualTo: subCategoryList[i]).get().then((snap){
            for(var e in snap.docs){
              taskRef.doc(e.id).update({"status": status});
            }
          });
          taskRef.where('category_id', isEqualTo: subCategoryList[i]).get().then((snap){
            for(var e in snap.docs){
              taskRef.doc(e.id).update({"status": status});
            }
          });
        }

      }
      //if you are drafting sub-category
      if(categoryId == ""){
        taskRef.where('categoryId', isEqualTo: subCategoryId).get().then((snap){
          for(var e in snap.docs){
            taskRef.doc(e.id).update({"status": status});
          }
        });
        taskRef.where('category_id', isEqualTo: subCategoryId).get().then((snap){
          for(var e in snap.docs){
            taskRef.doc(e.id).update({"status": status});
          }
        });
      }

      else{
        taskRef.where('id', isEqualTo: taskId).get().then((snap){
          for(var e in snap.docs){
            taskRef.doc(e.id).update({"status": status});
          }
        });
      }

    }catch(e){
      debugPrint("deleteSubCategory $e");
    }
  }



  ///------------------------------///



  Future<void> getCategory() async {
    try{
      categoryList.clear();
      categoriesRef
          .where('parent_id', isEqualTo: "")
          .where('status', isEqualTo: "publish")
          .get().then((snap){
        for(var e in snap.docs){
          categoryList.add(CategoryModel.fromDocument(e));
        }
        debugPrint("Length ${categoryList.length}");
      });
    }catch(e){
      debugPrint("getCategory $e");
    }
  }
  Future<void> getSubCategory({required String categoryId}) async {
    try{
      isDataLoading.value = true;
      subCategoryList.clear();
      categoriesRef
          .where('parent_id', isEqualTo: categoryId)
          .where('status', isEqualTo: "publish")
          .get().then((snap){
        for(var e in snap.docs){
          subCategoryList.add(CategoryModel.fromDocument(e));
        }
        debugPrint("Sub Length ${subCategoryList.length}");
        isDataLoading.value = false;
      });
    }catch(e){
      isDataLoading.value = false;
      debugPrint("getSubCategory $e");
    }
  }

  Future<void> addNewCategory({required String name, required File image}) async {
   try{
     var id = const Uuid().v4();

     var imagePath = await StorageServices.uploadImageToFirebaseStorage(id: id, imageFile:image, path: 'category' );
     CategoryModel data = CategoryModel(
       id: id,
       parentId: "",
       name: name,
       uid: userId.value,
       status: "publish",
       image: imagePath,
     );
     categoriesRef.doc(id).set(data.toMap());
   }catch(e){
     debugPrint("addNewCategory $e");
   }
  }
  Future<void> updateCategory({required String name}) async {
    try{

      categoriesRef.doc(categoryId.value).update({"name" : name});
    }catch(e){
      debugPrint("updateCategory $e");
    }
  }
  Future<void> addNewSubCategory({required String categoryID,required String name, required File image}) async {
    try{
      var id = const Uuid().v4();
      var imagePath = await StorageServices.uploadImageToFirebaseStorage(id: id, imageFile:image, path: 'category' );
      CategoryModel data = CategoryModel(
        id: id,
        parentId: categoryID,
        name: name,
        uid: userId.value,
        status: "publish",
        image: imagePath,
      );
      categoriesRef.doc(id).set(data.toMap());
    }catch(e){
      debugPrint("addNewSubCategory $e");
    }
  }
  Future<void> updateSubCategory({required String name}) async {
    try{
      categoriesRef.doc(subCategoryId.value).update({"name" : name});
    }catch(e){
      debugPrint("updateSubCategory $e");
    }
  }

  Future<void> changeStatusOfCategory({required String categoryId, required String status}) async {
    try{
      // Cycle: publish → coming_soon → draft → publish
      var updateStatus = "";
      if(status == "publish"){
        updateStatus = "coming_soon";
      } else if (status == "coming_soon") {
        updateStatus = "draft";
      } else {
        updateStatus = "publish";
      }
      categoriesRef.doc(categoryId).update({"status": updateStatus});
      // drafting or publishing all sub-categories
      categoriesRef.where('parent_id', isEqualTo: categoryId).get().then((snap){
        for(var e in snap.docs){
          categoriesRef.doc(e.id).update({"status": updateStatus});
        }
      }).then((_){
        changeStatusOfTask(categoryId: categoryId, subCategoryId: "", status: updateStatus);
      });


    }catch(e){
      debugPrint("deleteCategory $e");
    }
  }
  Future<void> changeStatusOfSubCategory({required String subCategoryId, required String status}) async {
    try{
      debugPrint(status.toString());
      var updateStatus = "";
      if(status == "publish"){
        updateStatus = "draft";
      }
      else{
        updateStatus = "publish";
      }
      categoriesRef.doc(subCategoryId).update({"status": updateStatus});
      categoriesRef.where('id', isEqualTo: subCategoryId).get().then((snap){
        for(var e in snap.docs){
          categoriesRef.doc(e.id).update({"status": updateStatus});
        }
      });
      changeStatusOfTask(categoryId: "", subCategoryId: subCategoryId, status: updateStatus);
    }catch(e){
      debugPrint("deleteSubCategory $e");
    }
  }


  

  //Save Artisan Profile

  Future<void> saveServiceProviderProfile({required String name,
    required String email, required String phone, required String password,
    required Position position, required File image}) async{

    try{
      var uId = const Uuid().v4();
      String url = await StorageServices().uploadImageToFirebase(id: uId,imageFile: image);
      ServiceProviderModel serviceData = ServiceProviderModel(
        docId: uId,
        name: name,
        email: email,
        password: password,
        deviceToken: "",
        lat: position.latitude.toString(),
        lng: position.longitude.toString(),
        active: 'y',
        contact: phone,
        image: url,
        balance: '',
        accountLinked: "0",

      );

      serviceProviderRef.doc(uId).set(serviceData.toMap()).whenComplete((){
        debugPrint("Artisan Saved");
        saveTaskForArtisan(userId: uId);
      });



    }catch(e){
      debugPrint("saveServiceProviderProfile $e");
    }
  }

  Future<void> saveTaskForArtisan({required String userId}) async{
    try{
      for(int i=0 ; i<savingTaskList.length; i++){
        final taskId = savingTaskList[i].id;
        
        // Validate that task exists in tasks collection before assigning
        try {
          final taskDoc = await taskRef.doc(taskId).get();
          if (!taskDoc.exists) {
            debugPrint("[saveTaskForArtisan] WARNING: Task $taskId does not exist in tasks collection. Skipping assignment.");
            Get.showSnackbar(GetSnackBar(
              backgroundColor: Colors.orange,
              duration: const Duration(seconds: 3),
              snackPosition: SnackPosition.TOP,
              title: 'Warning',
              message: 'Task ${savingTaskList[i].task} not found in catalog. Skipped.',
            ));
            continue; // Skip this task
          }
          debugPrint("[saveTaskForArtisan] Verified task $taskId exists: ${taskDoc.data()?['name']}");
        } catch (e) {
          debugPrint("[saveTaskForArtisan] ERROR verifying task $taskId: $e");
          continue; // Skip on error
        }
        
        var id = const Uuid().v4();
        final Map<String, dynamic> taskData = {
          'id' : id,
          'user_id' : userId,
          'task_id' : taskId,
          'status'  : "publish",
        };
        userTaskRef.doc(id).set(taskData).whenComplete((){
          debugPrint("Task Saved: task_id=$taskId assigned to user_id=$userId");
        });
      }
    }catch(e){
      debugPrint("saveTaskForServiceProvider $e");
    }
  }
  Future<bool> checkTaskAlreadyExistsForArtisan({required String artisanId}) async{
    bool result = false;
    debugPrint("id $artisanId");
    QuerySnapshot<Map<String, dynamic>> dc = await userTaskRef.where('user_id', isEqualTo: artisanId).get();
    if(dc.docs.isNotEmpty){
      for (var element in dc.docs) {
        var taskResult = savingTaskList.where((p) => p.id == element["task_id"]).toList();
        if(taskResult.isNotEmpty){
          result = true;
          break;
        }
      }
      return result;
    }
    else{
      return result;
    }
  }
  Future<void> changeStatusTaskForArtisan({required String taskId,required String status}) async{
    var updateStatus = "";
    if(status == "publish"){
      updateStatus = "draft";
    }
    else{
      updateStatus = "publish";
    }
    debugPrint("id $taskId");
    debugPrint("updating value $updateStatus");
    userTaskRef.doc(taskId).update({"status": updateStatus});
  }


  //Registering Tasks against Sub-Categories
  Future<void> saveTask() async{
    try{
      for(int i=0 ; i<dynamicListToAddTask.length; i++){
        var taskId = const Uuid().v4();
        print('[saveTask] Saving task: ${dynamicListToAddTask[i].task} for categoryId: ${dynamicListToAddTask[i].id}');
        SaveTaskModel taskData = SaveTaskModel(
            id: taskId,
            name: dynamicListToAddTask[i].task,
            cost: dynamicListToAddTask[i].clientRate.isNotEmpty ? dynamicListToAddTask[i].clientRate : dynamicListToAddTask[i].cost,
            outsourcedRate: dynamicListToAddTask[i].outsourcedRate,
            clientRate: dynamicListToAddTask[i].clientRate,
            categoryId: dynamicListToAddTask[i].id,
            status: 'publish',
            createdAt: DateTime.now().toString(),
        );
        await taskRef.doc(taskId).set(taskData.toMap());
        print('[saveTask] Task saved successfully with ID: $taskId');
      }
      // Reload tasks after saving
      await getTaskList();
    }catch(e){
      print('[saveTask] ERROR: $e');
      debugPrint("saveTaskForServiceProvider $e");
    }
  }
  Future<void> getTaskList() async{
    print('[getTaskList] Starting... selectedSubCategory: $selectedSubCategory');
    isDataLoading.value = true;
    availableTaskList.clear();
    final sid = selectedSubCategory.value.toString().trim();
    print('[getTaskList] Trimmed sid: "$sid"');
    
    if (sid.isEmpty) {
      print('[getTaskList] ERROR: sid is EMPTY!');
      isDataLoading.value = false;
      return;
    }

    final docsById = <String, QueryDocumentSnapshot<Map<String, dynamic>>>{};

    // Removed orderBy to avoid index requirement issues
    try {
      print('[getTaskList] Querying with categoryId = $sid');
      final snap1  = await taskRef
          .where('categoryId', isEqualTo: sid)
          .get();
      print('[getTaskList] categoryId query returned ${snap1.docs.length} docs');
      for (final d in snap1.docs) {
        print('[getTaskList]   - Found task: ${d.data()["name"]} (categoryId: ${d.data()["categoryId"]})');
        docsById[d.id] = d;
      }
    } catch (e) {
      print('[getTaskList] categoryId query ERROR: $e');
      debugPrint('getTaskList categoryId query error: $e');
    }

    try {
      print('[getTaskList] Querying with category_id = $sid');
      final snap2  = await taskRef
          .where('category_id', isEqualTo: sid)
          .get();
      print('[getTaskList] category_id query returned ${snap2.docs.length} docs');
      for (final d in snap2.docs) {
        print('[getTaskList]   - Found task: ${d.data()["name"]} (category_id: ${d.data()["category_id"]})');
        docsById[d.id] = d;
      }
    } catch (e) {
      print('[getTaskList] category_id query ERROR: $e');
      debugPrint('getTaskList category_id query error: $e');
    }

    print('[getTaskList] Total unique docs found: ${docsById.length}');
    for (final element in docsById.values) {
      final data = element.data();
      availableTaskList.add(Task(
        task: (data["name"] ?? '').toString(),
        cost: (data["cost"] ?? '').toString(),
        id: (data["id"] ?? element.id).toString(),
      ));
    }
    print('[getTaskList] Final availableTaskList count: ${availableTaskList.length}');
    debugPrint("Available Tasks ${availableTaskList.length}");
    isDataLoading.value = false;
  }
  Future<void> updateTaskInFirebase({required String name, required String cost}) async{
    taskRef.doc(updateTaskId.value).update({
      "name" : name,
      "cost" : cost,
    });
  }
  Future<void> deleteTaskFromFirebase({required String id}) async{
    taskRef.doc(id).delete();
  }
  Future<bool> checkTaskNameExists({required String taskName}) async{
    bool result = false;
    QuerySnapshot<Map<String, dynamic>> tasks = await taskRef.get();
    debugPrint("length ${tasks.docs.length}");
    if(tasks.docs.isNotEmpty){
      for (var element in tasks.docs) {
        if(element["name"].toString().toLowerCase() == taskName.toLowerCase()){
          result = true;
          break;
        }
      }
      return result;
    }
    else{
      return result;
    }
  }
  Future<void> changeStatusTaskInFirebase({required String taskId,required String status}) async{
    var updateStatus = "";
    if(status == "publish"){
      updateStatus = "draft";
    }
    else{
      updateStatus = "publish";
    }
    taskRef.doc(taskId).update({"status": updateStatus});
  }



  Future<void> getUserWiseTaskData({required String userId}) async{

    debugPrint("User $userId");
   var idsList = [];
   var taskList = [];
   QuerySnapshot snapshot = await  taskRef.where('user_id', isEqualTo: userId).where('status', isEqualTo: 'publish').get();

   for(var e in snapshot.docs){
     taskList.add(SaveTaskModel.fromDocument(e));
     var id = SaveTaskModel.fromDocument(e).categoryId;
     if(!idsList.contains(id)){
       idsList.add(id);
     }


   }
   debugPrint("ids $idsList");
   debugPrint("task $taskList");

  }



  Future<Map<String, dynamic>> getTaskManagementDetail({required String taskId}) async{

    try {
      debugPrint("Task");
      var taskName = "";
      QuerySnapshot snapshot = await taskQuery(taskId: taskId);
      for(var e in snapshot.docs){
        debugPrint(e.data().toString());
        taskName = e["name"];
      }
      debugPrint("Task Name $taskName");



      return {
        "taskName": taskName,
      };
    } catch (e) {
      debugPrint('Error: $e');
      rethrow;
    }


  }


  Future<QuerySnapshot<Object?>> taskQuery({required String taskId}) async {
    return await taskRef.where('id', isEqualTo: taskId).get();
  }

  Future<void> transferPaymentToArtisan({
    required String serviceProviderId,
    required String id, required String amount, required String fee}) async{

    final WriteBatch batch = FirebaseFirestore.instance.batch();

    final Map<String, dynamic> taskData = {
      'payment' : amount,
      'fee' : fee,
      'payment_status' : "artisan",
      'status' : "closed",
      'closed_date' : DateTime.now().toString(),
      'updated_at' : DateTime.now().toString(),
      'updated_by' : userId.value,
    };

    var tId = const Uuid().v4();
    final Map<String, dynamic> transactionData = {
      'id' : tId,
      'amount' : amount,
      'status' : 'success',
      'task_id' : id,
      'tasks_management_id': id,
      'service_provider_id': serviceProviderId,
      'task_name': "",
      'transaction_at' : DateTime.now().toString(),
      'transaction_by' : userId.value,
      'type' : 'Transfer to Artisan',
      'subtype': 'artisan_payout',
      'direction': 'out',
      'cash_movement': true,
      'profit': '0.00',
      'schema_version': 2,
    };

    // final WriteBatch batch = fireStore.batch();

    try{

      final DocumentReference transaction = transactionLogRef.doc(tId);
      batch.set(transaction, transactionData);

      final DocumentReference documentRef1 = tasksManagementRef.doc(id);
      batch.update(documentRef1, taskData);

      final DocumentReference documentRef2 = serviceProviderRef.doc(serviceProviderId);
      var artisanAmount = '';
      DocumentSnapshot dc = await documentRef2.get();
      debugPrint("already balance ${dc["balance"]}");
      artisanAmount = dc["balance"];
      if(artisanAmount == ""){
        artisanAmount = "0";
      }
      artisanAmount = (double.parse(artisanAmount) + double.parse(amount)).toStringAsFixed(2);
      debugPrint("New balance $artisanAmount");

      final Map<String, dynamic> serviceProviderData = {
        'balance' : artisanAmount,
        'balance_from' : 'admin',
      };
      batch.update(documentRef2, serviceProviderData);

      // Commit the batch
      await batch.commit();

      Get.showSnackbar(
          const GetSnackBar(
              backgroundColor: Colors.green,
              duration: Duration(seconds: 2),
              snackPosition: SnackPosition.TOP,
              title: 'Success',message:'Amount Transferred to Artisan'));


    }catch(e){
      final Map<String, dynamic> transactionData = {
        'id' : tId,
        'amount' : amount,
        'status' : 'failed',
        'task_id' : id,
        'tasks_management_id': id,
        'service_provider_id': serviceProviderId,
        'task_name': "",
        'transaction_at' : DateTime.now().toString(),
        'transaction_by' : userId.value,
        'type' : 'Transfer to Artisan',
        'subtype': 'artisan_payout',
        'direction': 'out',
        'cash_movement': true,
        'profit': '0.00',
        'schema_version': 2,
      };
      await transactionLogRef.doc(tId).set(transactionData);
      debugPrint("saveTaskForServiceProvider $e");
    }
  }

  Future<String> initiatePayment({required String key, required String id, required String comment, required amount}) async {
    debugPrint("payment");
    webUrl.value = "";
    String web = '';

    var body = {
      'merchant_id': id,
      'merchant_key': key,
      'amount' : amount,
      'item_name' : comment,
    };

    // final url = Uri.parse('https://sandbox.payfast.co.za/eng/process');
    final url = Uri.parse('https://www.payfast.co.za/eng/process');
    final response = await http.post(
      url,
      body: body,
      headers: {
        'Accept': 'application/json',
      },
    );

    if (response.statusCode == 302) {
      // Get the location header which contains the redirected URL
      final redirectedUrl = response.headers['location'];

      if (redirectedUrl != null) {
        debugPrint("Redirected URL: $redirectedUrl");
        return redirectedUrl;
      } else {
        debugPrint("Redirected URL not found.");
      }
    }
    else {
      debugPrint("HTTP error ${response.statusCode}");
    }

    return web;

  }

  Future<String?> initiatePaymentTest(BuildContext context) async {
    debugPrint("payment");

    final body = {
      'merchant_id': '10030978',
      'merchant_key': 'bf8lnaie335xl',
      'amount': '100',
      'item_name': 'Test Order #5',
    };

    final url = Uri.parse('https://sandbox.payfast.co.za/eng/process');
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
        debugPrint("Redirected URL: $redirectedUrl");

        final Completer<String?> completer = Completer<String?>();
        late final WebViewController webViewController;

        webViewController = WebViewController()
          ..setJavaScriptMode(JavaScriptMode.unrestricted)
          ..setBackgroundColor(Colors.transparent)
          ..setNavigationDelegate(
            NavigationDelegate(
              onPageFinished: (String url) async {
                try {
                  final htmlContent = await webViewController.runJavaScriptReturningResult(
                    'document.documentElement.outerHTML;',
                  );
                  debugPrint("HTML Content: $htmlContent");

                  if (context.mounted) Navigator.of(context).pop();
                  completer.complete(htmlContent.toString());
                } catch (e) {
                  debugPrint("Error getting HTML: $e");
                  if (context.mounted) Navigator.of(context).pop();
                  completer.complete(null);
                }
              },
            ),
          )
          ..loadRequest(Uri.parse(redirectedUrl));

        if (context.mounted) {
          showDialog(
            context: context,
            builder: (BuildContext context) {
              return AlertDialog(
                content: SizedBox(
                  width: double.maxFinite,
                  height: 500,
                  child: WebViewWidget(controller: webViewController),
                ),
              );
            },
          );
        }

        return completer.future;
      } else {
        debugPrint("Redirected URL not found.");
      }
    } else {
      debugPrint("HTTP error ${response.statusCode}");
    }

    return null;
  }



  Future<void> sendNotification({required String to, String? comment}) async{

    Map<String, Object> message = {};
    var title = "Account Link Request";
    var type = "Account Link Request";
    message = {
      'notification': {
        'title': title,
        'body': comment,
      },
      'data': {
        'image': '',
        'type': type,
      },
      'to': to,
    };
    NotificationModel notificationModel = NotificationModel(
        body: comment,
        imageUrl: "",
        time: DateTime.now().toString(),
        title: title,
        type: type,
        view: false);

    pushCustomNotification(notificationModel: notificationModel, message: message);

  }

  Future<void> pushCustomNotification({required NotificationModel notificationModel, required Map<String, Object> message}) async{

    FirebaseFirestore.instance.collection('notifications').add(notificationModel.toMap());

    // Send via secure backend instead of hardcoded FCM server key
    final to = message['to'] as String? ?? '';
    if (to.isNotEmpty) {
      await BackendFcmService.sendNotification(
        token: to,
        title: (message['notification'] as Map?)?['title']?.toString() ?? '',
        body: (message['notification'] as Map?)?['body']?.toString() ?? '',
        data: (message['data'] as Map<String, dynamic>?) ?? {},
      );
    }
  }





  ///For add any column in existing collections (Note: change name of collection as required before run this function)
  Future<void> addNewColumnToFirebaseCollection() async{
    categoriesRef.get().then((snap){
      for(var e in snap.docs){
        categoriesRef.doc(e.id).update({"image": ""});
      }
    });
  }

  Future<void> updateProfileImage(BuildContext context, {required String userId}) {
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
                      XFile? pickedFile = await ImagePicker().pickImage(source: ImageSource.gallery);
                      if(pickedFile != null){
                        isUploading.value = true;
                        imgUser = File(pickedFile.path);
                        String url = await StorageServices().uploadImageToFirebase(id: userId,imageFile: imgUser!);
                        serviceProviderRef.doc(userId).update({"image" : url}).whenComplete((){
                          debugPrint("Image updates");
                          isUploading.value = false;
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
                      XFile? pickedFile = await ImagePicker().pickImage(source: ImageSource.camera);
                      if(pickedFile != null){
                        isUploading.value = true;
                        imgUser = File(pickedFile.path);
                        String url = await StorageServices().uploadImageToFirebase(id: userId,imageFile: imgUser!);
                        serviceProviderRef.doc(userId).update({"image" : url}).whenComplete((){
                          debugPrint("Image updates");
                          isUploading.value = false;
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

}