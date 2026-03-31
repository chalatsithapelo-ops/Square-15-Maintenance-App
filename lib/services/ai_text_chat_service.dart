import 'dart:async';
import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// AI Text Chat Service — same capabilities as Lizzy Voice but via text.
/// Uses OpenAI GPT-4o-mini with function calling for bookings, lookups, etc.
class AITextChatService {
  AITextChatService._();
  static final AITextChatService instance = AITextChatService._();

  String? _cachedApiKey;

  Future<String> _getApiKey() async {
    if (_cachedApiKey != null && _cachedApiKey!.isNotEmpty) return _cachedApiKey!;

    // 1. Try compile-time key first
    const compileKey = String.fromEnvironment('OPENAI_API_KEY');
    if (compileKey.isNotEmpty) {
      _cachedApiKey = compileKey;
      return compileKey;
    }

    // 2. Fallback: read from Firestore config doc
    try {
      final doc = await FirebaseFirestore.instance
          .collection('app_config')
          .doc('ai_keys')
          .get();
      if (doc.exists) {
        final key = (doc.data()?['openai_api_key'] ?? '').toString().trim();
        if (key.isNotEmpty) {
          _cachedApiKey = key;
          return key;
        }
      }
    } catch (e) {
      debugPrint('[AITextChat] Failed to read API key from Firestore: $e');
    }
    return '';
  }

  final List<Map<String, dynamic>> _conversationHistory = [];
  String? _sessionId;
  String? _userRole; // 'client' or 'artisan'

  final _messageController = StreamController<ChatMessage>.broadcast();
  Stream<ChatMessage> get messageStream => _messageController.stream;

  final List<ChatMessage> messages = [];

  void startSession({required String userRole}) {
    _sessionId = DateTime.now().millisecondsSinceEpoch.toString();
    _userRole = userRole;
    _conversationHistory.clear();
    messages.clear();

    _conversationHistory.add({
      'role': 'system',
      'content': _systemPrompt(userRole),
    });

    final greeting = ChatMessage(
      role: 'assistant',
      content: userRole == 'artisan'
          ? 'Hi! I\'m Lizzy, your Square 15 AI assistant. I can help you manage your jobs, check bookings, and answer questions. How can I help?'
          : 'Hi! I\'m Lizzy, your Square 15 AI assistant. I can help you book maintenance services, check your bookings, track artisans, and more. What do you need help with?',
      timestamp: DateTime.now(),
    );
    messages.add(greeting);
    _messageController.add(greeting);
  }

  Future<void> sendMessage(String text) async {
    if (text.trim().isEmpty) return;

    final userMsg = ChatMessage(
      role: 'user',
      content: text.trim(),
      timestamp: DateTime.now(),
    );
    messages.add(userMsg);
    _messageController.add(userMsg);

    _conversationHistory.add({'role': 'user', 'content': text.trim()});

    // Show typing indicator
    final typingMsg = ChatMessage(
      role: 'assistant',
      content: '',
      timestamp: DateTime.now(),
      isTyping: true,
    );
    messages.add(typingMsg);
    _messageController.add(typingMsg);

    try {
      final response = await _callOpenAI();
      // Remove typing indicator
      messages.remove(typingMsg);

      final assistantMsg = ChatMessage(
        role: 'assistant',
        content: response,
        timestamp: DateTime.now(),
      );
      messages.add(assistantMsg);
      _messageController.add(assistantMsg);

      _conversationHistory.add({'role': 'assistant', 'content': response});
      _storeMessage(userMsg, assistantMsg);
    } catch (e) {
      messages.remove(typingMsg);
      final errorMsg = ChatMessage(
        role: 'assistant',
        content: 'Sorry, I encountered an error. Please try again.',
        timestamp: DateTime.now(),
      );
      messages.add(errorMsg);
      _messageController.add(errorMsg);
    }
  }

  Future<String> _callOpenAI({int depth = 0}) async {
    if (depth > 3) {
      return 'I\'ve processed several steps. Let me summarize what I found so far.';
    }

    final apiKey = await _getApiKey();
    if (apiKey.isEmpty) {
      return 'AI service is not configured. Please contact support.';
    }

    final response = await http.post(
      Uri.parse('https://api.openai.com/v1/chat/completions'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $apiKey',
      },
      body: jsonEncode({
        'model': 'gpt-4o-mini',
        'messages': _conversationHistory,
        'max_tokens': 500,
        'temperature': 0.3,
        'tools': _toolDefinitions,
        'tool_choice': 'auto',
      }),
    ).timeout(const Duration(seconds: 25));

    if (response.statusCode != 200) {
      debugPrint('Chat API error: ${response.statusCode}');
      return 'I\'m having trouble connecting. Please try again.';
    }

    final data = jsonDecode(response.body);
    final choice = data['choices'][0];
    final message = choice['message'];

    // Handle tool calls
    if (message['tool_calls'] != null) {
      final toolCalls = message['tool_calls'] as List;
      _conversationHistory.add(message);

      for (final toolCall in toolCalls) {
        final functionName = toolCall['function']['name'];
        final arguments = jsonDecode(toolCall['function']['arguments']);
        final result = await _executeToolCall(functionName, arguments);

        _conversationHistory.add({
          'role': 'tool',
          'tool_call_id': toolCall['id'],
          'content': jsonEncode(result),
        });
      }

      // Get follow-up response after tool execution (with depth limit)
      return _callOpenAI(depth: depth + 1);
    }

    return message['content'] ?? 'I\'m not sure how to respond to that.';
  }

