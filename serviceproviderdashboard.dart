import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter_easyloading/flutter_easyloading.dart';
import 'package:get/get.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:image_picker/image_picker.dart';
import 'package:maintenanceapp/controller/service_provider_controller.dart';
import 'package:maintenanceapp/providers/position_provider.dart';
import 'package:maintenanceapp/screens/auth/login.dart';
import 'package:maintenanceapp/screens/service_provider_panel/Serviceprovider/notification_screen.dart';
import 'package:maintenanceapp/screens/service_provider_panel/Serviceprovider/artisan_appointments_screen.dart';
import 'package:maintenanceapp/screens/service_provider_panel/Serviceprovider/toggle.dart';
import 'package:maintenanceapp/screens/service_provider_panel/service_provider_request_screen.dart';
import 'package:maintenanceapp/screens/service_provider_panel/wallet_page.dart';
import 'package:maintenanceapp/screens/home/livekit_voice_assistant.dart';
import 'package:maintenanceapp/services/notification_services.dart';
import 'package:maintenanceapp/utils/navigation.dart';
import 'package:maintenanceapp/utils/splash_timer.dart';
import 'package:provider/provider.dart';

class ServiceProviderDashboard extends StatefulWidget {
  final String email;
  final String password;

  const ServiceProviderDashboard(
      {super.key, required this.email, required this.password});

  @override
  State<ServiceProviderDashboard> createState() =>
      _ServiceProviderDashboardState();
}

class _ServiceProviderDashboardState extends State<ServiceProviderDashboard> {
  final ServiceProviderController serviceProviderController = Get.find();
  late final TextEditingController nameController;
  String _requestsStartedFor = '';

  String _providerListenerIdFromDoc(DocumentSnapshot doc) {
    // IMPORTANT: tasksManagement.service_provider_id is written using the
    // serviceProvider document id (doc.id). Listening on user_id/uid can cause
    // artisans to miss requests.
    final docId = doc.id.toString().trim();
    if (docId.isNotEmpty) return docId;

    final data = doc.data() as Map<String, dynamic>?;
    if (data == null) return '';

    // Fallback only if doc.id is missing (should be rare).
    const keys = <String>['provider_id', 'docId', 'user_id', 'uid', 'userId'];
    for (final k in keys) {
      final v = (data[k] ?? '').toString().trim();
      if (v.isNotEmpty) return v;
    }
    return '';
  }

  List<String> _providerListenerIdsFromDoc(DocumentSnapshot doc) {
    final ids = <String>{};
    final docId = doc.id.toString().trim();
    if (docId.isNotEmpty) ids.add(docId);
    final data = doc.data() as Map<String, dynamic>?;
    if (data != null) {
      const keys = <String>['provider_id', 'docId', 'user_id', 'uid', 'userId'];
      for (final k in keys) {
        final v = (data[k] ?? '').toString().trim();
        if (v.isNotEmpty) ids.add(v);
      }
    }
    return ids.toList();
  }

