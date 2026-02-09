import 'package:admain_maintence_app/controllers/app_controller.dart';
import 'package:admain_maintence_app/screen/service_provider/ServiceProvidesrRegistration.dart';
import 'package:admain_maintence_app/screen/service_provider/service_provider_detail_page.dart';
import 'package:admain_maintence_app/utily/const.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:timeago/timeago.dart' as timeago;

// ────────────────────────────────────────────────────────────────────────
//  Artisan management screen – searchable list with online/offline status,
//  rating, active badge, skills, and job count
// ────────────────────────────────────────────────────────────────────────

class ManagingServicesProviders extends StatefulWidget {
  const ManagingServicesProviders({super.key});

  @override
  State<ManagingServicesProviders> createState() =>
      _ManagingServicesProvidersState();
}

class _ManagingServicesProvidersState extends State<ManagingServicesProviders> {
  final AppController appController = Get.find();
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  String _statusFilter = 'all'; // 'all', 'active', 'inactive', 'online'

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  // ── helpers ──────────────────────────────────────────────────────────

  bool _isOnline(Map<String, dynamic> data) {
    final onlineVal = data['is_online'];
    final isMarkedOnline =
        onlineVal == true || onlineVal == 'true' || onlineVal == 1;

    if (isMarkedOnline) {
      final lastSeen = _toDateTime(data['last_seen']);
      if (lastSeen != null) {
        return DateTime.now().difference(lastSeen).inMinutes < 15;
      }
      return true;
    }

    final lastSeen = _toDateTime(data['last_seen']);
    if (lastSeen != null &&
        DateTime.now().difference(lastSeen).inMinutes < 2) {
      return true;
    }
    return false;
  }

  bool _isActive(Map<String, dynamic> data) {
    final active = (data['active'] ?? '').toString().toLowerCase();
    return active == 'y' || active == 'yes' || active == 'true';
  }

  DateTime? _toDateTime(dynamic value) {
    if (value == null) return null;
    if (value is Timestamp) return value.toDate();
    if (value is DateTime) return value;
    if (value is String) return DateTime.tryParse(value);
    return null;
  }

  String _lastSeenText(Map<String, dynamic> data) {
    if (_isOnline(data)) return 'Online now';
    final lastSeen = _toDateTime(data['last_seen']);
    if (lastSeen == null) return 'Never seen';
    return 'Last seen ${timeago.format(lastSeen)}';
  }

  String _initials(String name) {
    final parts = name.trim().split(RegExp(r'\s+'));
    if (parts.isEmpty || parts[0].isEmpty) return '?';
    if (parts.length == 1) return parts[0][0].toUpperCase();
    return '${parts[0][0]}${parts[1][0]}'.toUpperCase();
  }

  double _rating(Map<String, dynamic> data) {
    final r = data['rating'] ?? data['averageRating'] ?? data['average_rating'];
    if (r == null) return 0.0;
    if (r is num) return r.toDouble();
    return double.tryParse(r.toString()) ?? 0.0;
  }

  int _jobCount(Map<String, dynamic> data) {
    final c = data['completedJobs'] ??
        data['completed_jobs'] ??
        data['jobCount'] ??
        data['job_count'];
    if (c == null) return 0;
    if (c is num) return c.toInt();
    return int.tryParse(c.toString()) ?? 0;
  }

  String _skillsSummary(Map<String, dynamic> data) {
    final tasks = data['tasks'] ?? data['task'] ?? data['skills'];
    if (tasks is List && tasks.isNotEmpty) {
      final names = tasks
          .map((t) => t is Map ? (t['name'] ?? t['task_name'] ?? '') : t)
          .where((s) => s.toString().trim().isNotEmpty)
          .take(3)
          .toList();
      if (names.isNotEmpty) {
        final label = names.join(', ');
        if (tasks.length > 3) return '$label +${tasks.length - 3} more';
        return label;
      }
    }
    final category = (data['category'] ?? '').toString().trim();
    if (category.isNotEmpty) return category;
    return '';
  }

