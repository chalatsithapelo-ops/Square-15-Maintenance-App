import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_easyloading/flutter_easyloading.dart';
import 'package:flutter_rating_bar/flutter_rating_bar.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:get/get.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';
import 'package:maintenanceapp/controller/app_controller.dart';
import 'package:maintenanceapp/model/task_management_model.dart';
import 'package:maintenanceapp/screens/home/booking/attachment_view.dart';
import 'package:maintenanceapp/screens/home/booking/google_map_view.dart';
import 'package:maintenanceapp/screens/home/booking/payment_method_sheet.dart';
import 'package:maintenanceapp/screens/home/payment_method_view.dart';
import 'package:maintenanceapp/screens/service_provider_panel/service_provider_request_screen.dart';
import 'package:maintenanceapp/services/firestore_services/firebase_services.dart';
import 'package:maintenanceapp/services/deposit_service.dart';
import 'package:maintenanceapp/utils/dotted_line.dart';
import 'package:maintenanceapp/utils/helper.dart';
import 'package:maintenanceapp/utils/navigation.dart';

import 'booking_detail_page.dart';
import 'chat_screen.dart';
import 'create_future_booking_screen.dart';
import 'future_bookings_list_screen.dart';
import 'client_calendar_screen.dart';
import 'package:maintenanceapp/screens/home/widgets/predictive_maintenance_card.dart';

class booking extends StatefulWidget {
  const booking({super.key});

  @override
  State<booking> createState() => _bookingState();
}

class _bookingState extends State<booking> {
  int _currentPage = 0;
  final _pageController = PageController();
  final AppController appController = Get.find();
  late Stream<List<QueryDocumentSnapshot<Map<String, dynamic>>>> queryDocs;

  List<String> _candidateUserIds() {
    final ids = <String>{};
    final a = appController.userId.value.toString().trim();
    if (a.isNotEmpty) ids.add(a);
    final b = (FirebaseAuth.instance.currentUser?.uid ?? '').toString().trim();
    if (b.isNotEmpty) ids.add(b);
    return ids.toList(growable: false);
  }

  Stream<List<QueryDocumentSnapshot<Map<String, dynamic>>>> _buildQueryDocs({
    required bool closed,
  }) {
    final ids = _candidateUserIds();
    if (ids.isEmpty) {
      return Stream.value(<QueryDocumentSnapshot<Map<String, dynamic>>>[]);
    }

    // Some historical orders store ownership under uid/userId instead of user_id.
    // Query all known ownership fields and merge client-side.
    final effectiveIds = ids.take(10).toList(growable: false);

    Stream<List<QueryDocumentSnapshot<Map<String, dynamic>>>> byField(
        String field) {
      Query<Map<String, dynamic>> q = FirebaseService.tasksManagementRef;
      if (effectiveIds.length == 1) {
        q = q.where(field, isEqualTo: effectiveIds.first);
      } else {
        q = q.where(field, whereIn: effectiveIds);
      }
      // Avoid whereIn + orderBy requiring composite indexes; sort client-side.
      return q.snapshots().map((s) => s.docs);
    }

    return _mergeDocStreams(<Stream<
        List<QueryDocumentSnapshot<Map<String, dynamic>>>>>[
      byField('user_id'),
      byField('uid'),
      byField('userId'),
    ]);
  }

  Stream<List<QueryDocumentSnapshot<Map<String, dynamic>>>> _mergeDocStreams(
    List<Stream<List<QueryDocumentSnapshot<Map<String, dynamic>>>>> streams,
  ) {
    if (streams.isEmpty) {
      return Stream.value(<QueryDocumentSnapshot<Map<String, dynamic>>>[]);
    }
    if (streams.length == 1) return streams.first;

    final latest =
        List<List<QueryDocumentSnapshot<Map<String, dynamic>>>>.generate(
      streams.length,
      (_) => const <QueryDocumentSnapshot<Map<String, dynamic>>>[],
      growable: false,
    );
    final subs = <StreamSubscription<
        List<QueryDocumentSnapshot<Map<String, dynamic>>>>>[];

    late final StreamController<
        List<QueryDocumentSnapshot<Map<String, dynamic>>>> controller;
    controller =
        StreamController<List<QueryDocumentSnapshot<Map<String, dynamic>>>>(
      onListen: () {
        void emit() {
          final byId = <String, QueryDocumentSnapshot<Map<String, dynamic>>>{};
          for (final list in latest) {
            for (final d in list) {
              byId[d.id] = d;
            }
          }
          final merged = byId.values.toList(growable: false);
          merged.sort((a, b) {
            DateTime parse(dynamic v) {
              if (v is Timestamp) return v.toDate();
              final s = (v ?? '').toString();
              return DateTime.tryParse(s) ?? DateTime.fromMillisecondsSinceEpoch(0);
            }

            final adt = parse(a.data()['creation_date']);
            final bdt = parse(b.data()['creation_date']);
            return bdt.compareTo(adt);
          });
          if (!controller.isClosed) controller.add(merged);
        }

        for (var i = 0; i < streams.length; i++) {
          subs.add(streams[i].listen(
            (docs) {
              latest[i] = docs;
              emit();
            },
            onError: (e, st) {
              // Best-effort: keep rendering other query results.
              debugPrint('booking query stream error: $e');
              emit();
            },
          ));
        }
      },
      onCancel: () async {
        for (final s in subs) {
          await s.cancel();
        }
      },
    );

    return controller.stream;
  }

