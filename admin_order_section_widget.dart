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
        const SizedBox(height: 4),
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
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Center(
                  child: SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
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

            if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  'No orders',
                  style: TextStyle(
                    color: Colors.grey.shade600,
                    fontSize: 13,
                    fontStyle: FontStyle.italic,
                  ),
                ),
              );
            }

            var docs = snapshot.data!.docs.toList();

            // For "pending" section (accept == ''), exclude orders that
            // are already completed or closed so they don't appear twice.
            if (queryField == 'accept') {
              const finishedStatuses = {'completed', 'closed', 'cancelled', 'canceled'};
              docs = docs.where((d) {
                final st = (_safeGet(d, 'status') ?? '').toString().trim().toLowerCase();
                return !finishedStatuses.contains(st);
              }).toList();
            }

            // Deduplicate by order_no (keep first occurrence)
            final seenOrders = <String>{};
            docs = docs.where((d) {
              final orderNo = (_safeGet(d, 'order_no') ?? '').toString().trim();
              if (orderNo.isEmpty) return true; // keep orders with no number
              if (seenOrders.contains(orderNo)) return false;
              seenOrders.add(orderNo);
              return true;
            }).toList();

            // Sort by creation date descending
            docs.sort((a, b) {
              final aD = safeParseDate(_safeGet(a, 'creation_date'));
              final bD = safeParseDate(_safeGet(b, 'creation_date'));
              if (aD == null && bD == null) return 0;
              if (aD == null) return 1;
              if (bD == null) return -1;
              return bD.compareTo(aD);
            });

            if (docs.isEmpty) {
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  'No orders',
                  style: TextStyle(
                    color: Colors.grey.shade600,
                    fontSize: 13,
                    fontStyle: FontStyle.italic,
                  ),
                ),
              );
            }

            // Limit to 15 items for performance
            final displayDocs = docs.length > 15 ? docs.sublist(0, 15) : docs;

            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ...displayDocs.map((data) => _buildDirectOrderTile(context, data)),
                if (docs.length > 15)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Text(
                      '+ ${docs.length - 15} more orders',
                      style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                    ),
                  ),
              ],
            );
          },
        ),
      ],
    );
  }

  /// Safely get a field from a Firestore document snapshot.
  static dynamic _safeGet(DocumentSnapshot doc, String field) {
    try {
      return doc[field];
    } catch (_) {
      return null;
    }
  }

  /// Build an order tile directly from the task management document,
  /// WITHOUT an extra FutureBuilder to fetch user/provider names.
  /// Names are fetched only when the user taps "View".
  Widget _buildDirectOrderTile(BuildContext context, QueryDocumentSnapshot data) {
    final orderNo = (_safeGet(data, 'order_no') ?? '').toString();
    final creationDate = (_safeGet(data, 'creation_date') ?? '').toString();
    final userName = (_safeGet(data, 'user_name') ?? _safeGet(data, 'client_name') ?? '').toString();
    final artisanName = (_safeGet(data, 'artisan_name') ?? _safeGet(data, 'service_provider_name') ?? '').toString();
    final categoryName = (_safeGet(data, 'category_name') ?? _safeGet(data, 'category') ?? '').toString();
    final status = (_safeGet(data, 'status') ?? _safeGet(data, 'accept') ?? '').toString();

    DateTime? parsedDate;
    if (creationDate.isNotEmpty) {
      parsedDate = safeParseDate(creationDate);
    }
    final closedDate = safeParseDate(_safeGet(data, 'closed_date'));

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 3),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.grey.shade300),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      'Order #',
                      style: GoogleFonts.lato(fontSize: 12, fontWeight: FontWeight.bold),
                    ),
                    Flexible(
                      child: Text(
                        orderNo.isNotEmpty ? orderNo : '—',
                        style: GoogleFonts.lato(fontSize: 12),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
                if (userName.isNotEmpty)
                  Text(
                    'Client: $userName',
                    style: GoogleFonts.lato(fontSize: 13, fontWeight: FontWeight.w600),
                    overflow: TextOverflow.ellipsis,
                  ),
                if (artisanName.isNotEmpty)
                  Text(
                    'Artisan: $artisanName',
                    style: GoogleFonts.lato(fontSize: 13, fontWeight: FontWeight.w600),
                    overflow: TextOverflow.ellipsis,
                  ),
                if (categoryName.isNotEmpty)
                  Text(
                    categoryName,
                    style: GoogleFonts.lato(
                      fontSize: 11,
                      color: Colors.grey.shade700,
                    ),
                  ),
                if (parsedDate != null)
                  Text(
                    DateFormat('dd/MMM/yyyy hh:mm a').format(parsedDate),
                    style: GoogleFonts.lato(fontSize: 11, fontWeight: FontWeight.w500),
                  ),
                if (queryValue == 'closed' && closedDate != null)
                  Text(
                    'Closed: ${DateFormat("dd/MMM/yyyy hh:mm a").format(closedDate)}',
                    style: GoogleFonts.lato(fontSize: 11, fontWeight: FontWeight.w500),
                  ),
                if (status.isNotEmpty && status != queryValue.toString())
                  Text(
                    status,
                    style: GoogleFonts.lato(fontSize: 10, color: Colors.blueGrey),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          GestureDetector(
            onTap: () async {
              EasyLoading.show(status: 'Loading...');
              try {
                // Fetch user + provider only on tap
                final userId = (_safeGet(data, 'user_id') ?? '').toString();
                final providerId = (_safeGet(data, 'service_provider_id') ?? '').toString();
                DocumentSnapshot? userData;
                DocumentSnapshot? artisanData;
                try {
                  final results = await Future.wait([
                    userId.isNotEmpty
                        ? appController.userRef.doc(userId).get()
                        : Future<DocumentSnapshot?>.value(null),
                    providerId.isNotEmpty
                        ? appController.serviceProviderRef.doc(providerId).get()
                        : Future<DocumentSnapshot?>.value(null),
                  ]);
                  userData = results[0];
                  artisanData = results[1];
                } catch (_) {}

                await appController.getTaskManagementDetail(
                  taskId: _safeGet(data, 'task_id'),
                );
                Get.to(
                  () => PaymentsDetailScreen(
                    taskData: data,
                    userData: userData,
                    artisanData: artisanData,
                  ),
                  transition: Transition.fadeIn,
                );
              } catch (e) {
                debugPrint('Order tile tap error: $e');
              } finally {
                EasyLoading.dismiss();
              }
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
      style: TextStyle(
        fontWeight: FontWeight.bold,
        fontSize: 16,
        color: color ?? Colors.black,
      ),
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
