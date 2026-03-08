import 'package:admain_maintence_app/screen/payments_screen/payment_detail_screen.dart';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_easyloading/flutter_easyloading.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';
import 'package:get/get.dart';
import '../../controllers/app_controller.dart';

class OrdersSectionWidget extends StatelessWidget {
  final String headingText;
  final String queryField;
  final dynamic queryValue;
  final Color? headingColor;
  final Color viewColor;
  final Color viewBorderColor;
  /// When true, uses whereIn instead of isEqualTo (queryValue must be a List).
  final bool useWhereIn;

  OrdersSectionWidget({
    super.key,
    required this.headingText,
    required this.queryField,
    required this.queryValue,
    this.headingColor,
    required this.viewColor,
    required this.viewBorderColor,
    this.useWhereIn = false,
  });

  final AppController appController = Get.find();

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        heading(text: headingText, color: headingColor),
        StreamBuilder<QuerySnapshot>(
            stream: (useWhereIn && queryValue is List)
                ? appController.tasksManagementRef
                    .where(queryField, whereIn: queryValue)
                    .snapshots()
                : appController.tasksManagementRef
                    .where(queryField, isEqualTo: queryValue)
                    .snapshots(),
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) {
                return const Padding(
                  padding: EdgeInsets.symmetric(vertical: 16),
                  child: Center(child: SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))),
                );
              }

              if (snapshot.hasError) {
                debugPrint('OrdersSectionWidget error: ${snapshot.error}');
                return Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(
                    'Error loading orders.\n${snapshot.error}',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.red, fontSize: 12),
                  ),
                );
              }

              if (!snapshot.hasData) return const Padding(padding: EdgeInsets.all(12), child: Text('No data'));

              final docs = snapshot.data!.docs.toList()
                ..sort((a, b) {
                  final aDate = safeParseDate(a['creation_date']);
                  final bDate = safeParseDate(b['creation_date']);
                  if (aDate == null && bDate == null) return 0;
                  if (aDate == null) return 1;
                  if (bDate == null) return -1;
                  return bDate.compareTo(aDate); // descending
                });
              if (docs.isEmpty) {
                return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Center(child: Text('No Order in ${headingText.split(" ").last}',
                        style: TextStyle(color: Colors.grey.shade600, fontSize: 13))));
              }

              return Card(
                color: Colors.grey.shade200,
                child: ListView.builder(
                physics: const NeverScrollableScrollPhysics(),
                shrinkWrap: true,
                itemCount: docs.length,
                itemBuilder: (context, index) {
                  final data = docs[index];
                  final userId = (data['user_id'] ?? '').toString();
                  final serviceProviderId = (data['service_provider_id'] ?? '').toString();

                  // Combine user & provider fetch into one future
                  return FutureBuilder<Map<String, DocumentSnapshot?>>(
                    future: _fetchUserAndProvider(userId, serviceProviderId),
                    builder: (context, asyncSnap) {
                      if (asyncSnap.connectionState == ConnectionState.waiting) {
                        return const SizedBox();
                      }
                      if (!asyncSnap.hasData) return const SizedBox();

                      final userData = asyncSnap.data!['user'];
                      final artisanData = asyncSnap.data!['provider'];

                      return _buildOrderTile(context, data, userData, artisanData);
                    },
                  );
                },
              ));
            },
          ),
      ],
    );
  }

  Future<Map<String, DocumentSnapshot?>> _fetchUserAndProvider(String userId, String providerId) async {
    final userFuture = (userId.isNotEmpty)
        ? appController.userRef.doc(userId).get()
        : Future<DocumentSnapshot?>.value(null);
    final providerFuture = (providerId.isNotEmpty)
        ? appController.serviceProviderRef.doc(providerId).get()
        : Future<DocumentSnapshot?>.value(null);
    final results = await Future.wait([userFuture, providerFuture]);

    return {
      'user': results[0],
      'provider': results[1],
    };
  }

  Widget _buildOrderTile(
      BuildContext context,
      QueryDocumentSnapshot data,
      DocumentSnapshot? user,
      DocumentSnapshot? artisan,
      ) {
    String safeGetName(DocumentSnapshot? doc, String fallback) {
      try {
        if (doc == null || !doc.exists) return fallback;
        final d = doc.data();
        if (d is Map) return (d)['name']?.toString() ?? fallback;
        return fallback;
      } catch (_) {
        return fallback;
      }
    }

    final userName = safeGetName(user, 'Unknown User');
    final artisanName = safeGetName(artisan, 'Unassigned');
    final orderNo = data['order_no'] ?? '';
    final creationDate = data['creation_date'] ?? '';
    final closedDate = safeParseDate(data['closed_date']);

    // debugPrint("date $closedDate");

    return Padding(
      padding: const EdgeInsets.all(8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text("Order No. #", style: GoogleFonts.lato(fontSize: 12, fontWeight: FontWeight.bold)),
                    Text(orderNo.toString(), style: GoogleFonts.lato(fontSize: 12)),
                  ],
                ),
                Text('By: $userName',
                    style: GoogleFonts.lato(
                        fontSize: 14, fontWeight: FontWeight.w700)),
                Text('To: $artisanName',
                    style: GoogleFonts.lato(
                        fontSize: 14, fontWeight: FontWeight.w700)),
                if (creationDate.isNotEmpty)
                  Text(
                    DateFormat('dd/MMM/yyyy hh:mm a')
                        .format(DateTime.parse(creationDate)),
                    style: GoogleFonts.lato(
                        fontSize: 12, fontWeight: FontWeight.w500),
                  ),
                if (queryValue == 'closed' && closedDate != null)
                  Text(
                    'Closed at: ${DateFormat("dd/MMM/yyyy hh:mm a").format(closedDate)}',
                    style: GoogleFonts.lato(fontSize: 12, fontWeight: FontWeight.w500),
                  ),
              ],
            ),
          ),
          GestureDetector(
            onTap: () async {
              EasyLoading.show(status: 'Loading...');
              await appController
                  .getTaskManagementDetail(taskId: data['task_id'])
                  .then((record) {
                Get.to(
                      () => PaymentsDetailScreen(
                    taskData: data,
                    userData: user,
                    artisanData: artisan,
                  ),
                  transition: Transition.fadeIn,
                );
                EasyLoading.dismiss();
              });
            },
            child: Container(
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                color: viewColor,
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: viewBorderColor),
              ),
              child: Icon(Icons.remove_red_eye, color: viewBorderColor),
            ),
          ),
        ],
      ),
    );
  }
}

Widget heading({required String text, Color? color}) => Text(
  text,
  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: color ?? Colors.black),
);


DateTime? safeParseDate(dynamic value) {
  if (value is Timestamp) return value.toDate();
  if (value is DateTime) return value;
  if (value is String && value.isNotEmpty) {
    try {
      return DateTime.parse(value);
    } catch (_) {
      return null;
    }
  }
  return null;
}
