import 'dart:async';
import 'dart:developer';
import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_easyloading/flutter_easyloading.dart';
import 'package:get/get.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';
import 'package:maintenanceapp/controller/service_provider_controller.dart';
import 'package:maintenanceapp/screens/home/booking/attachment_view.dart';
import 'package:maintenanceapp/screens/home/booking/chat_icon_widget.dart';
import 'package:maintenanceapp/screens/home/booking/google_map_view.dart';
import 'package:maintenanceapp/screens/service_provider_panel/rfq/artisan_rfq_review_screen.dart';
import 'package:maintenanceapp/services/firestore_services/firebase_services.dart';
import 'package:maintenanceapp/services/future_booking_service.dart';
import 'package:maintenanceapp/utils/navigation.dart';
import 'package:maintenanceapp/utils/primary_button.dart';

class ServiceProviderRequestScreen extends StatefulWidget {
  final dynamic doc;
  const ServiceProviderRequestScreen({super.key, this.doc});

  @override
  State<ServiceProviderRequestScreen> createState() =>
      _ServiceProviderRequestScreenState();
}

class _ServiceProviderRequestScreenState
    extends State<ServiceProviderRequestScreen> {
  /// Per-order notes controllers keyed by tasksManagement doc id.
  /// This prevents notes typed for one order from appearing in all orders.
  final Map<String, TextEditingController> _notesControllers = {};
  final ServiceProviderController serviceProviderController = Get.find();
  String userName = "";
  int _requestTab = 0; // 0 = New Requests, 1 = Closed Requests

  TextEditingController _notesFor(String orderId) {
    return _notesControllers.putIfAbsent(orderId, () => TextEditingController());
  }

  @override
  void initState() {
    super.initState();
  }

  @override
  void dispose() {
    for (final c in _notesControllers.values) {
      c.dispose();
    }
    _notesControllers.clear();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    final height = MediaQuery.of(context).size.height;
    return SafeArea(
      child: Scaffold(
        body: Column(
          children: [
            Container(
                width: double.infinity,
                height: height * 0.15,
                padding: const EdgeInsets.only(left: 20, right: 20),
                decoration: const BoxDecoration(
                  borderRadius: BorderRadius.only(
                      bottomLeft: Radius.circular(40),
                      bottomRight: Radius.circular(40)),
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
                          onTap: () => Get.back(),
                          child: Icon(
                            Icons.arrow_back,
                            color: Colors.white,
                            size: width * 0.08,
                          ),
                        ),
                        Text("Requests",
                            style: GoogleFonts.lato(
                                fontWeight: FontWeight.w400,
                                fontSize: width * 0.06,
                                color: Colors.white)),
                        Container(),
                      ],
                    ),
                  ],
                )),
            const SizedBox(height: 10),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: [
                  Expanded(
                    child: GestureDetector(
                      onTap: () => setState(() => _requestTab = 0),
                      child: Container(
                        alignment: Alignment.center,
                        height: height * 0.055,
                        padding: const EdgeInsets.all(6),
                        decoration: BoxDecoration(
                          color: _requestTab == 0
                              ? const Color(0xFFc5a520)
                              : const Color(0xff868686),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          "New Requests",
                          style: GoogleFonts.roboto(
                            color: Colors.white,
                            fontWeight: FontWeight.w500,
                            fontSize: width * 0.04,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: GestureDetector(
                      onTap: () => setState(() => _requestTab = 1),
                      child: Container(
                        alignment: Alignment.center,
                        height: height * 0.055,
                        padding: const EdgeInsets.all(6),
                        decoration: BoxDecoration(
                          color: _requestTab == 1
                              ? const Color(0xFFc5a520)
                              : const Color(0xff868686),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          "Closed Requests",
                          style: GoogleFonts.roboto(
                            color: Colors.white,
                            fontWeight: FontWeight.w500,
                            fontSize: width * 0.04,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: Obx(() {
                final all = serviceProviderController.requestList;
                final filtered = all.where((r) {
                  if (r.isCancelledLike) return false;

                  final accept = (r.accept ?? '').toString().trim();
                  final statusLower =
                      (r.status ?? '').toString().trim().toLowerCase();

                  // Prefer updated_at for staleness checks.
                  final lastRaw =
                      (r.updatedAt ?? r.creationDate ?? '').toString().trim();
                  final last = DateTime.tryParse(lastRaw);
                  final ageDays =
                      last == null ? 0 : DateTime.now().difference(last).inDays;

                  if (_requestTab == 1) {
                    // Closed tab: show only truly completed / closed jobs.
                    return accept == '1' && r.isClosedLike;
                  }

                  // New tab:
                  // - Never show closed/completed
                  // - Never show rejected
                  // - Hide very old/stale pending requests
                  if (r.isClosedLike) return false;
                  if (accept == '0') return false;

                  // Pending acceptance older than 14 days is considered invalid.
                  if (accept.isEmpty && ageDays > 14) return false;

                  // Accepted but still not progressed for a long time is likely invalid.
                  final isNotStarted = statusLower.isEmpty ||
                      statusLower == 'pending' ||
                      statusLower == 'pending_payment' ||
                      statusLower == 'accepted';
                  if (accept == '1' && isNotStarted && ageDays > 60) {
                    return false;
                  }

                  return true;
                }).toList(growable: false);

                if (filtered.isEmpty) {
                  return Center(
                    child: Text(
                      _requestTab == 1
                          ? 'No Closed Requests'
                          : 'No New Requests',
                    ),
                  );
                }

                return ListView.builder(
                  itemCount: filtered.length,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  itemBuilder: (BuildContext context, int index) {
                    final data = filtered[index];
                    final accept = (data.accept ?? '').toString().trim();
                    final isValidClosed =
                        accept == '1' && data.isClosedLike;

                    final artisanImagesNorm =
                        ((data.artisanImages ?? '').toString().trim().isEmpty
                            ? '0'
                            : (data.artisanImages ?? '').toString().trim());
                    final statusLower =
                        (data.status ?? '').toString().trim().toLowerCase();
                    final createdAt = DateTime.tryParse(
                          (data.creationDate ?? '').toString(),
                        ) ??
                        DateTime.now();
                    return Stack(
                      alignment: Alignment.topCenter,
                      clipBehavior: Clip.none,
                      children: [
                        if (_requestTab == 1 && !isValidClosed)
                          Positioned(
                            right: 0,
                            top: -4,
                            child: IconButton(
                              tooltip: 'Delete invalid record',
                              icon: const Icon(Icons.delete, color: Colors.red),
                              onPressed: () async {
                                final requestId =
                                    (data.id ?? '').toString().trim();
                                if (requestId.isEmpty) {
                                  Get.snackbar(
                                    'Delete',
                                    'Missing request id.',
                                    backgroundColor: Colors.red,
                                    colorText: Colors.white,
                                  );
                                  return;
                                }

                                final confirmed = await showDialog<bool>(
                                  context: context,
                                  builder: (ctx) {
                                    return AlertDialog(
                                      title: const Text('Delete request?'),
                                      content: const Text(
                                        'This will permanently delete this invalid/legacy request record.',
                                      ),
                                      actions: [
                                        TextButton(
                                          onPressed: () =>
                                              Navigator.of(ctx).pop(false),
                                          child: const Text('Cancel'),
                                        ),
                                        TextButton(
                                          onPressed: () =>
                                              Navigator.of(ctx).pop(true),
                                          child: const Text('Delete'),
                                        ),
                                      ],
                                    );
                                  },
                                );

                                if (confirmed != true) return;

                                EasyLoading.show(status: 'Deleting...');
                                try {
                                  await FutureBookingService.tasksManagementRef
                                      .doc(requestId)
                                      .delete();

                                  final fbId = (data.futureBookingId ?? '')
                                      .toString()
                                      .trim();
                                  if (fbId.isNotEmpty) {
                                    await FutureBookingService.futureBookingsRef
                                        .doc(fbId)
                                        .delete();
                                  }

                                  Get.snackbar(
                                    'Deleted',
                                    'Request deleted.',
                                    backgroundColor: Colors.green,
                                    colorText: Colors.white,
                                  );
                                } catch (e) {
                                  Get.snackbar(
                                    'Error',
                                    'Could not delete request: $e',
                                    backgroundColor: Colors.red,
                                    colorText: Colors.white,
                                  );
                                } finally {
                                  EasyLoading.dismiss();
                                }
                              },
                            ),
                          ),
                        // Check if this is an RFQ request
                        Builder(
                          builder: (context) {
                            // Try to get RFQ status from data
                            final futureBookingId = (data.futureBookingId ?? '').toString().trim();
                            
                            return FutureBuilder<DocumentSnapshot?>(
                              future: futureBookingId.isNotEmpty
                                  ? FutureBookingService.futureBookingsRef.doc(futureBookingId).get()
                                  : null,
                              builder: (context, fbSnapshot) {
                                final fbData = fbSnapshot.data?.data() as Map<String, dynamic>?;
                                final rfqStatus = (fbData?['rfq_status'] ?? '').toString().trim();
                                final isRfq = (fbData?['is_rfq'] ?? '').toString().toLowerCase() == 'yes' ||
                                             rfqStatus.isNotEmpty;
                                final canReviewRfq = isRfq && rfqStatus == 'pending_artisan_acceptance';
                                
                                return GestureDetector(
                                  onTap: canReviewRfq && futureBookingId.isNotEmpty && fbData != null
                                      ? () {
                                          Get.to(() => ArtisanRFQReviewScreen(
                                                bookingId: futureBookingId,
                                                bookingData: fbData,
                                              ));
                                        }
                                      : null,
                                  child: Container(
                                    width: double.infinity,
                                    margin: const EdgeInsets.only(bottom: 15),
                                    padding: EdgeInsets.fromLTRB(
                                        8, data.accept == "" ? 24 : 4, 8, 8),
                          decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(8),
                              color: Colors.white,
                              boxShadow: [
                                BoxShadow(
                                    color: Colors.grey.shade300,
                                    offset: const Offset(1, 1),
                                    spreadRadius: 2,
                                    blurRadius: 2)
                              ]),
                          child: ListTile(
                            contentPadding: EdgeInsets.zero,
                            minLeadingWidth: 50,
                            // leading: const CircleAvatar(
                            //   backgroundColor: Colors.white,
                            //   radius: 30,
                            //   backgroundImage: AssetImage("assets/images/no_image.png"),
                            // ),
                            title: Row(
                              children: [
                                data.userId != ""
                                    ? Expanded(
                                        child: StreamBuilder<QuerySnapshot>(
                                          stream: FirebaseService.userRef
                                              .where('uid',
                                                  isEqualTo: data.userId)
                                              .snapshots(),
                                          builder: (context, snapshot) {
                                            if (!snapshot.hasData) {
                                              return noText();
                                            } else {
                                              final userDoc =
                                                  snapshot.data!.docs;
                                              if (userDoc.isEmpty) {
                                                return noText();
                                              } else {
                                                userName =
                                                    userDoc.first["name"];
                                                return Text(
                                                  "Request by:  $userName",
                                                  style: TextStyle(
                                                    color: Colors.black,
                                                    fontWeight: FontWeight.w500,
                                                    fontSize: width * 0.04,
                                                  ),
                                                );
                                              }
                                            }
                                          },
                                        ),
                                      )
                                    : noText(),
                                data.accept == "1" && data.status == "progress"
                                    ? ChatIconWidget(
                                        record: data, isArtisanSide: true)
                                    : const SizedBox()
                              ],
                            ),
                            subtitle: Padding(
                              padding: const EdgeInsets.only(top: 5),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    mainAxisAlignment:
                                        MainAxisAlignment.spaceBetween,
                                    children: [
                                      const Icon(Icons.location_on_outlined,
                                          size: 22, color: Color(0xFFc5a520)),
                                      Expanded(
                                        child: Text(
                                          data.userProvidedAddress ?? "N/A",
                                          textAlign: TextAlign.end,
                                        ),
                                      ),
                                    ],
                                  ),
                                  Divider(
                                      thickness: 0.5,
                                      color: Colors.grey.shade300,
                                      indent: 5,
                                      endIndent: 5),
                                  Row(
                                    mainAxisAlignment:
                                        MainAxisAlignment.spaceBetween,
                                    children: [
                                      const Text('Area'),
                                      Text(data.areaSqMeter == ""
                                          ? "N/A"
                                          : '${data.areaSqMeter} Square Meter'),
                                    ],
                                  ),
                                  // Row(
                                  //   mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                  //   children: [
                                  //     const Text('Cost'),
                                  //     Text('R${data.cost}'),
                                  //   ],
                                  // ),
                                  Row(
                                    mainAxisAlignment:
                                        MainAxisAlignment.spaceBetween,
                                    children: [
                                      const Text('Request at '),
                                      Text(DateFormat('dd/MMM/yyyy hh:mm a')
                                          .format(createdAt)),
                                    ],
                                  ),
                                  if (((data.scheduledDate ?? '')
                                          .trim()
                                          .isNotEmpty) ||
                                      ((data.scheduledTime ?? '')
                                          .trim()
                                          .isNotEmpty))
                                    Row(
                                      mainAxisAlignment:
                                          MainAxisAlignment.spaceBetween,
                                      children: [
                                        Text('Appointment',
                                            style: GoogleFonts.lato(
                                                fontWeight: FontWeight.w700)),
                                        Builder(builder: (_) {
                                          final scheduledDate =
                                              (data.scheduledDate ?? '')
                                                  .toString()
                                                  .trim();
                                          final scheduledTime =
                                              (data.scheduledTime ?? '')
                                                  .toString()
                                                  .trim();
                                          final dt = (scheduledDate
                                                      .isNotEmpty &&
                                                  scheduledTime.isNotEmpty)
                                              ? FutureBookingService
                                                  .tryParseScheduledDateTimePublic(
                                                  scheduledDate,
                                                  scheduledTime,
                                                )
                                              : null;

                                          final label = dt != null
                                              ? DateFormat(
                                                      'dd/MMM/yyyy hh:mm a')
                                                  .format(dt)
                                              : '$scheduledDate ${scheduledTime.isNotEmpty ? scheduledTime : ''}'
                                                  .trim();

                                          return Text(
                                            label,
                                            style: GoogleFonts.lato(
                                                fontWeight: FontWeight.w700),
                                          );
                                        })
                                      ],
                                    ),
                                  Row(
                                    mainAxisAlignment:
                                        MainAxisAlignment.spaceBetween,
                                    children: [
                                      Text('Total Cost',
                                          style: GoogleFonts.lato(
                                              fontWeight: FontWeight.bold)),
                                      Text(
                                          (data.cost == null || data.cost == "" || data.cost == "TBD" || data.cost == "0" || data.cost == "0.00")
                                              ? "Awaiting Quote"
                                              : "R${data.cost}",
                                          style: GoogleFonts.lato(
                                              fontWeight: FontWeight.bold)),
                                    ],
                                  ),
                                  const SizedBox(height: 5),
                                  Row(
                                    mainAxisAlignment:
                                        MainAxisAlignment.spaceBetween,
                                    children: [
                                      const SizedBox(),
                                      Builder(builder: (context) {
                                        final urls = <String>[];
                                        try {
                                          if (data.imageUrls != null &&
                                              data.imageUrls!.isNotEmpty) {
                                            urls.addAll(data.imageUrls!);
                                          }
                                        } catch (_) {}

                                        // Backward-compatible fallback.
                                        if (urls.isEmpty) {
                                          final a =
                                              (data.attachment ?? '').trim();
                                          final b =
                                              (data.additionalAttachment ?? '')
                                                  .trim();
                                          if (a.isNotEmpty) urls.add(a);
                                          if (b.isNotEmpty) urls.add(b);
                                        }

                                        // Keep UI minimal: show up to 3 links.
                                        if (urls.isEmpty) {
                                          return const SizedBox();
                                        }

                                        final display = urls.length > 3
                                            ? urls.sublist(0, 3)
                                            : urls;

                                        return Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.end,
                                          children: [
                                            for (int i = 0;
                                                i < display.length;
                                                i++)
                                              GestureDetector(
                                                onTap: () {
                                                  Get.to(
                                                    () => AttachmentView(
                                                      imagePath: display[i],
                                                    ),
                                                  );
                                                },
                                                child: Padding(
                                                  padding:
                                                      const EdgeInsets.only(
                                                    bottom: 4,
                                                  ),
                                                  child: Row(
                                                    mainAxisSize:
                                                        MainAxisSize.min,
                                                    children: [
                                                      Icon(
                                                        Icons.attachment,
                                                        color: Colors
                                                            .amber.shade500,
                                                      ),
                                                      const SizedBox(width: 5),
                                                      Text(
                                                        'Attachment ${i + 1}',
                                                        style: GoogleFonts.lato(
                                                          fontWeight:
                                                              FontWeight.w700,
                                                          color: Colors
                                                              .amber.shade500,
                                                          fontSize: 14,
                                                        ),
                                                      ),
                                                    ],
                                                  ),
                                                ),
                                              ),
                                          ],
                                        );
                                      }),
                                    ],
                                  ),
                                  Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    mainAxisAlignment:
                                        MainAxisAlignment.spaceBetween,
                                    children: [
                                      data.description == "" ||
                                              data.description == null
                                          ? const SizedBox()
                                          : descriptionWidget(
                                              height, data.description),
                                      data.additionalDescription == null ||
                                              data.additionalDescription == ""
                                          ? const SizedBox()
                                          : descriptionWidget(height,
                                              data.additionalDescription),
                                    ],
                                  ),
                                  const SizedBox(height: 5),
                                  Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        mainAxisAlignment:
                                            MainAxisAlignment.spaceBetween,
                                        children: [
                                          if ((data.orderNo ?? '')
                                              .toString()
                                              .trim()
                                              .isNotEmpty)
                                            Row(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                const Text('Order No. #'),
                                                const SizedBox(width: 6),
                                                Text(
                                                  (data.orderNo ?? '')
                                                      .toString(),
                                                  style: const TextStyle(
                                                      fontWeight:
                                                          FontWeight.w700),
                                                ),
                                              ],
                                            ),
                                          const Text('Order Status'),
                                        ],
                                      ),
                                      const SizedBox(height: 6),
                                      Align(
                                        alignment: Alignment.centerRight,
                                        child: Builder(
                                          builder: (context) {
                                            final statusLower =
                                                (data.status ?? '')
                                                    .toString()
                                                    .trim()
                                                    .toLowerCase();

                                            if (data.accept == '1' &&
                                                (data.paymentStatus ?? '')
                                                    .toString()
                                                    .trim()
                                                    .isEmpty) {
                                              return const Text(
                                                '(Payment is Pending)',
                                                style: TextStyle(
                                                  color: Colors.red,
                                                  fontWeight: FontWeight.w700,
                                                ),
                                              );
                                            }

                                            if (data.accept == '1' &&
                                                (data.status ?? '')
                                                        .toString()
                                                        .trim()
                                                        .toLowerCase() !=
                                                    'closed' &&
                                                (data.status ?? '')
                                                        .toString()
                                                        .trim()
                                                        .toLowerCase() !=
                                                    'completed' &&
                                                ((data.paymentStatus ?? '')
                                                        .toString()
                                                        .trim()
                                                        .toLowerCase() ==
                                                    'paid')) {
                                              return Column(
                                                crossAxisAlignment:
                                                    CrossAxisAlignment.end,
                                                children: [
                                                  const Text(
                                                    '(Payment Transferred)',
                                                    style: TextStyle(
                                                      color: Colors.green,
                                                      fontWeight:
                                                          FontWeight.w700,
                                                    ),
                                                  ),
                                                  const SizedBox(height: 6),
                                                  SizedBox(
                                                    height: 36,
                                                    child: ElevatedButton(
                                                      style: ElevatedButton
                                                          .styleFrom(
                                                        backgroundColor:
                                                            const Color(
                                                                0xFFc5a520),
                                                      ),
                                                      onPressed: () async {
                                                        final uid =
                                                            (data.userId ?? '')
                                                                .toString()
                                                                .trim();
                                                        if (uid.isEmpty) {
                                                          EasyLoading.showError(
                                                              'Missing client id');
                                                          return;
                                                        }

                                                        // Update status to "progress" (in-progress)
                                                        try {
                                                          final docId = (data.id ?? '').toString().trim();
                                                          if (docId.isNotEmpty) {
                                                            await FirebaseService.tasksManagementRef.doc(docId).update({
                                                              'status': 'progress',
                                                              'updated_at': DateTime.now().toString(),
                                                            });
                                                          }
                                                          // Also update future booking if linked
                                                          final fbId = (data.futureBookingId ?? '').toString().trim();
                                                          if (fbId.isNotEmpty) {
                                                            await FutureBookingService.futureBookingsRef.doc(fbId).update({
                                                              'status': 'in_progress',
                                                              'updated_at': DateTime.now().toString(),
                                                            });
                                                          }
                                                        } catch (e) {
                                                          debugPrint('Go to Site status update error: $e');
                                                        }

                                                        // Notify the client
                                                        FutureBookingService.sendNotificationToUser(
                                                          userId: uid,
                                                          title: 'Artisan On The Way',
                                                          message: 'Your artisan is on the way to your site. Track their location in real-time.',
                                                          type: 'artisan_going_to_site',
                                                          data: {
                                                            'type': 'artisan_going_to_site',
                                                            'booking_id': (data.futureBookingId ?? data.id ?? '').toString(),
                                                          },
                                                        ).catchError((e) {
                                                          debugPrint('Go to Site notification error: $e');
                                                        });

                                                        navigateToPage(
                                                          context: context,
                                                          pageName:
                                                              GoogleMapView(
                                                            id: uid,
                                                            name: userName,
                                                            taskRecord: data,
                                                          ),
                                                        );
                                                      },
                                                      child: Text(
                                                        'Go to Site',
                                                        style: GoogleFonts.lato(
                                                          fontWeight:
                                                              FontWeight.w700,
                                                          color: Colors.white,
                                                        ),
                                                      ),
                                                    ),
                                                  ),
                                                ],
                                              );
                                            }

                                            if (data.accept == '1' &&
                                                (data.status ?? '')
                                                        .toString()
                                                        .trim()
                                                        .toLowerCase() ==
                                                    'completed') {
                                              return Container(
                                                padding:
                                                    const EdgeInsets.all(6),
                                                decoration: BoxDecoration(
                                                  color: Colors.grey.shade100,
                                                  border: Border.all(
                                                      color: Colors.grey),
                                                  borderRadius:
                                                      BorderRadius.circular(6),
                                                ),
                                                child: Text(
                                                  'Order ${data.status}',
                                                  style: const TextStyle(
                                                    color: Colors.grey,
                                                    fontWeight: FontWeight.w700,
                                                  ),
                                                ),
                                              );
                                            }

                                            // Accepted but not yet in-progress: show a clear next action label.
                                            if (data.accept == '1' &&
                                                statusLower != 'closed' &&
                                                statusLower != 'completed') {
                                              return Container(
                                                padding:
                                                    const EdgeInsets.all(6),
                                                decoration: BoxDecoration(
                                                  color: Colors.amber.shade50,
                                                  border: Border.all(
                                                      color: Colors
                                                          .amber.shade300),
                                                  borderRadius:
                                                      BorderRadius.circular(6),
                                                ),
                                                child: Text(
                                                  'Go to Site',
                                                  style: GoogleFonts.lato(
                                                    fontWeight: FontWeight.w700,
                                                    color:
                                                        Colors.amber.shade700,
                                                  ),
                                                ),
                                              );
                                            }

                                            // Pending: show Reject/Accept, but keep within the card.
                                            return Row(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                SizedBox(
                                                  height: 36,
                                                  child: ElevatedButton(
                                                    style: ElevatedButton
                                                        .styleFrom(
                                                      backgroundColor:
                                                          Colors.red,
                                                    ),
                                                    onPressed: () async {
                                                      EasyLoading.show(
                                                          status:
                                                              'Loading...!');
                                                      try {
                                                        final requestId =
                                                            (data.id ?? '')
                                                                .toString()
                                                                .trim();
                                                        final toUserId =
                                                            (data.userId ?? '')
                                                                .toString()
                                                                .trim();
                                                        final fromProviderId =
                                                            (data.serviceProviderId ??
                                                                    '')
                                                                .toString()
                                                                .trim();
                                                        final taskId =
                                                            (data.taskId ?? '')
                                                                .toString()
                                                                .trim();

                                                        if (requestId.isEmpty ||
                                                            toUserId.isEmpty ||
                                                            fromProviderId
                                                                .isEmpty) {
                                                          throw Exception(
                                                              'Missing request identifiers. Please refresh and try again.');
                                                        }

                                                        await serviceProviderController
                                                            .responseToRequest(
                                                              id: requestId,
                                                              accept: '0',
                                                              to: toUserId,
                                                              from:
                                                                  fromProviderId,
                                                              taskId: taskId,
                                                            )
                                                            .timeout(
                                                                const Duration(
                                                                    seconds:
                                                                        25));
                                                      } catch (e) {
                                                        Get.snackbar(
                                                          'Error',
                                                          'Could not reject request: $e',
                                                          backgroundColor:
                                                              Colors.red,
                                                          colorText:
                                                              Colors.white,
                                                        );
                                                      } finally {
                                                        EasyLoading.dismiss();
                                                      }
                                                    },
                                                    child: const Text('Reject'),
                                                  ),
                                                ),
                                                const SizedBox(width: 10),
                                                SizedBox(
                                                  height: 36,
                                                  child: ElevatedButton(
                                                    style: ElevatedButton
                                                        .styleFrom(
                                                      backgroundColor:
                                                          Colors.green,
                                                    ),
                                                    onPressed: () async {
                                                      EasyLoading.show(
                                                          status:
                                                              'Loading...!');
                                                      try {
                                                        final requestId =
                                                            (data.id ?? '')
                                                                .toString()
                                                                .trim();
                                                        final toUserId =
                                                            (data.userId ?? '')
                                                                .toString()
                                                                .trim();
                                                        final fromProviderId =
                                                            (data.serviceProviderId ??
                                                                    '')
                                                                .toString()
                                                                .trim();
                                                        final taskId =
                                                            (data.taskId ?? '')
                                                                .toString()
                                                                .trim();

                                                        if (requestId.isEmpty ||
                                                            toUserId.isEmpty ||
                                                            fromProviderId
                                                                .isEmpty) {
                                                          throw Exception(
                                                              'Missing request identifiers. Please refresh and try again.');
                                                        }

                                                        await serviceProviderController
                                                            .responseToRequest(
                                                              id: requestId,
                                                              accept: '1',
                                                              to: toUserId,
                                                              from:
                                                                  fromProviderId,
                                                              taskId: taskId,
                                                            )
                                                            .timeout(
                                                                const Duration(
                                                                    seconds:
                                                                        25));
                                                      } catch (e) {
                                                        Get.snackbar(
                                                          'Error',
                                                          'Could not accept request: $e',
                                                          backgroundColor:
                                                              Colors.red,
                                                          colorText:
                                                              Colors.white,
                                                        );
                                                      } finally {
                                                        EasyLoading.dismiss();
                                                      }
                                                    },
                                                    child: const Text('Accept'),
                                                  ),
                                                ),
                                              ],
                                            );
                                          },
                                        ),
                                      ),
                                    ],
                                  ),
                                  data.status == "progress"
                                      ? GestureDetector(
                                          onTap: () {
                                            log("user_id ${data.userId!}");
                                            // TaskManagementModel record = TaskManagementModel.fromDocument(snapshot.data!.docs[index].data());
                                            navigateToPage(
                                                context: context,
                                                pageName: GoogleMapView(
                                                    id: data.userId!,
                                                    name: userName,
                                                    taskRecord: data));
                                          },
                                          child: Container(
                                            margin:
                                                const EdgeInsets.only(top: 10),
                                            padding: const EdgeInsets.all(5),
                                            decoration: BoxDecoration(
                                                color: Colors.amber.shade50,
                                                borderRadius:
                                                    BorderRadius.circular(5),
                                                border: Border.all(
                                                    color:
                                                        Colors.amber.shade300),
                                                boxShadow: [
                                                  BoxShadow(
                                                    color: Colors.grey.shade200,
                                                    blurRadius: 0.5,
                                                    spreadRadius: 0.5,
                                                  )
                                                ]),
                                            child: Row(
                                              mainAxisAlignment:
                                                  MainAxisAlignment.center,
                                              children: [
                                                Text('Track User',
                                                    style: GoogleFonts.lato(
                                                        fontWeight:
                                                            FontWeight.w700,
                                                        color: Colors
                                                            .amber.shade500,
                                                        fontSize: 16)),
                                                const SizedBox(width: 10),
                                                Image.asset(
                                                    'assets/images/track.png',
                                                    height: 30)
                                                // Icon(Icons.map_outlined)
                                              ],
                                            ),
                                          ),
                                        )
                                      : const SizedBox(),
                                  data.status == "progress" &&
                                          data.artisanImages != "2"
                                      ? Column(
                                          children: [
                                            const SizedBox(height: 10),
                                            AnimatedSwitcher(
                                              duration:
                                                  const Duration(seconds: 2),
                                              child: Obx(() =>
                                                  serviceProviderController
                                                          .showNotedField.value
                                                      ? Card(
                                                          elevation: 2,
                                                          color: Colors.white,
                                                          child: TextField(
                                                            controller:
                                                                _notesFor(data.id ?? 'unknown_$index'),
                                                            cursorColor:
                                                                Colors.black,
                                                            style: GoogleFonts
                                                                .roboto(
                                                                    fontSize:
                                                                        12),
                                                            decoration:
                                                                InputDecoration(
                                                              labelText:
                                                                  'Add Notes',
                                                              labelStyle: GoogleFonts.roboto(
                                                                  color: const Color(
                                                                      0xffACADB9),
                                                                  fontSize:
                                                                      width *
                                                                          0.04),
                                                              border:
                                                                  InputBorder
                                                                      .none,
                                                              focusedBorder:
                                                                  const OutlineInputBorder(
                                                                borderSide: BorderSide(
                                                                    color: Colors
                                                                        .white),
                                                              ),
                                                              filled: true,
                                                              fillColor:
                                                                  Colors.white,
                                                              prefixIcon: Icon(
                                                                Icons
                                                                    .description,
                                                                color: const Color(
                                                                    0xffACADB9),
                                                                size: width *
                                                                    0.07,
                                                              ),
                                                              contentPadding:
                                                                  const EdgeInsets
                                                                      .symmetric(
                                                                      vertical:
                                                                          5.0,
                                                                      horizontal:
                                                                          10.0),
                                                            ),
                                                          ),
                                                        )
                                                      : SizedBox(
                                                          height: height * 0.05,
                                                          width: width,
                                                          child: PrimaryButton(
                                                            title: 'Add Notes',
                                                            radius: 5,
                                                            onPressed: () =>
                                                                serviceProviderController
                                                                    .showNotedField
                                                                    .value = true,
                                                          ),
                                                        )),
                                            ),
                                          ],
                                        )
                                      : const SizedBox(),
                                  const SizedBox(height: 5),
                                  (statusLower == 'progress' ||
                                          statusLower == 'in_progress' ||
                                          statusLower == 'in progress')
                                      ? Row(
                                          mainAxisAlignment:
                                              MainAxisAlignment.spaceBetween,
                                          children: [
                                            MyImagePickerCard(
                                              icon: artisanImagesNorm == '0'
                                                  ? Icons.upload
                                                  : Icons.attachment,
                                              color: artisanImagesNorm == '0'
                                                  ? Colors.blue.shade500
                                                  : Colors.grey.shade500,
                                              title: 'Before Work',
                                              onTap: () {
                                                serviceProviderController
                                                    .currentRequest
                                                    .value = index.toString();
                                                if (artisanImagesNorm == '0') {
                                                  if (_notesFor(data.id ?? 'unknown_$index').text ==
                                                      "") {
                                                    EasyLoading.showError(
                                                        'Add Notes First');
                                                  } else {
                                                    serviceProviderController
                                                        .isBeforeWorkImage
                                                        .value = true;
                                                    serviceProviderController
                                                        .showChoiceDialog(
                                                            context);
                                                  }
                                                } else {
                                                  EasyLoading.show(
                                                      status:
                                                          'Please Wait...!');
                                                  FirebaseService
                                                      .artisanTaskImages
                                                      .where(
                                                          'task_management_id',
                                                          isEqualTo: data.id)
                                                      .where('before_work',
                                                          isNotEqualTo: "")
                                                      .get()
                                                      .then((value) {
                                                    EasyLoading.dismiss();
                                                    if (value.docs.isNotEmpty) {
                                                      // debugPrint("${value.docs.first["before_work"]}");
                                                      Get.to(() => AttachmentView(
                                                          imagePath: value
                                                                  .docs.first[
                                                              "before_work"]));
                                                    } else {
                                                      EasyLoading.showError(
                                                          'Attachment not found!');
                                                    }
                                                  });
                                                }
                                              },
                                            ),
                                            MyImagePickerCard(
                                              icon: artisanImagesNorm == '1' ||
                                                      artisanImagesNorm == '0'
                                                  ? Icons.upload
                                                  : Icons.attachment,
                                              color: artisanImagesNorm == '1'
                                                  ? Colors.green.shade500
                                                  : Colors.grey.shade500,
                                              title: 'After Work',
                                              onTap: () {
                                                serviceProviderController
                                                    .currentRequest
                                                    .value = index.toString();
                                                if (artisanImagesNorm == '1') {
                                                  if (_notesFor(data.id ?? 'unknown_$index').text ==
                                                      "") {
                                                    EasyLoading.showError(
                                                        'Add Notes First');
                                                  } else {
                                                    serviceProviderController
                                                        .isBeforeWorkImage
                                                        .value = false;
                                                    serviceProviderController
                                                        .showChoiceDialog(
                                                            context);
                                                  }
                                                } else if (artisanImagesNorm ==
                                                    '0') {
                                                  EasyLoading.showError(
                                                      'Upload Before Work image first');
                                                } else {
                                                  EasyLoading.show(
                                                      status:
                                                          'Please Wait...!');
                                                  FirebaseService
                                                      .artisanTaskImages
                                                      .where(
                                                          'task_management_id',
                                                          isEqualTo: data.id)
                                                      .where('after_work',
                                                          isNotEqualTo: "")
                                                      .get()
                                                      .then((value) {
                                                    EasyLoading.dismiss();
                                                    if (value.docs.isNotEmpty) {
                                                      Get.to(() => AttachmentView(
                                                          imagePath: value
                                                                  .docs.first[
                                                              "after_work"]));
                                                    } else {
                                                      EasyLoading.showError(
                                                          'Attachment not found!');
                                                    }
                                                  });
                                                }
                                              },
                                            ),
                                          ],
                                        )
                                      : const SizedBox(),

                                  Obx(() {
                                    final current = serviceProviderController
                                        .currentRequest.value
                                        .toString();
                                    if (current.isEmpty) {
                                      return const SizedBox();
                                    }
                                    if (serviceProviderController
                                            .imageProvider.value ==
                                        null) {
                                      return const SizedBox();
                                    }
                                    final currentIndex = int.tryParse(current);
                                    if (currentIndex == null ||
                                        currentIndex != index) {
                                      return const SizedBox();
                                    }

                                    return Column(
                                      children: [
                                        const SizedBox(height: 5),
                                        Stack(
                                          clipBehavior: Clip.none,
                                          alignment: Alignment.center,
                                          children: [
                                            ClipRRect(
                                              borderRadius:
                                                  BorderRadius.circular(8),
                                              child: Image.file(
                                                File(serviceProviderController
                                                    .imageProvider.value!.path),
                                                fit: BoxFit.cover,
                                                height: 150,
                                                width: width,
                                              ),
                                            ),
                                            Obx(() => serviceProviderController
                                                    .isUploading.value
                                                ? Positioned(
                                                    child:
                                                        CircularProgressIndicator(
                                                            color: Colors.amber
                                                                .shade500))
                                                : const SizedBox())
                                          ],
                                        ),
                                        const SizedBox(height: 10),
                                        SizedBox(
                                          height: height * 0.05,
                                          child: PrimaryButton(
                                            radius: 5,
                                            fontSize: 12,
                                            title: serviceProviderController
                                                    .isUploading.value
                                                ? "Uploading....!"
                                                : 'Upload Image',
                                            onPressed: () async {
                                              final to = (data.userId ?? '')
                                                  .toString()
                                                  .trim();
                                              final taskId = (data.id ?? '')
                                                  .toString()
                                                  .trim();
                                              final notesCtrl = _notesFor(data.id ?? 'unknown_$index');
                                              final notes =
                                                  notesCtrl.text.trim();

                                              if (to.isEmpty ||
                                                  taskId.isEmpty) {
                                                EasyLoading.showError(
                                                    'Invalid request');
                                                return;
                                              }
                                              if (notes.isEmpty) {
                                                EasyLoading.showError(
                                                    'Add Notes First');
                                                return;
                                              }

                                              final isBefore =
                                                  serviceProviderController
                                                      .isBeforeWorkImage.value;
                                              final referId =
                                                  (data.artisanImageDocId ?? '')
                                                      .toString()
                                                      .trim();
                                              if (!isBefore &&
                                                  referId.isEmpty) {
                                                EasyLoading.showError(
                                                    'Upload Before Work image first');
                                                return;
                                              }

                                              try {
                                                await serviceProviderController
                                                    .saveBeforeAndAfterImage(
                                                  to: to,
                                                  referId: referId,
                                                  taskId: taskId,
                                                  notes: notes,
                                                );
                                                notesCtrl.clear();
                                                serviceProviderController
                                                    .showNotedField
                                                    .value = false;
                                              } catch (e) {
                                                EasyLoading.showError(
                                                    'Upload failed: $e');
                                              }
                                            },
                                            color: Colors.green.shade500,
                                          ),
                                        )
                                      ],
                                    );
                                  }),
                                ],
                              ),
                            ),
                          ),
                        )  // Closes Container
                      );  // Closes GestureDetector return statement
                    },  // Closes FutureBuilder builder
                  );  // Closes FutureBuilder
                },  // Closes Builder builder
              ),  // Closes Builder
                        Positioned(
                          child: data.accept == ""
                              ? Container(
                                  alignment: Alignment.center,
                                  width: width * 0.50,
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 10, vertical: 5),
                                  decoration: const BoxDecoration(
                                    borderRadius: BorderRadius.only(
                                      bottomLeft: Radius.circular(12),
                                      bottomRight: Radius.circular(12),
                                    ),
                                    gradient: LinearGradient(
                                      begin: Alignment.centerLeft,
                                      end: Alignment.centerRight,
                                      colors: [
                                        Color(0xFFe5c958),
                                        Color(0xFFc5a520),
                                      ],
                                    ),
                                  ),
                                  child: TaskTimerCard(
                                    createdAt: createdAt,
                                    controller: serviceProviderController,
                                  ),
                                )
                              : const SizedBox(),
                        ),
                      ],  // Close Stack children
                    );  // Close Stack return statement
                  },  // Close itemBuilder lambda
                );  // Close ListView.builder
              }),  // Close Obx lambda
            )  // Close Obx widget
          ],
        ),
      ),
    );
  }
}