  @override
  void initState() {
    super.initState();
    queryDocs = _buildQueryDocs(closed: false);
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }



  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    final height = MediaQuery.of(context).size.height;

    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.start,
          children: [
            Container(
              width: double.infinity,
              height: height * 0.15,
              padding: const EdgeInsets.only(left: 20, right: 20),
              decoration: const BoxDecoration(
                borderRadius: BorderRadius.only(
                  bottomLeft: Radius.circular(40),
                  bottomRight: Radius.circular(40),
                ),
                gradient: LinearGradient(
                  begin: Alignment.centerLeft,
                  end: Alignment.centerRight,
                  colors: [
                    Color(0xFFe5c958), // #e5c958
                    Color(0xFFc5a520), // #c5a520
                  ],
                ),
              ),
              child: Stack(
                children: [
                  Center(
                    child: Text(
                      'Booking',
                      style: GoogleFonts.roboto(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                        fontSize: width * 0.06,
                      ),
                    ),
                  ),
                  if (_currentPage == 2)
                    Positioned(
                      right: 0,
                      top: 0,
                      bottom: 0,
                      child: IconButton(
                        tooltip: 'Calendar',
                        onPressed: () {
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => const ClientCalendarScreen(),
                            ),
                          );
                        },
                        icon: const Icon(Icons.calendar_month,
                            color: Colors.white),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            Expanded(
              child: Column(
                children: [
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        GestureDetector(
                          onTap: () {
                            setState(() => _currentPage = 0);
                            queryDocs = _buildQueryDocs(closed: false);
                          },
                          child: Container(
                            alignment: Alignment.center,
                            height: height * 0.06,
                            width: width * 0.25,
                            padding: const EdgeInsets.all(4),
                            decoration: BoxDecoration(
                                color: _currentPage == 0
                                    ? const Color(0xFFc5a520)
                                    : const Color(0xff868686),
                                borderRadius: BorderRadius.circular(5)),
                            child: Text(
                              'Current',
                              style: GoogleFonts.roboto(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w400,
                                  fontSize: width * 0.05),
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        GestureDetector(
                          onTap: () {
                            setState(() => _currentPage = 1);
                            queryDocs = _buildQueryDocs(closed: true);
                          },
                          child: Container(
                            alignment: Alignment.center,
                            height: height * 0.06,
                            width: width * 0.25,
                            padding: const EdgeInsets.all(4),
                            decoration: BoxDecoration(
                                color: _currentPage == 1
                                    ? const Color(0xFFc5a520)
                                    : const Color(0xff868686),
                                borderRadius: BorderRadius.circular(5)),
                            child: Text(
                              'Past',
                              style: GoogleFonts.roboto(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w400,
                                  fontSize: width * 0.05),
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        GestureDetector(
                          onTap: () {
                            setState(() => _currentPage = 2);
                          },
                          child: Container(
                            alignment: Alignment.center,
                            height: height * 0.06,
                            width: width * 0.25,
                            padding: const EdgeInsets.all(4),
                            decoration: BoxDecoration(
                                color: _currentPage == 2
                                    ? const Color(0xFFc5a520)
                                    : const Color(0xff868686),
                                borderRadius: BorderRadius.circular(5)),
                            child: Text(
                              'Future',
                              style: GoogleFonts.roboto(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w400,
                                  fontSize: width * 0.05),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 10),
                  // AI Predictive Maintenance alerts
                  if (_currentPage == 0) const PredictiveMaintenanceCard(),
                  Expanded(
                    child: _currentPage == 2
                        ? const FutureBookingsListScreen()
                        : GeneralMaintenancePage(
                            queryBy: queryDocs,
                            closedMode: _currentPage == 1,
                            includeFutureBookingBridges: _currentPage == 1,
                          ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      floatingActionButton: _currentPage == 2
          ? FloatingActionButton.extended(
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => const CreateFutureBookingScreen(),
                  ),
                );
              },
              backgroundColor: const Color(0xFFc5a520),
              icon: const Icon(Icons.add, color: Colors.white),
              label: Text('Schedule',
                  style: GoogleFonts.roboto(color: Colors.white)),
            )
          : null,
    );
  }
}

// ── Top-level helpers used by GeneralMaintenancePage ──

Widget _trackingStep(String label, bool active) {
  return Column(
    children: [
      Icon(
        active ? Icons.check_circle : Icons.radio_button_unchecked,
        size: 16,
        color: active ? Colors.green.shade600 : Colors.grey.shade400,
      ),
      const SizedBox(height: 2),
      Text(label,
          style: GoogleFonts.lato(
              fontSize: 9,
              fontWeight: active ? FontWeight.bold : FontWeight.normal,
              color: active ? Colors.green.shade700 : Colors.grey)),
    ],
  );
}

Widget _trackingLine(bool active) {
  return Expanded(
    child: Container(
      height: 2,
      margin: const EdgeInsets.only(bottom: 14),
      color: active ? Colors.green.shade400 : Colors.grey.shade300,
    ),
  );
}

Widget _buildBalancePaymentButton(
    TaskManagementModel record, BuildContext context, AppController appController) {
  return FutureBuilder<Map<String, dynamic>?>(
    future: DepositService.getDepositInfo(record.id ?? ''),
    builder: (context, snapshot) {
      final info = snapshot.data;
      final balanceAmount = (info?['balance_amount'] as double?) ?? 0;
      return Column(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            margin: const EdgeInsets.only(bottom: 6),
            decoration: BoxDecoration(
              color: Colors.teal.shade50,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.teal.shade400),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Icon(Icons.check_circle, color: Colors.green.shade600, size: 18),
                  const SizedBox(width: 6),
                  Text('Deposit paid — Job completed!',
                      style: GoogleFonts.lato(
                          fontWeight: FontWeight.bold,
                          fontSize: 12,
                          color: Colors.green.shade700)),
                ]),
                const SizedBox(height: 4),
                Text(
                  'Pay the remaining balance of R${balanceAmount.toStringAsFixed(2)} to complete and rate the artisan.',
                  style: GoogleFonts.lato(fontSize: 11, color: Colors.teal.shade700),
                ),
              ],
            ),
          ),
          GestureDetector(
            onTap: () async {
              appController.getUser(id: appController.userId.value);
              showModalBottomSheet(
                shape: const RoundedRectangleBorder(
                  borderRadius: BorderRadius.only(
                      topLeft: Radius.circular(16),
                      topRight: Radius.circular(16)),
                ),
                context: context,
                builder: (BuildContext ctx) {
                  return _BalancePaymentSheet(
                    record: record,
                    balanceAmount: balanceAmount,
                  );
                },
              );
            },
            child: Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: Colors.teal.shade700,
                borderRadius: BorderRadius.circular(5),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    'Pay Balance R${balanceAmount.toStringAsFixed(2)}',
                    style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w500,
                        color: Colors.white),
                  ),
                  const SizedBox(width: 5),
                  const Icon(Icons.payment, color: Colors.white),
                ],
              ),
            ),
          ),
        ],
      );
    },
  );
}

class GeneralMaintenancePage extends StatelessWidget {
  final Stream<List<QueryDocumentSnapshot<Map<String, dynamic>>>> queryBy;
  final bool includeFutureBookingBridges;
  final bool closedMode;
  const GeneralMaintenancePage({
    super.key,
    required this.queryBy,
    required this.closedMode,
    this.includeFutureBookingBridges = false,
  });

