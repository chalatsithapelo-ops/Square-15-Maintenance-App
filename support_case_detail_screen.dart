import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:intl/intl.dart';
import 'package:admain_maintence_app/services/user_name_cache.dart';
import 'package:admain_maintence_app/services/admin_notification_service.dart';

class SupportCaseDetailScreen extends StatefulWidget {
  final String caseId;
  final String docId;

  const SupportCaseDetailScreen({
    super.key,
    required this.caseId,
    required this.docId,
  });

  @override
  State<SupportCaseDetailScreen> createState() => _SupportCaseDetailScreenState();
}

class _SupportCaseDetailScreenState extends State<SupportCaseDetailScreen> {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final TextEditingController _notesController = TextEditingController();
  final TextEditingController _replyController = TextEditingController();
  bool _isUpdating = false;

  @override
  void dispose() {
    _notesController.dispose();
    _replyController.dispose();
    super.dispose();
  }

  Color _getStateColor(String? state) {
    switch (state?.toLowerCase()) {
      case 'open':
        return Colors.red;
      case 'pending_artisan':
      case 'pending_admin':
        return Colors.orange;
      case 'in_progress':
        return Colors.blue;
      case 'resolved':
        return Colors.green;
      case 'closed':
        return Colors.grey;
      default:
        return Colors.grey;
    }
  }

  Color _getPriorityColor(String? priority) {
    switch (priority?.toLowerCase()) {
      case 'high':
        return Colors.red;
      case 'normal':
        return Colors.orange;
      case 'low':
        return Colors.blue;
      default:
        return Colors.grey;
    }
  }

  Future<void> _updateCaseState(String newState, Map<String, dynamic> currentData) async {
    setState(() => _isUpdating = true);
    try {
      final now = DateTime.now().toIso8601String();
      final timeline = List<Map<String, dynamic>>.from(currentData['timeline'] ?? []);
      timeline.add({
        'timestamp': now,
        'actor': 'admin',
        'action': 'state_changed',
        'notes': 'State changed to $newState',
      });

      await _firestore.collection('assistant_cases').doc(widget.docId).update({
        'state': newState,
        'updated_at': now,
        'timeline': timeline,
      });

      Get.showSnackbar(const GetSnackBar(
        backgroundColor: Colors.green,
        duration: Duration(seconds: 2),
        message: 'Case state updated',
      ));
    } catch (e) {
      Get.showSnackbar(GetSnackBar(
        backgroundColor: Colors.red,
        duration: const Duration(seconds: 3),
        message: 'Error updating case: $e',
      ));
    } finally {
      setState(() => _isUpdating = false);
    }
  }

  Future<void> _updatePriority(String newPriority, Map<String, dynamic> currentData) async {
    setState(() => _isUpdating = true);
    try {
      final now = DateTime.now().toIso8601String();
      final timeline = List<Map<String, dynamic>>.from(currentData['timeline'] ?? []);
      timeline.add({
        'timestamp': now,
        'actor': 'admin',
        'action': 'priority_changed',
        'notes': 'Priority changed to $newPriority',
      });

      await _firestore.collection('assistant_cases').doc(widget.docId).update({
        'priority': newPriority,
        'updated_at': now,
        'timeline': timeline,
      });

      Get.showSnackbar(const GetSnackBar(
        backgroundColor: Colors.green,
        duration: Duration(seconds: 2),
        message: 'Priority updated',
      ));
    } catch (e) {
      Get.showSnackbar(GetSnackBar(
        backgroundColor: Colors.red,
        duration: const Duration(seconds: 3),
        message: 'Error updating priority: $e',
      ));
    } finally {
      setState(() => _isUpdating = false);
    }
  }