  bool _matchesSearch(Map<String, dynamic> data) {
    if (_searchQuery.isEmpty) return true;
    final q = _searchQuery.toLowerCase();
    final name = (data['name'] ?? '').toString().toLowerCase();
    final email = (data['email'] ?? '').toString().toLowerCase();
    final phone =
        (data['contact'] ?? data['phone'] ?? '').toString().toLowerCase();
    final skills = _skillsSummary(data).toLowerCase();
    return name.contains(q) ||
        email.contains(q) ||
        phone.contains(q) ||
        skills.contains(q);
  }

  bool _matchesStatusFilter(Map<String, dynamic> data) {
    switch (_statusFilter) {
      case 'active':
        return _isActive(data);
      case 'inactive':
        return !_isActive(data);
      case 'online':
        return _isOnline(data);
      default:
        return true;
    }
  }

  // ── build ──────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      appBar: AppBar(
        automaticallyImplyLeading: false,
        centerTitle: true,
        title: Text('Artisans',
            style:
                GoogleFonts.lato(fontSize: 22, fontWeight: FontWeight.w700)),
        actions: [
          IconButton(
            icon: const Icon(Icons.person_add_outlined, size: 24),
            tooltip: 'Register Artisan',
            onPressed: () => Get.to(
              () => const ServiceProviderRegistration(),
              transition: Transition.fadeIn,
            ),
          ),
          const SizedBox(width: 6),
        ],
      ),
      body: Column(
        children: [
          // ── Search bar ─────────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 14, 14, 4),
            child: TextField(
              controller: _searchController,
              onChanged: (v) => setState(() => _searchQuery = v),
              style: GoogleFonts.lato(fontSize: 15),
              decoration: InputDecoration(
                hintText: 'Search by name, email, phone or skill…',
                hintStyle:
                    GoogleFonts.lato(color: Colors.grey.shade500, fontSize: 14),
                prefixIcon:
                    Icon(Icons.search, color: Colors.grey.shade600, size: 22),
                suffixIcon: _searchQuery.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear, size: 20),
                        onPressed: () {
                          _searchController.clear();
                          setState(() => _searchQuery = '');
                        },
                      )
                    : null,
                filled: true,
                fillColor: Colors.white,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: Colors.grey.shade300),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide:
                      const BorderSide(color: Color(0xFF1565C0), width: 1.5),
                ),
              ),
            ),
          ),

          // ── Filter chips ───────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  _filterChip('All', 'all'),
                  const SizedBox(width: 8),
                  _filterChip('Active', 'active'),
                  const SizedBox(width: 8),
                  _filterChip('Inactive', 'inactive'),
                  const SizedBox(width: 8),
                  _filterChip('Online', 'online'),
                ],
              ),
            ),
          ),

          const SizedBox(height: 4),

          // ── Artisan list ───────────────────────────────────────────────
          Expanded(
            child: StreamBuilder<QuerySnapshot>(
              stream: FirebaseFirestore.instance
                  .collection('serviceProvider')
                  .snapshots(),
              builder: (context, snapshot) {
                if (!snapshot.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }

                final allDocs = snapshot.data!.docs;
                final filtered = allDocs.where((doc) {
                  final data = doc.data() as Map<String, dynamic>;
                  return _matchesSearch(data) && _matchesStatusFilter(data);
                }).toList();

                // Sort: online first → active first → alphabetical
                filtered.sort((a, b) {
                  final aData = a.data() as Map<String, dynamic>;
                  final bData = b.data() as Map<String, dynamic>;

                  final aOnline = _isOnline(aData) ? 0 : 1;
                  final bOnline = _isOnline(bData) ? 0 : 1;
                  if (aOnline != bOnline) return aOnline.compareTo(bOnline);

                  final aActive = _isActive(aData) ? 0 : 1;
                  final bActive = _isActive(bData) ? 0 : 1;
                  if (aActive != bActive) return aActive.compareTo(bActive);

                  return (aData['name'] ?? '')
                      .toString()
                      .toLowerCase()
                      .compareTo(
                          (bData['name'] ?? '').toString().toLowerCase());
                });

                // Counts
                final totalCount = allDocs.length;
                final activeCount = allDocs
                    .where(
                        (d) => _isActive(d.data() as Map<String, dynamic>))
                    .length;
                final onlineCount = allDocs
                    .where(
                        (d) => _isOnline(d.data() as Map<String, dynamic>))
                    .length;

                if (filtered.isEmpty) {
                  return Column(
                    children: [
                      _summaryBar(totalCount, activeCount, onlineCount),
                      const Expanded(
                        child: Center(
                          child: Text('No artisans found',
                              style: TextStyle(
                                  color: Colors.grey, fontSize: 16)),
                        ),
                      ),
                    ],
                  );
                }

                return Column(
                  children: [
                    _summaryBar(totalCount, activeCount, onlineCount),
                    Expanded(
                      child: ListView.separated(
                        padding: const EdgeInsets.fromLTRB(14, 4, 14, 20),
                        itemCount: filtered.length,
                        separatorBuilder: (_, __) =>
                            const SizedBox(height: 10),
                        itemBuilder: (context, index) {
                          final doc = filtered[index];
                          final data = doc.data() as Map<String, dynamic>;
                          return _artisanTile(data, doc);
                        },
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  // ── Widget helpers ─────────────────────────────────────────────────────

  Widget _summaryBar(int total, int active, int online) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 6),
      child: Row(
        children: [
          _summaryChip(Icons.people_alt_outlined, '$total total',
              Colors.grey.shade700),
          const SizedBox(width: 16),
          _summaryChip(
              Icons.check_circle_outline, '$active active', const Color(0xFF1565C0)),
          const SizedBox(width: 16),
          _summaryChip(
              Icons.circle, '$online online', const Color(0xFF4CAF50),
              iconSize: 10),
        ],
      ),
    );
  }

  Widget _summaryChip(IconData icon, String text, Color color,
      {double iconSize = 14}) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: iconSize, color: color),
        const SizedBox(width: 4),
        Text(text,
            style: GoogleFonts.lato(
                fontSize: 13, color: color, fontWeight: FontWeight.w500)),
      ],
    );
  }

  Widget _filterChip(String label, String value) {
    final selected = _statusFilter == value;
    return GestureDetector(
      onTap: () => setState(() => _statusFilter = value),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? const Color(0xFF1565C0) : Colors.white,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: selected ? const Color(0xFF1565C0) : Colors.grey.shade300,
          ),
        ),
        child: Text(
          label,
          style: GoogleFonts.lato(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: selected ? Colors.white : Colors.grey.shade700,
          ),
        ),
      ),
    );
  }

  Widget _artisanTile(Map<String, dynamic> data, DocumentSnapshot doc) {
    final name = (data['name'] ?? 'Unknown').toString();
    final email = (data['email'] ?? '').toString();
    final phone = (data['contact'] ?? data['phone'] ?? '').toString();
    final imageUrl = (data['image'] ?? '').toString().trim();
    final online = _isOnline(data);
    final active = _isActive(data);
    final lastSeen = _lastSeenText(data);
    final rating = _rating(data);
    final jobs = _jobCount(data);
    final skills = _skillsSummary(data);

    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(14),
      elevation: active ? 1.5 : 0.5,
      shadowColor: active ? Colors.black12 : Colors.transparent,
      child: Opacity(
        opacity: active ? 1.0 : 0.6,
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () => goTo(context, ServiceProviderDetailPage(data: doc)),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // ── Top row: avatar + name + badges ──
                Row(
                  children: [
                    // Avatar with online dot
                    Stack(
                      children: [
                        CircleAvatar(
                          radius: 28,
                          backgroundColor:
                              const Color(0xFF1565C0).withOpacity(0.15),
                          backgroundImage: imageUrl.isNotEmpty
                              ? NetworkImage(imageUrl)
                              : null,
                          onBackgroundImageError: imageUrl.isNotEmpty
                              ? (_, __) {}
                              : null,
                          child: imageUrl.isEmpty
                              ? Text(
                                  _initials(name),
                                  style: GoogleFonts.lato(
                                    fontSize: 19,
                                    fontWeight: FontWeight.w700,
                                    color: const Color(0xFF1565C0),
                                  ),
                                )
                              : null,
                        ),
                        Positioned(
                          right: 0,
                          bottom: 0,
                          child: Container(
                            width: 15,
                            height: 15,
                            decoration: BoxDecoration(
                              color: online
                                  ? const Color(0xFF4CAF50)
                                  : Colors.grey.shade400,
                              shape: BoxShape.circle,
                              border:
                                  Border.all(color: Colors.white, width: 2.5),
                            ),
                          ),
                        ),
                      ],
                    ),

                    const SizedBox(width: 14),

                    // Name + contact
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Flexible(
                                child: Text(
                                  name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: GoogleFonts.lato(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w600,
                                    color: Colors.black87,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              // Active / Inactive badge
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 8, vertical: 3),
                                decoration: BoxDecoration(
                                  color: active
                                      ? const Color(0xFF4CAF50).withOpacity(0.1)
                                      : Colors.red.shade50,
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Text(
                                  active ? 'Active' : 'Inactive',
                                  style: GoogleFonts.lato(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                    color: active
                                        ? const Color(0xFF4CAF50)
                                        : Colors.red.shade400,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 2),
                          if (email.isNotEmpty)
                            Text(
                              email,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: GoogleFonts.lato(
                                  fontSize: 13, color: Colors.grey.shade600),
                            ),
                          if (phone.isNotEmpty)
                            Text(
                              phone,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: GoogleFonts.lato(
                                  fontSize: 13, color: Colors.grey.shade600),
                            ),
                        ],
                      ),
                    ),

                    // Trailing chevron
                    Icon(Icons.chevron_right,
                        color: Colors.grey.shade400, size: 22),
                  ],
                ),

                const SizedBox(height: 10),

                // ── Bottom row: online status · rating · jobs · skills ──
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  decoration: BoxDecoration(
                    color: Colors.grey.shade50,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    children: [
                      // Online status
                      Icon(
                        online ? Icons.circle : Icons.access_time,
                        size: 10,
                        color: online
                            ? const Color(0xFF4CAF50)
                            : Colors.grey.shade500,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        lastSeen,
                        style: GoogleFonts.lato(
                          fontSize: 12,
                          color: online
                              ? const Color(0xFF4CAF50)
                              : Colors.grey.shade500,
                          fontWeight:
                              online ? FontWeight.w600 : FontWeight.w400,
                        ),
                      ),

                      const SizedBox(width: 14),

                      // Rating
                      if (rating > 0) ...[
                        const Icon(Icons.star_rounded,
                            size: 16, color: Color(0xFFFFC107)),
                        const SizedBox(width: 2),
                        Text(
                          rating.toStringAsFixed(1),
                          style: GoogleFonts.lato(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: Colors.grey.shade700,
                          ),
                        ),
                        const SizedBox(width: 14),
                      ],

                      // Job count
                      if (jobs > 0) ...[
                        Icon(Icons.work_outline,
                            size: 14, color: Colors.grey.shade600),
                        const SizedBox(width: 3),
                        Text(
                          '$jobs job${jobs == 1 ? '' : 's'}',
                          style: GoogleFonts.lato(
                            fontSize: 12,
                            color: Colors.grey.shade600,
                          ),
                        ),
                        const SizedBox(width: 14),
                      ],

                      // Skills
                      if (skills.isNotEmpty)
                        Expanded(
                          child: Text(
                            skills,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: GoogleFonts.lato(
                              fontSize: 12,
                              color: Colors.grey.shade500,
                              fontStyle: FontStyle.italic,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
