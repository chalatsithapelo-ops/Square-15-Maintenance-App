import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../support_cases/support_cases_screen.dart';
import '../admin/admin_user_management_screen.dart';
import '../service_areas/service_areas_screen.dart';
import '../setup/setup_screen.dart';
import '../data/assistant_monitoring_screen.dart';

/// Operations Hub — replaces the redundant Bookings & RFQs tab.
/// Gives the admin a quick overview of system health and fast access
/// to key sub-screens that are otherwise buried in menus.
class OperationsHubScreen extends StatefulWidget {
  const OperationsHubScreen({super.key});

  @override
  State<OperationsHubScreen> createState() => _OperationsHubScreenState();
}

class _OperationsHubScreenState extends State<OperationsHubScreen> {
  final _firestore = FirebaseFirestore.instance;

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: () async => setState(() {}),
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _buildQuickStatsSection(),
          const SizedBox(height: 20),
          _buildQuickActionsSection(context),
          const SizedBox(height: 20),
          _buildRecentActivitySection(),
        ],
      ),
    );
  }

  // ──────────────── Quick Stats ────────────────

  Widget _buildQuickStatsSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Quick Stats',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(child: _statCard('Pending Orders', _countByStatus('pending'), Colors.orange)),
            const SizedBox(width: 8),
            Expanded(child: _statCard('In Progress', _countByStatus('progress'), Colors.blue)),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(child: _statCard('Open RFQs', _countOpenRfqs(), Colors.purple)),
            const SizedBox(width: 8),
            Expanded(child: _statCard('Help Tickets', _countHelpTickets(), Colors.red)),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(child: _statCard('Active Artisans', _countActiveArtisans(), Colors.green)),
            const SizedBox(width: 8),
            Expanded(child: _statCard('Total Users', _countCollection('users'), Colors.teal)),
          ],
        ),
      ],
    );
  }

  Widget _statCard(String label, Future<int> countFuture, Color color) {
    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 12),
        child: Column(
          children: [
            FutureBuilder<int>(
              future: countFuture,
              builder: (context, snap) {
                if (snap.connectionState == ConnectionState.waiting) {
                  return SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: color,
                    ),
                  );
                }
                return Text(
                  '${snap.data ?? 0}',
                  style: TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.bold,
                    color: color,
                  ),
                );
              },
            ),
            const SizedBox(height: 4),
            Text(
              label,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12,
                color: Colors.grey.shade700,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<int> _countByStatus(String status) async {
    try {
      final snap = await _firestore
          .collection('futureBookings')
          .where('status', isEqualTo: status)
          .count()
          .get();
      return snap.count ?? 0;
    } catch (_) {
      // Fallback for older Firestore SDK without count()
      try {
        final snap = await _firestore
            .collection('futureBookings')
            .where('status', isEqualTo: status)
            .get();
        return snap.docs.length;
      } catch (_) {
        return 0;
      }
    }
  }

  Future<int> _countOpenRfqs() async {
    try {
      final statuses = [
        'pending_admin_review',
        'under_negotiation',
        'rfq_approved_waiting_assignment',
        'pending_artisan_acceptance',
      ];
      final snap = await _firestore
          .collection('futureBookings')
          .where('rfq_status', whereIn: statuses)
          .get();
      return snap.docs.length;
    } catch (_) {
      return 0;
    }
  }

  Future<int> _countHelpTickets() async {
    try {
      final snap = await _firestore.collection('help_center').get();
      int count = 0;
      for (final doc in snap.docs) {
        final data = doc.data();
        if ((data['unread'] ?? 0) > 0) count++;
      }
      return count;
    } catch (_) {
      return 0;
    }
  }

  Future<int> _countActiveArtisans() async {
    try {
      final snap = await _firestore
          .collection('serviceProvider')
          .where('isOnline', isEqualTo: true)
          .get();
      return snap.docs.length;
    } catch (_) {
      return 0;
    }
  }

  Future<int> _countCollection(String name) async {
    try {
      final snap = await _firestore.collection(name).count().get();
      return snap.count ?? 0;
    } catch (_) {
      try {
        final snap = await _firestore.collection(name).get();
        return snap.docs.length;
      } catch (_) {
        return 0;
      }
    }
  }

  // ──────────────── Quick Actions ────────────────

  Widget _buildQuickActionsSection(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Quick Actions',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _actionChip(
              context,
              icon: Icons.support_agent,
              label: 'Support Cases',
              color: Colors.indigo,
              onTap: () => Get.to(
                () => const SupportCasesScreen(),
                transition: Transition.cupertino,
              ),
            ),
            _actionChip(
              context,
              icon: Icons.admin_panel_settings,
              label: 'Admin Users',
              color: Colors.brown,
              onTap: () => Get.to(
                () => const AdminUserManagementScreen(),
                transition: Transition.cupertino,
              ),
            ),
            _actionChip(
              context,
              icon: Icons.map,
              label: 'Service Areas',
              color: Colors.teal,
              onTap: () => Get.to(
                () => const ServiceAreasScreen(),
                transition: Transition.cupertino,
              ),
            ),
            _actionChip(
              context,
              icon: Icons.settings,
              label: 'AI Agent Setup',
              color: Colors.deepPurple,
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const SetupScreen()),
              ),
            ),
            _actionChip(
              context,
              icon: Icons.monitor_heart,
              label: 'Monitoring',
              color: Colors.blue,
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (_) => const AssistantMonitoringScreen()),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _actionChip(
    BuildContext context, {
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onTap,
  }) {
    return ActionChip(
      avatar: Icon(icon, color: color, size: 18),
      label: Text(label),
      onPressed: onTap,
      backgroundColor: color.withOpacity(0.1),
      side: BorderSide(color: color.withOpacity(0.3)),
    );
  }

  // ──────────────── Recent Activity ────────────────

  Widget _buildRecentActivitySection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Recent Activity',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 12),
        StreamBuilder<QuerySnapshot>(
          stream: _firestore
              .collection('futureBookings')
              .orderBy('createdAt', descending: true)
              .limit(10)
              .snapshots(),
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snapshot.hasError) {
              return Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    'Unable to load recent activity: ${snapshot.error}',
                    style: TextStyle(color: Colors.grey.shade600),
                  ),
                ),
              );
            }

            final docs = snapshot.data?.docs ?? [];
            if (docs.isEmpty) {
              return Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    'No recent bookings.',
                    style: TextStyle(color: Colors.grey.shade600),
                  ),
                ),
              );
            }

            return Card(
              elevation: 2,
              child: Column(
                children: docs.map((doc) {
                  final data = doc.data() as Map<String, dynamic>? ?? {};
                  final status = (data['status'] ?? '').toString();
                  final category =
                      (data['category'] ?? data['serviceCategory'] ?? '')
                          .toString();
                  final rfqNumber =
                      (data['rfq_number'] ?? data['rfqNumber'] ?? '')
                          .toString();
                  final createdAt = data['createdAt'];
                  String timeStr = '';
                  if (createdAt is Timestamp) {
                    final dt = createdAt.toDate();
                    timeStr =
                        '${dt.day}/${dt.month}/${dt.year} ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
                  }

                  return ListTile(
                    dense: true,
                    leading: Icon(
                      _statusIcon(status),
                      color: _statusColor(status),
                      size: 20,
                    ),
                    title: Text(
                      rfqNumber.isNotEmpty
                          ? rfqNumber
                          : (category.isNotEmpty ? category : doc.id),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      '${_statusLabel(status)}${timeStr.isNotEmpty ? ' • $timeStr' : ''}',
                      style:
                          TextStyle(fontSize: 11, color: Colors.grey.shade600),
                    ),
                    trailing: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: _statusColor(status).withOpacity(0.1),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        _statusLabel(status),
                        style: TextStyle(
                          fontSize: 10,
                          color: _statusColor(status),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  );
                }).toList(),
              ),
            );
          },
        ),
      ],
    );
  }

  IconData _statusIcon(String status) {
    switch (status.toLowerCase()) {
      case 'pending':
        return Icons.hourglass_top;
      case 'progress':
      case 'in_progress':
        return Icons.engineering;
      case 'completed':
        return Icons.check_circle;
      case 'closed':
        return Icons.lock;
      case 'cancelled':
      case 'canceled':
        return Icons.cancel;
      default:
        return Icons.circle_outlined;
    }
  }

  Color _statusColor(String status) {
    switch (status.toLowerCase()) {
      case 'pending':
        return Colors.orange;
      case 'progress':
      case 'in_progress':
        return Colors.blue;
      case 'completed':
        return Colors.green;
      case 'closed':
        return Colors.grey;
      case 'cancelled':
      case 'canceled':
        return Colors.red;
      default:
        return Colors.blueGrey;
    }
  }

  String _statusLabel(String status) {
    switch (status.toLowerCase()) {
      case 'pending':
        return 'Pending';
      case 'progress':
      case 'in_progress':
        return 'In Progress';
      case 'completed':
        return 'Completed';
      case 'closed':
        return 'Closed';
      case 'cancelled':
      case 'canceled':
        return 'Cancelled';
      case 'pending_admin_review':
        return 'RFQ Review';
      case 'under_negotiation':
        return 'Negotiation';
      case 'rfq_approved_waiting_assignment':
        return 'Awaiting Assignment';
      default:
        return status.isNotEmpty ? status : 'Unknown';
    }
  }
}
