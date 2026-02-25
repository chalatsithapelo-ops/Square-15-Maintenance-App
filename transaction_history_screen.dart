import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:maintenanceapp/controller/app_controller.dart';

/// Displays all transaction history for the logged-in client, combining:
///   • transactionLogs  (wallet top-ups, refunds, payments)
///   • requests          (deposit/proof-of-payment requests)
///
/// Uses one-shot get() without orderBy to avoid composite Firestore index
/// requirements. Sorting is done client-side.
class TransactionHistoryScreen extends StatefulWidget {
  const TransactionHistoryScreen({super.key});

  @override
  State<TransactionHistoryScreen> createState() =>
      _TransactionHistoryScreenState();
}

class _TransactionHistoryScreenState extends State<TransactionHistoryScreen>
    with SingleTickerProviderStateMixin {
  static const Color _gold = Color(0xFFc5a520);
  final AppController _ctrl = Get.find<AppController>();

  late TabController _tabController;

  // Loaded data
  bool _loading = true;
  String? _error;
  List<_TxItem> _allItems = [];
  List<_TxItem> _paymentItems = [];
  List<_TxItem> _depositItems = [];

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _loadData();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  // ── One-shot data loading (no composite indexes needed) ────────

  Future<void> _loadData() async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final uid = _ctrl.userId.value;
      if (uid.isEmpty) {
        setState(() {
          _loading = false;
          _error = 'Not logged in';
        });
        return;
      }

      // Run all three queries in parallel — simple equality, NO orderBy
      final results = await Future.wait([
        _fetchTxLogs('transaction_by', uid),
        _fetchTxLogs('user_id', uid),
        _fetchDepositRequests(uid),
      ]);

      final txByActor = results[0];
      final txByUserId = results[1];
      final deposits = results[2];

      // Merge and deduplicate transactionLogs
      final seenIds = <String>{};
      final allTx = <_TxItem>[];
      for (final item in txByActor) {
        if (seenIds.add(item.id)) allTx.add(item);
      }
      for (final item in txByUserId) {
        if (seenIds.add(item.id)) allTx.add(item);
      }

      // Combined (all TX + deposits), sorted newest-first
      final combined = [...allTx, ...deposits];
      combined.sort((a, b) => b.dateTime.compareTo(a.dateTime));

      // Payments only
      allTx.sort((a, b) => b.dateTime.compareTo(a.dateTime));

      // Deposits only
      deposits.sort((a, b) => b.dateTime.compareTo(a.dateTime));

      if (!mounted) return;
      setState(() {
        _allItems = combined;
        _paymentItems = allTx;
        _depositItems = deposits;
        _loading = false;
      });
    } catch (e) {
      debugPrint('[TxHistory] load error: $e');
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Failed to load transactions. Pull down to retry.';
      });
    }
  }

  /// Fetch transactionLogs by a given field — NO orderBy to avoid
  /// composite index requirement.
  Future<List<_TxItem>> _fetchTxLogs(String field, String uid) async {
    try {
      final snap = await FirebaseFirestore.instance
          .collection('transactionLogs')
          .where(field, isEqualTo: uid)
          .limit(200)
          .get();
      return snap.docs.map((doc) => _TxItem.fromTxLog(doc)).toList();
    } catch (e) {
      debugPrint('[TxHistory] _fetchTxLogs($field) error: $e');
      return [];
    }
  }

  /// Fetch deposit/proof-of-payment requests.
  Future<List<_TxItem>> _fetchDepositRequests(String uid) async {
    try {
      final snap = await FirebaseFirestore.instance
          .collection('requests')
          .where('requestBy', isEqualTo: uid)
          .limit(200)
          .get();
      return snap.docs.map((doc) => _TxItem.fromDeposit(doc)).toList();
    } catch (e) {
      debugPrint('[TxHistory] _fetchDepositRequests error: $e');
      return [];
    }
  }

  // ── UI ──────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: _gold,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () => Get.back(),
        ),
        title: Text(
          'Transaction History',
          style: GoogleFonts.roboto(
            color: Colors.white,
            fontWeight: FontWeight.w600,
          ),
        ),
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: Colors.white,
          labelColor: Colors.white,
          unselectedLabelColor: Colors.white70,
          labelStyle: GoogleFonts.roboto(fontWeight: FontWeight.w600),
          tabs: const [
            Tab(text: 'All'),
            Tab(text: 'Payments'),
            Tab(text: 'Deposits'),
          ],
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? _errorWidget(_error!)
              : TabBarView(
                  controller: _tabController,
                  children: [
                    _buildList(_allItems, 'No transactions yet'),
                    _buildList(_paymentItems, 'No payment records'),
                    _buildList(_depositItems, 'No deposit requests'),
                  ],
                ),
    );
  }

  Widget _buildList(List<_TxItem> items, String emptyMessage) {
    if (items.isEmpty) return _emptyState(emptyMessage);
    return RefreshIndicator(
      onRefresh: _loadData,
      color: _gold,
      child: ListView.separated(
        padding: const EdgeInsets.all(16),
        itemCount: items.length,
        separatorBuilder: (_, __) => const Divider(height: 1),
        itemBuilder: (_, i) => _buildTile(items[i]),
      ),
    );
  }

  // ── Shared widgets ─────────────────────────────────────────────

  Widget _emptyState(String message) {
    return RefreshIndicator(
      onRefresh: _loadData,
      color: _gold,
      child: ListView(
        children: [
          SizedBox(height: MediaQuery.of(context).size.height * 0.3),
          Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.receipt_long_outlined,
                    size: 64, color: Colors.grey.shade400),
                const SizedBox(height: 12),
                Text(message,
                    style:
                        GoogleFonts.roboto(fontSize: 16, color: Colors.grey)),
                const SizedBox(height: 8),
                Text('Pull down to refresh',
                    style: GoogleFonts.roboto(
                        fontSize: 12, color: Colors.grey.shade400)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _errorWidget(String message) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.error_outline, size: 64, color: Colors.red.shade300),
          const SizedBox(height: 12),
          Text(message,
              textAlign: TextAlign.center,
              style: GoogleFonts.roboto(fontSize: 14, color: Colors.grey)),
          const SizedBox(height: 16),
          ElevatedButton.icon(
            onPressed: _loadData,
            icon: const Icon(Icons.refresh),
            label: const Text('Retry'),
            style: ElevatedButton.styleFrom(backgroundColor: _gold),
          ),
        ],
      ),
    );
  }

  Widget _buildTile(_TxItem item) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
      leading: CircleAvatar(
        backgroundColor: item.iconBgColor.withOpacity(0.15),
        child: Icon(item.icon, color: item.iconBgColor, size: 22),
      ),
      title: Text(
        item.title,
        style: GoogleFonts.roboto(fontWeight: FontWeight.w600, fontSize: 14),
      ),
      subtitle: Text(
        item.subtitle,
        style: GoogleFonts.roboto(fontSize: 12, color: Colors.grey.shade600),
      ),
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(
            item.amountText,
            style: GoogleFonts.roboto(
              fontWeight: FontWeight.w700,
              fontSize: 14,
              color: item.amountColor,
            ),
          ),
          const SizedBox(height: 2),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: item.statusColor.withOpacity(0.15),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              item.statusLabel,
              style: GoogleFonts.roboto(
                fontSize: 10,
                fontWeight: FontWeight.w600,
                color: item.statusColor,
              ),
            ),
          ),
        ],
      ),
      onTap: () => _showDetailDialog(item),
    );
  }

  void _showDetailDialog(_TxItem item) {
    Get.dialog(
      AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            Icon(item.icon, color: item.iconBgColor),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                item.title,
                style: GoogleFonts.roboto(fontWeight: FontWeight.w700, fontSize: 16),
              ),
            ),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              _detailRow('Amount', item.amountText),
              _detailRow('Status', item.statusLabel),
              _detailRow('Date', item.formattedDate),
              if (item.type.isNotEmpty) _detailRow('Type', item.type),
              if (item.subtype.isNotEmpty) _detailRow('Subtype', item.subtype),
              if (item.bookingId.isNotEmpty) _detailRow('Booking', item.bookingId),
              if (item.taskName.isNotEmpty) _detailRow('Service', item.taskName),
              if (item.direction.isNotEmpty) _detailRow('Direction', item.direction),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Get.back(),
            child: Text('Close', style: GoogleFonts.roboto(color: _gold)),
          ),
        ],
      ),
    );
  }

  Widget _detailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 80,
            child: Text(label,
                style: GoogleFonts.roboto(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: Colors.grey.shade700)),
          ),
          Expanded(
            child: Text(value,
                style: GoogleFonts.roboto(fontSize: 13, color: Colors.black87)),
          ),
        ],
      ),
    );
  }
}