Widget noText({String? text, TextAlign? align}) => Text(text ?? "N/A",
    textAlign: align ?? TextAlign.end,
    style: GoogleFonts.lato(
      color: Colors.black,
      fontWeight: FontWeight.w500,
      fontSize: 14,
    ));

class TaskTimerCard extends StatefulWidget {
  final DateTime createdAt;
  final ServiceProviderController controller;

  const TaskTimerCard(
      {super.key, required this.createdAt, required this.controller});

  @override
  _TaskTimerCardState createState() => _TaskTimerCardState();
}

class _TaskTimerCardState extends State<TaskTimerCard> {
  late Timer timer;
  static const Duration _window = Duration(seconds: 60);
  Duration remainingTime = _window; // Initial duration

  @override
  void initState() {
    super.initState();
    startTimer();
  }

  void startTimer() {
    timer = Timer.periodic(const Duration(seconds: 1), (Timer t) {
      setState(() {
        final now = DateTime.now().add(const Duration(seconds: 1));
        final difference = now.difference(widget.createdAt);
        final next = _window - difference;
        remainingTime = next.isNegative ? Duration.zero : next;

        if (remainingTime.inSeconds <= 0) {
          t.cancel();
          widget.controller.stopMusic();
        }
      });
    });
  }

  @override
  void dispose() {
    timer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    String formattedTime = remainingTime.inSeconds.toString().padLeft(2, '0');

    return Text('Remaining: $formattedTime seconds',
        style: GoogleFonts.lato(color: Colors.black, fontSize: 12));
  }
}

class MyImagePickerCard extends StatelessWidget {
  final String title;
  final Color color;
  final Function() onTap;
  final IconData icon;
  const MyImagePickerCard(
      {super.key,
      required this.title,
      required this.color,
      required this.onTap,
      required this.icon});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        GestureDetector(
          onTap: onTap,
          child: Container(
            margin: const EdgeInsets.only(bottom: 5, top: 5),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
                color: color.withOpacity(0.2),
                borderRadius: BorderRadius.circular(5),
                border: Border.all(color: color)),
            child: Icon(icon, color: color),
          ),
        ),
        Text(title, style: GoogleFonts.lato(color: color, fontSize: 12))
      ],
    );
  }
}

Widget descriptionWidget(height, String? text) => Expanded(
    child: Container(
        height: text != null && text.length > 50 ? height * 0.15 : null,
        margin: const EdgeInsets.symmetric(horizontal: 4),
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: Colors.grey.shade300, width: 1)),
        child: SingleChildScrollView(child: Text(text ?? ""))));