  Future<Map<String, dynamic>> _executeToolCall(
      String functionName, Map<String, dynamic> arguments) async {
    final uid = FirebaseAuth.instance.currentUser?.uid ?? '';

    switch (functionName) {
      case 'list_bookings':
        return _listBookings(uid, arguments['status'] as String?);
      case 'get_booking_details':
        return _getBookingDetails(arguments['booking_id'] as String?);
      case 'lookup_service_pricing':
        return _lookupPricing(arguments['service_name'] as String);
      case 'get_service_categories':
        return _getCategories();
      case 'check_payment_status':
        return _checkPayment(arguments['booking_id'] as String);
      case 'create_booking':
        return _createBooking(uid, arguments);
      case 'submit_rfq':
        return _submitRfq(uid, arguments);
      case 'explain_rfq_quote':
        return _explainRfqQuote(arguments['booking_id'] as String);
      case 'cancel_booking':
        return _cancelBooking(uid, arguments['booking_id'] as String, arguments['reason'] as String?);
      case 'reschedule_booking':
        return _rescheduleBooking(arguments['booking_id'] as String, arguments['scheduled_date'] as String?, arguments['scheduled_time'] as String?);
      case 'check_wallet_balance':
        return _checkWalletBalance(uid);
      case 'get_transaction_history':
        return _getTransactionHistory(uid);
      case 'submit_rating':
        return _submitRating(uid, arguments['booking_id'] as String, arguments['rating'] as num, arguments['review'] as String?);
      case 'submit_complaint':
        return _submitComplaint(uid, arguments['description'] as String, arguments['subject'] as String?, arguments['booking_id'] as String?);
      case 'get_notifications':
        return _getNotifications(uid);
      case 'get_scheduled_bookings':
        return _getScheduledBookings(uid);
      case 'get_artisan_info':
        return _getArtisanInfo(arguments['artisan_id'] as String);
      case 'apply_promo_code':
        return _applyPromoCode(arguments['code'] as String);
      case 'request_refund':
        return _requestRefund(uid, arguments['booking_id'] as String, arguments['reason'] as String?);
      default:
        return {'status': 'error', 'message': 'Unknown function: $functionName'};
    }
  }

  Future<Map<String, dynamic>> _listBookings(String uid, String? status) async {
    try {
      // Search tasksManagement
      var query = FirebaseFirestore.instance
          .collection('tasksManagement')
          .where('user_id', isEqualTo: uid);
      if (status != null && status.isNotEmpty) {
        query = query.where('status', isEqualTo: status);
      }
      final snap1 = await query.limit(10).get();
      final bookings = snap1.docs.map((d) {
        final data = d.data();
        return {
          'id': d.id,
          'category': data['category_name'] ?? data['category'] ?? '',
          'status': data['status'] ?? 'unknown',
          'cost': data['cost'] ?? 'N/A',
          'created': data['creation_date'] ?? '',
          'payment': data['payment_status'] ?? 'unknown',
          'order_no': data['order_no'] ?? '',
          'source': 'active',
        };
      }).toList();

      // Also search futureBookings for scheduled/RFQ bookings
      try {
        var fbQuery = FirebaseFirestore.instance
            .collection('futureBookings')
            .where('user_id', isEqualTo: uid);
        if (status != null && status.isNotEmpty) {
          fbQuery = fbQuery.where('status', isEqualTo: status);
        }
        final snap2 = await fbQuery.limit(10).get();
        for (final d in snap2.docs) {
          final data = d.data();
          bookings.add({
            'id': d.id,
            'category': data['category_name'] ?? data['task_name'] ?? '',
            'status': data['status'] ?? 'scheduled',
            'cost': data['cost'] ?? 'N/A',
            'scheduled_date': data['scheduled_date'] ?? '',
            'is_rfq': data['is_rfq'] ?? 'no',
            'rfq_status': data['rfq_status'] ?? '',
            'order_no': data['order_no'] ?? '',
            'source': 'future',
          });
        }
      } catch (e) { debugPrint('[AITextChat] futureBookings fetch failed: $e'); }

      return {'bookings': bookings, 'count': bookings.length};
    } catch (e) {
      return {'error': 'Failed to fetch bookings'};
    }
  }

  Future<Map<String, dynamic>> _getBookingDetails(String? bookingId) async {
    if (bookingId == null || bookingId.isEmpty) {
      return {'error': 'Please provide a booking ID.'};
    }
    try {
      // Try tasksManagement first
      var doc = await FirebaseFirestore.instance
          .collection('tasksManagement')
          .doc(bookingId)
          .get();

      // Fallback to futureBookings
      if (!doc.exists) {
        doc = await FirebaseFirestore.instance
            .collection('futureBookings')
            .doc(bookingId)
            .get();
      }

      // Try searching by order_no
      if (!doc.exists) {
        final snap = await FirebaseFirestore.instance
            .collection('tasksManagement')
            .where('order_no', isEqualTo: bookingId)
            .limit(1)
            .get();
        if (snap.docs.isNotEmpty) {
          doc = snap.docs.first;
        } else {
          final snap2 = await FirebaseFirestore.instance
              .collection('futureBookings')
              .where('order_no', isEqualTo: bookingId)
              .limit(1)
              .get();
          if (snap2.docs.isNotEmpty) doc = snap2.docs.first;
        }
      }

      if (!doc.exists) return {'error': 'Booking not found'};
      final data = doc.data()!;
      return {
        'id': doc.id,
        'category': data['category_name'] ?? data['category'] ?? '',
        'description': data['description'] ?? data['problem_description'] ?? '',
        'status': data['status'] ?? 'unknown',
        'cost': data['cost'] ?? 'N/A',
        'payment_status': data['payment_status'] ?? 'unknown',
        'order_no': data['order_no'] ?? '',
        'address': data['address'] ?? '',
        'artisan_id': data['artisan_id'] ?? '',
        'created': data['creation_date'] ?? '',
        'scheduled_date': data['scheduled_date'] ?? '',
        'scheduled_time': data['scheduled_time'] ?? '',
        'is_rfq': data['is_rfq'] ?? 'no',
        'rfq_status': data['rfq_status'] ?? '',
        'quoted_price': data['quoted_price'] ?? '',
      };
    } catch (e) {
      return {'error': 'Failed to fetch booking details'};
    }
  }

