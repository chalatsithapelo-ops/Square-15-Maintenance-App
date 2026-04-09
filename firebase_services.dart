import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:maintenanceapp/model/artisan_task_model.dart';
import 'package:maintenanceapp/model/category_model.dart';
import 'package:maintenanceapp/model/task_management_model.dart';
import 'package:maintenanceapp/model/task_model.dart';

class FirebaseService {
  static final categoryRef =
      FirebaseFirestore.instance.collection('categories');
  static final userRef = FirebaseFirestore.instance.collection('users');
  static final providerRef =
      FirebaseFirestore.instance.collection('serviceProvider');
  static final taskRef = FirebaseFirestore.instance.collection('tasks');
  static final artisanTasks =
      FirebaseFirestore.instance.collection('userTasks');
  static final tasksManagementRef =
      FirebaseFirestore.instance.collection('tasksManagement');
  static final transactionRef =
      FirebaseFirestore.instance.collection('transactionLogs');
  static final artisanTaskImages =
      FirebaseFirestore.instance.collection('artisanTasksImages');

  Stream<List<CategoryModel>> subCategoryQuery({required String id}) {
    return categoryRef
        .where('status', isEqualTo: 'publish')
        .where('parent_id', isEqualTo: id)
        .snapshots()
        .map((snapshot) => snapshot.docs
            .map((doc) => CategoryModel.fromDocument(doc.data()))
            .toList());
  }

  Stream<List<TaskModel>> taskQuery({required String id}) {
    final controller = StreamController<List<TaskModel>>.broadcast();
    StreamSubscription? subA;
    StreamSubscription? subB;

    List<QueryDocumentSnapshot<Map<String, dynamic>>> latestA = const <QueryDocumentSnapshot<Map<String, dynamic>>>[];
    List<QueryDocumentSnapshot<Map<String, dynamic>>> latestB = const <QueryDocumentSnapshot<Map<String, dynamic>>>[];

    void emit() {
      final byId = <String, TaskModel>{};
      for (final doc in <QueryDocumentSnapshot<Map<String, dynamic>>>[...latestA, ...latestB]) {
        final data = Map<String, dynamic>.from(doc.data());
        data['docId'] = doc.id;
        data['doc_id'] = doc.id;
        final model = TaskModel.fromDocument(data);
        final key = (model.id ?? doc.id).toString();
        byId[key] = model;
      }

      final list = byId.values.toList();
      list.sort((a, b) => (a.name ?? '').toLowerCase().compareTo((b.name ?? '').toLowerCase()));
      controller.add(list);
    }

    controller.onListen = () {
      subA = taskRef
          .where('status', isEqualTo: 'publish')
          .where('categoryId', isEqualTo: id)
          .snapshots()
          .listen((snapshot) {
        latestA = snapshot.docs;
        emit();
      }, onError: controller.addError);

      subB = taskRef
          .where('status', isEqualTo: 'publish')
          .where('category_id', isEqualTo: id)
          .snapshots()
          .listen((snapshot) {
        latestB = snapshot.docs;
        emit();
      }, onError: controller.addError);
    };

    controller.onCancel = () async {
      await subA?.cancel();
      await subB?.cancel();
      await controller.close();
    };

    return controller.stream;
  }

  Stream<List<ArtisanTaskModel>> artisanTaskQuery({required String id}) {
    return artisanTasks
        .where('status', isEqualTo: 'publish')
        .where('task_id', isEqualTo: id)
        .snapshots()
        .map((snapshot) => snapshot.docs
            .map((doc) => ArtisanTaskModel.fromDocument(doc.data()))
            .toList());
  }

  Stream<List<TaskManagementModel>> requestQuery({required String providerId}) {
    return requestQueryForProviders(providerIds: <String>[providerId]);
  }

  Stream<List<TaskManagementModel>> requestQueryForProviders({
    required List<String> providerIds,
  }) {
    final ids = <String>{
      for (final id in providerIds) id.toString().trim(),
    }.where((s) => s.isNotEmpty).toList();

    if (ids.isEmpty) {
      return Stream.value(<TaskManagementModel>[]);
    }

    // Firestore whereIn supports up to 10 values.
    final effectiveIds = ids.take(10).toList();

    final Query<Map<String, dynamic>> q = effectiveIds.length == 1
        ? tasksManagementRef.where('service_provider_id',
            isEqualTo: effectiveIds.first)
        : tasksManagementRef.where('service_provider_id',
            whereIn: effectiveIds);

    return q.snapshots().map((snapshot) {
      final list = snapshot.docs
          .map((doc) =>
              TaskManagementModel.fromDocument(doc.data(), docId: doc.id))
          // Accept == '' means pending; accept == '1' means accepted
          .where((m) {
        final accept = (m.accept ?? '').toString().trim();
        if (accept.isNotEmpty && accept != '1') return false;
        // Keep closed so Requests can show history, but never show cancelled.
        // Cancellation can be reflected in status or payment fields depending on flow.
        return !m.isCancelledLike;
      }).toList();

      list.sort((a, b) {
        final ad = DateTime.tryParse((a.creationDate ?? a.updatedAt ?? '').toString()) ??
            DateTime.tryParse((a.updatedAt ?? '').toString()) ??
            DateTime.fromMillisecondsSinceEpoch(0);
        final bd = DateTime.tryParse((b.creationDate ?? b.updatedAt ?? '').toString()) ??
            DateTime.tryParse((b.updatedAt ?? '').toString()) ??
            DateTime.fromMillisecondsSinceEpoch(0);
        return bd.compareTo(ad);
      });
      return list;
    }).handleError((error) {
      debugPrint("Error fetching data: $error");
    });
  }
}
