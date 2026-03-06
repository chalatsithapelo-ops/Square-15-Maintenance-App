import 'package:admain_maintence_app/controllers/app_controller.dart';
import 'package:admain_maintence_app/screen/bottomBar/widget/custom_icon.dart';
import 'package:admain_maintence_app/screen/category/category.dart';
import 'package:admain_maintence_app/screen/help_center/help_center.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

import '../operations/operations_hub_screen.dart';
import '../Chat/chatForm.dart';
import '../notification_screen/admin_notifications_inbox_screen.dart';
import '../notification_screen/notification_screen.dart';
import '../payments_screen/payments_screen.dart';
import '../service_provider/ManagingServicesProvider.dart';
import '../service_provider/ServiceProvidesrRegistration.dart';
import '../user/ShowAllUser.dart';
import '../pricing_guide/pricing_guide_management_screen.dart';
import '../setup/setup_screen.dart';
import '../data/data_dashboard_screen.dart';
import '../../services/admin_popup_alerts_service.dart';
import '../rfq/admin_rfq_list_screen.dart';
import '../support_cases/support_cases_screen.dart';
import '../admin/admin_user_management_screen.dart';
import '../service_areas/service_areas_screen.dart';

class BottomBar extends StatefulWidget {
  const BottomBar({super.key});

  @override
  State<BottomBar> createState() => _BottomBarState();
}

class _BottomBarState extends State<BottomBar> {
  final AppController appController = Get.find();
  late final AdminPopupAlertsService _popupAlerts;

  static const String _backendUrl = 'https://square15-livekit-backend.onrender.com';

  @override
  void initState() {
    super.initState();
    _popupAlerts = AdminPopupAlertsService(appController: appController);
    _popupAlerts.start();
  }

  @override
  void dispose() {
    _popupAlerts.dispose();
    super.dispose();
  }