  @override
  Widget build(BuildContext context) {
    final AppController appController = Get.find();
    final width = MediaQuery.of(context).size.width;
    final height = MediaQuery.of(context).size.height;
    final TextEditingController feedBackController = TextEditingController();
    return Container(
      color: Colors.white,
      child: StreamBuilder(
            stream: queryBy,
            builder: (context, snapshot) {
              debugPrint(
                  "record ${snapshot.data != null ? snapshot.data!.length : "N/A"}");
              if (snapshot.hasError) {
                return Center(child: noText(text: 'Failed to load bookings'));
              }
              if (!snapshot.hasData) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }
                return Center(child: noText(text: 'No Request Available'));
              }

              final filteredDocs = snapshot.data!.where((d) {
                  final data = d.data();
                  final record = TaskManagementModel.fromDocument(
                    data,
                    docId: d.id,
                  );

                  // Cancelled should not appear in any tabs.
                  if (record.isCancelledLike) return false;

                  final accept = (record.accept ?? '').toString().trim();
                  final isClosed = record.isClosedLike;

                  final statusLower =
                      (record.status ?? '').toString().trim().toLowerCase();
                  final source =
                      (record.source ?? '').toString().trim().toLowerCase();

                  // Future booking bridge tasksManagement docs exist for scheduled bookings.
                  // Keep them in Future tab until they transition to in-progress/closed.
                  // For 'future_booking' source, require future_booking_id.
                  // For 'whatsapp'/'whatsapp_rfq' source, ALWAYS treat as bridge
                  // (the main WA doc has no future_booking_id but is managed via futureBookings).
                  final futureBookingId =
                      (record.futureBookingId ?? '').toString().trim();
                  final isBridgeRecord =
                      (source == 'future_booking' && futureBookingId.isNotEmpty) ||
                      source == 'whatsapp' ||
                      source == 'whatsapp_rfq';
                  if (!includeFutureBookingBridges && isBridgeRecord) {
                    final isNowActive = statusLower == 'progress' ||
                        statusLower == 'in_progress' ||
                        statusLower == 'in progress' ||
                        statusLower == 'closed' ||
                        statusLower == 'completed';
                    if (!isNowActive) return false;
                  }

                  if (closedMode) {
                    // Past: show accepted & closed/completed.
                    if (accept != '1') return false;
                    if (!isClosed) return false;
                  } else {
                    // Current: exclude closed/completed.
                    if (isClosed) return false;
                  }

                  return true;
                }).toList(growable: false);

              return filteredDocs.isNotEmpty
                    ? ListView.builder(
                        physics: const ClampingScrollPhysics(),
                        itemCount: filteredDocs.length,
                        itemBuilder: (context, index) {
                          final doc = filteredDocs[index];
                          TaskManagementModel record =
                              TaskManagementModel.fromDocument(
                            doc.data(),
                            docId: doc.id,
                          );

                          final updatedRaw = (record.updatedAt ??
                                  record.creationDate ??
                                  DateTime.now().toString())
                              .toString();
                          final updatedDt =
                              DateTime.tryParse(updatedRaw) ?? DateTime.now();
                          final diff = DateTime.now().difference(updatedDt);
                          final minutes = diff.inMinutes;
                          final hours = diff.inHours;
                          final days = diff.inDays;
                          final months = (days / 30).floor();
                          return Container(
                              width: double.infinity,
                              margin: const EdgeInsets.symmetric(
                                  horizontal: 10, vertical: 10),
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 20, vertical: 10),
                              decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(12),
                                  color: Colors.white,
                                  // border: Border.all(color: Colors.grey, width: 0.2)
                                  boxShadow: [
                                    BoxShadow(
                                      color: Colors.grey.shade300,
                                      offset: const Offset(1, 1),
                                      spreadRadius: 0.3,
                                    ),
                                    BoxShadow(
                                      color: Colors.grey.shade300,
                                      offset: const Offset(-1, -1),
                                      spreadRadius: 0.3,
                                    ),
                                  ]),
                              child: ListTile(
                                contentPadding: EdgeInsets.zero,
                                minLeadingWidth: 50,
                                // leading: CircleAvatar(
                                //   radius: 30,
                                //   backgroundImage:
                                //   AssetImage("assets/images/artisan.png"),
                                // ),
                                subtitle: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        Text("Order No. #",
                                            style: GoogleFonts.lato(
                                                fontSize: 12,
                                                fontWeight: FontWeight.bold)),
                                        Text(record.orderNo.toString(),
                                            style:
                                                GoogleFonts.lato(fontSize: 12)),
                                      ],
                                    ),
                                    const SizedBox(height: 5),
                                    Row(
                                      mainAxisAlignment:
                                          MainAxisAlignment.spaceBetween,
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text("Task Created for following jobs",
                                            style:
                                                GoogleFonts.lato(fontSize: 12)),
                                        Row(
                                          mainAxisAlignment:
                                              MainAxisAlignment.end,
                                          children: [
                                            Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                Text('Last Updated',
                                                    style: GoogleFonts.lato(
                                                        fontSize: 12)),
                                                Text(
                                                  minutes <= 59
                                                      ? "$minutes minutes ago"
                                                      : hours <= 24
                                                          ? "$hours hours ago"
                                                          : days < 30
                                                              ? "$days day${days > 1 ? 's' : ''} ago"
                                                              : "$months month${months > 1 ? 's' : ''} ago",
                                                  style: GoogleFonts.lato(
                                                      fontSize: 12),
                                                ),
                                              ],
                                            ),
                                          ],
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 5),
                                    StreamBuilder<QuerySnapshot>(
                                        stream: FirebaseService
                                            .tasksManagementRef
                                            .doc(record.id)
                                            .collection('jobs')
                                            .snapshots(),
                                        builder: (context, snapshot) {
                                          if (!snapshot.hasData) {
                                            return Center(
                                                child: noText(
                                                    align: TextAlign.start));
                                          } else {
                                            if (snapshot.data!.docs.isEmpty) {
                                              return noText(
                                                  align: TextAlign.start);
                                            } else {
                                              return SingleChildScrollView(
                                                scrollDirection:
                                                    Axis.horizontal,
                                                child: Row(
                                                  children: List.generate(
                                                      snapshot.data!.docs
                                                          .length, (index) {
                                                    return StreamBuilder(
                                                        stream: FirebaseService
                                                            .taskRef
                                                            .doc(snapshot.data!
                                                                    .docs[index]
                                                                ["task_id"])
                                                            .snapshots(),
                                                        builder: (context,
                                                            taskSnapshot) {
                                                          if (!taskSnapshot
                                                              .hasData) {
                                                            return Center(
                                                                child: noText(
                                                                    align: TextAlign
                                                                        .start));
                                                          } else {
                                                            // Get job data for fallback
                                                            final jobData = snapshot.data!.docs[index];
                                                            final jobMap = jobData.data() as Map<String, dynamic>;
                                                            final jobName = (jobMap['name'] ?? jobMap['description'] ?? '').toString();
                                                            final jobCost = (jobMap['cost'] ?? '0').toString();
                                                            
                                                            // Use task data if available, otherwise use job data as fallback
                                                            final taskData = taskSnapshot.data!.data();
                                                            final displayName = (taskData != null && taskData['name'] != null && taskData['name'].toString().isNotEmpty) 
                                                                ? taskData['name'].toString() 
                                                                : (jobName.isNotEmpty ? jobName : "N/A");
                                                            final displayCost = (taskData != null && taskData['cost'] != null && taskData['cost'].toString().isNotEmpty)
                                                                ? taskData['cost'].toString()
                                                                : jobCost;
                                                            
                                                            if(displayName == "N/A" && displayCost == "0"){
                                                              return Center(child: noText(align: TextAlign.start));
                                                            }
                                                            else {
                                                              return GestureDetector(
                                                                onTap: () {
                                                                  debugPrint(
                                                                      "clicked");
                                                                  Get.to(() => BookingDetailPage(
                                                                      pageName:
                                                                          'Booking',
                                                                      requestId:
                                                                          record
                                                                              .id
                                                                              .toString(),
                                                                      data: snapshot
                                                                              .data!
                                                                              .docs[
                                                                          index],
                                                                      taskName: displayName));
                                                                },
                                                                child:
                                                                    Container(
                                                                  padding:
                                                                      EdgeInsets
                                                                          .all(
                                                                              8),
                                                                  margin:
                                                                      const EdgeInsets
                                                                          .only(
                                                                          right:
                                                                              8,
                                                                          bottom:
                                                                              5),
                                                                  decoration: BoxDecoration(
                                                                      borderRadius:
                                                                          BorderRadius.circular(
                                                                              8),
                                                                      color: Colors
                                                                          .white,
                                                                      boxShadow: [
                                                                        BoxShadow(
                                                                            color: Colors
                                                                                .grey.shade200,
                                                                            offset: const Offset(
                                                                                1, 1),
                                                                            spreadRadius:
                                                                                2,
                                                                            blurRadius:
                                                                                2)
                                                                      ]),
                                                                  child: Column(
                                                                    crossAxisAlignment:
                                                                        CrossAxisAlignment
                                                                            .start,
                                                                    children: [
                                                                      Container(
                                                                        padding: const EdgeInsets
                                                                            .symmetric(
                                                                            horizontal:
                                                                                4,
                                                                            vertical:
                                                                                2),
                                                                        margin: const EdgeInsets
                                                                            .only(
                                                                            right:
                                                                                8,
                                                                            bottom:
                                                                                5),
                                                                        decoration: BoxDecoration(
                                                                            color:
                                                                                Colors.grey.shade100,
                                                                            borderRadius: BorderRadius.circular(3),
                                                                            border: Border.all(color: Colors.grey.shade700)),
                                                                        child:
                                                                            Row(
                                                                          children: [
                                                                            Container(
                                                                              margin: const EdgeInsets.only(right: 5),
                                                                              padding: const EdgeInsets.all(5),
                                                                              decoration: BoxDecoration(color: Colors.grey.shade500, shape: BoxShape.circle),
                                                                            ),
                                                                            Text(displayName,
                                                                                textAlign: TextAlign.start,
                                                                                style: GoogleFonts.lato(fontSize: 14, color: Colors.grey.shade700, fontWeight: FontWeight.w600)),
                                                                          ],
                                                                        ),
                                                                      ),
                                                                      snapshot.data!.docs[index]["description"] == "" ||
                                                                              snapshot.data!.docs[index]["description"] ==
                                                                                  null
                                                                          ? SizedBox
                                                                              .shrink()
                                                                          : Text(
                                                                              snapshot.data!.docs[index]["description"] ?? "N/A",
                                                                              textAlign: TextAlign.start,
                                                                              style: GoogleFonts.lato(fontSize: 12, color: Colors.grey.shade700)),
                                                                      displayCost == "" || displayCost == "0"
                                                                          ? SizedBox
                                                                              .shrink()
                                                                          : Text(
                                                                              "R$displayCost",
                                                                              textAlign: TextAlign.start,
                                                                              style: GoogleFonts.lato(fontSize: 12, color: Colors.grey.shade700)),
                                                                    ],
                                                                  ),
                                                                ),
                                                              );
                                                            }
                                                          }
                                                        });
                                                  }),
                                                ),
                                              );
                                            }
                                          }
                                        }),
                                    const SizedBox(height: 5),
                                    Row(
                                      mainAxisAlignment:
                                          MainAxisAlignment.spaceBetween,
                                      children: [
                                        Row(
                                          children: [
                                            Text("Total Cost: ",
                                                style: GoogleFonts.lato(
                                                    fontSize: 12,
                                                    fontWeight: FontWeight.w600,
                                                    color: Colors.black)),
                                            Text(
                                                record.cost == null
                                                    ? "N/A"
                                                    : "R${record.cost}",
                                                style: GoogleFonts.lato(
                                                    fontSize: 12,
                                                    fontWeight: FontWeight.w600,
                                                    color: Colors.black)),
                                          ],
                                        ),

                                        ///chatting
                                        (() {
                                          final isFutureBookingBridge =
                                              (record.source ?? '')
                                                          .toString()
                                                          .trim()
                                                          .toLowerCase() ==
                                                      'future_booking' ||
                                                  (record.futureBookingId ?? '')
                                                      .toString()
                                                      .trim()
                                                      .isNotEmpty;
                                          final status = (record.status ?? '')
                                              .toString()
                                              .trim()
                                              .toLowerCase();
                                          final paymentStatus =
                                              (record.paymentStatus ?? '')
                                                  .toString()
                                                  .trim()
                                                  .toLowerCase();

                                          final isInProgress =
                                              status == 'progress' ||
                                                  status == 'in_progress';

                                          final canChat = isFutureBookingBridge
                                              ? (paymentStatus == 'paid' ||
                                                  status == 'accepted' ||
                                                  isInProgress)
                                              : isInProgress;

                                          return record.accept == '1' && canChat
                                              ? ChatIconWidget(record: record)
                                              : const SizedBox();
                                        })()
                                      ],
                                    ),
                                    const SizedBox(height: 10),
                                    Row(
                                      children: [
                                        const Text("Status: "),
                                        Container(
                                          padding: const EdgeInsets.all(4),
                                          decoration: BoxDecoration(
                                              borderRadius:
                                                  BorderRadius.circular(5),
                                              color: record.status == "closed"
                                                  ? Colors.grey.shade100
                                                  : record.status == "completed"
                                                      ? Colors.grey.shade100
                                                      : record.accept == "1"
                                                          ? Colors
                                                              .green.shade100
                                                          : record.accept == "0"
                                                              ? Colors
                                                                  .red.shade100
                                                              : Colors.amber
                                                                  .shade100,
                                              border: Border.all(
                                                  color: record.status ==
                                                          "closed"
                                                      ? Colors.grey
                                                      : record.status ==
                                                              "completed"
                                                          ? Colors.grey
                                                          : record.accept == "1"
                                                              ? Colors.green
                                                                  .shade900
                                                              : record.accept ==
                                                                      "0"
                                                                  ? Colors.red
                                                                      .shade900
                                                                  : Colors.amber
                                                                      .shade900)),
                                          child: Text(
                                            record.status == "closed"
                                                ? "closed"
                                                : record.status == "completed"
                                                    ? "completed"
                                                    : (record.status ==
                                                                "progress" ||
                                                            record.status ==
                                                                "in_progress")
                                                        ? "On Progress"
                                                        : record.accept == "1"
                                                            ? "Accepted"
                                                            : record.accept ==
                                                                    "0"
                                                                ? "Rejected"
                                                                : "Pending to Artisan",
                                            style: TextStyle(
                                                fontSize: 16,
                                                fontWeight: FontWeight.w500,
                                                color: record.status == "closed"
                                                    ? Colors.grey
                                                    : record.status ==
                                                            "completed"
                                                        ? Colors.grey
                                                        : record.accept == "1"
                                                            ? Colors
                                                                .green.shade900
                                                            : record.accept ==
                                                                    "0"
                                                                ? Colors.red
                                                                    .shade900
                                                                : Colors.amber
                                                                    .shade900),
                                          ),
                                        ),
                                        Flexible(
                                          child: record.paymentStatus == "paid"
                                              ? const Text(
                                                  ' (Payment Secured in Escrow)',
                                                  overflow: TextOverflow.ellipsis,
                                                )
                                              : record.paymentStatus == "deposit_paid"
                                                  ? const Text(
                                                      ' (Deposit Received)',
                                                      style: TextStyle(color: Colors.teal),
                                                      overflow: TextOverflow.ellipsis,
                                                    )
                                                  : const SizedBox(),
                                        ),
                                      ],
                                    ),

                                    // ── Strategy 8: Live Job Tracking ──────
                                    if ((record.status == "progress" ||
                                            record.status == "in_progress") &&
                                        (record.paymentStatus == "paid" ||
                                            record.paymentStatus == "deposit_paid"))
                                      Container(
                                        margin: const EdgeInsets.only(top: 8),
                                        padding: const EdgeInsets.all(10),
                                        decoration: BoxDecoration(
                                          color: Colors.blue.shade50,
                                          borderRadius: BorderRadius.circular(8),
                                          border: Border.all(color: Colors.blue.shade200),
                                        ),
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            Row(children: [
                                              Icon(Icons.location_on, color: Colors.blue.shade700, size: 16),
                                              const SizedBox(width: 6),
                                              Text('Live Job Tracking',
                                                  style: GoogleFonts.lato(
                                                      fontWeight: FontWeight.bold,
                                                      fontSize: 12,
                                                      color: Colors.blue.shade800)),
                                            ]),
                                            const SizedBox(height: 6),
                                            // Progress steps
                                            Row(children: [
                                              _trackingStep('Accepted', true),
                                              _trackingLine(true),
                                              _trackingStep('On The Way', true),
                                              _trackingLine(record.buyingMaterial == 'true'),
                                              _trackingStep('Buying\nMaterial', record.buyingMaterial == 'true'),
                                              _trackingLine(record.artisanImages != "0"),
                                              _trackingStep('Working', record.artisanImages != "0"),
                                              _trackingLine(record.artisanImages == "2"),
                                              _trackingStep('Done', record.artisanImages == "2"),
                                            ]),
                                            const SizedBox(height: 6),
                                            GestureDetector(
                                              onTap: () {
                                                final uid = (record.serviceProviderId ?? '').trim();
                                                if (uid.isNotEmpty) {
                                                  Get.to(() => GoogleMapView(
                                                      id: uid,
                                                      name: 'Artisan',
                                                      taskRecord: record));
                                                }
                                              },
                                              child: Row(children: [
                                                Icon(Icons.map, color: Colors.blue.shade600, size: 14),
                                                const SizedBox(width: 4),
                                                Text('Track artisan on map',
                                                    style: GoogleFonts.lato(
                                                        fontSize: 11,
                                                        color: Colors.blue.shade600,
                                                        decoration: TextDecoration.underline)),
                                              ]),
                                            ),
                                          ],
                                        ),
                                      ),
                                    const SizedBox(height: 5),
                                    Row(
                                      children: [
                                        const Text("Created at: "),
                                        Text(record.creationDate != null && record.creationDate!.isNotEmpty
                                            ? DateFormat('dd/MMM/yyyy hh:mm a')
                                                .format(DateTime.parse(record.creationDate!))
                                            : 'N/A'),
                                      ],
                                    ),
                                    // Text(record.description == "" ? "" : "\"${record.description}\"",
                                    //     style: const TextStyle(color: Colors.black)),
                                    // const SizedBox(height: 5),
                                    Row(
                                      mainAxisAlignment:
                                          MainAxisAlignment.spaceBetween,
                                      children: [
                                        record.attachment == null ||
                                                record.attachment == ""
                                            ? const SizedBox()
                                            : GestureDetector(
                                                onTap: () {
                                                  Get.to(() => AttachmentView(
                                                      imagePath:
                                                          record.attachment!));
                                                },
                                                child: Row(
                                                  mainAxisAlignment:
                                                      MainAxisAlignment.end,
                                                  children: [
                                                    Icon(Icons.attachment,
                                                        color: Colors
                                                            .amber.shade500),
                                                    const SizedBox(width: 5),
                                                    Text('Attachment',
                                                        style: GoogleFonts.lato(
                                                            fontWeight:
                                                                FontWeight.w700,
                                                            color: Colors
                                                                .amber.shade500,
                                                            fontSize: 14)),
                                                  ],
                                                )),
                                        record.additionalAttachment == null ||
                                                record.additionalAttachment ==
                                                    ""
                                            ? const SizedBox()
                                            : GestureDetector(
                                                onTap: () {
                                                  Get.to(() => AttachmentView(
                                                      imagePath: record
                                                          .additionalAttachment!));
                                                },
                                                child: Row(
                                                  mainAxisAlignment:
                                                      MainAxisAlignment.end,
                                                  children: [
                                                    Icon(Icons.attachment,
                                                        color: Colors
                                                            .amber.shade500),
                                                    const SizedBox(width: 5),
                                                    Text(
                                                        'Additional attachment',
                                                        style: GoogleFonts.lato(
                                                            fontWeight:
                                                                FontWeight.w700,
                                                            color: Colors
                                                                .amber.shade500,
                                                            fontSize: 14)),
                                                  ],
                                                )),
                                      ],
                                    ),
                                    Row(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      mainAxisAlignment:
                                          MainAxisAlignment.spaceBetween,
                                      children: [
                                        record.description == "" ||
                                                record.description == null
                                            ? const SizedBox()
                                            : descriptionWidget(
                                                height, record.description),
                                        record.additionalDescription == null ||
                                                record.additionalDescription ==
                                                    ""
                                            ? const SizedBox()
                                            : descriptionWidget(height,
                                                record.additionalDescription),
                                      ],
                                    ),
                                    const SizedBox(height: 10),
                                    record.accept == "1" &&
                                            ((record.paymentStatus ?? '')
                                                    .toString()
                                                    .trim()
                                                    .toLowerCase() !=
                                                "paid") &&
                                            ((record.paymentStatus ?? '')
                                                    .toString()
                                                    .trim()
                                                    .toLowerCase() !=
                                                "deposit_paid") &&
                                            record.status != "closed" &&
                                            record.status != "completed" &&
                                            record.status != "progress" &&
                                            record.status != "in_progress"
                                        ? GestureDetector(
                                            onTap: () async {
                                              // appController.isWithdraw.value = false;
                                              appController.getUser(
                                                  id: appController
                                                      .userId.value);
                                              showModalBottomSheet(
                                                shape:
                                                    const RoundedRectangleBorder(
                                                  borderRadius:
                                                      BorderRadius.only(
                                                          topLeft:
                                                              Radius.circular(
                                                                  16),
                                                          topRight:
                                                              Radius.circular(
                                                                  16)),
                                                ),
                                                context: context,
                                                builder:
                                                    (BuildContext context) {
                                                  return ModelBottomSheet(
                                                      record: record);
                                                },
                                              );
                                            },
                                            child: Container(
                                              padding: const EdgeInsets.all(6),
                                              decoration: BoxDecoration(
                                                color: const Color(0xff35540C),
                                                borderRadius:
                                                    BorderRadius.circular(5),
                                              ),
                                              child: const Text(
                                                'Pay to confirm Order',
                                                style: TextStyle(
                                                    fontSize: 16,
                                                    fontWeight: FontWeight.w500,
                                                    color: Colors.white),
                                              ),
                                            ),
                                          )
                                        // ── Balance payment for deposit orders ──
                                        : record.accept == "1" &&
                                                record.paymentStatus ==
                                                    "deposit_paid" &&
                                                record.status != "completed" &&
                                                record.artisanImages != "0"
                                            ? _buildBalancePaymentButton(record, context, appController)
                                        : record.accept == "1" &&
                                                record.paymentStatus ==
                                                    "paid" &&
                                                record.status != "completed" &&
                                                record.artisanImages != "0"
                                            ? Column(
                                                children: [
                                                  Container(
                                                    // height: height * 0.25,
                                                    padding:
                                                        const EdgeInsets.all(4),
                                                    margin:
                                                        const EdgeInsets.only(
                                                            bottom: 5),
                                                    width: width,
                                                    decoration: BoxDecoration(
                                                        color: Colors.white,
                                                        border: Border.all(
                                                            color:
                                                                Colors.grey)),
                                                    child: StreamBuilder(
                                                        stream: appController
                                                            .artisanTaskImages
                                                            .doc(record
                                                                .artisanImageDocId)
                                                            .snapshots(),
                                                        builder: (context,
                                                            workImageSnapshot) {
                                                          if (!workImageSnapshot
                                                              .hasData) {
                                                            return const SizedBox();
                                                          } else {
                                                            return Row(
                                                              children: [
                                                                Expanded(
                                                                  child: Column(
                                                                    crossAxisAlignment:
                                                                        CrossAxisAlignment
                                                                            .start,
                                                                    children: [
                                                                      Text(
                                                                          "Before:\n'${workImageSnapshot.data!["before_notes"]}'",
                                                                          style:
                                                                              GoogleFonts.lato(fontSize: 12)),
                                                                      Text(
                                                                          "Date:\n${Helper.formatDateTime(date: workImageSnapshot.data!["created_at"])}",
                                                                          style:
                                                                              GoogleFonts.lato(fontSize: 12)),
                                                                      workImageSnapshot.data!["before_work"] ==
                                                                              ""
                                                                          ? const SizedBox()
                                                                          : GestureDetector(
                                                                              onTap: () {
                                                                                Get.to(() => AttachmentView(imagePath: workImageSnapshot.data!["before_work"]));
                                                                              },
                                                                              child: Text('Before Work Image', style: GoogleFonts.lato(fontWeight: FontWeight.w700, color: Colors.amber.shade500, fontSize: 12))),
                                                                    ],
                                                                  ),
                                                                ),
                                                                Expanded(
                                                                  child: Column(
                                                                    crossAxisAlignment:
                                                                        CrossAxisAlignment
                                                                            .start,
                                                                    children: [
                                                                      Text(
                                                                          "After:\n'${workImageSnapshot.data!["after_notes"]}'",
                                                                          style:
                                                                              GoogleFonts.lato(fontSize: 12)),
                                                                      Text(
                                                                          "Date:\n${Helper.formatDateTime(date: workImageSnapshot.data!["updated_at"])}",
                                                                          style:
                                                                              GoogleFonts.lato(fontSize: 12)),
                                                                      workImageSnapshot.data!["after_work"] ==
                                                                              ""
                                                                          ? const SizedBox()
                                                                          : GestureDetector(
                                                                              onTap: () {
                                                                                Get.to(() => AttachmentView(imagePath: workImageSnapshot.data!["after_work"]));
                                                                              },
                                                                              child: Text('After Work Image', style: GoogleFonts.lato(fontWeight: FontWeight.w700, color: Colors.amber.shade500, fontSize: 12))),
                                                                    ],
                                                                  ),
                                                                ),
                                                              ],
                                                            );
                                                          }
                                                        }),
                                                  ),
                                                  GestureDetector(
                                                    onTap: () async {
                                                      double userRating = 0.0;
                                                      showDialog(
                                                        context: context,
                                                        builder: (context) {
                                                          return AlertDialog(
                                                            title: const Text(
                                                                'Rate Artisan'),
                                                            content: Column(
                                                              mainAxisSize:
                                                                  MainAxisSize
                                                                      .min,
                                                              children: <Widget>[
                                                                const Text(
                                                                    'Enter your feedback:'),
                                                                const SizedBox(
                                                                    height: 20),
                                                                ClipRRect(
                                                                  borderRadius:
                                                                      BorderRadius
                                                                          .circular(
                                                                              10),
                                                                  child: Card(
                                                                    elevation:
                                                                        2,
                                                                    color: Colors
                                                                        .white,
                                                                    child:
                                                                        TextField(
                                                                      maxLines:
                                                                          5,
                                                                      controller:
                                                                          feedBackController,
                                                                      cursorColor:
                                                                          Colors
                                                                              .black,
                                                                      style: GoogleFonts.roboto(
                                                                          fontWeight:
                                                                              FontWeight.normal),
                                                                      decoration:
                                                                          InputDecoration(
                                                                        labelText:
                                                                            'Comment',
                                                                        labelStyle: GoogleFonts.roboto(
                                                                            color:
                                                                                const Color(0xffACADB9),
                                                                            fontSize: width * 0.04),
                                                                        border:
                                                                            InputBorder.none,
                                                                        focusedBorder:
                                                                            const OutlineInputBorder(
                                                                          borderSide:
                                                                              BorderSide(color: Colors.white),
                                                                        ),
                                                                        filled:
                                                                            true,
                                                                        fillColor:
                                                                            Colors.white,
                                                                        prefixIcon:
                                                                            Icon(
                                                                          Icons
                                                                              .comment,
                                                                          color:
                                                                              const Color(0xffACADB9),
                                                                          size: width *
                                                                              0.07,
                                                                        ),
                                                                        contentPadding: const EdgeInsets
                                                                            .symmetric(
                                                                            vertical:
                                                                                15.0,
                                                                            horizontal:
                                                                                16.0),
                                                                      ),
                                                                    ),
                                                                  ),
                                                                ),
                                                                const SizedBox(
                                                                    height: 20),
                                                                RatingBar
                                                                    .builder(
                                                                  initialRating:
                                                                      0,
                                                                  minRating: 1,
                                                                  direction: Axis
                                                                      .horizontal,
                                                                  // allowHalfRating: true,
                                                                  itemCount: 5,
                                                                  itemPadding: const EdgeInsets
                                                                      .symmetric(
                                                                      horizontal:
                                                                          1.0),
                                                                  itemBuilder:
                                                                      (context,
                                                                              _) =>
                                                                          const Icon(
                                                                    Icons.star,
                                                                    color: Colors
                                                                        .amber,
                                                                  ),
                                                                  onRatingUpdate:
                                                                      (rating) {
                                                                    userRating =
                                                                        rating;

                                                                    /// for average of rating
                                                                    // if(record.rating != ""){
                                                                    //   userRating = double.parse(record.rating!);
                                                                    // }
                                                                    // userRating = (rating + userRating ) / 2;
                                                                  },
                                                                ),
                                                              ],
                                                            ),
                                                            actions: <Widget>[
                                                              TextButton(
                                                                onPressed: () {
                                                                  Navigator.of(
                                                                          context)
                                                                      .pop();
                                                                },
                                                                child: const Text(
                                                                    'Cancel'),
                                                              ),
                                                              TextButton(
                                                                onPressed: () {
                                                                  Navigator.of(
                                                                          context)
                                                                      .pop();
                                                                  // Handle the user's feedback and rating here
                                                                  debugPrint(
                                                                      'Feedback: ${feedBackController.text}');
                                                                  debugPrint(
                                                                      'Rating: $userRating');

                                                                  EasyLoading.show(
                                                                      status:
                                                                          'Please Wait...!');
                                                                  appController
                                                                      .markOrderAsCompleted(
                                                                          rating: userRating
                                                                              .toString(),
                                                                          feedback: feedBackController
                                                                              .text
                                                                              .trArgs(),
                                                                          taskManagementId:
                                                                              record.id!)
                                                                      .then((_) {
                                                                    EasyLoading
                                                                        .dismiss();
                                                                  });
                                                                },
                                                                child: const Text(
                                                                    'Submit'),
                                                              ),
                                                            ],
                                                          );
                                                        },
                                                      );
                                                    },
                                                    child: Container(
                                                      padding:
                                                          const EdgeInsets.all(
                                                              6),
                                                      decoration: BoxDecoration(
                                                          color: const Color(
                                                                  0xFFc5a520)
                                                              .withOpacity(0.2),
                                                          borderRadius:
                                                              BorderRadius
                                                                  .circular(5),
                                                          border: Border.all(
                                                              color: const Color(
                                                                  0xFFc5a520))),
                                                      child: const Row(
                                                        children: [
                                                          Text(
                                                              'Press to Complete order',
                                                              style: TextStyle(
                                                                  fontSize: 16,
                                                                  fontWeight:
                                                                      FontWeight
                                                                          .w500,
                                                                  color: Color(
                                                                      0xFFc5a520))),
                                                          SizedBox(width: 5),
                                                          Icon(
                                                            Icons
                                                                .verified_outlined,
                                                            color: Color(
                                                                0xFFc5a520),
                                                          )
                                                        ],
                                                      ),
                                                    ),
                                                  ),
                                                ],
                                              )
                                            : (record.status == "completed" || record.status == "closed") &&
                                                    (record.rating == null || record.rating == "")
                                                ? GestureDetector(
                                                    onTap: () async {
                                                      double userRating = 0.0;
                                                      showDialog(
                                                        context: context,
                                                        builder: (context) {
                                                          return AlertDialog(
                                                            title: const Text('Rate Artisan'),
                                                            content: Column(
                                                              mainAxisSize: MainAxisSize.min,
                                                              children: <Widget>[
                                                                const Text('How was the service?'),
                                                                const SizedBox(height: 20),
                                                                RatingBar.builder(
                                                                  initialRating: 0,
                                                                  minRating: 1,
                                                                  direction: Axis.horizontal,
                                                                  itemCount: 5,
                                                                  itemPadding: const EdgeInsets.symmetric(horizontal: 1.0),
                                                                  itemBuilder: (context, _) => const Icon(Icons.star, color: Colors.amber),
                                                                  onRatingUpdate: (rating) { userRating = rating; },
                                                                ),
                                                              ],
                                                            ),
                                                            actions: <Widget>[
                                                              TextButton(
                                                                onPressed: () => Navigator.of(context).pop(),
                                                                child: const Text('Cancel'),
                                                              ),
                                                              TextButton(
                                                                onPressed: () {
                                                                  Navigator.of(context).pop();
                                                                  EasyLoading.show(status: 'Submitting...');
                                                                  appController.markOrderAsCompleted(
                                                                    rating: userRating.toString(),
                                                                    feedback: '',
                                                                    taskManagementId: record.id!,
                                                                  ).then((_) => EasyLoading.dismiss());
                                                                },
                                                                child: const Text('Submit'),
                                                              ),
                                                            ],
                                                          );
                                                        },
                                                      );
                                                    },
                                                    child: Container(
                                                      padding: const EdgeInsets.all(6),
                                                      decoration: BoxDecoration(
                                                        color: const Color(0xFFc5a520).withOpacity(0.2),
                                                        borderRadius: BorderRadius.circular(5),
                                                        border: Border.all(color: const Color(0xFFc5a520)),
                                                      ),
                                                      child: const Row(
                                                        children: [
                                                          Text('Rate this Artisan', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500, color: Color(0xFFc5a520))),
                                                          SizedBox(width: 5),
                                                          Icon(Icons.star_outline, color: Color(0xFFc5a520)),
                                                        ],
                                                      ),
                                                    ),
                                                  )
                                                : const SizedBox(),
                                    const SizedBox(height: 10),
                                    CustomPaint(
                                      size: Size(width, height * 0.01),
                                      painter: DottedLinePainter(
                                          Colors.grey.shade700),
                                    ),
                                    const SizedBox(height: 10),
                                    StreamBuilder(
                                        stream: FirebaseService.providerRef
                                            .doc(record.serviceProviderId)
                                            .snapshots(),
                                        builder: (context, snapshot) {
                                          if (!snapshot.hasData) {
                                            return Center(
                                                child: noText(
                                                    align: TextAlign.start));
                                          } else {
                                            if (snapshot.data!.data() == null) {
                                              return Center(
                                                  child: noText(
                                                      align: TextAlign.start));
                                            } else {
                                              return Column(
                                                children: [
                                                  Row(
                                                    children: [
                                                      snapshot.data!.data()![
                                                                  "image"] ==
                                                              ""
                                                          ? ClipRRect(
                                                              borderRadius:
                                                                  BorderRadius
                                                                      .circular(
                                                                          50.0),
                                                              child: SizedBox(
                                                                  height: MediaQuery.of(
                                                                              context)
                                                                          .size
                                                                          .width *
                                                                      0.1,
                                                                  width: MediaQuery.of(
                                                                              context)
                                                                          .size
                                                                          .width *
                                                                      0.1,
                                                                  child: Image.asset(
                                                                      'assets/images/no_image.png',
                                                                      fit: BoxFit
                                                                          .cover)),
                                                            )
                                                          : ClipRRect(
                                                              borderRadius:
                                                                  BorderRadius
                                                                      .circular(
                                                                          50.0),
                                                              child: SizedBox(
                                                                  height: MediaQuery.of(
                                                                              context)
                                                                          .size
                                                                          .width *
                                                                      0.1,
                                                                  width: MediaQuery.of(
                                                                              context)
                                                                          .size
                                                                          .width *
                                                                      0.1,
                                                                  child: Image.network(
                                                                      snapshot.data!
                                                                              .data()![
                                                                          "image"],
                                                                      fit: BoxFit
                                                                          .cover)),
                                                            ),
                                                      const SizedBox(width: 10),
                                                      Text(
                                                        snapshot.data!.data()![
                                                                "name"] ??
                                                            "N/A",
                                                        textAlign:
                                                            TextAlign.start,
                                                        style: const TextStyle(
                                                            color: Colors.black,
                                                            fontSize: 16,
                                                            fontWeight:
                                                                FontWeight
                                                                    .w700),
                                                      ),
                                                      const Spacer(),
                                                      Text('R${record.cost}'),
                                                    ],
                                                  ),
                                                  (record.status ==
                                                              "progress" ||
                                                          record.status ==
                                                              "in_progress")
                                                      ? GestureDetector(
                                                          onTap: () {
                                                            navigateToPage(
                                                                context:
                                                                    context,
                                                                pageName: GoogleMapView(
                                                                    id: record
                                                                        .serviceProviderId!,
                                                                    taskRecord:
                                                                        record,
                                                                    name: snapshot
                                                                            .data!
                                                                            .data()![
                                                                        "name"]));
                                                          },
                                                          child: Container(
                                                            margin:
                                                                const EdgeInsets
                                                                    .only(
                                                                    top: 10),
                                                            padding:
                                                                const EdgeInsets
                                                                    .all(5),
                                                            decoration: BoxDecoration(
                                                                color: Colors
                                                                    .amber
                                                                    .shade50,
                                                                borderRadius:
                                                                    BorderRadius
                                                                        .circular(
                                                                            5),
                                                                border: Border.all(
                                                                    color: Colors
                                                                        .amber
                                                                        .shade300),
                                                                boxShadow: [
                                                                  BoxShadow(
                                                                    color: Colors
                                                                        .grey
                                                                        .shade200,
                                                                    blurRadius:
                                                                        0.5,
                                                                    spreadRadius:
                                                                        0.5,
                                                                  )
                                                                ]),
                                                            child: Row(
                                                              mainAxisAlignment:
                                                                  MainAxisAlignment
                                                                      .center,
                                                              children: [
                                                                Text(
                                                                    'Track Artisan',
                                                                    style: GoogleFonts.lato(
                                                                        fontWeight:
                                                                            FontWeight
                                                                                .w700,
                                                                        color: Colors
                                                                            .amber
                                                                            .shade500,
                                                                        fontSize:
                                                                            16)),
                                                                const SizedBox(
                                                                    width: 10),
                                                                Image.asset(
                                                                    'assets/images/track.png',
                                                                    height: 30)
                                                                // Icon(Icons.map_outlined)
                                                              ],
                                                            ),
                                                          ))
                                                      : const SizedBox()
                                                ],
                                              );
                                            }
                                          }
                                        }),
                                  ],
                                ),
                              ));
                        })
                    : Center(child: noText(text: 'No Request Available'));
            }),
    );
  }
}