  Future<Map<String, dynamic>> _lookupPricing(String serviceName) async {
    try {
      final snap = await FirebaseFirestore.instance
          .collection('pricingGuidance')
          .limit(20)
          .get();
      final matches = <Map<String, dynamic>>[];
      final searchLower = serviceName.toLowerCase();
      for (final doc in snap.docs) {
        final name = (doc.data()['category_name'] ?? '').toString().toLowerCase();
        if (name.contains(searchLower) || searchLower.contains(name)) {
          matches.add({
            'category': doc.data()['category_name'],
            'labor_rate_per_hour': doc.data()['labor_rate_per_hour'],
            'material_markup': doc.data()['material_markup_percent'],
          });
        }
      }
      return {'pricing': matches, 'count': matches.length};
    } catch (e) {
      return {'error': 'Failed to lookup pricing'};
    }
  }

  Future<Map<String, dynamic>> _getCategories() async {
    try {
      final snap = await FirebaseFirestore.instance
          .collection('categories')
          .where('status', isEqualTo: 'publish')
          .where('parent_id', isEqualTo: '0')
          .get();
      final categories = snap.docs
          .map((d) => d.data()['category_name'] ?? 'Unknown')
          .toList();
      return {'categories': categories};
    } catch (e) {
      return {'error': 'Failed to fetch categories'};
    }
  }

  Future<Map<String, dynamic>> _checkPayment(String bookingId) async {
    try {
      var doc = await FirebaseFirestore.instance
          .collection('tasksManagement')
          .doc(bookingId)
          .get();
      if (!doc.exists) {
        doc = await FirebaseFirestore.instance
            .collection('futureBookings')
            .doc(bookingId)
            .get();
      }
      if (!doc.exists) return {'error': 'Booking not found'};
      return {
        'booking_id': bookingId,
        'payment_status': doc.data()?['payment_status'] ?? 'unknown',
        'cost': doc.data()?['cost'] ?? 'N/A',
        'payment_method': doc.data()?['payment_method'] ?? '',
      };
    } catch (e) {
      return {'error': 'Failed to check payment'};
    }
  }

  // ═══════════════════════════════════════════════════════════════
  // CREATE BOOKING
  // ═══════════════════════════════════════════════════════════════
  Future<Map<String, dynamic>> _createBooking(String uid, Map<String, dynamic> args) async {
    try {
      final category = (args['category'] as String?) ?? '';
      final description = (args['description'] as String?) ?? '';
      final address = (args['address'] as String?) ?? '';
      final scheduledDate = (args['scheduled_date'] as String?) ?? '';
      final scheduledTime = (args['scheduled_time'] as String?) ?? '';
      final urgency = (args['urgency'] as String?) ?? 'normal';

      if (category.isEmpty) return {'error': 'Please specify a service category.'};
      if (description.isEmpty) return {'error': 'Please describe the issue.'};

      // Get user info
      final userDoc = await FirebaseFirestore.instance.collection('users').doc(uid).get();
      final userData = userDoc.data() ?? {};
      final userName = userData['name'] ?? userData['fullName'] ?? '';
      final userPhone = userData['contact'] ?? userData['phone'] ?? '';

      // Look up estimated pricing
      String estimatedCost = '500';
      try {
        final pSnap = await FirebaseFirestore.instance
            .collection('pricingGuidance')
            .limit(20)
            .get();
        for (final p in pSnap.docs) {
          final catName = (p.data()['category_name'] ?? '').toString().toLowerCase();
          if (catName.contains(category.toLowerCase()) || category.toLowerCase().contains(catName)) {
            estimatedCost = (p.data()['average_price'] ?? p.data()['min_price'] ?? 500).toString();
            break;
          }
        }
      } catch (e) { debugPrint('[AITextChat] pricing lookup failed: $e'); }

      final now = FieldValue.serverTimestamp();
      final bookingId = FirebaseFirestore.instance.collection('futureBookings').doc().id;
      final orderNo = 'SQ-${DateTime.now().millisecondsSinceEpoch.toString().substring(5)}';

      final booking = {
        'id': bookingId,
        'bookingId': bookingId,
        'order_no': orderNo,
        'category_name': category,
        'category': category,
        'description': description,
        'address': address,
        'urgency': urgency,
        'name': userName,
        'contact': userPhone,
        'user_id': uid,
        'status': 'pending',
        'payment_status': 'unpaid',
        'cost': estimatedCost,
        'scheduled_date': scheduledDate,
        'scheduled_time': scheduledTime,
        'source': 'ai_text_chat',
        'is_rfq': 'no',
        'creation_date': DateTime.now().toIso8601String(),
        'createdAt': now,
      };

      // Write to futureBookings
      await FirebaseFirestore.instance.collection('futureBookings').doc(bookingId).set(booking);
      // Also write to tasksManagement
      await FirebaseFirestore.instance.collection('tasksManagement').doc(bookingId).set(booking);

      // Notify admin
      try {
        await FirebaseFirestore.instance.collection('Notifications').add({
          'title': 'New Booking via AI Chat',
          'body': '$userName booked $category ($orderNo)',
          'type': 'new_booking',
          'booking_id': bookingId,
          'target': 'admin',
          'read': false,
          'timestamp': now,
        });
      } catch (e) { debugPrint('[AITextChat] booking notification failed: $e'); }

      return {
        'success': true,
        'booking_id': bookingId,
        'order_no': orderNo,
        'estimated_cost': estimatedCost,
        'message': 'Booking created successfully! Order: $orderNo',
      };
    } catch (e) {
      return {'error': 'Failed to create booking. Please try again.'};
    }
  }