// ── Data class ─────────────────────────────────────────────────

class _TxItem {
  final String id;
  final String title;
  final String subtitle;
  final String amountText;
  final Color amountColor;
  final String statusLabel;
  final Color statusColor;
  final IconData icon;
  final Color iconBgColor;
  final DateTime dateTime;
  final String formattedDate;
  final String type;
  final String subtype;
  final String direction;
  final String bookingId;
  final String taskName;

  _TxItem({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.amountText,
    required this.amountColor,
    required this.statusLabel,
    required this.statusColor,
    required this.icon,
    required this.iconBgColor,
    required this.dateTime,
    required this.formattedDate,
    required this.type,
    required this.subtype,
    required this.direction,
    required this.bookingId,
    required this.taskName,
  });

  /// Parse a transactionLogs document.
  factory _TxItem.fromTxLog(QueryDocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data();
    final amount = _parseAmount(d['amount']);
    final status = (d['status'] ?? '').toString().toLowerCase();
    final type = (d['type'] ?? '').toString();
    final subtype = (d['subtype'] ?? '').toString();
    final direction = (d['direction'] ?? '').toString().toLowerCase();
    final taskName = (d['task_name'] ?? '').toString();
    final bookingId = (d['booking_id'] ?? '').toString();
    // Try multiple date fields for robustness
    final txAt = (d['transaction_at'] ?? d['created_at'] ?? '').toString();

    final dt = _parseDate(txAt, d['transaction_at'] ?? d['created_at']);

    // Determine display title from type/subtype
    String title = type;
    if (title.isEmpty) title = subtype.isNotEmpty ? subtype : 'Transaction';

    // Friendly names
    if (subtype == 'wallet_topup') title = 'Wallet Top-up';
    if (subtype == 'future_booking_refund') title = 'Booking Refund';
    if (subtype == 'future_booking_hold') title = 'Booking Payment';
    if (subtype == 'artisan_payout') title = 'Artisan Payment';
    if (subtype == 'wallet_deduction' || type.toLowerCase().contains('deduct'))
      title = 'Wallet Deduction';
    if (subtype == 'admin_topup') title = 'Admin Top-up';
    if (subtype == 'admin_deposit_approval') title = 'Deposit Approved';
    if (type.toLowerCase() == 'wallet' && subtype.isEmpty) title = 'Wallet Transaction';

    // Amount color: green for inbound, red for outbound
    final isInbound = direction == 'in' ||
        subtype == 'wallet_topup' ||
        subtype == 'future_booking_refund';

    final statusColor = _statusColor(status);

    return _TxItem(
      id: doc.id,
      title: title,
      subtitle: taskName.isNotEmpty ? taskName : _formatDateShort(dt),
      amountText: 'R${amount.toStringAsFixed(2)}',
      amountColor: isInbound ? Colors.green.shade700 : Colors.red.shade700,
      statusLabel: _capitalize(status.isEmpty ? 'unknown' : status),
      statusColor: statusColor,
      icon: isInbound ? Icons.arrow_downward : Icons.arrow_upward,
      iconBgColor: isInbound ? Colors.green : Colors.red,
      dateTime: dt,
      formattedDate: _formatDateLong(dt),
      type: type,
      subtype: subtype,
      direction: direction,
      bookingId: bookingId,
      taskName: taskName,
    );
  }