  @override
  void initState() {
    super.initState();

    nameController = TextEditingController();
    // NOTE: Requests will be started once we have the provider doc from the StreamBuilder.

    ///for user side

    ///initialize notification
    NotificationService.initializeNotification(context);

    // FirebaseMessaging.instance.getToken().then((token) => print(token));

    ///When the app is terminated navigation works after tapping on the message
    FirebaseMessaging.instance
        .getInitialMessage()
        .then((RemoteMessage? message) {
      if (message != null) {
        final routeFromMessage = message.data["route"];
        debugPrint(routeFromMessage);
        // Get.to(()=> const LoginScreen());
      }
    });

    ///When the app is on foreground parsing message data
    FirebaseMessaging.onMessage.listen((RemoteMessage message) async {
      RemoteNotification? notification = message.notification;
      AndroidNotification? android = message.notification?.android;
      if (notification != null && android != null) {
        debugPrint(notification.title);
        debugPrint(notification.body);
        debugPrint(message.data.toString());
        if (mounted) {
          Provider.of<PositionProvider>(context, listen: false)
              .notificationType = message.data["type"];
        }
      }
      if (Platform.isIOS) {
        NotificationService.displayNotification(context, message: message);
      } else {
        NotificationService.displayNotification(context, message: message);
      }
    });

    ///When app in background but running and navigation works after tapping on the message
    FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage message) {
      final routeFromMessage = message.data["route"];
      // print(routeFromMessage);
      debugPrint(routeFromMessage);
      RemoteNotification? notification = message.notification;
      AndroidNotification? android = message.notification?.android;
      debugPrint(routeFromMessage);
      if (notification != null && android != null) {
        debugPrint(notification.title);
        debugPrint(notification.body);
        debugPrint(message.data.toString());
        Provider.of<PositionProvider>(context, listen: false).notificationType =
            message.data["type"];
        debugPrint(Provider.of<PositionProvider>(context, listen: false)
            .notificationType
            .toString());
      }
      if (Platform.isIOS) {
        NotificationService.displayNotification(context, message: message);
      } else {
        NotificationService.displayNotification(context, message: message);
      }
      // Get.to(()=> const LoginScreen());
      // navigateToPage(context: context, pageName: const NotificationPageView());
    });
  }

  Future<void> _refresh() async {
    // Let the StreamBuilder drive provider id; just reset so next build re-subscribes.
    _requestsStartedFor = '';
    setState(() {});
  }

  @override
  void dispose() {
    super.dispose();
    nameController.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    final height = MediaQuery.of(context).size.height;
    return Scaffold(
      floatingActionButton: StreamBuilder(
        stream: FirebaseFirestore.instance
            .collection("serviceProvider")
            .where("email", isEqualTo: widget.email)
            .where("password", isEqualTo: widget.password)
            .snapshots(),
        builder: (context, snapshot) {
          if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
            return const SizedBox.shrink();
          }

          final DocumentSnapshot providerDoc = snapshot.data!.docs.first;
          final providerListenerId = _providerListenerIdFromDoc(providerDoc);

          return FloatingActionButton(
            backgroundColor: const Color(0xFFc5a520),
            onPressed: () {
              Get.to(
                () => LivekitVoiceAssistant(
                  role: 'artisan',
                  providerDoc: providerDoc,
                  providerListenerId: providerListenerId,
                ),
                transition: Transition.fadeIn,
              );
            },
            child: const Icon(Icons.mic, color: Colors.white),
          );
        },
      ),
      body: SafeArea(
          child: RefreshIndicator(
        onRefresh: _refresh,
        backgroundColor: const Color(0xFFc5a520),
        color: Colors.white,
        child: ListView(
          children: [
            StreamBuilder(
              stream: FirebaseFirestore.instance
                  .collection("serviceProvider")
                  .where("email", isEqualTo: widget.email)
                  .where("password", isEqualTo: widget.password)
                  .snapshots(),
              builder: (BuildContext context, AsyncSnapshot<dynamic> snapshot) {
                if (snapshot.hasData && snapshot.data!.docs.isNotEmpty) {
                  final DocumentSnapshot providerDoc =
                      snapshot.data!.docs.first;
                  final providerListenerId =
                      _providerListenerIdFromDoc(providerDoc);

                  if (_requestsStartedFor != providerListenerId) {
                    _requestsStartedFor = providerListenerId;
                    final providerListenerIds =
                        _providerListenerIdsFromDoc(providerDoc);
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      serviceProviderController.getRequests(
                        providerId: providerListenerId,
                        additionalProviderIds: providerListenerIds,
                      );
                      // Load the artisan announcement toggle setting and
                      // arm/disarm the background listener accordingly.
                      serviceProviderController
                          .loadAnnouncementSetting(providerListenerId);
                    });
                  }
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.start,
                    children: [
                      Stack(children: [
                        Container(
                          width: double.infinity,
                          height: height * 0.2,
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
                          child: Stack(
                            children: [
                              Positioned(
                                left: 0,
                                right: 0,
                                top: MediaQuery.sizeOf(context).height * 0.05,
                                child: Center(
                                  child: Text(
                                    'Square 15 Artisan',
                                    style: GoogleFonts.inter(
                                        fontWeight: FontWeight.w600,
                                        fontSize: width * 0.06,
                                        color: Colors.white),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        GestureDetector(
                          onTap: () {
                            nameController.text =
                                snapshot.data!.docs[0]["name"];
                            showDialog(
                              context: context,
                              builder: (context) {
                                return AlertDialog(
                                  title: const Text('Update Profile'),
                                  content: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    mainAxisSize: MainAxisSize.min,
                                    children: <Widget>[
                                      const SizedBox(height: 20),
                                      ClipRRect(
                                        borderRadius: BorderRadius.circular(10),
                                        child: Card(
                                          elevation: 2,
                                          color: Colors.white,
                                          child: TextField(
                                            maxLines: 1,
                                            controller: nameController,
                                            cursorColor: Colors.black,
                                            style: GoogleFonts.roboto(
                                                fontWeight: FontWeight.normal),
                                            decoration: InputDecoration(
                                              labelText: snapshot.data!.docs[0]
                                                  ["name"],
                                              labelStyle: GoogleFonts.roboto(
                                                  color:
                                                      const Color(0xffACADB9),
                                                  fontSize:
                                                      MediaQuery.of(context)
                                                              .size
                                                              .width *
                                                          0.04),
                                              border: InputBorder.none,
                                              focusedBorder:
                                                  const OutlineInputBorder(
                                                borderSide: BorderSide(
                                                    color: Colors.white),
                                              ),
                                              filled: true,
                                              fillColor: Colors.white,
                                              prefixIcon: Icon(
                                                Icons.person,
                                                color: const Color(0xffACADB9),
                                                size: MediaQuery.of(context)
                                                        .size
                                                        .width *
                                                    0.07,
                                              ),
                                              contentPadding:
                                                  const EdgeInsets.symmetric(
                                                      vertical: 15.0,
                                                      horizontal: 16.0),
                                            ),
                                          ),
                                        ),
                                      ),
                                      const SizedBox(height: 10),
                                      Obx(() => serviceProviderController
                                                  .imageProvider.value ==
                                              null
                                          ? const SizedBox()
                                          : Image.file(
                                              File(serviceProviderController
                                                  .imageProvider.value!.path),
                                              height: 150)),
                                      ListBody(
                                        children: [
                                          const Divider(height: 1
                                              // color: Colors.blue,
                                              ),
                                          ListTile(
                                            onTap: () async {
                                              serviceProviderController
                                                      .imageProvider.value =
                                                  await ImagePicker().pickImage(
                                                      source:
                                                          ImageSource.gallery);
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
                                              serviceProviderController
                                                      .imageProvider.value =
                                                  await ImagePicker().pickImage(
                                                      source:
                                                          ImageSource.camera);
                                            },
                                            title: const Text("Camera"),
                                            leading: const Icon(
                                              Icons.camera,
                                              // color: Colors.blue,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ],
                                  ),
                                  actions: <Widget>[
                                    TextButton(
                                      onPressed: () {
                                        Navigator.of(context).pop();
                                      },
                                      child: const Text('Cancel'),
                                    ),
                                    TextButton(
                                      onPressed: () async {
                                        EasyLoading.show(
                                            status: "Updating Profile...!");
                                        if (nameController.text == "") {
                                          Get.showSnackbar(const GetSnackBar(
                                            backgroundColor: Colors.red,
                                            duration: Duration(seconds: 2),
                                            snackPosition: SnackPosition.TOP,
                                            title: 'Oops',
                                            message:
                                                'Name field cannot be empty',
                                          ));
                                        } else {
                                          serviceProviderController
                                              .updateServiceProviderProfile(
                                                  file: File(
                                                      serviceProviderController
                                                          .imageProvider
                                                          .value!
                                                          .path),
                                                  id: snapshot.data!.docs[0]
                                                      ["docId"],
                                                  name: nameController.text
                                                      .trim())
                                              .then((value) {
                                            EasyLoading.dismiss();
                                            serviceProviderController
                                                .imageProvider.value = null;
                                            nameController.clear();
                                            Navigator.of(context).pop();
                                          });
                                        }
                                      },
                                      child: const Text('Update'),
                                    ),
                                  ],
                                );
                              },
                            );
                          },
                          child: Stack(
                            alignment: Alignment.bottomCenter,
                            clipBehavior: Clip.none,
                            children: [
                              Center(
                                child: Padding(
                                  padding: EdgeInsets.only(
                                      top: MediaQuery.of(context).size.height *
                                          0.10),
                                  child: CircleAvatar(
                                    radius: 60,
                                    backgroundColor: Colors.transparent,
                                    backgroundImage: NetworkImage(
                                        snapshot.data!.docs[0]["image"]),
                                    child:
                                        snapshot.data!.docs[0]["image"].isEmpty
                                            ? const Text("No Image")
                                            : null,
                                  ),
                                ),
                              ),
                              Positioned(
                                  bottom: -10,
                                  left: MediaQuery.of(context).size.width / 1.9,
                                  width: 30,
                                  height: 30,
                                  child: Container(
                                      decoration: BoxDecoration(
                                          color: const Color(0xFFc5a520),
                                          borderRadius:
                                              BorderRadius.circular(50)),
                                      alignment: Alignment.center,
                                      child: const Icon(Icons.edit,
                                          color: Colors.white, size: 22)))
                            ],
                          ),
                        )
                      ]),
                      const SizedBox(
                        height: 20,
                      ),
                      Center(
                        child: Text(
                          snapshot.data!.docs[0]["name"],
                          style: GoogleFonts.roboto(
                              color: Colors.black,
                              fontSize: 20,
                              fontWeight: FontWeight.bold),
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.only(left: 20, right: 20),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisAlignment: MainAxisAlignment.start,
                          children: [
                            SizedBox(
                              height: height * 0.03,
                            ),
                            GestureDetector(
                              onTap: () {},
                              child: SizedBox(
                                height: height * 0.065,
                                child: Card(
                                  color: Colors.white,
                                  elevation: 0.5,
                                  child: Center(
                                    child: Row(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        const SizedBox(
                                          width: 10,
                                        ),
                                        const Icon(
                                          Icons.check_circle_outline,
                                          color: Color(0xff252525),
                                        ),
                                        const SizedBox(
                                          width: 10,
                                        ),
                                        Text(
                                          'Status',
                                          style: GoogleFonts.inter(
                                              color: Colors.black,
                                              fontSize: 16,
                                              fontWeight: FontWeight.w500),
                                        ),
                                        SizedBox(
                                          width: MediaQuery.of(context)
                                                  .size
                                                  .width *
                                              0.1,
                                        ),
                                        SizedBox(
                                          width: width * 0.35,
                                        ),
                                        Expanded(
                                            child: ToggleButton(
                                                status: snapshot.data!.docs[0]
                                                    ["active"],
                                                providerId: snapshot
                                                    .data!.docs[0]["docId"])),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            SizedBox(
                              height: height * 0.03,
                            ),
                            SizedBox(
                              height: height * 0.065,
                              child: Card(
                                color: Colors.white,
                                elevation: 0.5,
                                child: Center(
                                  child: Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.center,
                                    children: [
                                      const SizedBox(width: 10),
                                      const Icon(
                                        Icons.notifications_active,
                                        color: Color(0xff252525),
                                      ),
                                      const SizedBox(width: 10),
                                      Expanded(
                                        child: Text(
                                          'Job Announcements',
                                          style: GoogleFonts.inter(
                                              color: Colors.black,
                                              fontSize: 16,
                                              fontWeight: FontWeight.w500),
                                        ),
                                      ),
                                      Obx(() {
                                        final enabled =
                                            serviceProviderController
                                                .announcementsEnabled.value;
                                        return GestureDetector(
                                          onTap: () {
                                            final providerId = snapshot
                                                .data!.docs[0]["docId"];
                                            serviceProviderController
                                                .setAnnouncementsEnabled(
                                              providerId: providerId,
                                              enabled: !enabled,
                                            );
                                          },
                                          child: AnimatedContainer(
                                            duration: const Duration(
                                                milliseconds: 200),
                                            curve: Curves.easeInOut,
                                            width: 50.0,
                                            height: 30.0,
                                            decoration: BoxDecoration(
                                              borderRadius:
                                                  BorderRadius.circular(20.0),
                                              color: enabled
                                                  ? const Color(0xff3A5527)
                                                  : Colors.white,
                                              border: Border.all(
                                                  color: Colors.black),
                                            ),
                                            child: Stack(
                                              alignment: enabled
                                                  ? Alignment.centerRight
                                                  : Alignment.centerLeft,
                                              children: [
                                                Container(
                                                  margin:
                                                      const EdgeInsets
                                                          .symmetric(
                                                          horizontal: 2.0),
                                                  width: 20.0,
                                                  height: 20.0,
                                                  decoration: BoxDecoration(
                                                    color: enabled
                                                        ? Colors.white
                                                        : Colors.black,
                                                    shape: BoxShape.circle,
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                        );
                                      }),
                                      const SizedBox(width: 10),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                            SizedBox(
                              height: height * 0.03,
                            ),
                            //wallet
                            GestureDetector(
                              onTap: () {
                                serviceProviderController.withDrawAmount.value =
                                    "";
                                Get.to(
                                    () => WalletPage(
                                        id: snapshot.data!.docs[0]["docId"]),
                                    transition: Transition.fadeIn);
                              },
                              child: SizedBox(
                                height: height * 0.065,
                                child: Card(
                                  color: Colors.white,
                                  elevation: 0.5,
                                  child: Center(
                                    child: Row(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        const SizedBox(
                                          width: 10,
                                        ),
                                        const Icon(
                                          Icons.payment,
                                          color: Color(0xff252525),
                                        ),
                                        const SizedBox(
                                          width: 10,
                                        ),
                                        Text(
                                          'Wallet',
                                          style: GoogleFonts.inter(
                                              color: Colors.black,
                                              fontSize: 16,
                                              fontWeight: FontWeight.w500),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            SizedBox(
                              height: height * 0.03,
                            ),
                            //Request
                            GestureDetector(
                              onTap: () {
                                // Stop the alarm tone when artisan opens Requests
                                serviceProviderController.stopMusic();
                                // serviceProviderController.addNewColumnToFirebaseCollection();
                                appController.userName.value =
                                    snapshot.data!.docs[0]["name"];
                                debugPrint(
                                    "Name ${appController.userName.value}");
                                Get.to(
                                    () => ServiceProviderRequestScreen(
                                        doc: snapshot.data!.docs[0]),
                                    transition: Transition.fadeIn);
                              },
                              child: SizedBox(
                                height: height * 0.065,
                                child: Card(
                                  color: Colors.white,
                                  elevation: 0.5,
                                  child: Center(
                                    child: Row(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        const SizedBox(
                                          width: 10,
                                        ),
                                        Obx(() => serviceProviderController
                                                .requestList.isEmpty
                                            ? const SizedBox()
                                            : Badge(
                                                label: Text(
                                                    serviceProviderController
                                                        .requestList.length
                                                        .toString()),
                                                child: const Icon(Icons
                                                    .home_repair_service_outlined),
                                              )),
                                        const SizedBox(
                                          width: 10,
                                        ),
                                        Text(
                                          'Requests',
                                          style: GoogleFonts.inter(
                                              color: Colors.black,
                                              fontSize: 16,
                                              fontWeight: FontWeight.w500),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            SizedBox(
                              height: height * 0.03,
                            ),

                            //Appointments
                            GestureDetector(
                              onTap: () {
                                final providerDocId =
                                    providerDoc.id.toString().trim();
                                final providerDocIdField =
                                    (snapshot.data!.docs[0]["docId"] ?? '')
                                        .toString()
                                        .trim();
                                final ids = <String>{
                                  providerListenerId,
                                  providerDocId,
                                  providerDocIdField,
                                  appController.userId.value.trim(),
                                }..removeWhere((e) => e.trim().isEmpty);

                                Get.to(
                                  () => ArtisanAppointmentsScreen(
                                    artisanIds: ids.toList(),
                                  ),
                                  transition: Transition.fadeIn,
                                );
                              },
                              child: SizedBox(
                                height: height * 0.065,
                                child: Card(
                                  color: Colors.white,
                                  elevation: 0.5,
                                  child: Center(
                                    child: Row(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        const SizedBox(width: 10),
                                        const Icon(
                                          Icons.event_note,
                                          color: Color(0xff252525),
                                        ),
                                        const SizedBox(width: 10),
                                        Text(
                                          'Appointments',
                                          style: GoogleFonts.inter(
                                            color: Colors.black,
                                            fontSize: 16,
                                            fontWeight: FontWeight.w500,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            SizedBox(
                              height: height * 0.03,
                            ),

                            //Notifications
                            SizedBox(
                              height: height * 0.065,
                              child: GestureDetector(
                                onTap: () {
                                  navigateToPage(
                                      context: context,
                                      pageName: const NotificationPageView(
                                          type: "service"));
                                },
                                child: Card(
                                  color: Colors.white,
                                  elevation: 0.6,
                                  child: Center(
                                    child: Row(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        const SizedBox(
                                          width: 10,
                                        ),
                                        const Icon(
                                          Icons.notifications_none_outlined,
                                          color: Color(0xff252525),
                                        ),
                                        const SizedBox(
                                          width: 10,
                                        ),
                                        Text(
                                          'Notifications',
                                          style: GoogleFonts.inter(
                                              color: Colors.black,
                                              fontSize: 16,
                                              fontWeight: FontWeight.w500),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            SizedBox(
                              height: height * 0.03,
                            ),

                            // Voice AI
                            GestureDetector(
                              onTap: () {
                                Get.to(
                                  () => LivekitVoiceAssistant(
                                    role: 'artisan',
                                    providerDoc: providerDoc,
                                    providerListenerId: providerListenerId,
                                  ),
                                  transition: Transition.fadeIn,
                                );
                              },
                              child: SizedBox(
                                height: height * 0.065,
                                child: Card(
                                  color: Colors.white,
                                  elevation: 0.5,
                                  child: Center(
                                    child: Row(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        const SizedBox(width: 10),
                                        const Icon(
                                          Icons.mic,
                                          color: Color(0xff252525),
                                        ),
                                        const SizedBox(width: 10),
                                        Text(
                                          'Voice AI',
                                          style: GoogleFonts.inter(
                                            color: Colors.black,
                                            fontSize: 16,
                                            fontWeight: FontWeight.w500,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            SizedBox(
                              height: height * 0.03,
                            ),

                            //LogOut
                            GestureDetector(
                              onTap: () async {
                                // Clear FCM token from Firestore BEFORE signing out
                                // so this artisan stops receiving push notifications.
                                await NotificationService.clearFcmTokenOnSignOut();
                                appController.clearCredentials();
                                await FirebaseAuth.instance
                                    .signOut()
                                    .then((value) {
                                  // appController.clearCredentials();
                                  Navigator.pushReplacement(
                                      context,
                                      MaterialPageRoute(
                                          builder: (context) => const Login()));
                                });
                              },
                              child: SizedBox(
                                height: height * 0.065,
                                child: Card(
                                  color: Colors.white,
                                  elevation: 0.5,
                                  child: Center(
                                    child: Row(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        const SizedBox(
                                          width: 10,
                                        ),
                                        const Icon(
                                          Icons.logout_outlined,
                                          color: Color(0xff252525),
                                        ),
                                        const SizedBox(
                                          width: 10,
                                        ),
                                        Text(
                                          'Log Out',
                                          style: GoogleFonts.inter(
                                              color: Colors.black,
                                              fontSize: 16,
                                              fontWeight: FontWeight.w500),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            // GestureDetector(
                            //   onTap: () async {
                            //     serviceProviderController.getMusicFile();
                            //   },
                            //   child: SizedBox(
                            //     height: height * 0.065,
                            //     child: Card(
                            //       color: Colors.white,
                            //       elevation: 0.5,
                            //       child: Center(
                            //         child: Row(
                            //           crossAxisAlignment: CrossAxisAlignment.start,
                            //           children: [
                            //             const SizedBox(
                            //               width: 10,
                            //             ),
                            //             const Icon(
                            //               Icons.music_note_rounded,
                            //               color: Color(0xff252525),
                            //             ),
                            //             const SizedBox(
                            //               width: 10,
                            //             ),
                            //             Text(
                            //               'Get Music File',
                            //               style: GoogleFonts.inter(
                            //                   color: Colors.black,
                            //                   fontSize: 16,
                            //                   fontWeight: FontWeight.w500),
                            //             ),
                            //           ],
                            //         ),
                            //       ),
                            //     ),
                            //   ),
                            // ),
                          ],
                        ),
                      )
                    ],
                  );
                } else {
                  return Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      SizedBox(
                          height:
                              MediaQuery.of(context).size.height / 1.8 - 100),
                      const Text("Please wait...!"),
                      const SizedBox(height: 20),
                      const CircularProgressIndicator(color: Color(0xFFc5a520)),
                      const SizedBox(height: 20),
                      const Text("No Artisan is found"),
                      SizedBox(
                          height: MediaQuery.of(context).size.height / 2 - 100),
                    ],
                  );
                }
              },
            )
          ],
        ),
      )),
    );
  }
}