  // ═══════════════════════════════════════════════════════════════
  // SUBMIT RFQ
  // ═══════════════════════════════════════════════════════════════
  Future<Map<String, dynamic>> _submitRfq(String uid, Map<String, dynamic> args) async {
    try {
      final category = (args['category'] as String?) ?? '';
      final description = (args['description'] as String?) ?? '';
      final address = (args['address'] as String?) ?? '';
      final scopeOfWork = (args['scope_of_work'] as String?) ?? description;

      if (category.isEmpty) return {'error': 'Please specify a service category for the RFQ.'};
      if (description.isEmpty) return {'error': 'Please describe what you need quoted.'};

      final userDoc = await FirebaseFirestore.instance.collection('users').doc(uid).get();
      final userData = userDoc.data() ?? {};
      final userName = userData['name'] ?? userData['fullName'] ?? '';
      final userPhone = userData['contact'] ?? userData['phone'] ?? '';

      final now = FieldValue.serverTimestamp();
      final rfqId = FirebaseFirestore.instance.collection('futureBookings').doc().id;
      final rfqNo = 'RFQ-${DateTime.now().millisecondsSinceEpoch.toString().substring(5)}';

      final rfqDoc = {
        'id': rfqId,
        'bookingId': rfqId,
        'order_no': rfqNo,
        'rfq_no': rfqNo,
        'category_name': category,
        'category': category,
        'description': description,
        'problem_description': description,
        'scope_of_work': scopeOfWork,
        'address': address,
        'name': userName,
        'contact': userPhone,
        'user_id': uid,
        'status': 'rfq_submitted',
        'is_rfq': 'yes',
        'rfq_status': 'pending_admin_review',
        'payment_status': 'unpaid',
        'source': 'ai_text_chat',
        'creation_date': DateTime.now().toIso8601String(),
        'createdAt': now,
      };

      await FirebaseFirestore.instance.collection('futureBookings').doc(rfqId).set(rfqDoc);

      // Notify admin
      try {
        await FirebaseFirestore.instance.collection('Notifications').add({
          'title': 'New RFQ via AI Chat',
          'body': '$userName submitted RFQ for $category ($rfqNo)',
          'type': 'rfq_submitted',
          'booking_id': rfqId,
          'target': 'admin',
          'read': false,
          'timestamp': now,
        });
      } catch (e) { debugPrint('[AITextChat] RFQ notification failed: $e'); }

      return {
        'success': true,
        'rfq_id': rfqId,
        'rfq_no': rfqNo,
        'message': 'Your RFQ ($rfqNo) has been submitted. Admin will review and provide a quote.',
      };
    } catch (e) {
      return {'error': 'Failed to submit RFQ. Please try again.'};
    }
  }

  // ═══════════════════════════════════════════════════════════════
  // EXPLAIN RFQ QUOTE
  // ═══════════════════════════════════════════════════════════════
  Future<Map<String, dynamic>> _explainRfqQuote(String bookingId) async {
    try {
      var doc = await FirebaseFirestore.instance
          .collection('futureBookings')
          .doc(bookingId)
          .get();
      if (!doc.exists) {
        doc = await FirebaseFirestore.instance
            .collection('tasksManagement')
            .doc(bookingId)
            .get();
      }
      if (!doc.exists) return {'error': 'Booking not found'};
      final data = doc.data()!;
      if (data['is_rfq'] != 'yes') return {'error': 'This booking is not an RFQ.'};

      return {
        'rfq_no': data['rfq_no'] ?? data['order_no'] ?? '',
        'category': data['category_name'] ?? '',
        'description': data['problem_description'] ?? data['description'] ?? '',
        'scope_of_work': data['scope_of_work'] ?? '',
        'rfq_status': data['rfq_status'] ?? 'pending',
        'quoted_price': data['quoted_price'] ?? '',
        'quote_details': data['quote_details'] ?? '',
        'status': data['status'] ?? '',
      };
    } catch (e) {
      return {'error': 'Failed to fetch RFQ details'};
    }
  }

  // ═══════════════════════════════════════════════════════════════
  // CANCEL BOOKING
  // ═══════════════════════════════════════════════════════════════
  Future<Map<String, dynamic>> _cancelBooking(String uid, String bookingId, String? reason) async {
    try {
      var collection = 'tasksManagement';
      var doc = await FirebaseFirestore.instance.collection(collection).doc(bookingId).get();
      if (!doc.exists) {
        collection = 'futureBookings';
        doc = await FirebaseFirestore.instance.collection(collection).doc(bookingId).get();
      }
      if (!doc.exists) return {'error': 'Booking not found'};

      final data = doc.data()!;
      final status = (data['status'] ?? '').toString().toLowerCase();
      if (status == 'completed' || status == 'closed' || status == 'cancelled') {
        return {'error': 'Cannot cancel a booking that is already $status.'};
      }
      if (status == 'progress' || status == 'in_progress') {
        return {'error': 'This booking is currently in progress. Please contact support@square15.co.za to cancel an active job.'};
      }

      final cancelReason = reason ?? 'Cancelled via AI chat';
      final now = FieldValue.serverTimestamp();

      // Update in primary collection
      await FirebaseFirestore.instance.collection(collection).doc(bookingId).update({
        'status': 'cancelled',
        'cancel_reason': cancelReason,
        'cancellation_reason': cancelReason,
        'cancelled_by': 'client_ai_chat',
        'cancelled_at': now,
      });
      // Also update in other collection
      final otherCol = collection == 'tasksManagement' ? 'futureBookings' : 'tasksManagement';
      try {
        final otherDoc = await FirebaseFirestore.instance.collection(otherCol).doc(bookingId).get();
        if (otherDoc.exists) {
          await FirebaseFirestore.instance.collection(otherCol).doc(bookingId).update({
            'status': 'cancelled',
            'cancel_reason': cancelReason,
            'cancellation_reason': cancelReason,
            'cancelled_by': 'client_ai_chat',
            'cancelled_at': now,
          });
        }
      } catch (e) { debugPrint('[AITextChat] cancel sync to $otherCol failed: $e'); }

      // Auto-refund wallet payment
      if (data['payment_status'] == 'paid' && data['payment_method'] == 'wallet') {
        try {
          final cost = double.tryParse(data['cost']?.toString() ?? '0') ?? 0;
          if (cost > 0) {
            await FirebaseFirestore.instance.collection('users').doc(uid).update({
              'wallet_balance': FieldValue.increment(cost),
            });
            await FirebaseFirestore.instance.collection('wallet_transactions').add({
              'user_id': uid,
              'amount': cost,
              'type': 'refund',
              'description': 'Auto-refund for cancelled booking $bookingId',
              'booking_id': bookingId,
              'timestamp': now,
            });
            // Also write to transactionLogs for cross-platform consistency
            await FirebaseFirestore.instance.collection('transactionLogs').add({
              'user_id': uid,
              'type': 'refund',
              'subtype': 'wallet_refund',
              'amount': cost,
              'booking_id': bookingId,
              'source': 'ai_text_chat',
              'status': 'success',
              'created_at': now,
            });
          }
        } catch (e) { debugPrint('[AITextChat] wallet refund failed: $e'); }
      }

      // Notify admin
      try {
        await FirebaseFirestore.instance.collection('Notifications').add({
          'title': 'Booking Cancelled',
          'body': 'Booking $bookingId cancelled: $cancelReason',
          'type': 'booking_cancelled',
          'booking_id': bookingId,
          'target': 'admin',
          'read': false,
          'timestamp': now,
        });
      } catch (e) { debugPrint('[AITextChat] cancel notification failed: $e'); }

      return {'success': true, 'message': 'Booking $bookingId has been cancelled.'};
    } catch (e) {
      return {'error': 'Failed to cancel booking'};
    }
  }

