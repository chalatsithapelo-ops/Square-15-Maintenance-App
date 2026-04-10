import 'dart:async';
import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'error_reporting_service.dart';
import 'future_booking_service.dart';

/// AI Text Chat Service — same capabilities as Lizzy Voice but via text.
/// Uses OpenAI GPT-4o-mini with function calling for bookings, lookups, etc.
class AITextChatService {
  AITextChatService._();
  static final AITextChatService instance = AITextChatService._();

  /// Photo URLs uploaded by the user during this chat session, to be attached to the next booking/RFQ.
  final List<String> pendingPhotoUrls = [];

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

  StreamController<ChatMessage> _messageController = StreamController<ChatMessage>.broadcast();
  Stream<ChatMessage> get messageStream => _messageController.stream;

  final List<ChatMessage> messages = [];

  void startSession({required String userRole}) {
    // Re-create the stream controller if it was closed by a previous dispose()
    if (_messageController.isClosed) {
      _messageController = StreamController<ChatMessage>.broadcast();
    }
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
      case 'request_payment_link':
        return _requestPaymentLink(uid, arguments['booking_id'] as String, arguments['payment_type'] as String? ?? 'full');
      case 'create_booking':
        return _createBooking(uid, arguments);
      case 'submit_rfq':
        return _submitRfq(uid, arguments);
      case 'explain_rfq_quote':
        return _explainRfqQuote(arguments['booking_id'] as String);
      case 'accept_rfq_quote':
        return _acceptRfqQuote(uid, arguments['booking_id'] as String);
      case 'reject_rfq_quote':
        return _rejectRfqQuote(uid, arguments['booking_id'] as String, arguments['reason'] as String?);
      case 'check_rfq_status':
        return _checkRfqStatus(uid);
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
      case 'report_technical_error':
        return _reportTechnicalError(uid, arguments['error_type'] as String, arguments['description'] as String, arguments['booking_id'] as String?);
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
      case 'send_message':
        return _sendMessage(uid, arguments['booking_id'] as String, arguments['message'] as String, arguments['recipient'] as String?);
      case 'list_cases':
        return _listCases(uid, arguments['state'] as String?);
      case 'reply_to_case':
        return _replyToCase(uid, arguments['case_id'] as String, arguments['message'] as String);
      case 'get_case_details':
        return _getCaseDetails(arguments['case_id'] as String);
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
      final data = doc.data() ?? {};
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
      // Normalize: replace underscores/hyphens with spaces for consistent matching
      String normalize(String s) => s.toLowerCase().replaceAll(RegExp(r'[_\-]+'), ' ').trim();
      final searchLower = normalize(serviceName);
      final searchWords = searchLower.split(RegExp(r'\s+')).where((w) => w.length >= 3).toList();

      // Comprehensive 14-category synonym map (matches livekit-backend)
      const synonyms = <String, List<String>>{
        'plumbing':    ['toilet', 'cistern', 'basin', 'bath', 'tap', 'pipe', 'drain', 'geyser', 'shower', 'sink', 'plumb', 'blocked', 'leak', 'water', 'bathroom', 'kitchen'],
        'electrical':  ['light', 'switch', 'socket', 'wire', 'wiring', 'breaker', 'db board', 'plug', 'circuit', 'electric', 'power', 'volt'],
        'painting':    ['paint', 'wall', 'ceiling', 'enamel', 'pva', 'varnish', 'roof', 'garage', 'door'],
        'cleaning':    ['clean', 'wash', 'deep clean', 'carpet', 'window', 'scrub'],
        'tiling':      ['tile', 'floor', 'grout', 'ceramic'],
        'carpentry':   ['wood', 'cabinet', 'shelf', 'cupboard', 'door', 'frame', 'carpenter'],
        'solar':       ['panel', 'inverter', 'battery', 'geyser', 'energy'],
        'maintenance': ['repair', 'fix', 'maintain', 'service', 'general'],
        'bathroom':    ['toilet', 'cistern', 'basin', 'bath', 'shower', 'tap', 'plumb', 'blocked', 'drain'],
        'kitchen':     ['tap', 'mixer', 'sink', 'faucet', 'cupboard'],
        'door':        ['lock', 'handle', 'hinge', 'frame', 'door'],
        'window':      ['glass', 'pane', 'frame', 'window'],
        'installation':['install', 'setup', 'mount', 'fit'],
      };

      // Expand search words with synonyms (bidirectional)
      final expandedSearch = <String>{...searchWords};
      for (final w in searchWords) {
        // If word matches a category key, add all its synonyms
        if (synonyms.containsKey(w)) {
          expandedSearch.addAll(synonyms[w]!);
        }
        // Reverse: if word appears in a category's synonyms, add the key + all siblings
        for (final entry in synonyms.entries) {
          if (entry.value.contains(w)) {
            expandedSearch.add(entry.key);
            expandedSearch.addAll(entry.value);
          }
        }
      }
      final expandedSearchStr = expandedSearch.join(' ');

      // Score how well two strings match: exact > substring > word overlap (with synonym expansion)
      int matchScore(String a, String b) {
        final al = normalize(a), bl = normalize(b);
        if (al == bl) return 1000;
        if (al.contains(bl) || bl.contains(al)) return 100;
        final aw = al.split(RegExp(r'\s+')).where((w) => w.length >= 3).toList();
        final bw = bl.split(RegExp(r'\s+')).where((w) => w.length >= 3).toList();
        int score = 0;
        for (final w in aw) { if (bl.contains(w)) score++; }
        for (final w in bw) { if (al.contains(w)) score++; }
        // Also check expanded synonyms against the task name words
        for (final w in expandedSearch) {
          if (w.length >= 3 && al.contains(w)) score++;
        }
        return score;
      }

      // 1) AUTHORITATIVE SOURCE: tasks collection (admin-managed fixed prices)
      final allFixedPrices = <Map<String, dynamic>>[];
      String? bestService;
      double? bestPrice;
      int bestScore = 0;

      try {
        final taskSnap = await FirebaseFirestore.instance
            .collection('tasks')
            .limit(200)
            .get();
        for (final td in taskSnap.docs) {
          final data = td.data();
          final taskName = (data['name'] ?? data['title'] ?? data['task_name'] ?? '').toString();
          final cost = double.tryParse((data['client_rate'] ?? data['clientRate'] ?? data['cost'] ?? data['price'] ?? data['amount'] ?? '0').toString()) ?? 0;
          if (taskName.isEmpty || cost <= 0) continue;
          final score = matchScore(taskName, searchLower);
          if (score > 0) {
            allFixedPrices.add({'service': taskName, 'fixedPrice': 'R${cost.toStringAsFixed(2)}'});
            if (score > bestScore) {
              bestScore = score;
              bestService = taskName;
              bestPrice = cost;
            }
          }
        }
      } catch (e) { debugPrint('[AITextChat] tasks lookup failed: $e'); }

      // 2) pricingGuidance — for AI context (labor rates) only, does NOT override task prices
      Map<String, dynamic>? matchedGuidance;
      try {
        final snap = await FirebaseFirestore.instance
            .collection('pricingGuidance')
            .limit(20)
            .get();
        for (final doc in snap.docs) {
          final data = doc.data();
          final name = (data['category_name'] ?? '').toString().toLowerCase();
          final categoryMatch = name.contains(searchLower) || searchLower.contains(name);
          final wordMatch = searchWords.any((w) => name.contains(w));
          if (categoryMatch || wordMatch) {
            matchedGuidance ??= data;
          }
        }
      } catch (e) { debugPrint('[AITextChat] pricingGuidance lookup failed: $e'); }

      // 3) Build response — return best-scoring match from tasks
      if (bestService != null && bestPrice != null && bestScore > 0) {
        return {
          'matched': true,
          'service': bestService,
          'fixedPrice': 'R${bestPrice.toStringAsFixed(2)}',
          'category': matchedGuidance?['category_name'] ?? serviceName,
          'allServicesInCategory': allFixedPrices,
          'note': 'FIXED PRICE FOUND. You MUST call create_booking with this fixedPrice as the cost parameter. DO NOT suggest RFQ. DO NOT recommend a quote. Just confirm the price with the customer and proceed to create_booking.',
        };
      }

      if (allFixedPrices.isNotEmpty) {
        return {
          'matched': false,
          'category': matchedGuidance?['category_name'] ?? serviceName,
          'availableServices': allFixedPrices,
          if (matchedGuidance != null) 'labor_rate_per_hour': matchedGuidance['labor_rate_per_hour'],
          'note': 'No exact match found. Show the customer these available fixed-price services. If one matches what they need, call create_booking with that price. Only suggest RFQ if none of these services match.',
        };
      }

      return {
        'matched': false,
        'pricing': <Map<String, dynamic>>[],
        'count': 0,
        'note': 'No fixed pricing found for this service. You may suggest submitting an RFQ for a detailed quote.',
      };
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
      final data = doc.data() ?? {};
      final paymentStatus = (data['payment_status'] ?? 'unknown').toString();
      final cost = (data['cost'] ?? 'N/A').toString();
      final depositPaid = data['deposit_paid'] == true;
      final balancePaid = data['balance_paid'] == true;
      final paymentType = (data['payment_type'] ?? '').toString();

      String guidance = '';
      final isRfq = data['is_rfq'] == 'yes';
      final rfqStatus = (data['rfq_status'] ?? '').toString();

      if (isRfq && rfqStatus == 'pending_admin_review') {
        guidance = 'This is an RFQ awaiting admin review. No payment is due yet — a quote must be provided and accepted first.';
      } else if (isRfq && rfqStatus == 'pending_client_response') {
        final quotedPrice = data['quoted_price'] ?? data['cost'] ?? '';
        guidance = 'A quote of R$quotedPrice is ready. Accept the quote first, then an artisan must accept before payment.';
      } else if (isRfq && rfqStatus == 'under_negotiation') {
        guidance = 'This RFQ is under negotiation. No payment is due until a revised quote is accepted.';
      } else if (paymentStatus == 'unpaid' || paymentStatus == 'unknown') {
        guidance = 'Payment is pending. Go to your Bookings tab and tap "Pay to confirm booking" once an artisan accepts.';
      } else if (paymentStatus == 'deposit_paid' && !balancePaid) {
        final balanceAmt = data['balance_amount'] ?? '';
        guidance = 'Deposit paid. Balance of R$balanceAmt is due after job completion. You will be prompted to pay from your bookings.';
      } else if (paymentStatus == 'paid') {
        guidance = 'Fully paid. No action needed.';
      } else if (paymentStatus == 'cancelled' || paymentStatus == 'failed') {
        guidance = 'Payment was $paymentStatus. You can retry from your Bookings tab.';
      }

      return {
        'booking_id': bookingId,
        'payment_status': paymentStatus,
        'cost': cost,
        'payment_method': data['payment_method'] ?? '',
        'payment_type': paymentType,
        'deposit_paid': depositPaid,
        'balance_paid': balancePaid,
        'guidance': guidance,
      };
    } catch (e) {
      return {'error': 'Failed to check payment'};
    }
  }

  // ═══════════════════════════════════════════════════════════════
  // REQUEST PAYMENT LINK (calls backend to generate PayFast URL)
  // ═══════════════════════════════════════════════════════════════
  Future<Map<String, dynamic>> _requestPaymentLink(String uid, String bookingId, String paymentType) async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) return {'error': 'Not signed in'};
      final token = await user.getIdToken();

      const backendUrl = 'https://square15-livekit-backend.onrender.com';
      final response = await http.post(
        Uri.parse('$backendUrl/api/action/execute'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $token',
        },
        body: jsonEncode({
          'action': 'request_payment_link',
          'payload': {
            'booking_id': bookingId,
            'payment_type': paymentType,
            'source': 'text_chat',
          },
        }),
      ).timeout(const Duration(seconds: 20));

      final body = jsonDecode(response.body);
      if (response.statusCode == 200 && (body['success'] == true || (body['result'] != null && body['result']['ok'] == true))) {
        final data = body['result']?['data'] ?? body['data'] ?? body;
        return {
          'status': 'success',
          'message': data['message'] ?? 'Payment link generated. Check your notifications.',
          'amount': data['amount'],
          'payment_type': data['payment_type'] ?? paymentType,
          'payment_url': data['paymentUrl'] ?? '',
        };
      } else {
        final error = body['result']?['error'] ?? body['error'] ?? 'unknown_error';
        return {'error': error};
      }
    } catch (e) {
      debugPrint('[AITextChat] request_payment_link error: $e');
      return {'error': 'Failed to generate payment link. Try paying from the Bookings tab instead.'};
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
      if (uid.isEmpty) return {'error': 'You must be signed in to create a booking.'};
      if (address.isEmpty) {
        return {'error': 'Please provide a service address so the artisan knows where to go.'};
      }

      // Get user info
      final userDoc = await FirebaseFirestore.instance.collection('users').doc(uid).get();
      if (!userDoc.exists) return {'error': 'User account not found. Please sign in again.'};
      final userData = userDoc.data() ?? {};
      final userName = userData['name'] ?? userData['fullName'] ?? '';
      final userPhone = userData['contact'] ?? userData['phone'] ?? '';

      // Use cost from AI tool call (lookup_service_pricing) if provided
      double estimatedCost = 0;
      String pricingSource = 'none';
      final providedCost = double.tryParse((args['cost'] ?? '0').toString()) ?? 0;

      if (providedCost > 0) {
        estimatedCost = providedCost;
        pricingSource = 'fixed';
        debugPrint('[AITextChat] Using AI-provided cost: R${estimatedCost.toStringAsFixed(2)}');
      } else {
        // Fallback: look up from tasks collection
        final descLower = description.toLowerCase();
        final searchWords = descLower.split(RegExp(r'\s+')).where((w) => w.length >= 3).toList();

        try {
          final taskSnap = await FirebaseFirestore.instance
              .collection('tasks')
              .limit(200)
              .get();
          for (final td in taskSnap.docs) {
            final data = td.data();
            final taskName = (data['name'] ?? data['title'] ?? '').toString().toLowerCase();
            final cost = double.tryParse((data['client_rate'] ?? data['clientRate'] ?? data['cost'] ?? data['price'] ?? data['amount'] ?? '0').toString()) ?? 0;
            if (taskName.isNotEmpty && cost > 0 &&
                (descLower.contains(taskName) || taskName.contains(descLower) ||
                 searchWords.any((w) => taskName.contains(w)))) {
              estimatedCost = cost;
              pricingSource = 'fixed';
              break;
            }
          }
        } catch (e) { debugPrint('[AITextChat] pricing lookup failed: $e'); }
      }

      // Calculate deposit (35%) and balance (65%), matching WhatsApp bot + deposit_service.dart
      final depositAmount = (estimatedCost * 0.35 * 100).round() / 100;
      final balanceAmount = ((estimatedCost - depositAmount) * 100).round() / 100;

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
        'provided_address': address,
        'urgency': urgency,
        'name': userName,
        'contact': userPhone,
        'phone': userPhone,
        'customer_phone': userPhone,
        'user_id': uid,
        'source': 'ai_text_chat',
        'status': 'pending',
        'accept': '',
        'artisan_confirmed': 'pending',
        'cost': estimatedCost > 0 ? estimatedCost.toStringAsFixed(2) : '0',
        'deposit_amount': depositAmount.toStringAsFixed(2),
        'balance_amount': balanceAmount.toStringAsFixed(2),
        'payment_type': '',
        'deposit_paid': false,
        'balance_paid': false,
        'payment_status': 'unpaid',
        'scheduled_date': scheduledDate,
        'scheduled_time': scheduledTime,
        'is_rfq': estimatedCost <= 0 ? 'yes' : 'no',
        'pricing_source': pricingSource,
        'service_provider_id': '',
        'service_provider_name': '',
        // Photo URLs uploaded during this chat session
        'work_images': pendingPhotoUrls.isNotEmpty ? List<String>.from(pendingPhotoUrls) : <String>[],
        'image_urls': pendingPhotoUrls.isNotEmpty ? List<String>.from(pendingPhotoUrls) : <String>[],
        'imageUrls': pendingPhotoUrls.isNotEmpty ? List<String>.from(pendingPhotoUrls) : <String>[],
        'has_photos': pendingPhotoUrls.isNotEmpty ? 'yes' : 'no',
        'creation_date': DateTime.now().toIso8601String(),
        'createdAt': now,
      };

      // Write to futureBookings
      await FirebaseFirestore.instance.collection('futureBookings').doc(bookingId).set(booking);
      // Also write to tasksManagement
      await FirebaseFirestore.instance.collection('tasksManagement').doc(bookingId).set(booking);

      // Clear pending photos after attaching to booking
      pendingPhotoUrls.clear();

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

      // Dispatch to artisans: create per-artisan bridge records in tasksManagement
      // so bookings appear in each artisan's "New Requests" screen.
      if (estimatedCost <= 0) {
        // Auto-converted to RFQ — tryAutoDispatchRfq handles R12K threshold
        try {
          await FutureBookingService.tryAutoDispatchRfq(bookingId);
        } catch (e) { debugPrint('[AITextChat] RFQ auto-dispatch failed: $e'); }
      } else {
        // Direct booking with known price — create per-artisan bridge records + FCM
        try {
          final catSlug = category.toLowerCase().replaceAll(RegExp(r'\s+'), '_');
          // Query all serviceProvider docs and filter in-code to handle
          // status variants (publish/approved) and missing is_suspended field.
          QuerySnapshot<Map<String, dynamic>> artisanSnap;
          try {
            artisanSnap = await FirebaseFirestore.instance
                .collection('serviceProvider')
                .where('status', isEqualTo: 'publish')
                .limit(200)
                .get();
            if (artisanSnap.docs.isEmpty) {
              artisanSnap = await FirebaseFirestore.instance
                  .collection('serviceProvider')
                  .where('status', isEqualTo: 'approved')
                  .limit(200)
                  .get();
            }
            if (artisanSnap.docs.isEmpty) {
              artisanSnap = await FirebaseFirestore.instance
                  .collection('serviceProvider')
                  .limit(200)
                  .get();
            }
          } catch (_) {
            artisanSnap = await FirebaseFirestore.instance
                .collection('serviceProvider')
                .limit(200)
                .get();
          }
          final photoUrls = booking['work_images'] as List<dynamic>? ?? [];
          int dispatched = 0;
          for (final artDoc in artisanSnap.docs) {
            final ad = artDoc.data();
            final st = (ad['status'] ?? '').toString().toLowerCase();
            if (st.isNotEmpty && st != 'publish' && st != 'published' && st != 'approved' && st != 'approve') continue;
            if (ad['is_suspended'] == true) continue;
            final cats = (ad['categories'] ?? ad['category'] ?? '').toString().toLowerCase();
            if (cats.isNotEmpty && catSlug.isNotEmpty &&
                !cats.contains(catSlug) && catSlug != 'general_maintenance') continue;

            final artisanId = artDoc.id;
            final bridgeId = '${bookingId}_$artisanId';

            // Create tasksManagement bridge record for this artisan
            try {
              await FirebaseFirestore.instance.collection('tasksManagement').doc(bridgeId).set({
                'id': bridgeId,
                'bookingId': bridgeId,
                'order_no': orderNo,
                'future_booking_id': bookingId,
                'category_name': category,
                'category': category,
                'description': description,
                'address': address,
                'provided_address': address,
                'urgency': urgency,
                'name': userName,
                'contact': userPhone,
                'phone': userPhone,
                'customer_phone': userPhone,
                'user_id': uid,
                'source': 'ai_text_chat',
                'status': 'pending',
                'accept': '',
                'cost': estimatedCost.toStringAsFixed(2),
                'payment_status': 'unpaid',
                'service_provider_id': artisanId,
                'service_provider_name': ad['name'] ?? ad['fullName'] ?? '',
                'work_images': List<dynamic>.from(photoUrls),
                'image_urls': List<dynamic>.from(photoUrls),
                'imageUrls': List<dynamic>.from(photoUrls),
                'has_photos': photoUrls.isNotEmpty ? 'yes' : 'no',
                'creation_date': DateTime.now().toIso8601String(),
                'createdAt': FieldValue.serverTimestamp(),
              });
              dispatched++;
            } catch (e) { debugPrint('[AITextChat] Bridge for $artisanId failed: $e'); }

            // Send FCM notification
            try {
              await FutureBookingService.sendNotificationToArtisan(
                artisanId: artisanId,
                bookingId: bridgeId,
                message: 'New $category booking ($orderNo) — R${estimatedCost.toStringAsFixed(2)}. Tap to view and accept.',
              );
            } catch (_) {}
          }
          debugPrint('[AITextChat] Dispatched $bookingId to $dispatched artisans');
        } catch (e) { debugPrint('[AITextChat] artisan dispatch failed: $e'); }
      }

      // Build response with pricing context
      final costDisplay = estimatedCost > 0
          ? 'R${estimatedCost.toStringAsFixed(2)}'
          : null;
      final pricingNote = pricingSource == 'fixed'
          ? 'Fixed price: $costDisplay.'
          : (pricingSource == 'estimate' || pricingSource == 'labor_estimate')
              ? 'Estimated cost: $costDisplay (final price may vary).'
              : 'No fixed pricing found — an artisan will provide a quote.';
      final depositNote = estimatedCost > 0
          ? ' You can pay a 35% deposit of R${depositAmount.toStringAsFixed(2)} upfront, with the remaining R${balanceAmount.toStringAsFixed(2)} due after job completion.'
          : '';

      return {
        'success': true,
        'booking_id': bookingId,
        'order_no': orderNo,
        'estimated_cost': costDisplay ?? 'Pending quote',
        'pricing_source': pricingSource,
        'message': 'Booking created! Order: $orderNo. $pricingNote$depositNote '
            'Once an artisan accepts, you can complete payment from your Bookings tab '
            'using your wallet, Ozow instant EFT, or Buy Now Pay Later.',
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

      // ── CODE-LEVEL GUARD: If a fixed price exists, auto-redirect to create_booking ──
      // The AI model sometimes calls submit_rfq even when a fixed price exists.
      try {
        final rfqSearch = '$category $description'.toLowerCase().trim();
        final taskSnap = await FirebaseFirestore.instance.collection('tasks').limit(200).get();
        String? guardService;
        double? guardPrice;
        int guardBestScore = 0;
        for (final td in taskSnap.docs) {
          final d = td.data();
          final tName = (d['name'] ?? d['title'] ?? '').toString();
          final tCost = double.tryParse((d['client_rate'] ?? d['clientRate'] ?? d['cost'] ?? d['price'] ?? d['amount'] ?? '0').toString()) ?? 0;
          if (tName.isEmpty || tCost <= 0) continue;
          final tl = tName.toLowerCase();
          int sc = 0;
          if (tl == rfqSearch) { sc = 1000; }
          else if (tl.contains(rfqSearch) || rfqSearch.contains(tl)) { sc = 100; }
          else {
            for (final w in rfqSearch.split(RegExp(r'\s+')).where((w) => w.length >= 3)) {
              if (tl.contains(w)) sc += 10;
            }
          }
          if (sc > guardBestScore) { guardBestScore = sc; guardService = tName; guardPrice = tCost; }
        }
        if (guardService != null && guardPrice != null && guardPrice > 0 && guardBestScore >= 20) {
          debugPrint('[AITextChat] submit_rfq REDIRECTED to create_booking — fixed price: "$guardService" @ R${guardPrice.toStringAsFixed(2)} (score $guardBestScore)');
          args['cost'] = guardPrice;
          return _createBooking(uid, args);
        }
      } catch (e) { debugPrint('[AITextChat] Fixed-price guard failed: $e'); }

      if (category.isEmpty) return {'error': 'Please specify a service category for the RFQ.'};
      if (description.isEmpty) return {'error': 'Please describe what you need quoted.'};
      if (address.isEmpty) return {'error': 'Please provide the service address for the RFQ.'};

      final userDoc = await FirebaseFirestore.instance.collection('users').doc(uid).get();
      if (!userDoc.exists) return {'error': 'User account not found. Please sign in again.'};
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
        'cost': '',
        'quoted_price': '',
        'deposit_amount': '0',
        'balance_amount': '0',
        'deposit_paid': false,
        'balance_paid': false,
        'service_provider_id': '',
        'service_provider_name': '',
        // Photo URLs uploaded during this chat session
        'work_images': pendingPhotoUrls.isNotEmpty ? List<String>.from(pendingPhotoUrls) : <String>[],
        'image_urls': pendingPhotoUrls.isNotEmpty ? List<String>.from(pendingPhotoUrls) : <String>[],
        'imageUrls': pendingPhotoUrls.isNotEmpty ? List<String>.from(pendingPhotoUrls) : <String>[],
        'has_photos': pendingPhotoUrls.isNotEmpty ? 'yes' : 'no',
        'source': 'ai_text_chat',
        'creation_date': DateTime.now().toIso8601String(),
        'createdAt': now,
      };

      await FirebaseFirestore.instance.collection('futureBookings').doc(rfqId).set(rfqDoc);

      // Clear pending photos after attaching to RFQ
      pendingPhotoUrls.clear();

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

      // Attempt AI-generated quote via pricing guidance
      String quoteInfo = '';
      try {
        final catSlug = category.toLowerCase().replaceAll(RegExp(r'\s+'), '_');
        final guidanceDoc = await FirebaseFirestore.instance
            .collection('pricingGuidance')
            .doc(catSlug)
            .get();
        if (guidanceDoc.exists) {
          final gd = guidanceDoc.data() ?? {};
          final laborRate = double.tryParse((gd['labor_rate_per_hour'] ?? gd['labor_cost_per_hour'] ?? '150').toString()) ?? 150;
          // Simple estimate: 4 hours labor + 15% contingency
          final laborCost = laborRate * 4;
          final contingency = laborCost * 0.15;
          final estimatedTotal = laborCost + contingency;
          final deposit = (estimatedTotal * 0.35 * 100).roundToDouble() / 100;
          final balance = ((estimatedTotal - deposit) * 100).roundToDouble() / 100;

          await FirebaseFirestore.instance.collection('futureBookings').doc(rfqId).update({
            'quoted_price': estimatedTotal.toStringAsFixed(2),
            'cost': estimatedTotal.toStringAsFixed(2),
            'deposit_amount': deposit.toStringAsFixed(2),
            'balance_amount': balance.toStringAsFixed(2),
            'rfq_status': 'pending_client_response',
            'quote_source': 'ai_estimate',
          });

          quoteInfo = ' An estimated quote of R${estimatedTotal.toStringAsFixed(2)} has been generated based on pricing guidance. '
              'You can accept or negotiate this quote.';
        }
      } catch (e) {
        debugPrint('[AITextChat] RFQ AI quote attempt failed: $e');
      }

      return {
        'success': true,
        'rfq_id': rfqId,
        'rfq_no': rfqNo,
        'message': 'Your RFQ ($rfqNo) has been submitted.$quoteInfo'
            '${quoteInfo.isEmpty ? ' Admin will review and provide a quote. You can check status anytime.' : ''}',
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
      final data = doc.data() ?? {};
      if (data['is_rfq'] != 'yes') return {'error': 'This booking is not an RFQ.'};

      final rfqStatus = (data['rfq_status'] ?? 'pending').toString();
      final quotedPrice = (data['quoted_price'] ?? data['cost'] ?? '').toString();
      final aiQuote = data['ai_quote'] as Map<String, dynamic>?;

      // Status-specific guidance
      String nextStep;
      switch (rfqStatus) {
        case 'pending_admin_review':
          nextStep = 'Your RFQ is being reviewed. A quote will be provided soon. You can check status anytime.';
          break;
        case 'pending_client_response':
          nextStep = quotedPrice.isNotEmpty
              ? 'A quote of R$quotedPrice is ready. You can accept it with accept_rfq_quote or negotiate with reject_rfq_quote.'
              : 'A quote is being prepared. Please check back shortly.';
          break;
        case 'accepted_converted':
          nextStep = 'Quote accepted. Waiting for an artisan to accept the job, then you can proceed to payment.';
          break;
        case 'under_negotiation':
          nextStep = 'Under negotiation with the admin team. They will provide an updated quote.';
          break;
        default:
          nextStep = 'Check your Bookings tab for the latest status.';
      }

      final result = <String, dynamic>{
        'rfq_no': data['rfq_no'] ?? data['order_no'] ?? '',
        'category': data['category_name'] ?? '',
        'description': data['problem_description'] ?? data['description'] ?? '',
        'scope_of_work': data['scope_of_work'] ?? '',
        'rfq_status': rfqStatus,
        'quoted_price': quotedPrice.isNotEmpty ? 'R$quotedPrice' : 'Not yet quoted',
        'quote_details': data['quote_details'] ?? '',
        'status': data['status'] ?? '',
        'next_step': nextStep,
      };

      // Include AI quote breakdown if available
      if (aiQuote != null) {
        result['labor_cost'] = aiQuote['laborCost']?.toString() ?? '';
        result['materials_cost'] = aiQuote['materials_with_markup']?.toString() ?? '';
        result['contingency'] = aiQuote['contingency']?.toString() ?? '';
        result['estimated_duration'] = aiQuote['estimated_duration']?.toString() ?? '';
      }

      return result;
    } catch (e) {
      return {'error': 'Failed to fetch RFQ details'};
    }
  }

  // ═══════════════════════════════════════════════════════════════
  // ACCEPT RFQ QUOTE
  // ═══════════════════════════════════════════════════════════════
  Future<Map<String, dynamic>> _acceptRfqQuote(String uid, String bookingId) async {
    try {
      final doc = await FirebaseFirestore.instance
          .collection('futureBookings')
          .doc(bookingId)
          .get();
      if (!doc.exists) return {'error': 'RFQ not found'};
      final data = doc.data() ?? {};
      if (data['is_rfq'] != 'yes') return {'error': 'This booking is not an RFQ.'};

      final rfqStatus = (data['rfq_status'] ?? '').toString();
      if (rfqStatus == 'accepted_converted') return {'error': 'This quote has already been accepted.'};

      final quotedPrice = double.tryParse((data['quoted_price'] ?? data['cost'] ?? '0').toString()) ?? 0;
      if (quotedPrice <= 0) {
        return {'error': 'No quote has been provided yet. Please wait for the admin to review your RFQ, or check status with check_rfq_status.'};
      }

      final depositAmount = (quotedPrice * 0.35 * 100).roundToDouble() / 100;
      final balanceAmount = ((quotedPrice - depositAmount) * 100).roundToDouble() / 100;
      final now = FieldValue.serverTimestamp();

      // Update futureBookings
      await FirebaseFirestore.instance.collection('futureBookings').doc(bookingId).update({
        'rfq_status': 'accepted_converted',
        'status': 'pending_artisan_acceptance',
        'cost': quotedPrice.toStringAsFixed(2),
        'deposit_amount': depositAmount.toStringAsFixed(2),
        'balance_amount': balanceAmount.toStringAsFixed(2),
        'deposit_paid': false,
        'balance_paid': false,
        'accepted_at': DateTime.now().toIso8601String(),
        'accepted_via': 'ai_text_chat',
      });

      // Mirror to tasksManagement so artisans/admin can see it
      final tmDoc = {
        'id': bookingId,
        'order_no': data['order_no'] ?? data['rfq_no'] ?? bookingId,
        'user_id': data['user_id'] ?? uid,
        'name': data['name'] ?? '',
        'contact': data['contact'] ?? '',
        'category_name': data['category_name'] ?? '',
        'description': data['description'] ?? data['problem_description'] ?? '',
        'problem_description': data['problem_description'] ?? data['description'] ?? '',
        'address': data['address'] ?? '',
        'status': 'pending_artisan_acceptance',
        'artisan_confirmed': 'pending',
        'accept': '',
        'payment_status': 'unpaid',
        'cost': quotedPrice.toStringAsFixed(2),
        'deposit_amount': depositAmount.toStringAsFixed(2),
        'balance_amount': balanceAmount.toStringAsFixed(2),
        'deposit_paid': false,
        'balance_paid': false,
        'payment_type': '',
        'source': data['source'] ?? 'ai_text_chat',
        'is_rfq': 'yes',
        'rfq_status': 'accepted_converted',
        'service_provider_id': data['service_provider_id'] ?? '',
        'service_provider_name': data['service_provider_name'] ?? '',
        'scheduled_date': data['scheduled_date'] ?? '',
        'scheduled_time': data['scheduled_time'] ?? '',
        'creation_date': data['creation_date'] ?? DateTime.now().toIso8601String(),
        'accepted_at': DateTime.now().toIso8601String(),
        'accepted_via': 'ai_text_chat',
        'createdAt': now,
      };
      await FirebaseFirestore.instance
          .collection('tasksManagement')
          .doc(bookingId)
          .set(tmDoc, SetOptions(merge: true));

      // Try auto-dispatch to artisans (client buys materials OR under R12K)
      final autoDispatched = await FutureBookingService.tryAutoDispatchRfq(bookingId);

      if (!autoDispatched) {
        // Notify admin to assign artisan
        try {
          await FirebaseFirestore.instance.collection('Notifications').add({
            'title': 'RFQ Quote Accepted — Assign Artisan',
            'body': '${data['name'] ?? 'Customer'} accepted RFQ ${data['rfq_no'] ?? bookingId} (R${quotedPrice.toStringAsFixed(2)})',
            'type': 'rfq_accepted',
            'booking_id': bookingId,
            'target': 'admin',
            'read': false,
            'timestamp': now,
          });
        } catch (e) { debugPrint('[AITextChat] accept RFQ notification failed: $e'); }
      }

      final routingMsg = autoDispatched
          ? 'Your accepted quote has been sent directly to available artisans. '
              'You will be notified when an artisan accepts.'
          : 'An artisan needs to accept your job before payment. '
              'You will be notified when an artisan accepts.';

      return {
        'success': true,
        'booking_id': bookingId,
        'rfq_no': data['rfq_no'] ?? data['order_no'] ?? '',
        'quoted_price': 'R${quotedPrice.toStringAsFixed(2)}',
        'deposit_amount': 'R${depositAmount.toStringAsFixed(2)}',
        'balance_amount': 'R${balanceAmount.toStringAsFixed(2)}',
        'auto_dispatched': autoDispatched,
        'message': 'Quote accepted! $routingMsg '
            'Payment options: full R${quotedPrice.toStringAsFixed(2)} or 35% deposit of R${depositAmount.toStringAsFixed(2)} '
            '(balance R${balanceAmount.toStringAsFixed(2)} after completion). '
            'Pay from your Bookings tab using wallet, Ozow instant EFT, or Buy Now Pay Later.',
      };
    } catch (e) {
      return {'error': 'Failed to accept RFQ quote. Please try again.'};
    }
  }

  // ═══════════════════════════════════════════════════════════════
  // REJECT / NEGOTIATE RFQ QUOTE
  // ═══════════════════════════════════════════════════════════════
  Future<Map<String, dynamic>> _rejectRfqQuote(String uid, String bookingId, String? reason) async {
    try {
      final doc = await FirebaseFirestore.instance
          .collection('futureBookings')
          .doc(bookingId)
          .get();
      if (!doc.exists) return {'error': 'RFQ not found'};
      final data = doc.data() ?? {};
      if (data['is_rfq'] != 'yes') return {'error': 'This booking is not an RFQ.'};

      final negotiationReason = reason ?? 'Customer wants to negotiate via AI chat';
      final now = FieldValue.serverTimestamp();

      await FirebaseFirestore.instance.collection('futureBookings').doc(bookingId).update({
        'rfq_status': 'under_negotiation',
        'negotiation_reason': negotiationReason,
        'negotiation_at': DateTime.now().toIso8601String(),
        'negotiation_via': 'ai_text_chat',
      });

      // Notify admin
      try {
        await FirebaseFirestore.instance.collection('Notifications').add({
          'title': 'RFQ Quote Negotiation',
          'body': '${data['name'] ?? 'Customer'} wants to negotiate RFQ ${data['rfq_no'] ?? bookingId}. Reason: $negotiationReason',
          'type': 'rfq_negotiation',
          'booking_id': bookingId,
          'target': 'admin',
          'read': false,
          'timestamp': now,
        });
      } catch (e) { debugPrint('[AITextChat] reject RFQ notification failed: $e'); }

      return {
        'success': true,
        'booking_id': bookingId,
        'rfq_no': data['rfq_no'] ?? data['order_no'] ?? '',
        'message': 'Your negotiation request has been sent to the admin team. They will review and adjust the quote. '
            'You can check status anytime by asking me about your RFQ.',
      };
    } catch (e) {
      return {'error': 'Failed to submit negotiation. Please try again.'};
    }
  }

  // ═══════════════════════════════════════════════════════════════
  // CHECK RFQ STATUS
  // ═══════════════════════════════════════════════════════════════
  Future<Map<String, dynamic>> _checkRfqStatus(String uid) async {
    try {
      final snap = await FirebaseFirestore.instance
          .collection('futureBookings')
          .where('user_id', isEqualTo: uid)
          .where('is_rfq', isEqualTo: 'yes')
          .limit(10)
          .get();

      if (snap.docs.isEmpty) return {'message': 'No RFQ requests found.'};

      final rfqs = snap.docs.map((d) {
        final data = d.data();
        final rfqStatus = (data['rfq_status'] ?? 'pending').toString();
        final quotedPrice = (data['quoted_price'] ?? data['cost'] ?? '').toString();

        String statusExplain;
        switch (rfqStatus) {
          case 'pending_admin_review':
            statusExplain = 'Awaiting admin review — a quote will be provided soon.';
            break;
          case 'pending_client_response':
            statusExplain = quotedPrice.isNotEmpty
                ? 'Quote ready: R$quotedPrice. You can accept or negotiate.'
                : 'Quote is being prepared.';
            break;
          case 'accepted_converted':
            statusExplain = 'Quote accepted — waiting for artisan to accept the job.';
            break;
          case 'under_negotiation':
            statusExplain = 'Under negotiation — admin is reviewing your request.';
            break;
          default:
            statusExplain = rfqStatus;
        }

        return {
          'rfq_id': d.id,
          'rfq_no': data['rfq_no'] ?? data['order_no'] ?? '',
          'category': data['category_name'] ?? '',
          'rfq_status': rfqStatus,
          'status_explanation': statusExplain,
          'quoted_price': quotedPrice.isNotEmpty ? 'R$quotedPrice' : 'Pending',
          'created': data['creation_date'] ?? '',
        };
      }).toList();

      return {'rfqs': rfqs, 'count': rfqs.length};
    } catch (e) {
      return {'error': 'Failed to check RFQ status'};
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

      final data = doc.data() ?? {};
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

      final data = doc.data() ?? {};
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
  // REPORT TECHNICAL ERROR (auto-escalation)
  // ═══════════════════════════════════════════════════════════════
  Future<Map<String, dynamic>> _reportTechnicalError(String uid, String errorType, String description, String? bookingId) async {
    try {
      final caseId = await ErrorReportingService.reportErrorAsSupportCase(
        errorType: errorType,
        description: description,
        source: 'ai_text_chat',
        bookingId: bookingId,
        severity: 'high',
      );
      return {
        'success': true,
        'case_id': caseId ?? 'unknown',
        'message': 'Technical issue logged and sent to our support team. Reference: ${caseId ?? 'pending'}. Admin will investigate and fix this.',
      };
    } catch (e) {
      return {'error': 'Failed to report technical error'};
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
      final data = doc.data() ?? {};
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

      final data = doc.data() ?? {};
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

  // ═══════════════════════════════════════════════════════════════
  // SEND MESSAGE (to artisan, client, or admin)
  // ═══════════════════════════════════════════════════════════════
  Future<Map<String, dynamic>> _sendMessage(String uid, String bookingId, String message, String? recipient) async {
    try {
      final target = recipient ?? 'admin';
      final msgId = FirebaseFirestore.instance.collection('messages').doc().id;
      await FirebaseFirestore.instance.collection('messages').doc(msgId).set({
        'id': msgId,
        'booking_id': bookingId,
        'sender_id': uid,
        'sender_type': _userRole ?? 'client',
        'recipient_type': target,
        'message': message,
        'source': 'ai_text_chat',
        'read': false,
        'created_at': FieldValue.serverTimestamp(),
      });
      return {'success': true, 'message_id': msgId, 'message': 'Message sent to $target.'};
    } catch (e) {
      return {'error': 'Failed to send message'};
    }
  }

  // ═══════════════════════════════════════════════════════════════
  // LIST CASES
  // ═══════════════════════════════════════════════════════════════
  Future<Map<String, dynamic>> _listCases(String uid, String? state) async {
    try {
      var query = FirebaseFirestore.instance
          .collection('customer_support_cases')
          .where('user_id', isEqualTo: uid);
      if (state != null && state.isNotEmpty) {
        query = query.where('status', isEqualTo: state);
      }
      final snap = await query.orderBy('created_at', descending: true).limit(10).get();
      final cases = snap.docs.map((d) {
        final data = d.data();
        return {
          'case_id': d.id,
          'subject': data['subject'] ?? '',
          'status': data['status'] ?? 'unknown',
          'created': data['created_at']?.toDate()?.toString() ?? '',
          'description': data['description'] ?? '',
        };
      }).toList();
      return {'cases': cases, 'count': cases.length};
    } catch (e) {
      return {'error': 'Failed to fetch cases'};
    }
  }

  // ═══════════════════════════════════════════════════════════════
  // REPLY TO CASE
  // ═══════════════════════════════════════════════════════════════
  Future<Map<String, dynamic>> _replyToCase(String uid, String caseId, String message) async {
    try {
      await FirebaseFirestore.instance
          .collection('customer_support_cases')
          .doc(caseId)
          .collection('replies')
          .add({
        'user_id': uid,
        'message': message,
        'source': 'ai_text_chat',
        'created_at': FieldValue.serverTimestamp(),
      });
      return {'success': true, 'message': 'Reply added to case $caseId.'};
    } catch (e) {
      return {'error': 'Failed to reply to case'};
    }
  }

  // ═══════════════════════════════════════════════════════════════
  // GET CASE DETAILS
  // ═══════════════════════════════════════════════════════════════
  Future<Map<String, dynamic>> _getCaseDetails(String caseId) async {
    try {
      final doc = await FirebaseFirestore.instance.collection('customer_support_cases').doc(caseId).get();
      if (!doc.exists) return {'error': 'Case not found'};
      final data = doc.data() ?? {};
      final repliesSnap = await FirebaseFirestore.instance
          .collection('customer_support_cases')
          .doc(caseId)
          .collection('replies')
          .orderBy('created_at', descending: false)
          .limit(20)
          .get();
      final replies = repliesSnap.docs.map((d) {
        final r = d.data();
        return {
          'message': r['message'] ?? '',
          'created': r['created_at']?.toDate()?.toString() ?? '',
        };
      }).toList();
      return {
        'case_id': caseId,
        'subject': data['subject'] ?? '',
        'status': data['status'] ?? 'unknown',
        'description': data['description'] ?? '',
        'created': data['created_at']?.toDate()?.toString() ?? '',
        'replies': replies,
      };
    } catch (e) {
      return {'error': 'Failed to fetch case details'};
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
- Cancel or reschedule bookings
- Check payment status
- Request payment links (card checkout via PayFast)
- Check wallet balance and transaction history
- Submit ratings for completed jobs (1-5 stars)
- File complaints / support cases
- Report technical errors (auto-escalate to admin)
- Check notifications
- View scheduled/upcoming bookings
- Look up artisan info (rating, location)
- Validate promo codes
- Request refunds
- Look up service pricing
- Send messages to artisans, clients, or admin
- List and manage support cases
- Reply to support cases
- View case details

MESSAGING:
- send_message(booking_id, message, recipient) — send a message to artisan, client, or admin

SUPPORT CASES:
- list_cases(state) — list your support cases, optionally filtered by state (open/closed)
- reply_to_case(case_id, message) — add a reply to an existing case
- get_case_details(case_id) — view full case details and reply history

ERROR DETECTION & AUTO-REPORTING (CRITICAL):
- report_technical_error(error_type, description, booking_id?) — auto-log and escalate to admin
- When a user reports ANY technical problem (payment failed, pictures won't load, app crashed, booking error, screen not loading, etc.), you MUST call report_technical_error IMMEDIATELY — do NOT just sympathise or acknowledge
- error_type values: payment_error, image_upload_error, booking_error, network_error, app_crash, loading_error
- This creates a support case AND alerts admin in real time so they can fix it
- After calling report_technical_error, reassure the user: "I've logged this issue and our tech team has been notified. They'll look into it right away."
- If the user describes symptoms that sound like a bug (e.g. "the page is blank", "I keep getting an error", "my photos won't send"), treat it as a technical error and report it

KEY GUIDELINES:
- Be helpful, friendly, and concise
- Amounts are in South African Rand (R)
- For booking, guide through: service type → description → address → timing → urgency
- IMPORTANT: ALWAYS ask the customer to send a photo of the issue BEFORE creating a booking or RFQ. Say: "Could you send a photo of the issue? It helps our artisans come prepared." If they already sent one in this conversation, don't ask again. If they can't send one, proceed without blocking.
- IMPORTANT: You MUST call lookup_service_pricing BEFORE calling create_booking, EVERY TIME, NO EXCEPTIONS. This ensures the customer gets the correct fixed price.
- IMPORTANT: You MUST collect the customer's address before calling create_booking. The address is required — do NOT create a booking without it.
- PHOTO REQUIREMENT (CRITICAL): ALWAYS ask the customer to send a photo of the issue BEFORE creating a booking or RFQ. Say: "Could you please send a photo of the issue? It helps our artisans come prepared." If they already sent one in this conversation, don't ask again. If they can't send one, proceed without blocking.
- If lookup_service_pricing returns matched=true, use that fixedPrice as the booking cost. ALWAYS pass the cost parameter to create_booking. NEVER suggest RFQ when a fixed price exists.
- If lookup_service_pricing returns matched=false with availableServices, show those options to the customer
- If no pricing found at all, call create_booking anyway — it will auto-handle as RFQ
- ALWAYS use create_booking for ALL requests — there is no separate RFQ tool
- IMPORTANT: You MUST collect the customer's address before calling submit_rfq. The address is required.
- RFQ LIFECYCLE: submit_rfq → quote generated → customer accept_rfq_quote or reject_rfq_quote → artisan accepts → payment
- RFQ STATUSES: pending_admin_review (awaiting quote), pending_client_response (quote ready — tell customer the price and ask to accept or negotiate), accepted_converted (waiting for artisan), under_negotiation (admin adjusting quote)
- When a customer asks about their RFQ status, use check_rfq_status
- When a quote is ready (rfq_status=pending_client_response), show the price and ask the customer to accept or negotiate
- When customer accepts, use accept_rfq_quote. When they want changes, use reject_rfq_quote with a reason.
- After an RFQ quote is accepted, payment happens AFTER an artisan accepts (same as regular bookings)
- For emergencies (burst pipes, electrical hazards, flooding), treat as urgent

PRICE CONFIRMATION (CRITICAL — NEVER SKIP):
- After calling lookup_service_pricing, you MUST present the price to the customer and WAIT for their explicit confirmation BEFORE calling create_booking.
- Say something like: "The cost for [service] is R[price]. Shall I go ahead and create the booking?"
- Do NOT call create_booking in the same response as lookup_service_pricing. You must STOP and wait for the customer to say yes/confirm.
- Only after the customer confirms (e.g. "yes", "ok", "go ahead", "book it") should you call create_booking.
- If the customer questions the price or wants to negotiate, do NOT create the booking — explain the pricing and wait.
- This applies even if you already have all other details (category, address, description, photo). The price MUST be confirmed first.

PAYMENT FLOW (CRITICAL):
- When the customer asks to pay, says "pay", or wants to make payment, you MUST first ask: "Would you like to pay the full amount of R[X] or a 35% deposit of R[Y] (with R[Z] balance due after the job is completed)?"
- WAIT for the customer to choose "full" or "deposit" before calling request_payment_link.
- Pass the customer's choice as the payment_type parameter ("full" or "deposit").
- Do NOT call request_payment_link without first asking and getting the customer's payment type choice.
- Only offer payment AFTER an artisan has accepted the job. NEVER offer payment immediately after booking creation.
- If customer says deposit or 35 percent, call request_payment_link with payment_type=deposit
- If customer says full or pay everything, call request_payment_link with payment_type=full

BOOKING FLOW (follow this for EVERY booking — CRITICAL):
1. Customer describes their need → identify the category
2. Ask for a photo of the issue (PHOTO REQUIREMENT)
3. Call lookup_service_pricing → get the service price
4. If lookup_service_pricing returned matched=true with a fixedPrice:
   → Tell the customer the fixed price and WAIT for confirmation (PRICE CONFIRMATION above)
   → Only after they confirm, call create_booking with the fixedPrice as cost parameter
5. If lookup_service_pricing returned matched=false (no fixed price):
   → Tell the customer: "This job needs a detailed quote"
   → Call create_booking anyway — it will auto-generate an RFQ
6. After booking is created, tell the customer an artisan needs to accept first
7. When artisan accepts, follow the PAYMENT FLOW above (ask full or deposit)
8. Generate payment link using request_payment_link with their choice
9. After payment, confirm escrow protection

- After a completed booking, ask if they'd like to rate their artisan
- Never share other users' personal information
- Always confirm before cancelling a booking
- Money is held in escrow until customer is satisfied. 100% money-back guarantee.
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
            'description': 'Look up pricing for a service. If it returns matched=true with a fixedPrice, you MUST proceed with create_booking — NEVER suggest RFQ.',
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
            'name': 'request_payment_link',
            'description': 'Generate a payment link (PayFast card checkout) for a booking. Only works AFTER an artisan has accepted the job. Ask the customer if they want to pay the full amount or a 35% deposit first.',
            'parameters': {
              'type': 'object',
              'properties': {
                'booking_id': {
                  'type': 'string',
                  'description': 'The booking ID to pay for',
                },
                'payment_type': {
                  'type': 'string',
                  'description': 'Payment type: deposit (35%) or full (100%)',
                  'enum': ['deposit', 'full'],
                },
              },
              'required': ['booking_id', 'payment_type'],
            },
          },
        },
        {
          'type': 'function',
          'function': {
            'name': 'create_booking',
            'description': 'Create a new maintenance booking. You MUST call lookup_service_pricing first and pass the returned fixedPrice as the cost parameter. Guide user through: category, description, address, date/time, urgency.',
            'parameters': {
              'type': 'object',
              'properties': {
                'category': {'type': 'string', 'description': 'Service category (e.g. Plumbing, Electrical)'},
                'description': {'type': 'string', 'description': 'Description of the issue'},
                'address': {'type': 'string', 'description': 'Service address'},
                'scheduled_date': {'type': 'string', 'description': 'Preferred date (YYYY-MM-DD)'},
                'scheduled_time': {'type': 'string', 'description': 'Preferred time (HH:MM)'},
                'urgency': {'type': 'string', 'description': 'Urgency level: normal, urgent, emergency'},
                'cost': {'type': 'number', 'description': 'The exact fixedPrice returned by lookup_service_pricing. MUST be provided.'},
              },
              'required': ['category', 'description', 'cost'],
            },
          },
        },
        // submit_rfq REMOVED from AI tools — the AI kept calling it for fixed-price services.
        // RFQ creation is handled automatically inside create_booking when no fixed price exists.
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
            'name': 'accept_rfq_quote',
            'description': 'Accept an RFQ quote. Only call after customer confirms they want to accept the quoted price.',
            'parameters': {
              'type': 'object',
              'properties': {
                'booking_id': {'type': 'string', 'description': 'The RFQ booking ID to accept'},
              },
              'required': ['booking_id'],
            },
          },
        },
        {
          'type': 'function',
          'function': {
            'name': 'reject_rfq_quote',
            'description': 'Reject or negotiate an RFQ quote. Customer wants a different price or changes.',
            'parameters': {
              'type': 'object',
              'properties': {
                'booking_id': {'type': 'string', 'description': 'The RFQ booking ID to negotiate'},
                'reason': {'type': 'string', 'description': 'Reason for negotiation or what the customer wants changed'},
              },
              'required': ['booking_id'],
            },
          },
        },
        {
          'type': 'function',
          'function': {
            'name': 'check_rfq_status',
            'description': 'Check the status of all the customer\'s RFQ requests. Shows quote amounts, statuses, and next steps.',
            'parameters': {
              'type': 'object',
              'properties': {},
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
        {
          'type': 'function',
          'function': {
            'name': 'send_message',
            'description': 'Send a message to an artisan, client, or admin related to a booking',
            'parameters': {
              'type': 'object',
              'properties': {
                'booking_id': {'type': 'string', 'description': 'The booking ID the message relates to'},
                'message': {'type': 'string', 'description': 'The message content'},
                'recipient': {'type': 'string', 'description': 'Who to send to: artisan, client, or admin'},
              },
              'required': ['booking_id', 'message'],
            },
          },
        },
        {
          'type': 'function',
          'function': {
            'name': 'list_cases',
            'description': 'List support cases, optionally filtered by state (open, closed)',
            'parameters': {
              'type': 'object',
              'properties': {
                'state': {'type': 'string', 'description': 'Filter by state: open, closed. Omit for all.'},
              },
            },
          },
        },
        {
          'type': 'function',
          'function': {
            'name': 'reply_to_case',
            'description': 'Add a reply to an existing support case',
            'parameters': {
              'type': 'object',
              'properties': {
                'case_id': {'type': 'string', 'description': 'The case ID to reply to'},
                'message': {'type': 'string', 'description': 'The reply message'},
              },
              'required': ['case_id', 'message'],
            },
          },
        },
        {
          'type': 'function',
          'function': {
            'name': 'get_case_details',
            'description': 'Get full details and reply history for a support case',
            'parameters': {
              'type': 'object',
              'properties': {
                'case_id': {'type': 'string', 'description': 'The case ID'},
              },
              'required': ['case_id'],
            },
          },
        },
        {
          'type': 'function',
          'function': {
            'name': 'report_technical_error',
            'description': 'Report a technical error the user is experiencing (payment failure, image upload issue, app crash, loading error, etc.). Auto-creates a support case and alerts admin for real-time fixing.',
            'parameters': {
              'type': 'object',
              'properties': {
                'error_type': {'type': 'string', 'description': 'Type of error: payment_error, image_upload_error, booking_error, network_error, app_crash, loading_error'},
                'description': {'type': 'string', 'description': 'What happened — include what the user was trying to do and what went wrong'},
                'booking_id': {'type': 'string', 'description': 'Related booking ID if applicable'},
              },
              'required': ['error_type', 'description'],
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