  /// Parse a deposit request document.
  factory _TxItem.fromDeposit(QueryDocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data();
    final amount = _parseAmount(d['amount']);
    final status = (d['status'] ?? 'pending').toString().toLowerCase();
    final createdAt = (d['createdAt'] ?? d['created_at'] ?? '').toString();

    final dt = _parseDate(createdAt, d['createdAt'] ?? d['created_at']);
    final statusColor = _statusColor(status);

    return _TxItem(
      id: doc.id,
      title: 'Deposit Request',
      subtitle: _formatDateShort(dt),
      amountText: 'R${amount.toStringAsFixed(2)}',
      amountColor: status == 'approved'
          ? Colors.green.shade700
          : (status == 'rejected' ? Colors.red.shade700 : Colors.orange.shade700),
      statusLabel: _capitalize(status),
      statusColor: statusColor,
      icon: Icons.account_balance_wallet,
      iconBgColor: Colors.orange,
      dateTime: dt,
      formattedDate: _formatDateLong(dt),
      type: 'Deposit Request',
      subtype: '',
      direction: 'in',
      bookingId: '',
      taskName: '',
    );
  }

  // ── helpers ──

  static double _parseAmount(dynamic v) {
    if (v == null) return 0;
    if (v is num) return v.toDouble();
    return double.tryParse(v.toString().replaceAll(RegExp(r'[^0-9.]'), '')) ?? 0;
  }

  static DateTime _parseDate(String raw, [dynamic rawValue]) {
    // Handle Firestore Timestamp objects directly
    if (rawValue is Timestamp) {
      return rawValue.toDate();
    }
    if (raw.isEmpty) return DateTime(2000);
    try {
      return DateTime.parse(raw);
    } catch (_) {
      // Try parsing "Timestamp(seconds=..., nanoseconds=...)" format
      try {
        final match = RegExp(r'seconds=(\d+)').firstMatch(raw);
        if (match != null) {
          final seconds = int.parse(match.group(1)!);
          return DateTime.fromMillisecondsSinceEpoch(seconds * 1000);
        }
      } catch (_) {}
      return DateTime(2000);
    }
  }

  static Color _statusColor(String status) {
    switch (status) {
      case 'approved':
      case 'success':
      case 'done':
        return Colors.green;
      case 'pending':
        return Colors.orange;
      case 'failed':
      case 'rejected':
        return Colors.red;
      default:
        return Colors.grey;
    }
  }

  static String _capitalize(String s) =>
      s.isEmpty ? s : '${s[0].toUpperCase()}${s.substring(1)}';

  static String _formatDateShort(DateTime dt) {
    if (dt.year <= 2000) return '';
    final months = [
      '', 'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    ];
    return '${dt.day} ${months[dt.month]} ${dt.year}';
  }

  static String _formatDateLong(DateTime dt) {
    if (dt.year <= 2000) return 'Unknown';
    final months = [
      '', 'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    ];
    final h = dt.hour.toString().padLeft(2, '0');
    final m = dt.minute.toString().padLeft(2, '0');
    return '${dt.day} ${months[dt.month]} ${dt.year}, $h:$m';
  }
}