  // ═══════════════════════════════════════════════════════════════
  // RESCHEDULE BOOKING
  // ═══════════════════════════════════════════════════════════════
  Future<Map<String, dynamic>> _rescheduleBooking(String bookingId, String? date, String? time) async {
    if ((date == null || date.isEmpty) && (time == null || time.isEmpty)) {
      return {'error': 'Please provide a new date or time for rescheduling.'};
    }
    try {
      final updates = <String, dynamic>{
        'updated_at': FieldValue.serverTimestamp(),
      };
      if (date != null && date.isNotEmpty) updates['scheduled_date'] = date;
      if (time != null && time.isNotEmpty) updates['scheduled_time'] = time;

      // Update both collections
      bool found = false;
      final doc1 = await FirebaseFirestore.instance.collection('tasksManagement').doc(bookingId).get();
      if (doc1.exists) {
        await FirebaseFirestore.instance.collection('tasksManagement').doc(bookingId).update(updates);
        found = true;
      }
      final doc2 = await FirebaseFirestore.instance.collection('futureBookings').doc(bookingId).get();
      if (doc2.exists) {
        await FirebaseFirestore.instance.collection('futureBookings').doc(bookingId).update(updates);
        found = true;
      }
      if (!found) return {'error': 'Booking not found'};

      return {'success': true, 'message': 'Booking rescheduled to ${date ?? ''} ${time ?? ''}'.trim()};
    } catch (e) {
      return {'error': 'Failed to reschedule'};
    }
  }

  // ═══════════════════════════════════════════════════════════════
  // WALLET BALANCE
  // ═══════════════════════════════════════════════════════════════
  Future<Map<String, dynamic>> _checkWalletBalance(String uid) async {
    try {
      final doc = await FirebaseFirestore.instance.collection('users').doc(uid).get();
      if (!doc.exists) return {'error': 'User not found'};
      final data = doc.data() ?? {};
      // The app stores balance in 'balance' field (string), fallback to 'wallet_balance'
      final raw = data['balance'] ?? data['wallet_balance'] ?? '0';
      final balance = double.tryParse(raw.toString()) ?? 0.0;
      return {'balance': balance, 'formatted': 'R${balance.toStringAsFixed(2)}'};
    } catch (e) {
      return {'error': 'Failed to check wallet balance'};
    }
  }

  // ═══════════════════════════════════════════════════════════════
  // TRANSACTION HISTORY
  // ═══════════════════════════════════════════════════════════════
  Future<Map<String, dynamic>> _getTransactionHistory(String uid) async {
    try {
      final snap = await FirebaseFirestore.instance
          .collection('wallet_transactions')
          .where('user_id', isEqualTo: uid)
          .orderBy('timestamp', descending: true)
          .limit(10)
          .get();
      final txs = snap.docs.map((d) {
        final data = d.data();
        return {
          'type': data['type'] ?? '',
          'amount': data['amount'] ?? 0,
          'description': data['description'] ?? '',
          'date': data['timestamp']?.toDate()?.toIso8601String() ?? '',
        };
      }).toList();
      return {'transactions': txs, 'count': txs.length};
    } catch (e) {
      return {'error': 'Failed to fetch transaction history'};
    }
  }

  // ═══════════════════════════════════════════════════════════════
  // SUBMIT RATING
  // ═══════════════════════════════════════════════════════════════
  Future<Map<String, dynamic>> _submitRating(String uid, String bookingId, num rating, String? review) async {
    try {
      var doc = await FirebaseFirestore.instance.collection('tasksManagement').doc(bookingId).get();
      if (!doc.exists) {
        doc = await FirebaseFirestore.instance.collection('futureBookings').doc(bookingId).get();
      }
      if (!doc.exists) return {'error': 'Booking not found'};

      final data = doc.data()!;
      final status = (data['status'] ?? '').toString().toLowerCase();
      if (status != 'completed' && status != 'closed') {
        return {'error': 'You can only rate completed bookings. Current status: $status'};
      }
      final artisanId = data['artisan_id'] ?? '';
      if (artisanId.isEmpty) return {'error': 'No artisan assigned to this booking'};

      final ratingVal = rating.toInt().clamp(1, 5);

      // Write review to artisan's reviews subcollection
      await FirebaseFirestore.instance
          .collection('artisan')
          .doc(artisanId)
          .collection('reviews')
          .add({
        'booking_id': bookingId,
        'user_id': uid,
        'rating': ratingVal,
        'review': review ?? '',
        'timestamp': FieldValue.serverTimestamp(),
      });

      // Recalculate average rating
      try {
        final allReviews = await FirebaseFirestore.instance
            .collection('artisan')
            .doc(artisanId)
            .collection('reviews')
            .get();
        if (allReviews.docs.isNotEmpty) {
          double sum = 0;
          for (final r in allReviews.docs) {
            sum += (r.data()['rating'] as num?)?.toDouble() ?? 0;
          }
          final avg = sum / allReviews.docs.length;
          await FirebaseFirestore.instance.collection('artisan').doc(artisanId).update({
            'rating': double.parse(avg.toStringAsFixed(1)),
            'review_count': allReviews.docs.length,
          });
        }
      } catch (e) { debugPrint('[AITextChat] artisan rating update failed: $e'); }

      return {'success': true, 'message': 'Thank you! Your $ratingVal-star rating has been submitted.'};
    } catch (e) {
      return {'error': 'Failed to submit rating'};
    }
  }