class BusinessPage extends StatelessWidget {
  const BusinessPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
        body: Image.asset('assets/images/book/Group 1261152605.png'));
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

class ChatIconWidget extends StatelessWidget {
  final TaskManagementModel record;
  final bool isArtisanSide;
  const ChatIconWidget(
      {super.key, required this.record, this.isArtisanSide = false});

  @override
  Widget build(BuildContext context) {
    final AppController appController = Get.find();

    final isFutureBookingBridge =
        (record.source ?? '').toString().trim().toLowerCase() ==
                'future_booking' ||
            (record.futureBookingId ?? '').toString().trim().isNotEmpty;
    final status = (record.status ?? '').toString().trim().toLowerCase();
    final paymentStatus =
        (record.paymentStatus ?? '').toString().trim().toLowerCase();
    final canChatForFutureBooking = paymentStatus == 'paid' ||
        status == 'accepted' ||
        status == 'in_progress';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Stack(
          clipBehavior: Clip.none,
          alignment: Alignment.topRight,
          children: [
            GestureDetector(
              onTap: () {
                if (isFutureBookingBridge && !canChatForFutureBooking) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content:
                          Text('Chat is available after payment is completed.'),
                      backgroundColor: Colors.orange,
                    ),
                  );
                  return;
                }
                Get.to(() =>
                    ChatScreen(task: record, isArtisanSide: isArtisanSide));
              },
              child: Container(
                  padding: EdgeInsets.all(4),
                  decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(color: Colors.grey)),
                  child: Icon(Icons.message, color: Colors.grey.shade500)),
            ),
            StreamBuilder<QuerySnapshot>(
                stream: FirebaseFirestore.instance
                    .collection("tasksManagement")
                    .doc(record.id)
                    .collection("chat")
                    .where("receiver_id",
                        isEqualTo:
                            appController.userId.value) // Only messages for me
                    .where("isRead", isEqualTo: false) // Only unread
                    .snapshots(),
                builder: (context, snapshot) {
                  if (snapshot.hasError) {
                    return SizedBox();
                  } else if (!snapshot.hasData) {
                    return SizedBox();
                  }
                  int unreadCount = snapshot.data!.docs.length;
                  if (unreadCount != 0) {
                    return Positioned(
                      top: -15,
                      right: -10,
                      child: Container(
                        padding: EdgeInsets.all(6),
                        decoration: BoxDecoration(
                            shape: BoxShape.circle, color: Colors.red),
                        child: Text(unreadCount.toString(),
                            style:
                                TextStyle(color: Colors.white, fontSize: 12)),
                      ),
                    );
                  }
                  return SizedBox();
                })
          ],
        ),
        Text("Chat", style: GoogleFonts.lato(fontSize: 12))
      ],
    );
  }
}

