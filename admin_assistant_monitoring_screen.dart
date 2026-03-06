import 'package:admain_maintence_app/services/assistant_backend_service.dart';
import 'package:flutter/material.dart';

class AssistantMonitoringScreen extends StatefulWidget {
  const AssistantMonitoringScreen({super.key});

  @override
  State<AssistantMonitoringScreen> createState() => _AssistantMonitoringScreenState();
}

class _AssistantMonitoringScreenState extends State<AssistantMonitoringScreen> {
  late Future<Map<String, dynamic>> _financeFuture;
  late Future<List<Map<String, dynamic>>> _auditFuture;

  final TextEditingController _bookingIdController = TextEditingController();
  final TextEditingController _targetUidController = TextEditingController();
  Future<Map<String, dynamic>>? _reassignDebugFuture;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    _financeFuture = AssistantBackendService.fetchFinanceSummary();
    _auditFuture = AssistantBackendService.fetchRecentAssistantAudit();
  }

  @override
  void dispose() {
    _bookingIdController.dispose();
    _targetUidController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Assistant Monitoring'),
        backgroundColor: Colors.blue,
        actions: [
          IconButton(
            onPressed: () {
              setState(_reload);
            },
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _buildFinanceCard(),
          const SizedBox(height: 16),
          _buildReassignmentDebugCard(),
          const SizedBox(height: 16),
          _buildAuditCard(),
        ],
      ),
    );
  }

  Widget _buildReassignmentDebugCard() {
    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Reassignment notification debug',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(
              'Paste a booking ID to verify which artisan UID(s) will receive the reassignment notification.',
              style: TextStyle(color: Colors.grey.shade700),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _bookingIdController,
                    decoration: const InputDecoration(
                      labelText: 'Booking ID',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                ElevatedButton.icon(
                  onPressed: () {
                    final id = _bookingIdController.text.trim();
                    if (id.isEmpty) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Enter a booking ID')),
                      );
                      return;
                    }
                    setState(() {
                      _reassignDebugFuture =
                          AssistantBackendService.fetchReassignmentRecipientsDebug(
                        bookingId: id,
                      );
                    });
                  },
                  icon: const Icon(Icons.search),
                  label: const Text('Check'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (_reassignDebugFuture == null)
              Text(
                'No booking checked yet.',
                style: TextStyle(color: Colors.grey.shade700),
              )
            else
              FutureBuilder<Map<String, dynamic>>(
                future: _reassignDebugFuture,
                builder: (context, snap) {
                  if (snap.connectionState == ConnectionState.waiting) {
                    return const _LoadingBlock(title: 'debug mapping');
                  }
                  if (snap.hasError) {
                    return _ErrorBlock(title: 'Debug mapping', error: snap.error);
                  }
                  final data = snap.data ?? <String, dynamic>{};
                  final providerDocFound = data['provider_doc_found'];
                  final providerDocId = data['provider_doc_id'];
                  final primaryUid = data['provider_primary_uid'];
                  final bookingProviderId = data['booking_service_provider_id'];
                  final recipients = (data['notification_recipient_ids'] as List?)
                          ?.map((e) => e.toString())
                          .toList() ??
                      const <String>[];

                  final suggested = (primaryUid ?? '').toString().trim();
                  if (_targetUidController.text.trim().isEmpty && suggested.isNotEmpty) {
                    _targetUidController.text = suggested;
                  }

                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _kv('Booking provider id', bookingProviderId),
                      _kv('Provider doc found', providerDocFound),
                      _kv('Provider doc id', providerDocId),
                      _kv('Primary auth uid', primaryUid),
                      const SizedBox(height: 8),
                      const Text(
                        'Notification recipient ids',
                        style: TextStyle(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 6),
                      if (recipients.isEmpty)
                        Text('No recipients resolved.',
                            style: TextStyle(color: Colors.grey.shade700))
                      else
                        ...recipients.map(
                          (id) => Padding(
                            padding: const EdgeInsets.symmetric(vertical: 2),
                            child: Text(id),
                          ),
                        ),
                      const SizedBox(height: 12),
                      const Divider(height: 1),
                      const SizedBox(height: 12),
                      const Text(
                        'Fix mapping (admin-only)',
                        style: TextStyle(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Set the artisan FirebaseAuth uid to write into serviceProvider.user_id/uid/userId. Use this only if notifications are not reaching the artisan.',
                        style: TextStyle(color: Colors.grey.shade700),
                      ),
                      const SizedBox(height: 10),
                      TextField(
                        controller: _targetUidController,
                        decoration: const InputDecoration(
                          labelText: 'Target artisan auth uid',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          ElevatedButton.icon(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.orange,
                              foregroundColor: Colors.white,
                            ),
                            onPressed: () async {
                              final bookingId = _bookingIdController.text.trim();
                              final targetUid = _targetUidController.text.trim();
                              if (bookingId.isEmpty || targetUid.isEmpty) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text('Provide booking ID and target UID'),
                                  ),
                                );
                                return;
                              }
                              try {
                                await AssistantBackendService.fixServiceProviderUidMapping(
                                  bookingId: bookingId,
                                  targetUid: targetUid,
                                );
                                if (!mounted) return;
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(content: Text('Mapping updated')), 
                                );
                                setState(() {
                                  _reassignDebugFuture =
                                      AssistantBackendService.fetchReassignmentRecipientsDebug(
                                    bookingId: bookingId,
                                  );
                                });
                              } catch (e) {
                                if (!mounted) return;
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(content: Text('Fix failed: $e')),
                                );
                              }
                            },
                            icon: const Icon(Icons.build),
                            label: const Text('Fix mapping'),
                          ),
                          const SizedBox(width: 12),
                          TextButton(
                            onPressed: () {
                              _targetUidController.text = '';
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('Cleared target UID')),
                              );
                            },
                            child: const Text('Clear'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        (data['note'] ?? '').toString(),
                        style: TextStyle(color: Colors.grey.shade700),
                      ),
                    ],
                  );
                },
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildFinanceCard() {
    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: FutureBuilder<Map<String, dynamic>>(
          future: _financeFuture,
          builder: (context, snap) {
            if (snap.connectionState == ConnectionState.waiting) {
              return const _LoadingBlock(title: 'Finance summary');
            }
            if (snap.hasError) {
              return _ErrorBlock(title: 'Finance summary', error: snap.error);
            }

            final data = snap.data ?? <String, dynamic>{};
            final totalIn = data['total_in'];
            final totalOut = data['total_out'];
            final profit = data['profit_total'];
            final sample = data['sample_size'];
            final note = (data['note'] ?? '').toString().trim();

            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Finance snapshot (recent logs)',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 12),
                _kv('Total in', totalIn),
                _kv('Total out', totalOut),
                _kv('Profit total', profit),
                _kv('Sample size', sample),
                if (note.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(note, style: TextStyle(color: Colors.grey.shade700)),
                ],
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildAuditCard() {
    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: FutureBuilder<List<Map<String, dynamic>>>(
          future: _auditFuture,
          builder: (context, snap) {
            if (snap.connectionState == ConnectionState.waiting) {
              return const _LoadingBlock(title: 'Assistant action audit');
            }
            if (snap.hasError) {
              return _ErrorBlock(title: 'Assistant action audit', error: snap.error);
            }

            final items = snap.data ?? <Map<String, dynamic>>[];
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Assistant action audit (recent)',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 12),
                if (items.isEmpty)
                  Text('No audit items found.', style: TextStyle(color: Colors.grey.shade700))
                else
                  ...items.take(30).map((e) {
                    final action = (e['action'] ?? '').toString();
                    final status = (e['status'] ?? '').toString();
                    final bookingId = (e['booking_id'] ?? '').toString();
                    final createdAt = (e['created_at'] ?? '').toString();
                    return ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: Text(action.isNotEmpty ? action : 'action'),
                      subtitle: Text(
                        [
                          if (bookingId.isNotEmpty) 'booking: $bookingId',
                          if (createdAt.isNotEmpty) createdAt,
                        ].join(' • '),
                      ),
                      trailing: Text(
                        status,
                        style: TextStyle(
                          color: status == 'success'
                              ? Colors.green.shade700
                              : (status == 'error' ? Colors.red.shade700 : Colors.orange.shade700),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    );
                  }),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _kv(String k, Object? v) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(width: 120, child: Text(k, style: const TextStyle(fontWeight: FontWeight.w600))),
          Expanded(child: Text(v?.toString() ?? '-')),
        ],
      ),
    );
  }
}

class _LoadingBlock extends StatelessWidget {
  final String title;
  const _LoadingBlock({required this.title});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        const SizedBox(width: 12),
        Text('Loading $title...'),
      ],
    );
  }
}

class _ErrorBlock extends StatelessWidget {
  final String title;
  final Object? error;
  const _ErrorBlock({required this.title, required this.error});

  bool get _is403 {
    final msg = (error?.toString() ?? '').toLowerCase();
    return msg.contains('403') || msg.contains('forbidden') || msg.contains('admin only');
  }

  @override
  Widget build(BuildContext context) {
    if (_is403) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.orange.shade50,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.orange.shade300),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.warning_amber_rounded, color: Colors.orange.shade700),
                    const SizedBox(width: 8),
                    Text(
                      'Admin Claims Not Set',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: Colors.orange.shade800,
                        fontSize: 14,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                const Text(
                  'Your account does not have admin custom claims. '
                  'Go to AI Agent Setup → "Fix Admin Claims (403)" to set them up.',
                ),
                const SizedBox(height: 12),
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.orange,
                    foregroundColor: Colors.white,
                  ),
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.arrow_back),
                  label: const Text('Go back to Setup'),
                ),
              ],
            ),
          ),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        Text(
          'Error: ${error ?? 'unknown'}',
          style: TextStyle(color: Colors.red.shade700),
        ),
        const SizedBox(height: 8),
        const Text('Make sure you are signed in as an admin user.'),
      ],
    );
  }
}