  // ═══════════════════════════════════════════════════════════════
  // SUBMIT COMPLAINT
  // ═══════════════════════════════════════════════════════════════
  Future<Map<String, dynamic>> _submitComplaint(String uid, String description, String? subject, String? bookingId) async {
    try {
      final caseId = FirebaseFirestore.instance.collection('customer_support_cases').doc().id;
      await FirebaseFirestore.instance.collection('customer_support_cases').doc(caseId).set({
        'id': caseId,
        'user_id': uid,
        'subject': subject ?? 'Complaint',
        'description': description,
        'booking_id': bookingId ?? '',
        'status': 'open',
        'source': 'ai_text_chat',
        'created_at': FieldValue.serverTimestamp(),
      });

      // Notify admin
      try {
        await FirebaseFirestore.instance.collection('Notifications').add({
          'title': 'New Support Case',
          'body': '${subject ?? 'Complaint'}: $description',
          'type': 'support_case',
          'case_id': caseId,
          'target': 'admin',
          'read': false,
          'timestamp': FieldValue.serverTimestamp(),
        });
      } catch (e) { debugPrint('[AITextChat] complaint notification failed: $e'); }

      return {'success': true, 'case_id': caseId, 'message': 'Your complaint has been submitted (ref: $caseId). Our team will review it.'};
    } catch (e) {
      return {'error': 'Failed to submit complaint'};
    }
  }

  // ═══════════════════════════════════════════════════════════════
  // GET NOTIFICATIONS
  // ═══════════════════════════════════════════════════════════════
  Future<Map<String, dynamic>> _getNotifications(String uid) async {
    try {
      final snap = await FirebaseFirestore.instance
          .collection('Notifications')
          .where('user_id', isEqualTo: uid)
          .orderBy('timestamp', descending: true)
          .limit(10)
          .get();
      final notifs = snap.docs.map((d) {
        final data = d.data();
        return {
          'title': data['title'] ?? '',
          'body': data['body'] ?? '',
          'type': data['type'] ?? '',
          'read': data['read'] ?? false,
          'date': data['timestamp']?.toDate()?.toIso8601String() ?? '',
        };
      }).toList();
      return {'notifications': notifs, 'count': notifs.length};
    } catch (e) {
      return {'error': 'Failed to fetch notifications'};
    }
  }

  // ═══════════════════════════════════════════════════════════════
  // GET SCHEDULED BOOKINGS (future/upcoming)
  // ═══════════════════════════════════════════════════════════════
  Future<Map<String, dynamic>> _getScheduledBookings(String uid) async {
    try {
      final snap = await FirebaseFirestore.instance
          .collection('futureBookings')
          .where('user_id', isEqualTo: uid)
          .limit(10)
          .get();
      final bookings = snap.docs.map((d) {
        final data = d.data();
        return {
          'id': d.id,
          'category': data['category_name'] ?? data['task_name'] ?? '',
          'scheduled_date': data['scheduled_date'] ?? '',
          'scheduled_time': data['scheduled_time'] ?? '',
          'status': data['status'] ?? '',
          'is_rfq': data['is_rfq'] ?? 'no',
          'rfq_status': data['rfq_status'] ?? '',
          'cost': data['cost'] ?? 'N/A',
          'order_no': data['order_no'] ?? '',
        };
      }).toList();
      return {'scheduled_bookings': bookings, 'count': bookings.length};
    } catch (e) {
      return {'error': 'Failed to fetch scheduled bookings'};
    }
  }

  // ═══════════════════════════════════════════════════════════════
  // GET ARTISAN INFO
  // ═══════════════════════════════════════════════════════════════
  Future<Map<String, dynamic>> _getArtisanInfo(String artisanId) async {
    try {
      final doc = await FirebaseFirestore.instance
          .collection('artisan')
          .doc(artisanId)
          .get();
      if (!doc.exists) return {'error': 'Artisan not found'};
      final data = doc.data()!;
      return {
        'name': data['name'] ?? data['fullName'] ?? 'Unknown',
        'rating': data['rating'] ?? 'No rating yet',
        'review_count': data['review_count'] ?? 0,
        'location': data['location'] ?? data['address'] ?? '',
        'skills': data['skills'] ?? [],
        'verified': data['verified'] ?? false,
      };
    } catch (e) {
      return {'error': 'Failed to fetch artisan info'};
    }
  }

  // ═══════════════════════════════════════════════════════════════
  // APPLY PROMO CODE
  // ═══════════════════════════════════════════════════════════════
  Future<Map<String, dynamic>> _applyPromoCode(String code) async {
    try {
      final snap = await FirebaseFirestore.instance
          .collection('promo_codes')
          .where('code', isEqualTo: code.toUpperCase())
          .limit(1)
          .get();
      if (snap.docs.isEmpty) return {'valid': false, 'message': 'Promo code not found.'};

      final doc = snap.docs.first;
      final data = doc.data();

      // Check expiry
      if (data['end_date'] != null) {
        final endDate = (data['end_date'] is Timestamp)
            ? (data['end_date'] as Timestamp).toDate()
            : DateTime.tryParse(data['end_date'].toString());
        if (endDate != null && endDate.isBefore(DateTime.now())) {
          return {'valid': false, 'message': 'This promo code has expired.'};
        }
      }

      // Check max uses
      final maxUses = data['max_uses'] as int?;
      final usedCount = data['used_count'] as int? ?? 0;
      if (maxUses != null && usedCount >= maxUses) {
        return {'valid': false, 'message': 'This promo code has reached its maximum uses.'};
      }

      final discountType = data['discount_type'] ?? data['discountType'] ?? 'percentage';
      final discountValue = data['discount_value'] ?? data['discountValue'] ?? 0;

      if (discountType == 'percentage') {
        return {'valid': true, 'message': 'Promo "$code" valid! $discountValue% discount.', 'discount_type': 'percentage', 'discount_value': discountValue};
      } else {
        return {'valid': true, 'message': 'Promo "$code" valid! R$discountValue discount.', 'discount_type': 'fixed', 'discount_value': discountValue};
      }
    } catch (e) {
      return {'error': 'Failed to validate promo code'};
    }
  }