/// Bottom sheet for paying the remaining balance on a deposit order.
class _BalancePaymentSheet extends StatelessWidget {
  final TaskManagementModel record;
  final double balanceAmount;

  const _BalancePaymentSheet({
    required this.record,
    required this.balanceAmount,
  });

  @override
  Widget build(BuildContext context) {
    final AppController appController = Get.find();

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Pay Remaining Balance',
                style: GoogleFonts.lato(fontWeight: FontWeight.w700, fontSize: 16)),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.teal.shade50,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.teal.shade300),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('Balance Due', style: GoogleFonts.lato(fontSize: 13)),
                  Text('R${balanceAmount.toStringAsFixed(2)}',
                      style: GoogleFonts.lato(
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                          color: Colors.teal.shade800)),
                ],
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xff35540C),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                onPressed: () async {
                  appController.isPaymentUsingPayFast.value = false;
                  appController.isPaymentUsingBnpl.value = false;
                  appController.activePaymentMethod.value = 'wallet';
                  EasyLoading.show(status: 'Processing balance payment...');
                  try {
                    await appController.getUser(id: appController.userId.value);
                    final bal = double.tryParse(appController.userBalance.value) ?? 0;
                    if (balanceAmount <= bal) {
                      // Mark balance as paid
                      await DepositService.markBalancePaid(
                        taskManagementId: record.id ?? '',
                      );
                      // Deduct balance from wallet and create transaction
                      await appController.savePaymentStatus(
                        cost: balanceAmount.toStringAsFixed(2),
                        taskManagementId: record.id ?? '',
                        status: 'success',
                      );
                      EasyLoading.dismiss();
                      EasyLoading.showSuccess('Balance paid! You can now rate the artisan.');
                      if (Navigator.of(context).canPop()) {
                        Navigator.of(context).pop();
                      }
                    } else {
                      EasyLoading.dismiss();
                      Get.showSnackbar(GetSnackBar(
                        backgroundColor: Colors.red.shade900,
                        duration: const Duration(seconds: 4),
                        snackPosition: SnackPosition.TOP,
                        title: 'Insufficient Balance',
                        message: 'Balance is low! Please top up your wallet.',
                      ));
                    }
                  } catch (e) {
                    EasyLoading.dismiss();
                    debugPrint('Balance payment error: $e');
                  }
                },
                child: Text('Pay R${balanceAmount.toStringAsFixed(2)} Via Wallet',
                    style: GoogleFonts.lato(
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                        fontSize: 14)),
              ),
            ),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFFc5a520),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                onPressed: () async {
                  appController.isPaymentUsingPayFast.value = true;
                  appController.isPaymentUsingBnpl.value = false;
                  appController.activePaymentMethod.value = 'ozow';
                  EasyLoading.show(status: 'Please Wait...!');
                  try {
                    await appController.getUser(id: appController.userId.value);
                    final costStr = balanceAmount.toStringAsFixed(2);
                    appController.webUrl.value =
                        await appController.initiatePayment(
                            cost: costStr,
                            taskManagementId: record.id);
                    if (appController.webUrl.value.isEmpty) {
                      EasyLoading.dismiss();
                      Get.showSnackbar(GetSnackBar(
                        backgroundColor: Colors.red.shade900,
                        duration: const Duration(seconds: 4),
                        snackPosition: SnackPosition.TOP,
                        title: 'Payment Error',
                        message: 'Could not connect to payment provider. Please try again or use wallet payment.',
                      ));
                      return;
                    }
                    // markBalancePaid is called by PaymentMethodView on Ozow
                    // success callback — not here, to avoid marking paid before
                    // user completes the external payment.
                    Get.to(
                      () => PaymentMethodView(
                        taskManagementModel: record,
                        chargeAmount: costStr,
                      ),
                      transition: Transition.fadeIn,
                    );
                  } finally {
                    EasyLoading.dismiss();
                  }
                },
                child: Text('Pay R${balanceAmount.toStringAsFixed(2)} Via Ozow',
                    style: GoogleFonts.lato(
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                        fontSize: 14)),
              ),
            ),
            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }
}
