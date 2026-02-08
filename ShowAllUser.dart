import 'package:admain_maintence_app/controllers/app_controller.dart';
import 'package:admain_maintence_app/screen/user/bank_page.dart';
import 'package:admain_maintence_app/screen/user/request_page.dart';
import 'package:admain_maintence_app/screen/user/user_detail_page.dart';
import 'package:admain_maintence_app/utily/const.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:timeago/timeago.dart' as timeago;

// ───────────────────────────────────────────────────────────────────────
//  Users management screen – searchable list with online/offline status
// ───────────────────────────────────────────────────────────────────────

class ManagingUser extends StatefulWidget {
  const ManagingUser({super.key});

  @override
  State<ManagingUser> createState() => _ManagingUserState();
}

class _ManagingUserState extends State<ManagingUser> {
  final AppController appController = Get.find();
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  String _statusFilter = 'all'; // 'all', 'online', 'offline'

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  // ── helpers ────────────────────────────────────────────────────────────

  bool _isOnline(Map<String, dynamic> data) {
    if (data['is_online'] == true) {
      // Also check last_seen — if it's been more than 5 min, treat as offline
      final lastSeen = _toDateTime(data['last_seen']);
      if (lastSeen != null) {
        return DateTime.now().difference(lastSeen).inMinutes < 5;
      }
      return true;
    }
    return false;
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

  bool _matchesSearch(Map<String, dynamic> data) {
    if (_searchQuery.isEmpty) return true;
    final q = _searchQuery.toLowerCase();
    final name = (data['name'] ?? '').toString().toLowerCase();
    final email = (data['email'] ?? '').toString().toLowerCase();
    final phone =
        (data['contact'] ?? data['phone'] ?? '').toString().toLowerCase();
    return name.contains(q) || email.contains(q) || phone.contains(q);
  }

  bool _matchesStatusFilter(Map<String, dynamic> data) {
    if (_statusFilter == 'all') return true;
    if (_statusFilter == 'online') return _isOnline(data);
    return !_isOnline(data);
  }

  // ── build ──────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      appBar: AppBar(
        leading: GestureDetector(
          onTap: () =>
              Get.to(() => const BankPage(), transition: Transition.fadeIn),
          child: const Icon(Icons.account_balance_outlined, size: 26),
        ),
        centerTitle: true,
        title: Text('Users',
            style: GoogleFonts.lato(
                fontSize: 22, fontWeight: FontWeight.w700)),
        actions: [
          GestureDetector(
            onTap: () =>
                Get.to(() => const RequestPage(), transition: Transition.fadeIn),
            child: Stack(
              clipBehavior: Clip.none,
              alignment: Alignment.topLeft,
              children: [
                const Icon(Icons.notifications, size: 26),
                Positioned(
                  right: 10,
                  top: -8,
                  child: StreamBuilder(
                    stream: appController.requests
                        .where('status', isEqualTo: 'pending')
                        .snapshots(),
                    builder: (context, snapshot) {
                      if (!snapshot.hasData) return const SizedBox();
                      final count = snapshot.data?.docs.length ?? 0;
                      if (count == 0) return const SizedBox();
                      return Container(
                        padding: const EdgeInsets.all(4),
                        decoration: const BoxDecoration(
                          color: Colors.red,
                          shape: BoxShape.circle,
                        ),
                        child: Text('$count',
                            style: GoogleFonts.lato(
                                fontSize: 12, color: Colors.white)),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
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
                hintText: 'Search by name, email or phone…',
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
                      const BorderSide(color: Color(0xFFD4A843), width: 1.5),
                ),
              ),
            ),
          ),

          // ── Status filter chips ────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
            child: Row(
              children: [
                _filterChip('All', 'all'),
                const SizedBox(width: 8),
                _filterChip('Online', 'online'),
                const SizedBox(width: 8),
                _filterChip('Offline', 'offline'),
              ],
            ),
          ),

          const SizedBox(height: 4),

          // ── User list ──────────────────────────────────────────────────
          Expanded(
            child: StreamBuilder<QuerySnapshot>(
              stream: FirebaseFirestore.instance
                  .collection('users')
                  .where('isUser', isEqualTo: true)
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

                // Sort: online first, then by name
                filtered.sort((a, b) {
                  final aData = a.data() as Map<String, dynamic>;
                  final bData = b.data() as Map<String, dynamic>;
                  final aOnline = _isOnline(aData) ? 0 : 1;
                  final bOnline = _isOnline(bData) ? 0 : 1;
                  if (aOnline != bOnline) return aOnline.compareTo(bOnline);
                  return (aData['name'] ?? '')
                      .toString()
                      .toLowerCase()
                      .compareTo(
                          (bData['name'] ?? '').toString().toLowerCase());
                });

                // ── Summary bar ──
                final onlineCount =
                    allDocs.where((d) => _isOnline(d.data() as Map<String, dynamic>)).length;
                final totalCount = allDocs.length;

                if (filtered.isEmpty) {
                  return Column(
                    children: [
                      _summaryBar(totalCount, onlineCount),
                      const Expanded(
                        child: Center(
                          child: Text('No users found',
                              style: TextStyle(
                                  color: Colors.grey, fontSize: 16)),
                        ),
                      ),
                    ],
                  );
                }

                return Column(
                  children: [
                    _summaryBar(totalCount, onlineCount),
                    Expanded(
                      child: ListView.separated(
                        padding: const EdgeInsets.fromLTRB(14, 4, 14, 20),
                        itemCount: filtered.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 8),
                        itemBuilder: (context, index) {
                          final doc = filtered[index];
                          final data = doc.data() as Map<String, dynamic>;
                          return _userTile(data, doc);
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

  Widget _summaryBar(int total, int online) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 4),
      child: Row(
        children: [
          Text(
            '$total user${total == 1 ? '' : 's'}',
            style: GoogleFonts.lato(
                fontSize: 13,
                color: Colors.grey.shade600,
                fontWeight: FontWeight.w500),
          ),
          const SizedBox(width: 12),
          Container(
            width: 8,
            height: 8,
            decoration: const BoxDecoration(
              color: Color(0xFF4CAF50),
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 4),
          Text(
            '$online online',
            style: GoogleFonts.lato(
                fontSize: 13,
                color: const Color(0xFF4CAF50),
                fontWeight: FontWeight.w500),
          ),
        ],
      ),
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
          color: selected ? const Color(0xFFD4A843) : Colors.white,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: selected ? const Color(0xFFD4A843) : Colors.grey.shade300,
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

  Widget _userTile(Map<String, dynamic> data, DocumentSnapshot doc) {
    final name = (data['name'] ?? 'Unknown').toString();
    final email = (data['email'] ?? '').toString();
    final phone =
        (data['contact'] ?? data['phone'] ?? '').toString();
    final online = _isOnline(data);
    final lastSeen = _lastSeenText(data);
    final blocked = data['isBlocked'] == true;
    final photoUrl =
        (data['photo'] ?? data['imageUrl'] ?? '').toString();

    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(14),
      elevation: 1,
      shadowColor: Colors.black12,
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => goTo(context, UserDetailPage(data: doc)),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: [
              // ── Avatar with online indicator ──
              Stack(
                children: [
                  CircleAvatar(
                    radius: 26,
                    backgroundColor: const Color(0xFFD4A843).withOpacity(0.2),
                    backgroundImage: photoUrl.isNotEmpty
                        ? NetworkImage(photoUrl)
                        : null,
                    child: photoUrl.isEmpty
                        ? Text(
                            _initials(name),
                            style: GoogleFonts.lato(
                              fontSize: 18,
                              fontWeight: FontWeight.w700,
                              color: const Color(0xFFD4A843),
                            ),
                          )
                        : null,
                  ),
                  Positioned(
                    right: 0,
                    bottom: 0,
                    child: Container(
                      width: 14,
                      height: 14,
                      decoration: BoxDecoration(
                        color: online
                            ? const Color(0xFF4CAF50)
                            : Colors.grey.shade400,
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white, width: 2.5),
                      ),
                    ),
                  ),
                ],
              ),

              const SizedBox(width: 14),

              // ── User info ──
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
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              color: Colors.black87,
                            ),
                          ),
                        ),
                        if (blocked) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: Colors.red.shade50,
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text('Blocked',
                                style: GoogleFonts.lato(
                                    fontSize: 10,
                                    color: Colors.red,
                                    fontWeight: FontWeight.w600)),
                          ),
                        ],
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
                    const SizedBox(height: 3),
                    Row(
                      children: [
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
                      ],
                    ),
                  ],
                ),
              ),

              // ── Trailing arrow ──
              Icon(Icons.chevron_right, color: Colors.grey.shade400, size: 22),
            ],
          ),
        ),
      ),
    );
  }
}