  // ═══════════════════════════════════════════════════════════════
  // REQUEST REFUND
  // ═══════════════════════════════════════════════════════════════
  Future<Map<String, dynamic>> _requestRefund(String uid, String bookingId, String? reason) async {
    try {
      var doc = await FirebaseFirestore.instance.collection('tasksManagement').doc(bookingId).get();
      if (!doc.exists) {
        doc = await FirebaseFirestore.instance.collection('futureBookings').doc(bookingId).get();
      }
      if (!doc.exists) return {'error': 'Booking not found'};

      final data = doc.data()!;
      if (data['payment_status'] != 'paid') {
        return {'error': 'No payment found for this booking to refund.'};
      }

      // Check duplicate
      final existing = await FirebaseFirestore.instance
          .collection('refund_requests')
          .where('booking_id', isEqualTo: bookingId)
          .where('user_id', isEqualTo: uid)
          .limit(1)
          .get();
      if (existing.docs.isNotEmpty) {
        return {'error': 'A refund request already exists for this booking.'};
      }

      final refundId = FirebaseFirestore.instance.collection('refund_requests').doc().id;
      await FirebaseFirestore.instance.collection('refund_requests').doc(refundId).set({
        'id': refundId,
        'booking_id': bookingId,
        'user_id': uid,
        'amount': data['cost'],
        'reason': reason ?? 'Refund requested via AI chat',
        'status': 'pending',
        'payment_method': data['payment_method'] ?? 'unknown',
        'created_at': FieldValue.serverTimestamp(),
      });

      // Notify admin
      try {
        await FirebaseFirestore.instance.collection('Notifications').add({
          'title': 'Refund Request',
          'body': 'Refund requested for booking $bookingId (R${data['cost']})',
          'type': 'refund_request',
          'booking_id': bookingId,
          'target': 'admin',
          'read': false,
          'timestamp': FieldValue.serverTimestamp(),
        });
      } catch (e) { debugPrint('[AITextChat] refund notification failed: $e'); }

      return {'success': true, 'refund_id': refundId, 'message': 'Refund request submitted. Admin will review shortly.'};
    } catch (e) {
      return {'error': 'Failed to submit refund request'};
    }
  }