  Future<void> _addNote() async {
    final note = _notesController.text.trim();
    if (note.isEmpty) {
      Get.showSnackbar(const GetSnackBar(
        backgroundColor: Colors.orange,
        duration: Duration(seconds: 2),
        message: 'Please enter a note',
      ));
      return;
    }

    setState(() => _isUpdating = true);
    try {
      final doc = await _firestore.collection('assistant_cases').doc(widget.docId).get();
      if (!doc.exists) {
        throw Exception('Case not found');
      }

      final data = doc.data()!;
      final now = DateTime.now().toIso8601String();
      final timeline = List<Map<String, dynamic>>.from(data['timeline'] ?? []);
      timeline.add({
        'timestamp': now,
        'actor': 'admin',
        'action': 'note_added',
        'notes': note,
      });

      await _firestore.collection('assistant_cases').doc(widget.docId).update({
        'updated_at': now,
        'timeline': timeline,
      });

      _notesController.clear();
      Get.showSnackbar(const GetSnackBar(
        backgroundColor: Colors.green,
        duration: Duration(seconds: 2),
        message: 'Note added successfully',
      ));
    } catch (e) {
      Get.showSnackbar(GetSnackBar(
        backgroundColor: Colors.red,
        duration: const Duration(seconds: 3),
        message: 'Error adding note: $e',
      ));
    } finally {
      setState(() => _isUpdating = false);
    }
  }