  Widget getSelectedWidget({required int currentIndex}) {
    Widget widget;
    switch (currentIndex) {
      case 0:
        widget = const ManagingUser();
        break;
      case 1:
        widget = const ManagingServicesProviders();
        break;
      case 2:
        widget = const NotificationScreen();
        break;
      case 3:
        widget = const PaymentsScreen();
        break;
      case 4:
        widget = const CategoryScreen();
        break;
      case 5:
        widget = const OperationsHubScreen();
        break;
      case 6:
        widget = const PricingGuideManagementScreen(); // NEW: Pricing Guide
        break;
      case 7:
        widget = const HelpCenter();
        break;
      case 8:
        widget = const DataDashboardScreen();
        break;
      case 9:
        widget = const AdminRFQListScreen();
        break;
      default:
        widget = const MyChatForm();
        break;
    }
    return widget;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Admin Panel'),
        backgroundColor: Colors.green.shade900,
        actions: [
          PopupMenuButton<String>(
            tooltip: 'More',
            icon: const Icon(Icons.more_vert),
            onSelected: (value) async {
              final messenger = ScaffoldMessenger.of(context);
              switch (value) {
                case 'support_cases':
                  Get.to(
                    () => const SupportCasesScreen(),
                    transition: Transition.cupertino,
                  );
                  return;
                case 'admin_users':
                  Get.to(
                    () => const AdminUserManagementScreen(),
                    transition: Transition.cupertino,
                  );
                  return;
                case 'service_areas':
                  Get.to(
                    () => const ServiceAreasScreen(),
                    transition: Transition.cupertino,
                  );
                  return;
                case 'inbox':
                  Get.to(
                    () => const AdminNotificationsInboxScreen(),
                    transition: Transition.cupertino,
                  );
                  return;
                case 'backend':
                  Clipboard.setData(const ClipboardData(text: _backendUrl));
                  messenger.showSnackBar(
                    const SnackBar(content: Text('Backend URL copied.')),
                  );
                  return;
                case 'token':
                  final user = FirebaseAuth.instance.currentUser;
                  if (user == null) {
                    messenger.showSnackBar(
                      const SnackBar(content: Text('Not logged in.')),
                    );
                    return;
                  }
                  try {
                    final token = await user.getIdToken(true);
                    final t = (token ?? '').trim();
                    if (t.isEmpty) {
                      messenger.showSnackBar(
                        const SnackBar(content: Text('Failed to get ID token.')),
                      );
                      return;
                    }
                    await Clipboard.setData(ClipboardData(text: t));
                    messenger.showSnackBar(
                      SnackBar(content: Text('ID token copied (${t.length} chars).')),
                    );
                  } catch (e) {
                    messenger.showSnackBar(
                      SnackBar(content: Text('Failed to get token: $e')),
                    );
                  }
                  return;
              }
            },
            itemBuilder: (context) => [
              const PopupMenuItem(value: 'support_cases', child: Row(
                children: [
                  Icon(Icons.support_agent, size: 20),
                  SizedBox(width: 8),
                  Text('Support Cases'),
                ],
              )),
              const PopupMenuItem(value: 'admin_users', child: Row(
                children: [
                  Icon(Icons.admin_panel_settings, size: 20),
                  SizedBox(width: 8),
                  Text('Admin Users'),
                ],
              )),
              const PopupMenuItem(value: 'service_areas', child: Row(
                children: [
                  Icon(Icons.map, size: 20),
                  SizedBox(width: 8),
                  Text('Service Areas'),
                ],
              )),
              const PopupMenuItem(value: 'inbox', child: Text('Open Admin Inbox')),
              if (kDebugMode) PopupMenuItem(value: 'token', child: Text('Copy Firebase ID token')),
              if (kDebugMode) PopupMenuItem(value: 'backend', child: Text('Copy backend URL')),
            ],
          ),
          // Setup/Configuration button
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: 'System Setup',
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => const SetupScreen(),
                ),
              );
            },
          ),
        ],
      ),
      body: Obx(() =>
          getSelectedWidget(currentIndex: appController.currentIndex.value)),
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
      floatingActionButton: FloatingActionButton(
          backgroundColor: Colors.green.shade900,
          onPressed: () {
            appController.availableTaskList.clear();
            appController.savingTaskList.clear();
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (BuildContext context) {
                  return const ServiceProviderRegistration();
                },
              ),
            );
          },
          child: const Icon(Icons.add, color: Colors.white)),
      bottomNavigationBar: BottomAppBar(
        clipBehavior: Clip.none,
        height: 70,
        color: Colors.white,
        shape: const CircularNotchedRectangle(),
        notchMargin: 10,
        child: Obx(() => Padding(
              padding: const EdgeInsets.only(right: 60),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                // Users
                CustomIcon(
                  icon: Icons.people,
                  backgroundColor: appController.currentIndex.value == 0
                      ? Colors.green.shade900
                      : Colors.grey,
                  iconColor: appController.currentIndex.value == 0
                      ? Colors.white
                      : Colors.black,
                  onTap: () {
                    appController.currentIndex.value = 0;
                  },
                ),
                // Service Providers
                CustomIcon(
                  icon: Icons.person,
                  backgroundColor: appController.currentIndex.value == 1
                      ? Colors.green.shade900
                      : Colors.grey,
                  iconColor: appController.currentIndex.value == 1
                      ? Colors.white
                      : Colors.black,
                  onTap: () {
                    appController.currentIndex.value = 1;
                  },
                ),
                // Notifications
                CustomIcon(
                  icon: Icons.notifications,
                  backgroundColor: appController.currentIndex.value == 2
                      ? Colors.green.shade900
                      : Colors.grey,
                  iconColor: appController.currentIndex.value == 2
                      ? Colors.white
                      : Colors.black,
                  onTap: () {
                    appController.currentIndex.value = 2;
                  },
                ),
                // Payments
                CustomIcon(
                  icon: Icons.monetization_on_outlined,
                  backgroundColor: appController.currentIndex.value == 3
                      ? Colors.green.shade900
                      : Colors.grey,
                  iconColor: appController.currentIndex.value == 3
                      ? Colors.white
                      : Colors.black,
                  onTap: () {
                    appController.currentIndex.value = 3;
                  },
                ),
                // Categories
                CustomIcon(
                  icon: Icons.category,
                  backgroundColor: appController.currentIndex.value == 4
                      ? Colors.green.shade900
                      : Colors.grey,
                  iconColor: appController.currentIndex.value == 4
                      ? Colors.white
                      : Colors.black,
                  onTap: () {
                    appController.currentIndex.value = 4;
                  },
                ),
                // Operations Hub
                CustomIcon(
                  icon: Icons.dashboard,
                  backgroundColor: appController.currentIndex.value == 5
                      ? Colors.green.shade900
                      : Colors.grey,
                  iconColor: appController.currentIndex.value == 5
                      ? Colors.white
                      : Colors.black,
                  onTap: () {
                    appController.currentIndex.value = 5;
                  },
                ),
                // Pricing Guide
                CustomIcon(
                  icon: Icons.price_change,
                  backgroundColor: appController.currentIndex.value == 6
                      ? Colors.green.shade900
                      : Colors.grey,
                  iconColor: appController.currentIndex.value == 6
                      ? Colors.white
                      : Colors.black,
                  onTap: () {
                    appController.currentIndex.value = 6;
                  },
                ),
                // Analytics
                CustomIcon(
                  icon: Icons.analytics,
                  backgroundColor: appController.currentIndex.value == 8
                      ? Colors.green.shade900
                      : Colors.grey,
                  iconColor: appController.currentIndex.value == 8
                      ? Colors.white
                      : Colors.black,
                  onTap: () {
                    appController.currentIndex.value = 8;
                  },
                ),
                // RFQ with badge
                Stack(
                  clipBehavior: Clip.none,
                  children: [
                    CustomIcon(
                      icon: Icons.request_quote,
                      backgroundColor: appController.currentIndex.value == 9
                          ? Colors.green.shade900
                          : Colors.grey,
                      iconColor: appController.currentIndex.value == 9
                          ? Colors.white
                          : Colors.black,
                      onTap: () {
                        appController.currentIndex.value = 9;
                      },
                    ),
                    StreamBuilder<QuerySnapshot>(
                      stream: FirebaseFirestore.instance
                          .collection('futureBookings')
                          .where('rfq_status', whereIn: [
                            'pending_admin_review',
                            'under_negotiation',
                            'rfq_approved_waiting_assignment',
                            'pending_artisan_acceptance',
                          ])
                          .snapshots(),
                      builder: (context, primarySnapshot) {
                        return StreamBuilder<QuerySnapshot>(
                          stream: FirebaseFirestore.instance
                              .collection('future_bookings')
                              .where('rfq_status', whereIn: [
                                'pending_admin_review',
                                'under_negotiation',
                                'rfq_approved_waiting_assignment',
                                'pending_artisan_acceptance',
                              ])
                              .snapshots(),
                          builder: (context, legacySnapshot) {
                            final primaryCount =
                                primarySnapshot.data?.docs.length ?? 0;
                            final legacyCount =
                                legacySnapshot.data?.docs.length ?? 0;
                            final count = primaryCount + legacyCount;

                            if (count > 0) {
                              return Positioned(
                                right: -2,
                                top: -4,
                                child: Container(
                                  padding: const EdgeInsets.all(4),
                                  constraints: const BoxConstraints(
                                    minWidth: 16,
                                    minHeight: 16,
                                  ),
                                  decoration: const BoxDecoration(
                                    color: Colors.red,
                                    shape: BoxShape.circle,
                                  ),
                                  child: Center(
                                    child: Text(
                                      count > 99 ? '99+' : count.toString(),
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 9,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ),
                                ),
                              );
                            }

                            return const SizedBox();
                          },
                        );
                      },
                    ),
                  ],
                ),
                // Help Center with badge
                Stack(
                  clipBehavior: Clip.none,
                  children: [
                    CustomIcon(
                      icon: Icons.help,
                      backgroundColor: appController.currentIndex.value == 7
                          ? Colors.green.shade900
                          : Colors.grey,
                      iconColor: appController.currentIndex.value == 7
                          ? Colors.white
                          : Colors.black,
                      onTap: () {
                        appController.currentIndex.value = 7;
                      },
                    ),
                    StreamBuilder<bool>(
                      stream: FirebaseFirestore.instance
                          .collection('help_center')
                          .snapshots()
                          .map((snapshot) {
                        for (var doc in snapshot.docs) {
                          final data = doc.data();
                          if ((data['unread'] ?? 0) > 0) {
                            return true;
                          }
                        }
                        return false;
                      }),
                      builder: (context, snapshot) {
                        final hasUnread = snapshot.data ?? false;
                        if (hasUnread) {
                          return Positioned(
                            right: -2,
                            top: -4,
                            child: Container(
                              width: 10,
                              height: 10,
                              decoration: const BoxDecoration(
                                color: Colors.red,
                                shape: BoxShape.circle,
                              ),
                            ),
                          );
                        } else {
                          return const SizedBox();
                        }
                      },
                    ),
                  ],
                ),
              ],
            ),
            )),
      ),
    );
  }
}