  void _storeMessage(ChatMessage userMsg, ChatMessage assistantMsg) {
    try {
      final uid = FirebaseAuth.instance.currentUser?.uid;
      FirebaseFirestore.instance.collection('ai_chat_sessions').doc(_sessionId).set({
        'user_id': uid,
        'user_role': _userRole,
        'updated_at': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      FirebaseFirestore.instance
          .collection('ai_chat_sessions')
          .doc(_sessionId)
          .collection('messages')
          .add({
        'user_message': userMsg.content,
        'assistant_message': assistantMsg.content,
        'timestamp': FieldValue.serverTimestamp(),
      });
    } catch (e) { debugPrint('[AITextChat] message store failed: $e'); }
  }

  void endSession() {
    _conversationHistory.clear();
    messages.clear();
    _sessionId = null;
  }

  void dispose() {
    _messageController.close();
  }

  String _systemPrompt(String role) {
    return '''You are Lizzy, the AI assistant for Square 15 Maintenance, a property maintenance company in South Africa.
You help ${role == 'artisan' ? 'artisans manage their jobs, check bookings, and track payments' : 'clients book maintenance services, manage bookings, track payments, submit RFQs, and more'}.

YOUR CAPABILITIES:
- List bookings (active + scheduled/future)
- Get booking details (by ID or order number)
- Create new bookings for maintenance services
- Submit RFQs (Request for Quotation) for complex/large jobs
- Explain RFQ quotes and pricing
- Cancel or reschedule bookings
- Check payment status
- Check wallet balance and transaction history
- Submit ratings for completed jobs (1-5 stars)
- File complaints / support cases
- Check notifications
- View scheduled/upcoming bookings
- Look up artisan info (rating, location)
- Validate promo codes
- Request refunds
- Look up service pricing

KEY GUIDELINES:
- Be helpful, friendly, and concise
- Amounts are in South African Rand (R)
- For booking, guide through: service type → description → address → timing → urgency
- For RFQs: use when job is complex, unclear pricing, or customer wants a formal quote first
- For emergencies (burst pipes, electrical hazards, flooding), treat as urgent
- After a completed booking, ask if they'd like to rate their artisan
- Never share other users' personal information
- Always confirm before cancelling a booking
- If you can't help, suggest contacting Square 15 support''';
  }

  List<Map<String, dynamic>> get _toolDefinitions => [
        {
          'type': 'function',
          'function': {
            'name': 'list_bookings',
            'description': 'List the user\'s bookings (active + scheduled/future), optionally filtered by status',
            'parameters': {
              'type': 'object',
              'properties': {
                'status': {
                  'type': 'string',
                  'description': 'Filter by status: pending, progress, completed, closed, cancelled, rfq_submitted',
                },
              },
            },
          },
        },
        {
          'type': 'function',
          'function': {
            'name': 'get_booking_details',
            'description': 'Get full details of a specific booking by ID or order number',
            'parameters': {
              'type': 'object',
              'properties': {
                'booking_id': {
                  'type': 'string',
                  'description': 'The booking ID or order number (e.g. SQ-XXXXX or RFQ-XXXXX)',
                },
              },
              'required': ['booking_id'],
            },
          },
        },
        {
          'type': 'function',
          'function': {
            'name': 'lookup_service_pricing',
            'description': 'Look up pricing for a service category',
            'parameters': {
              'type': 'object',
              'properties': {
                'service_name': {
                  'type': 'string',
                  'description': 'The service to look up (e.g. plumbing, electrical)',
                },
              },
              'required': ['service_name'],
            },
          },
        },
        {
          'type': 'function',
          'function': {
            'name': 'get_service_categories',
            'description': 'Get all available service categories',
            'parameters': {'type': 'object', 'properties': {}},
          },
        },
        {
          'type': 'function',
          'function': {
            'name': 'check_payment_status',
            'description': 'Check payment status for a booking',
            'parameters': {
              'type': 'object',
              'properties': {
                'booking_id': {
                  'type': 'string',
                  'description': 'The booking ID',
                },
              },
              'required': ['booking_id'],
            },
          },
        },
        {
          'type': 'function',
          'function': {
            'name': 'create_booking',
            'description': 'Create a new maintenance booking. Guide user through: category, description, address, date/time, urgency.',
            'parameters': {
              'type': 'object',
              'properties': {
                'category': {'type': 'string', 'description': 'Service category (e.g. Plumbing, Electrical)'},
                'description': {'type': 'string', 'description': 'Description of the issue'},
                'address': {'type': 'string', 'description': 'Service address'},
                'scheduled_date': {'type': 'string', 'description': 'Preferred date (YYYY-MM-DD)'},
                'scheduled_time': {'type': 'string', 'description': 'Preferred time (HH:MM)'},
                'urgency': {'type': 'string', 'description': 'Urgency level: normal, urgent, emergency'},
              },
              'required': ['category', 'description'],
            },
          },
        },
        {
          'type': 'function',
          'function': {
            'name': 'submit_rfq',
            'description': 'Submit a Request for Quotation (RFQ) for complex jobs that need a formal quote before proceeding.',
            'parameters': {
              'type': 'object',
              'properties': {
                'category': {'type': 'string', 'description': 'Service category'},
                'description': {'type': 'string', 'description': 'Detailed description of the work needed'},
                'scope_of_work': {'type': 'string', 'description': 'Scope of work details'},
                'address': {'type': 'string', 'description': 'Service address'},
              },
              'required': ['category', 'description'],
            },
          },
        },
        {
          'type': 'function',
          'function': {
            'name': 'explain_rfq_quote',
            'description': 'Explain the quote/pricing details for an RFQ booking',
            'parameters': {
              'type': 'object',
              'properties': {
                'booking_id': {'type': 'string', 'description': 'The RFQ booking ID'},
              },
              'required': ['booking_id'],
            },
          },
        },
        {
          'type': 'function',
          'function': {
            'name': 'cancel_booking',
            'description': 'Cancel a booking. Always confirm with user before cancelling.',
            'parameters': {
              'type': 'object',
              'properties': {
                'booking_id': {'type': 'string', 'description': 'The booking ID to cancel'},
                'reason': {'type': 'string', 'description': 'Reason for cancellation'},
              },
              'required': ['booking_id'],
            },
          },
        },
        {
          'type': 'function',
          'function': {
            'name': 'reschedule_booking',
            'description': 'Reschedule a booking to a new date and/or time',
            'parameters': {
              'type': 'object',
              'properties': {
                'booking_id': {'type': 'string', 'description': 'The booking ID to reschedule'},
                'scheduled_date': {'type': 'string', 'description': 'New date (YYYY-MM-DD)'},
                'scheduled_time': {'type': 'string', 'description': 'New time (HH:MM)'},
              },
              'required': ['booking_id'],
            },
          },
        },
        {
          'type': 'function',
          'function': {
            'name': 'check_wallet_balance',
            'description': 'Check the user\'s wallet balance',
            'parameters': {'type': 'object', 'properties': {}},
          },
        },
        {
          'type': 'function',
          'function': {
            'name': 'get_transaction_history',
            'description': 'Get the user\'s wallet transaction history',
            'parameters': {'type': 'object', 'properties': {}},
          },
        },
        {
          'type': 'function',
          'function': {
            'name': 'submit_rating',
            'description': 'Submit a rating and review for a completed booking',
            'parameters': {
              'type': 'object',
              'properties': {
                'booking_id': {'type': 'string', 'description': 'The completed booking ID'},
                'rating': {'type': 'integer', 'description': 'Rating from 1 to 5 stars'},
                'review': {'type': 'string', 'description': 'Optional review text'},
              },
              'required': ['booking_id', 'rating'],
            },
          },
        },
        {
          'type': 'function',
          'function': {
            'name': 'submit_complaint',
            'description': 'File a complaint or support case',
            'parameters': {
              'type': 'object',
              'properties': {
                'description': {'type': 'string', 'description': 'What went wrong'},
                'subject': {'type': 'string', 'description': 'Complaint subject'},
                'booking_id': {'type': 'string', 'description': 'Related booking ID (optional)'},
              },
              'required': ['description'],
            },
          },
        },
        {
          'type': 'function',
          'function': {
            'name': 'get_notifications',
            'description': 'Get the user\'s recent notifications',
            'parameters': {'type': 'object', 'properties': {}},
          },
        },
        {
          'type': 'function',
          'function': {
            'name': 'get_scheduled_bookings',
            'description': 'Get the user\'s upcoming/scheduled bookings and pending RFQs',
            'parameters': {'type': 'object', 'properties': {}},
          },
        },
        {
          'type': 'function',
          'function': {
            'name': 'get_artisan_info',
            'description': 'Get information about a specific artisan/service provider',
            'parameters': {
              'type': 'object',
              'properties': {
                'artisan_id': {'type': 'string', 'description': 'The artisan\'s ID'},
              },
              'required': ['artisan_id'],
            },
          },
        },
        {
          'type': 'function',
          'function': {
            'name': 'apply_promo_code',
            'description': 'Validate a promo/discount code to check if it\'s active and what discount it offers',
            'parameters': {
              'type': 'object',
              'properties': {
                'code': {'type': 'string', 'description': 'The promo code to validate'},
              },
              'required': ['code'],
            },
          },
        },
        {
          'type': 'function',
          'function': {
            'name': 'request_refund',
            'description': 'Request a refund for a paid booking',
            'parameters': {
              'type': 'object',
              'properties': {
                'booking_id': {'type': 'string', 'description': 'The booking ID to refund'},
                'reason': {'type': 'string', 'description': 'Reason for the refund request'},
              },
              'required': ['booking_id'],
            },
          },
        },
      ];
}

class ChatMessage {
  final String role;
  final String content;
  final DateTime timestamp;
  final bool isTyping;

  ChatMessage({
    required this.role,
    required this.content,
    required this.timestamp,
    this.isTyping = false,
  });
}