  Future<void> _replyToClient(Map<String, dynamic> currentData) async {
    final reply = _replyController.text.trim();
    if (reply.isEmpty) {
      Get.showSnackbar(const GetSnackBar(
        backgroundColor: Colors.orange,
        duration: Duration(seconds: 2),
        message: 'Please enter a reply message',
      ));
      return;
    }

    setState(() => _isUpdating = true);
    try {
      final doc = await _firestore.collection('assistant_cases').doc(widget.docId).get();
      if (!doc.exists) throw Exception('Case not found');

      final data = doc.data()!;
      final clientUid = (data['client_uid'] ?? '').toString().trim();
      final now = DateTime.now().toIso8601String();
      final timeline = List<Map<String, dynamic>>.from(data['timeline'] ?? []);
      timeline.add({
        'timestamp': now,
        'actor': 'admin',
        'action': 'reply_to_client',
        'notes': reply,
      });

      // Update case: add to timeline, set state to in_progress if open
      final updates = <String, dynamic>{
        'updated_at': now,
        'timeline': timeline,
      };
      if (data['state'] == 'open') {
        updates['state'] = 'in_progress';
      }
      await _firestore.collection('assistant_cases').doc(widget.docId).update(updates);

      // Send push notification to the client
      if (clientUid.isNotEmpty) {
        await AdminNotificationService.sendNotificationToUser(
          userId: clientUid,
          title: 'Support Reply (Case #${widget.caseId.length > 8 ? widget.caseId.substring(0, 8) : widget.caseId})',
          message: reply,
          type: 'case_reply',
        );
      }

      _replyController.clear();
      Get.showSnackbar(const GetSnackBar(
        backgroundColor: Colors.green,
        duration: Duration(seconds: 2),
        message: 'Reply sent to client successfully',
      ));
    } catch (e) {
      Get.showSnackbar(GetSnackBar(
        backgroundColor: Colors.red,
        duration: const Duration(seconds: 3),
        message: 'Error sending reply: $e',
      ));
    } finally {
      setState(() => _isUpdating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Case #${widget.caseId.substring(0, 8)}'),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.copy),
            tooltip: 'Copy Case ID',
            onPressed: () {
              Clipboard.setData(ClipboardData(text: widget.caseId));
              Get.showSnackbar(const GetSnackBar(
                backgroundColor: Colors.green,
                duration: Duration(seconds: 2),
                message: 'Case ID copied to clipboard',
              ));
            },
          ),
        ],
      ),
      body: StreamBuilder<DocumentSnapshot>(
        stream: _firestore.collection('assistant_cases').doc(widget.docId).snapshots(),
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(
              child: Text('Error: ${snapshot.error}'),
            );
          }

          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(
              child: CircularProgressIndicator(),
            );
          }

          if (!snapshot.hasData || !snapshot.data!.exists) {
            return const Center(
              child: Text('Case not found'),
            );
          }

          final data = snapshot.data!.data() as Map<String, dynamic>;
          return _buildCaseDetails(data);
        },
      ),
    );
  }

  Widget _buildCaseDetails(Map<String, dynamic> data) {
    final subject = data['subject'] ?? 'No subject';
    final message = data['message'] ?? '';
    final state = data['state'] ?? 'unknown';
    final priority = data['priority'] ?? 'normal';
    final type = data['type'] ?? 'unknown';
    final bookingId = data['booking_id'];
    final clientUid = data['client_uid'] ?? 'Unknown';
    final createdAt = data['created_at'] ?? '';
    final updatedAt = data['updated_at'] ?? '';
    final slaDeadline = data['sla_deadline'];
    final escalated = data['escalated'] == true;
    final timeline = List<Map<String, dynamic>>.from(data['timeline'] ?? []);

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Case header
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Text(
                                  subject,
                                  style: const TextStyle(
                                    fontSize: 20,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                if (escalated) ...[
                                  const SizedBox(width: 8),
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                    decoration: BoxDecoration(
                                      color: Colors.red,
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: const Text(
                                      'ESCALATED',
                                      style: TextStyle(
                                        color: Colors.white,
                                        fontSize: 12,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                            const SizedBox(height: 8),
                            Text(
                              message,
                              style: TextStyle(color: Colors.grey[700]),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const Divider(height: 24),
                  Wrap(
                    spacing: 16,
                    runSpacing: 12,
                    children: [
                      _buildInfoRow(Icons.category, 'Type', type),
                      FutureBuilder<String>(
                        future: UserNameCache.instance.displayNameWithContact(clientUid),
                        builder: (ctx, snap) => _buildInfoRow(
                          Icons.person,
                          'Client',
                          snap.data ?? clientUid,
                        ),
                      ),
                      if (bookingId != null)
                        _buildInfoRow(Icons.receipt_long, 'Booking', bookingId),
                      _buildInfoRow(Icons.access_time, 'Created', _formatTimestamp(createdAt)),
                      _buildInfoRow(Icons.update, 'Updated', _formatTimestamp(updatedAt)),
                      if (slaDeadline != null)
                        _buildInfoRow(
                          Icons.alarm,
                          'SLA Deadline',
                          _formatTimestamp(slaDeadline),
                          color: _isSlaOverdue(slaDeadline) ? Colors.red : null,
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          // Quick actions
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Quick Actions',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 16),
                  // State selector
                  Row(
                    children: [
                      const Text('State:', style: TextStyle(fontWeight: FontWeight.bold)),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          decoration: BoxDecoration(
                            border: Border.all(color: Colors.grey),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: DropdownButton<String>(
                            value: state,
                            isExpanded: true,
                            underline: const SizedBox(),
                            items: const [
                              DropdownMenuItem(value: 'open', child: Text('Open')),
                              DropdownMenuItem(value: 'pending_artisan', child: Text('Pending Artisan')),
                              DropdownMenuItem(value: 'pending_admin', child: Text('Pending Admin')),
                              DropdownMenuItem(value: 'in_progress', child: Text('In Progress')),
                              DropdownMenuItem(value: 'resolved', child: Text('Resolved')),
                              DropdownMenuItem(value: 'closed', child: Text('Closed')),
                            ],
                            onChanged: _isUpdating
                                ? null
                                : (newState) {
                                    if (newState != null && newState != state) {
                                      _updateCaseState(newState, data);
                                    }
                                  },
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: _getStateColor(state),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: const Icon(Icons.circle, size: 16, color: Colors.white),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  // Priority selector
                  Row(
                    children: [
                      const Text('Priority:', style: TextStyle(fontWeight: FontWeight.bold)),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          decoration: BoxDecoration(
                            border: Border.all(color: Colors.grey),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: DropdownButton<String>(
                            value: priority,
                            isExpanded: true,
                            underline: const SizedBox(),
                            items: const [
                              DropdownMenuItem(value: 'low', child: Text('Low')),
                              DropdownMenuItem(value: 'normal', child: Text('Normal')),
                              DropdownMenuItem(value: 'high', child: Text('High')),
                            ],
                            onChanged: _isUpdating
                                ? null
                                : (newPriority) {
                                    if (newPriority != null && newPriority != priority) {
                                      _updatePriority(newPriority, data);
                                    }
                                  },
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: _getPriorityColor(priority),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: const Icon(Icons.flag, size: 16, color: Colors.white),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          // Add note section
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Add Note',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _notesController,
                    maxLines: 3,
                    decoration: const InputDecoration(
                      hintText: 'Enter admin notes here...',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: _isUpdating ? null : _addNote,
                      icon: const Icon(Icons.add_comment),
                      label: Text(_isUpdating ? 'Adding...' : 'Add Note'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFFc5a520),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          // Reply to client section
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: const [
                      Icon(Icons.reply, color: Color(0xFFc5a520)),
                      SizedBox(width: 8),
                      Text(
                        'Reply to Client',
                        style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _replyController,
                    maxLines: 3,
                    decoration: const InputDecoration(
                      hintText: 'Type your reply to the client...',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: _isUpdating ? null : () => _replyToClient(data),
                      icon: const Icon(Icons.send),
                      label: Text(_isUpdating ? 'Sending...' : 'Send Reply'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.blue,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          // Timeline
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Timeline',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 16),
                  if (timeline.isEmpty)
                    const Center(
                      child: Padding(
                        padding: EdgeInsets.all(16),
                        child: Text('No timeline entries', style: TextStyle(color: Colors.grey)),
                      ),
                    )
                  else
                    ...timeline.reversed.map((entry) {
                      final timestamp = entry['timestamp'] ?? '';
                      final actor = entry['actor'] ?? 'system';
                      final action = entry['action'] ?? 'unknown';
                      final notes = entry['notes'] ?? '';

                      return Container(
                        margin: const EdgeInsets.only(bottom: 16),
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Colors.grey[100],
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: Colors.grey[300]!),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Icon(_getActionIcon(action), size: 16, color: Colors.grey[600]),
                                const SizedBox(width: 8),
                                Text(
                                  _formatAction(action),
                                  style: const TextStyle(fontWeight: FontWeight.bold),
                                ),
                                const Spacer(),
                                Text(
                                  _formatTimestamp(timestamp),
                                  style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                                ),
                              ],
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'By: $actor',
                              style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                            ),
                            if (notes.isNotEmpty) ...[
                              const SizedBox(height: 8),
                              Text(notes),
                            ],
                          ],
                        ),
                      );
                    }),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInfoRow(IconData icon, String label, String value, {Color? color}) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 16, color: color ?? Colors.grey[600]),
        const SizedBox(width: 4),
        Text(
          '$label: ',
          style: TextStyle(fontSize: 12, color: Colors.grey[600], fontWeight: FontWeight.bold),
        ),
        Text(
          value,
          style: TextStyle(fontSize: 12, color: color ?? Colors.grey[800]),
        ),
      ],
    );
  }

  IconData _getActionIcon(String action) {
    switch (action) {
      case 'case_created':
        return Icons.add_circle;
      case 'state_changed':
        return Icons.change_circle;
      case 'priority_changed':
        return Icons.flag;
      case 'note_added':
        return Icons.note_add;
      case 'reply_to_client':
        return Icons.reply;
      case 'auto_escalated':
        return Icons.arrow_upward;
      default:
        return Icons.circle;
    }
  }

  String _formatAction(String action) {
    return action.replaceAll('_', ' ').split(' ').map((word) {
      return word.isNotEmpty ? '${word[0].toUpperCase()}${word.substring(1)}' : '';
    }).join(' ');
  }

  String _formatTimestamp(String? timestamp) {
    if (timestamp == null || timestamp.isEmpty) return 'Unknown';
    try {
      final date = DateTime.parse(timestamp);
      return DateFormat('MMM d, yyyy HH:mm').format(date);
    } catch (e) {
      return 'Unknown';
    }
  }

  bool _isSlaOverdue(String? slaDeadline) {
    if (slaDeadline == null || slaDeadline.isEmpty) return false;
    try {
      return DateTime.parse(slaDeadline).isBefore(DateTime.now());
    } catch (e) {
      return false;
    }
  }
}
