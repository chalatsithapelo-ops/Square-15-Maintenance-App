import 'package:flutter/material.dart';
import 'package:livekit_client/livekit_client.dart' hide ConnectionState;
import 'package:livekit_client/livekit_client.dart' as livekit;
import 'package:permission_handler/permission_handler.dart';
import 'dart:async';
import 'dart:convert';
import 'package:geocoding/geocoding.dart';
import 'package:http/http.dart' as http;
import 'package:get/get.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:maintenanceapp/controller/app_controller.dart';
import 'package:maintenanceapp/controller/service_provider_controller.dart';
import 'package:maintenanceapp/model/task_management_model.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:uuid/uuid.dart';
import 'package:flutter_phone_direct_caller/flutter_phone_direct_caller.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:maintenanceapp/screens/home/booking/booking.dart';
import 'package:maintenanceapp/screens/home/booking/future_bookings_list_screen.dart';
import 'package:maintenanceapp/screens/home/booking/ai_photo_upload_screen.dart';
import 'package:maintenanceapp/screens/home/booking/client_calendar_screen.dart';
import 'package:maintenanceapp/screens/home/booking/payment_method_sheet.dart';
import 'package:maintenanceapp/screens/service_provider_panel/Serviceprovider/artisan_appointments_screen.dart';
import 'package:maintenanceapp/screens/service_provider_panel/service_provider_request_screen.dart';
import 'package:maintenanceapp/screens/service_provider_panel/wallet_page.dart';
import 'package:maintenanceapp/services/future_booking_service.dart';
import 'package:maintenanceapp/services/firestore_services/firebase_services.dart';

/// Professional Livekit Voice AI Assistant Integration
/// Enables voice interactions with AI agent for booking, support, and general queries
class LivekitVoiceAssistant extends StatefulWidget {
  final String role;

  // Optional: only needed when launched from artisan portal.
  final dynamic providerDoc;
  final String providerListenerId;

  const LivekitVoiceAssistant({
    super.key,
    this.role = 'client',
    this.providerDoc,
    this.providerListenerId = '',
  });

  @override
  State<LivekitVoiceAssistant> createState() => _LivekitVoiceAssistantState();
}

class _VoiceStartInfo {
  final String roomName;
  final String token;
  final String livekitUrl;
  final String sessionId;
  final String sessionNonce;

  const _VoiceStartInfo({
    required this.roomName,
    required this.token,
    required this.livekitUrl,
    this.sessionId = '',
    this.sessionNonce = '',
  });
}

class _RoomEventHandler {
  final dynamic eventType;
  final Function(dynamic) handler;

  const _RoomEventHandler(this.eventType, this.handler);
}

class _LivekitVoiceAssistantState extends State<LivekitVoiceAssistant>
    with TickerProviderStateMixin {
  static const String _assistantName = 'Lizzy';

  String _voiceSessionId = '';
  String _voiceSessionNonce = '';
  String _voiceRoomName = '';
  String _firebaseIdToken = '';

  // Backend Configuration
  // IMPORTANT: To work on mobile data and without your laptop, this must be a publicly reachable HTTPS URL
  // pointing to the deployed `livekit-backend` server.
  // Example: https://your-service.onrender.com
  static const String _backendFromDefine = String.fromEnvironment(
    'LIVEKIT_BACKEND_URL',
    defaultValue: '',
  );

  static String get backendBaseUrl {
    final fromDefine = _backendFromDefine.trim();
    if (fromDefine.isNotEmpty) return fromDefine;

    // Default to the public backend so debug installs also work over mobile data.
    // To use a LAN/local backend for development, run with:
    // flutter run --dart-define=LIVEKIT_BACKEND_URL=http://<your-ip>:3001
    return 'https://square15-livekit-backend.onrender.com';
  }

  // Livekit Room and Participant
  Room? _room;
  LocalParticipant? _localParticipant;

  // Connection State
  bool _isConnecting = false;
  bool _isConnected = false;
  bool _isMuted = false;
  String _connectionStatus = 'Not Connected';
  String _aiResponse = 'Tap the microphone to start talking...';

  livekit.ConnectionState? _lastConnectionState;
  final Set<String> _seenRemoteParticipants = <String>{};
  bool _hasHandledDisconnect = false;
  bool _isDisconnecting = false;
  Timer? _disconnectDebounce;
  Timer? _metadataPoller;

  // Conversation Transcript
  final List<Map<String, String>> _transcript = [];
  final ScrollController _transcriptScrollController = ScrollController();

  // Track which remote participants we've already wired listeners for.
  final Set<String> _wiredRemoteParticipants = <String>{};

  // Extra safety: also listen to room events (some SDK versions emit explicit
  // metadata update events rather than notifying the participant).
  EventsListener<RoomEvent>? _lkRoomListener;
  StreamSubscription? _roomEventsSub;
  dynamic _roomEventsEmitter;
  final List<_RoomEventHandler> _roomEventHandlers = <_RoomEventHandler>[];

  // Prevent re-processing identical metadata payloads.
  final Map<String, String> _lastMetadataByParticipant = <String, String>{};

  // Debounce UI actions so the agent can retry if needed, without spamming.
  final Map<String, DateTime> _lastUiActionAt = <String, DateTime>{};
  bool _isRespondingToRequest = false;
  bool _isCreatingOrderBooking = false;
  String _lastCreatedBookingId = '';
  String _lastAssignedArtisanId = '';
  String _watchBookingLastProviderId = '';

  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>?
      _bookingStatusSubscription;

  // App -> Agent voice prompts (via LiveKit participant metadata)
  int _appMetadataSeq = 0;
  String _lastSpokenToAgent = '';
  DateTime _lastSpokenToAgentAt = DateTime.fromMillisecondsSinceEpoch(0);
  bool _sentLizzySpokenIntro = false;

  // Photo upload navigation guard
  bool _isOpeningPhotoUpload = false;

  // Payment auto-open guard (client-side)
  bool _isOpeningPaymentSheet = false;
  String _openedPaymentSheetForTasksManagementId = '';

  // Artisan-side: announce new incoming requests while connected
  Worker? _artisanRequestsWorker;
  String _lastAnnouncedRequestId = '';

  // Animation Controllers
  late AnimationController _waveAnimationController;
  late AnimationController _pulseAnimationController;
  late Animation<double> _pulseAnimation;

  // Backend session info
  // (kept minimal; avoids leaking API secrets to the client)

  @override
  void initState() {
    super.initState();
    _stopAnyBackgroundTts();
    _initializeAnimations();
    _requestPermissions();
    _ensureArtisanRequestsSubscription();
    _attachArtisanRequestAnnouncements();
  }

  Future<void> _stopAnyBackgroundTts() async {
    // Users reported hearing 2 voices at once: LiveKit agent + device TTS.
    // The app has other AI surfaces (e.g., ChatBot) that may still be speaking.
    // Calling stop() on a new FlutterTts instance is a safe best-effort way
    // to halt any ongoing platform TTS so only the LiveKit agent voice is heard.
    try {
      final tts = FlutterTts();
      final dynamic r = tts.stop();
      if (r is Future) await r;
    } catch (_) {
      // Best-effort; ignore.
    }
  }

  void _attachArtisanRequestAnnouncements() {
    final role = widget.role.toLowerCase().trim();
    if (role != 'artisan') return;
    if (!Get.isRegistered<ServiceProviderController>()) return;

    try {
      final sp = Get.find<ServiceProviderController>();
      _artisanRequestsWorker?.dispose();

      _artisanRequestsWorker = ever<List<TaskManagementModel>>(
        sp.requestList,
        (list) async {
          if (!mounted) return;
          if (!_isConnected) return;

          TaskManagementModel? pending;
          for (final r in list) {
            final accept = (r.accept ?? '').toString().trim();
            if (accept.isEmpty) {
              pending = r;
              break;
            }
          }
          if (pending == null) return;

          final reqId = (pending.id ?? '').toString().trim();
          if (reqId.isEmpty) return;
          if (reqId == _lastAnnouncedRequestId) return;
          _lastAnnouncedRequestId = reqId;

          final scheduledDate = (pending.scheduledDate ?? '').toString().trim();
          final scheduledTime = (pending.scheduledTime ?? '').toString().trim();
          final desc = (pending.description ?? '').toString().trim();
          final addr = (pending.userProvidedAddress ?? '').toString().trim();

          final when = (scheduledDate.isNotEmpty || scheduledTime.isNotEmpty)
              ? 'Scheduled for ${scheduledDate.isNotEmpty ? scheduledDate : 'a date to be confirmed'}'
                  '${scheduledTime.isNotEmpty ? ' at $scheduledTime' : ''}.'
              : '';

          final where = addr.isNotEmpty ? 'Location: $addr.' : '';

          final summary =
              'You have a new booking request. ${desc.isNotEmpty ? 'Problem: $desc.' : ''} $when $where '
              'Say “open requests” to view details and photos, then say “accept latest request” or “reject latest request”.';

          await _sendSpeakToAgent(summary);
        },
      );
    } catch (_) {
      // Best-effort: if controller isn't ready, skip announcements.
    }
  }

  void _ensureArtisanRequestsSubscription() {
    final role = widget.role.toLowerCase().trim();
    if (role != 'artisan') return;
    final providerId = widget.providerListenerId.trim();
    if (providerId.isEmpty) return;
    if (!Get.isRegistered<ServiceProviderController>()) return;
    try {
      final sp = Get.find<ServiceProviderController>();
      final extraIds = <String>[];
      try {
        final data = widget.providerDoc?.data() as Map<String, dynamic>?;
        if (data != null) {
          const keys = <String>[
            'provider_id',
            'docId',
            'user_id',
            'uid',
            'userId'
          ];
          for (final k in keys) {
            final v = (data[k] ?? '').toString().trim();
            if (v.isNotEmpty) extraIds.add(v);
          }
        }
      } catch (_) {}
      sp.getRequests(providerId: providerId, additionalProviderIds: extraIds);
    } catch (_) {
      // Best-effort: Voice AI can still navigate even if requests aren't live.
    }
  }

  bool _boolValue(dynamic raw, {required bool defaultValue}) {
    if (raw == null) return defaultValue;
    if (raw is bool) return raw;
    final s = raw.toString().trim().toLowerCase();
    if (s.isEmpty) return defaultValue;
    return s == 'true' || s == '1' || s == 'yes' || s == 'y';
  }

  List<String> _stringListFromDynamic(dynamic v) {
    if (v == null) return <String>[];
    if (v is List) {
      return v
          .where((e) => e != null)
          .map((e) => e.toString().trim())
          .where((s) => s.isNotEmpty)
          .toList();
    }
    final s = v.toString().trim();
    if (s.isEmpty) return <String>[];
    return s
        .split(',')
        .map((x) => x.trim())
        .where((x) => x.isNotEmpty)
        .toList();
  }

  void _initializeAnimations() {
    _waveAnimationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    );

    _pulseAnimationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    );

    _pulseAnimation = Tween<double>(begin: 1.0, end: 1.2).animate(
      CurvedAnimation(
        parent: _pulseAnimationController,
        curve: Curves.easeInOut,
      ),
    );
  }

  Future<void> _requestPermissions() async {
    await [
      Permission.microphone,
      Permission.camera,
    ].request();
  }

  /// Connect to Livekit Room with AI Agent
  Future<void> _connectToLivekit() async {
    if (_isConnecting || _isConnected) return;

    // If another in-app assistant (e.g., ChatBot TTS) was speaking, stop it
    // before starting the LiveKit audio session.
    await _stopAnyBackgroundTts();

    // Reset per-session one-shot prompts.
    _sentLizzySpokenIntro = false;

    setState(() {
      _isConnecting = true;
      _connectionStatus = 'Connecting to $_assistantName...';
    });
    try {
      // Check microphone permission
      final micStatus = await Permission.microphone.status;
      if (!micStatus.isGranted) {
        await Permission.microphone.request();
      }
      final micAfter = await Permission.microphone.status;
      if (!micAfter.isGranted) {
        throw Exception(
            'Microphone permission denied. Please allow microphone access and try again.');
      }

      // Create room instance
      _room = Room();

      // Set up event listeners
      _setupRoomListeners();

      // Ask backend to create a room + mint a token + dispatch the agent.
      setState(() {
        _connectionStatus = 'Requesting voice session...';
      });

      final rolePrefix =
          widget.role.trim().isEmpty ? 'user' : widget.role.trim();
      final participantName =
          '$rolePrefix-${DateTime.now().millisecondsSinceEpoch}';
      final startInfo =
          await _startVoiceSession(participantName: participantName);
      final roomName = startInfo.roomName;
      final token = startInfo.token;
      final livekitUrl = startInfo.livekitUrl;

      _voiceSessionId = startInfo.sessionId;
      _voiceSessionNonce = startInfo.sessionNonce;
      _voiceRoomName = roomName;

      // Create connection options
      final connectOptions = ConnectOptions(
        // IMPORTANT: must auto-subscribe so the phone actually receives the AI agent audio.
        // LiveKit does not loop back your own mic audio by default, so this won't create echo.
        autoSubscribe: true,
      );

      // Connect to the room
      await _room!
          .connect(
            livekitUrl,
            token,
            connectOptions: connectOptions,
          )
          .timeout(const Duration(seconds: 30));

      // Enable local audio track
      await _room!.localParticipant?.setMicrophoneEnabled(true);

      setState(() {
        _isConnected = true;
        _isConnecting = false;
        _connectionStatus = 'Connected - Waiting for AI...';
        _localParticipant = _room!.localParticipant;
        _aiResponse = '🎤 YOU ARE NOW CONNECTED!\n\n'
            'Room: $roomName\n\n'
            '$_assistantName is being started by the backend.\n\n'
            'Start speaking to interact with $_assistantName!\n\n'
            'The agent will help you with:\n'
            '• Maintenance bookings\n'
            '• Schedule inquiries\n'
            '• General support\n\n'
            'Keep this app open while talking.';

        // Don't pre-fill an AI greeting; wait for the real agent audio/metadata.
        _addToTranscript(
            'System', 'Connected. Waiting for AI agent to join...');
      });

      // If this is an artisan session, ensure request announcements are attached.
      _attachArtisanRequestAnnouncements();

      // ── CRITICAL: send Firebase credentials so the agent can call backend tools ──
      // Uses data channel (publishData) so it won't be overwritten by
      // subsequent setMetadata calls for context/speak.
      await _sendCredentialsToAgent();

      // Provide capabilities + in-app context so the agent can reliably
      // navigate and complete tasks via square15_ui actions.
      await _sendAppContextToAgent(reason: 'connected');

      _waveAnimationController.repeat(reverse: true);
      _pulseAnimationController.repeat(reverse: true);

      debugPrint('✅ Connected to $_assistantName (LiveKit)');
    } catch (e) {
      debugPrint('❌ Error connecting to Livekit: $e');
      setState(() {
        _isConnecting = false;
        _connectionStatus = 'Connection Failed';
        _aiResponse = 'Failed to connect to $_assistantName. Please try again.';
      });

      _showErrorDialog(
          'Connection Error', 'Failed to connect to $_assistantName: $e');
    }
  }

  Future<void> _sendSpeakToAgent(String text) async {
    final t = text.trim();
    if (t.isEmpty) return;

    // Never send UI directives or obvious JSON/tool blobs into the voice channel.
    // These are meant for app parsing and sound like "code" when spoken.
    if (t.contains('SQUARE15_UI:') || t.contains('square15_ui:')) return;
    if ((t.startsWith('{') || t.startsWith('[')) && t.contains('"action"')) {
      return;
    }

    if (!mounted) return;
    if (_room == null || _room!.localParticipant == null) return;

    final now = DateTime.now();
    // Avoid spamming identical phrases.
    if (t == _lastSpokenToAgent &&
        now.difference(_lastSpokenToAgentAt) < const Duration(seconds: 2)) {
      return;
    }
    _lastSpokenToAgent = t;
    _lastSpokenToAgentAt = now;

    final meta = jsonEncode({
      'type': 'square15_app',
      'action': 'speak',
      'payload': {
        'text': t,
      },
      'ts': now.toIso8601String(),
      'seq': ++_appMetadataSeq,
    });

    try {
      // Some SDK versions expose setMetadata as Future; others as sync.
      final dynamic lp = _room!.localParticipant!;
      final dynamic result = lp.setMetadata(meta);
      if (result is Future) {
        await result;
      }
      print('[ai_app] speak_sent len=${t.length}');
    } catch (e) {
      // Best-effort: speaking is optional.
      print('[ai_app] speak_send_failed err=$e');
    }
  }

  void _maybeSendLizzySpokenIntro({required String remoteIdentity}) {
    if (_sentLizzySpokenIntro) return;
    if (!mounted) return;
    if (_room == null) return;
    if (_room!.remoteParticipants.isEmpty) return;

    _sentLizzySpokenIntro = true;

    // Give the agent a moment to finish joining + attach metadata listeners.
    Future.delayed(const Duration(milliseconds: 700), () async {
      try {
        await _sendSpeakToAgent(
          'I am $_assistantName, how can I help you today?',
        );
        // Retry once in case the first metadata update was missed.
        await Future.delayed(const Duration(seconds: 3));
        await _sendSpeakToAgent(
          'I am $_assistantName, how can I help you today?',
        );
      } catch (_) {
        // Best-effort: ignore.
      }
    });
  }

  Map<String, dynamic> _buildAgentCapabilities() {
    return {
      'ui_action_schema_version': 1,
      'ui_action_transport': 'livekit_participant_metadata',
      'ui_action_formats': [
        'JSON: {"type":"square15_ui","action":"...","payload":{...}}',
        'TEXT: SQUARE15_UI:{"action":"...","payload":{...}}'
      ],
      'supported_actions': [
        // Generic navigation
        'open_future_bookings',
        'open_bookings_tab',
        'open_notifications',
        'open_profile',
        'open_settings',
        'open_support',
        'open_wallet',
        'open_calendar',
        'open_map',
        'open_help',
        'go_home',
        'go_back',
        'close_window',
        'close_dialog',
        'dismiss',

        // Booking + dispatch
        'create_order_booking',
        'dispatch_artisan',
        'open_rfq_upload',
        'call_assigned_artisan',

        // Booking management
        'get_booking_status',
        'reschedule_booking',
        'cancel_booking',
        'reassign_booking',
        'mark_booking_in_progress',
        'artisan_cancel_and_reassign',

        // Admin / privileged (role-gated; will no-op for non-admin)
        'admin_assign_artisan',
        'rfq_approve',
        'rfq_reject',

        // Artisan actions
        'open_artisan_requests',
        'open_artisan_appointments',
        'open_artisan_wallet',
        'open_schedule',
        'open_artisan_schedule',
        'accept_latest_request',
        'reject_latest_request',
        'respond_to_request',
      ],
      'notes':
          'For create_order_booking/dispatch_artisan, payload supports category_name, problem_description, additional_notes, scheduled_date/time, materials_responsibility, require_photos, work_image_urls, and optional service_address/service_lat/service_lng. If pricing is unavailable, the app will prompt for an RFQ or a priced service selection.',
      'safety':
          'Do not submit payment or destructive actions without user confirmation. When unsure, ask a follow-up question rather than guessing.',
    };
  }

  Map<String, dynamic> _buildAppContext({required String reason}) {
    final role = widget.role.toLowerCase().trim();
    final route = Get.currentRoute.toString();

    String userId = '';
    try {
      if (Get.isRegistered<AppController>()) {
        userId = Get.find<AppController>().userId.value.toString().trim();
      }
    } catch (_) {
      userId = '';
    }

    int pendingRequests = 0;
    if (role == 'artisan') {
      try {
        if (Get.isRegistered<ServiceProviderController>()) {
          final sp = Get.find<ServiceProviderController>();
          pendingRequests = sp.requestList
              .where((r) => (r.accept ?? '').toString().trim().isEmpty)
              .length;
        }
      } catch (_) {
        pendingRequests = 0;
      }
    }

    return {
      'assistant_name': _assistantName,
      'reason': reason,
      'role': role,
      'route': route,
      'user_id': userId,
      'last_created_booking_id': _lastCreatedBookingId,
      'last_assigned_artisan_id': _lastAssignedArtisanId,
      'pending_requests_count': pendingRequests,
      'capabilities': _buildAgentCapabilities(),
      'ts': DateTime.now().toIso8601String(),
    };
  }

  /// Send Firebase credentials to the agent so it can authenticate
  /// backend API calls (booking lookup, wallet, messaging, etc.).
  Future<void> _sendCredentialsToAgent() async {
    if (!mounted) return;
    if (_room == null || _room!.localParticipant == null) return;

    // Refresh the token if it's empty (e.g. expired).
    String token = _firebaseIdToken;
    if (token.trim().isEmpty) {
      try {
        final u = FirebaseAuth.instance.currentUser;
        if (u != null) {
          token = (await u.getIdToken(true)) ?? '';
          _firebaseIdToken = token;
        }
      } catch (_) {}
    }

    if (token.trim().isEmpty) {
      print('[ai_app] credentials_send_skipped: no firebase token');
      return;
    }

    final meta = jsonEncode({
      'type': 'square15_voice_credentials',
      'firebase_token': token.trim(),
      'session_id': _voiceSessionId,
      'session_nonce': _voiceSessionNonce,
      'ts': DateTime.now().toIso8601String(),
      'seq': ++_appMetadataSeq,
    });

    // Use publishData (reliable data channel) instead of setMetadata.
    // setMetadata gets overwritten by subsequent calls (speak, context)
    // before the agent can read it — the data channel delivers independently.
    try {
      final dynamic lp = _room!.localParticipant!;
      final bytes = utf8.encode(meta);
      await lp.publishData(bytes, reliable: true);
      print('[ai_app] credentials_sent via data channel');
    } catch (e) {
      print('[ai_app] credentials_data_send_failed err=$e, falling back to metadata');
      // Fallback: try setMetadata + delay so agent has time to read it
      try {
        final dynamic lp = _room!.localParticipant!;
        final dynamic result = lp.setMetadata(meta);
        if (result is Future) await result;
        await Future.delayed(const Duration(milliseconds: 1500));
      } catch (_) {}
    }
  }

  Future<void> _sendAppContextToAgent({required String reason}) async {
    if (!mounted) return;
    if (_room == null || _room!.localParticipant == null) return;

    final meta = jsonEncode({
      'type': 'square15_app',
      'action': 'context',
      'payload': _buildAppContext(reason: reason),
      'ts': DateTime.now().toIso8601String(),
      'seq': ++_appMetadataSeq,
    });

    try {
      final dynamic lp = _room!.localParticipant!;
      final dynamic result = lp.setMetadata(meta);
      if (result is Future) {
        await result;
      }
      print('[ai_app] context_sent reason=$reason');
    } catch (e) {
      print('[ai_app] context_send_failed err=$e');
    }
  }

  Future<void> _suggestClosestServices({
    required String description,
    required String? categoryId,
    int limit = 200,
  }) async {
    try {
      final raw = description.trim().toLowerCase();
      if (raw.isEmpty) return;

      Set<String> tokens(String s) {
        return s
            .toLowerCase()
            .split(RegExp(r'[^a-z0-9]+'))
            .where((t) => t.trim().isNotEmpty && t.trim().length >= 3)
            .toSet();
      }

      int scoreFor(String hint, String name) {
        final ht = tokens(hint);
        final nt = tokens(name);
        int score = 0;
        if (name.toLowerCase().contains(hint) ||
            hint.contains(name.toLowerCase())) {
          score += 12;
        }
        score += ht.intersection(nt).length * 4;
        return score;
      }

      final tasks = FirebaseFirestore.instance.collection('tasks');
      Query<Map<String, dynamic>> q;
      if ((categoryId ?? '').trim().isNotEmpty) {
        q = tasks.where('categoryId', isEqualTo: categoryId!.trim());
      } else {
        q = tasks;
      }
      final snap = await q.limit(limit).get();
      final scored = <Map<String, dynamic>>[];
      for (final d in snap.docs) {
        final data = d.data();
        final name = (data['name'] ?? '').toString().trim();
        if (name.isEmpty) continue;
        final s = scoreFor(raw, name);
        if (s > 0) {
          scored.add({'name': name, 'score': s});
        }
      }
      scored.sort((a, b) => (b['score'] as int).compareTo(a['score'] as int));
      final top = scored.take(3).toList();
      if (top.isEmpty) return;

      final names = top.map((e) => e['name'] as String).toList();
      final msg =
          'I found these close matches: 1) ${names[0]}${names.length > 1 ? ', 2) ${names[1]}' : ''}${names.length > 2 ? ', 3) ${names[2]}' : ''}. Please say the number or name to confirm, or you can proceed with a general request.';
      await _sendSpeakToAgent(msg);
      setState(() {
        _aiResponse = msg;
      });
    } catch (_) {
      // Non-fatal: continue the normal flow
    }
  }

  bool _shouldDebounceUiAction(String action,
      {Duration cooldown = const Duration(milliseconds: 1200)}) {
    final a = action.trim();
    if (a.isEmpty) return false;
    final now = DateTime.now();
    final last = _lastUiActionAt[a];
    if (last != null && now.difference(last) < cooldown) {
      return true;
    }
    _lastUiActionAt[a] = now;
    return false;
  }

  Future<String> _getAppCheckTokenBestEffort() async {
    try {
      final token = await FirebaseAppCheck.instance.getToken();
      return (token ?? '').trim();
    } catch (_) {
      return '';
    }
  }

  Future<_VoiceStartInfo> _startVoiceSession(
      {required String participantName}) async {
    final uri = Uri.parse('$backendBaseUrl/api/voice/start');

    String userId = '';
    try {
      if (Get.isRegistered<AppController>()) {
        userId = Get.find<AppController>().userId.value.toString().trim();
      }
    } catch (_) {
      userId = '';
    }

    final metadata = jsonEncode({
      'app': 'square15',
      'assistant_name': _assistantName,
      'role': widget.role,
      'user_id': userId,
      'provider_id': widget.providerListenerId,
      'route': Get.currentRoute.toString(),
      'capabilities': _buildAgentCapabilities(),
      'ts': DateTime.now().toIso8601String(),
    });

    http.Response? resp;
    Object? lastError;

    String idToken = '';
    try {
      final u = FirebaseAuth.instance.currentUser;
      if (u != null) {
        idToken = (await u.getIdToken()) ?? '';
      }
    } catch (_) {
      idToken = '';
    }

    // Cache the Firebase ID token so we can send it to the agent after connect.
    _firebaseIdToken = idToken;

    final appCheckToken = await _getAppCheckTokenBestEffort();

    for (int attempt = 0; attempt < 2; attempt++) {
      try {
        final headers = <String, String>{'Content-Type': 'application/json'};
        if (idToken.trim().isNotEmpty) {
          headers['Authorization'] = 'Bearer ${idToken.trim()}';
        }
        if (appCheckToken.isNotEmpty) {
          headers['X-Firebase-AppCheck'] = appCheckToken;
        }
        resp = await http
            .post(
              uri,
              headers: headers,
              body: jsonEncode({
                'participantName': participantName,
                'metadata': metadata,
              }),
            )
            .timeout(const Duration(seconds: 30));
        lastError = null;
        break;
      } catch (e) {
        lastError = e;
        // Quick retry helps on mobile networks / cold Render instances.
        await Future.delayed(const Duration(milliseconds: 600));
      }
    }

    if (resp == null) {
      throw Exception('Backend voice start failed: $lastError');
    }

    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw Exception(
        'Backend voice start failed (${resp.statusCode}): ${resp.body}',
      );
    }

    final data = jsonDecode(resp.body) as Map<String, dynamic>;
    final roomName = (data['roomName'] ?? '').toString();
    final token = (data['token'] ?? '').toString();
    final url = (data['url'] ?? '').toString();
    final sessionId = (data['sessionId'] ?? '').toString();
    final sessionNonce =
      (data['sessionNonce'] ?? data['session_nonce'] ?? '').toString();

    if (roomName.isEmpty || token.isEmpty || url.isEmpty) {
      throw Exception(
          'Backend voice start returned invalid response: ${resp.body}');
    }

    return _VoiceStartInfo(
      roomName: roomName,
      token: token,
      livekitUrl: url,
      sessionId: sessionId,
      sessionNonce: sessionNonce,
    );
  }

  Future<Map<String, dynamic>?> _tryExecuteAssistantAction({
    required String action,
    required Map<String, dynamic> payload,
  }) async {
    final a = action.trim();
    if (a.isEmpty) return null;

    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return null;

    String? idToken;
    try {
      idToken = await user.getIdToken();
    } catch (_) {
      return null;
    }

    final trimmedToken = (idToken ?? '').trim();
    if (trimmedToken.isEmpty) return null;

    final proposeUri = Uri.parse('$backendBaseUrl/api/action/propose');
    final confirmUri = Uri.parse('$backendBaseUrl/api/action/confirm');
    final executeUri = Uri.parse('$backendBaseUrl/api/action/execute');
    final idem = 'va-${const Uuid().v4()}';

    final appCheckToken = await _getAppCheckTokenBestEffort();

    Map<String, String> baseHeaders() {
      return {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $trimmedToken',
        if (appCheckToken.isNotEmpty) 'X-Firebase-AppCheck': appCheckToken,
      };
    }

    Map<String, dynamic> buildContext() {
      return {
        'session_id': _voiceSessionId,
        'session_nonce': _voiceSessionNonce,
        'room_name': _voiceRoomName,
      };
    }

    Future<Map<String, dynamic>?> tryProposeConfirm() async {
      // 1) Propose
      final proposeResp = await http
          .post(
            proposeUri,
            headers: baseHeaders(),
            body: jsonEncode({
              'action': a,
              'payload': payload,
              'context': buildContext(),
            }),
          )
          .timeout(const Duration(seconds: 30));

      if (proposeResp.statusCode < 200 || proposeResp.statusCode >= 300) {
        return null;
      }

      final proposeData = jsonDecode(proposeResp.body) as Map<String, dynamic>;
      final proposalId =
          (proposeData['proposalId'] ?? proposeData['proposal_id'] ?? '')
              .toString()
              .trim();
      if (proposalId.isEmpty) return null;

      // 2) Confirm
      final confirmResp = await http
          .post(
            confirmUri,
            headers: {
              ...baseHeaders(),
              'Idempotency-Key': idem,
            },
            body: jsonEncode({'proposalId': proposalId}),
          )
          .timeout(const Duration(seconds: 30));

      if (confirmResp.statusCode < 200 || confirmResp.statusCode >= 300) {
        return null;
      }

      final confirmData = jsonDecode(confirmResp.body) as Map<String, dynamic>;
      return confirmData;
    }

    try {
      // Prefer Phase 1 server-enforced safety flow.
      final confirmData = await tryProposeConfirm();
      if (confirmData != null) return confirmData;

      // Fallback for older deployments: direct execute.
      final resp = await http
          .post(
            executeUri,
            headers: {
              ...baseHeaders(),
              'Idempotency-Key': idem,
            },
            body: jsonEncode({
              'action': a,
              'payload': payload,
              'context': buildContext(),
            }),
          )
          .timeout(const Duration(seconds: 30));

      if (resp.statusCode < 200 || resp.statusCode >= 300) return null;
      return jsonDecode(resp.body) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  /// Set up room event listeners
  void _setupRoomListeners() {
    if (_room == null) return;

    // Preferred: use LiveKit's typed event listener API.
    // This is the most reliable way to observe participant metadata updates.
    _attachTypedRoomListener();

    // Best-effort fallback: keep legacy/dynamic approach for older SDK shapes.
    // Only try this when typed listener isn't available to avoid confusing logs.
    if (_lkRoomListener == null) {
      _tryAttachRoomEventsListener();
    }

    // Use a single callback-based listener (compatible with this SDK version)
    _room!.addListener(() {
      if (_room == null) return;

      // Check for remote participants (AI agent)
      for (final participant in _room!.remoteParticipants.values) {
        final pid = participant.identity;
        if (!_seenRemoteParticipants.contains(pid)) {
          _seenRemoteParticipants.add(pid);
          debugPrint('👤 Remote participant: $pid');
          _maybeSendLizzySpokenIntro(remoteIdentity: pid);
        }

        // Subscribe to all remote audio tracks
        for (final publication in participant.trackPublications.values) {
          if (publication.kind == TrackType.AUDIO && !publication.subscribed) {
            publication.subscribe();
            debugPrint(
                '✅ Subscribed to remote audio track from ${participant.identity}');
          }
        }

        // Handle AI responses via metadata (wire once per participant)
        final id = participant.identity;
        if (!_wiredRemoteParticipants.contains(id)) {
          _wiredRemoteParticipants.add(id);
          participant.addListener(() {
            if (participant.metadata != null &&
                participant.metadata!.isNotEmpty) {
              if (mounted) {
                _maybeHandleParticipantMetadata(
                  participantKey: participant.identity,
                  rawMetadata: participant.metadata!,
                );
              }
            }
          });
        }
      }

      // Update status when remote participants are present
      if (_room!.remoteParticipants.isNotEmpty && mounted) {
        setState(() {
          _connectionStatus = '$_assistantName Active';
        });
      }

      // Handle connection state changes
      final state = _room!.connectionState;
      if (_lastConnectionState != state) {
        _lastConnectionState = state;
        debugPrint('ℹ️ Room state: $state');

        if (state == livekit.ConnectionState.connected) {
          debugPrint('✅ Room connected');
          _disconnectDebounce?.cancel();
          _disconnectDebounce = null;
          _hasHandledDisconnect = false;

          // Fallback: poll participant metadata periodically.
          // Some livekit_client versions don't emit metadata updates via participant listeners.
          _metadataPoller?.cancel();
          _metadataPoller =
              Timer.periodic(const Duration(milliseconds: 600), (_) {
            if (!mounted || _room == null) return;
            for (final p in _room!.remoteParticipants.values) {
              final md = p.metadata;
              if (md != null && md.trim().isNotEmpty) {
                _maybeHandleParticipantMetadata(
                  participantKey: p.identity,
                  rawMetadata: md,
                );
              }
            }
          });
        }

        if (state == livekit.ConnectionState.disconnected) {
          String reason = '';
          try {
            final dynamic dynRoom = _room;
            reason = (dynRoom as dynamic).disconnectReason?.toString() ?? '';
          } catch (_) {
            reason = '';
          }
          if (reason.isNotEmpty) {
            debugPrint('❌ Room disconnected (reason=$reason)');
          } else {
            debugPrint('❌ Room disconnected');
          }

          // Debounce: LiveKit can briefly report "disconnected" during network blips
          // and then recover to "connected". Only update UI if it stays disconnected.
          _disconnectDebounce?.cancel();
          _disconnectDebounce = Timer(const Duration(seconds: 2), () {
            if (!mounted || _room == null) return;
            if (_room!.connectionState !=
                livekit.ConnectionState.disconnected) {
              return;
            }

            _metadataPoller?.cancel();
            _metadataPoller = null;

            if (!_hasHandledDisconnect) {
              _hasHandledDisconnect = true;
              _handleDisconnection();
              _seenRemoteParticipants.clear();
              _wiredRemoteParticipants.clear();
            }
          });
        }
      }
    });
  }

  void _attachTypedRoomListener() {
    if (_room == null) return;
    if (_lkRoomListener != null) return;

    // ASCII-only log markers so they show cleanly in release logcat.
    print('[lk_typed] attach: start');
    try {
      _lkRoomListener = _room!.createListener();
    } catch (e) {
      print('[lk_typed] attach: createListener_not_available err=$e');
      _lkRoomListener = null;
      return;
    }

    try {
      _lkRoomListener!
        ..on<ParticipantMetadataUpdatedEvent>((event) {
          try {
            final p = event.participant;
            final md = p.metadata;
            if (md == null || md.trim().isEmpty) return;
            if (!mounted) return;
            print(
              '[lk_typed] metadata_updated from=${p.identity} len=${md.length}',
            );
            _maybeHandleParticipantMetadata(
              participantKey: p.identity,
              rawMetadata: md,
            );
          } catch (e) {
            print('[lk_typed] metadata_updated parse_failed err=$e');
          }
        })
        ..on<DataReceivedEvent>((event) {
          // Some agents/tools may send UI actions via data channel.
          // Decode to text when possible and feed into the same handler.
          try {
            final bytes = event.data;
            String text;
            try {
              text = utf8.decode(bytes);
            } catch (_) {
              text = String.fromCharCodes(bytes);
            }
            final from = event.participant?.identity ?? 'unknown';
            debugPrint(
              '[ai_data] recv len=${bytes.length} from=$from',
            );
            if (text.trim().isEmpty) return;
            _handleAgentMetadata(text);
          } catch (e) {
            print('[lk_typed] data_received parse_failed err=$e');
          }
        });

      print('[lk_typed] attach: ok');
    } catch (e) {
      print('[lk_typed] attach_failed err=$e');
    }
  }

  void _disposeTypedRoomListener() {
    try {
      _lkRoomListener?.dispose();
    } catch (_) {
      // ignore
    }
    _lkRoomListener = null;
  }

  void _tryAttachRoomEventsListener() {
    if (_room == null) return;
    if (_roomEventsSub != null) return;
    if (_roomEventsEmitter != null) return;

    // Use dynamic to remain compatible across livekit_client versions.
    final dynamic dynRoom = _room;
    try {
      final dynamic events = dynRoom.events;

      void handleRoomEvent(dynamic event) {
        try {
          // Try common shapes for metadata updates.
          dynamic participant;
          try {
            participant = (event as dynamic).participant;
          } catch (_) {}
          try {
            participant ??= (event as dynamic).remoteParticipant;
          } catch (_) {}
          try {
            participant ??= (event as dynamic).target;
          } catch (_) {}

          String participantKey = 'unknown';
          try {
            participantKey = (participant as dynamic).identity.toString();
          } catch (_) {}
          if (participantKey == 'unknown') {
            try {
              participantKey = (participant as dynamic).sid.toString();
            } catch (_) {}
          }

          String? metadata;
          try {
            metadata = (participant as dynamic).metadata?.toString();
          } catch (_) {}
          if (metadata == null) {
            try {
              metadata = (event as dynamic).metadata?.toString();
            } catch (_) {}
          }
          if (metadata == null || metadata.trim().isEmpty) return;
          if (!mounted) return;

          _maybeHandleParticipantMetadata(
            participantKey: participantKey,
            rawMetadata: metadata,
          );
        } catch (e) {
          debugPrint('⚠️ Room event parse failed: $e');
        }
      }

      if (events is Stream) {
        _roomEventsSub = events.listen(
          (dynamic event) => handleRoomEvent(event),
          onError: (Object e, StackTrace st) {
            debugPrint('⚠️ Room events stream error: $e');
          },
        );
        debugPrint('✅ Attached LiveKit room events listener (stream)');
        return;
      }

      // livekit_client ^2.3.x exposes `events` as an EventsEmitter, not a Stream.
      // Prefer a `.stream` or `.asStream()` adapter when available.
      bool attachedAny = false;
      _roomEventsEmitter = events;

      Stream? emitterStream;
      try {
        emitterStream = (events as dynamic).stream as Stream;
      } catch (_) {
        emitterStream = null;
      }
      if (emitterStream == null) {
        try {
          emitterStream = (events as dynamic).asStream() as Stream;
        } catch (_) {
          emitterStream = null;
        }
      }

      if (emitterStream != null) {
        _roomEventsSub = emitterStream.listen(
          (dynamic event) => handleRoomEvent(event),
          onError: (Object e, StackTrace st) {
            debugPrint('⚠️ Room events stream error: $e');
          },
        );
        debugPrint('✅ Attached LiveKit room events listener (emitter.stream)');
        return;
      }

      void tryOn(dynamic eventType) {
        try {
          (events as dynamic).on(eventType, handleRoomEvent);
          _roomEventHandlers.add(_RoomEventHandler(eventType, handleRoomEvent));
          attachedAny = true;
        } catch (_) {
          // ignore
        }
      }

      // String-based fallbacks (names vary by emitter implementation).
      for (final name in <String>[
        'participantMetadataUpdated',
        'participantMetadataChanged',
        'participantMetadataUpdate',
        'metadataChanged',
        'roomEvent',
      ]) {
        tryOn(name);
      }

      if (attachedAny) {
        debugPrint('✅ Attached LiveKit room events listener (emitter)');
      } else {
        _roomEventsEmitter = null;
        _roomEventHandlers.clear();
        debugPrint(
            'ℹ️ LiveKit room events listener not supported: ${events.runtimeType}');
      }
    } catch (e) {
      // Not supported on this SDK version.
      debugPrint('ℹ️ LiveKit room events stream not available: $e');
    }
  }

  Future<void> _disposeRoomEventsListener() async {
    await _roomEventsSub?.cancel();
    _roomEventsSub = null;

    if (_roomEventsEmitter != null && _roomEventHandlers.isNotEmpty) {
      for (final h in _roomEventHandlers) {
        try {
          (_roomEventsEmitter as dynamic).off(h.eventType, h.handler);
        } catch (_) {
          // ignore
        }
      }
    }
    _roomEventsEmitter = null;
    _roomEventHandlers.clear();
  }

  void _maybeHandleParticipantMetadata({
    required String participantKey,
    required String rawMetadata,
  }) {
    final last = _lastMetadataByParticipant[participantKey];
    if (last == rawMetadata) return;
    _lastMetadataByParticipant[participantKey] = rawMetadata;
    _handleAgentMetadata(rawMetadata);
  }

  void _handleAgentMetadata(String raw) {
    // Always log receipt so we can confirm the agent is sending metadata.
    // ASCII-only to avoid PowerShell encoding issues.
    final preview = raw.length > 180 ? '${raw.substring(0, 180)}...' : raw;
    print('[ai_meta] recv preview="$preview"');

    // Backward compatible: plain text metadata continues to work.
    // New format: JSON like {"text":"...","type":"square15_ui","action":"open_rfq_upload","payload":{...}}
    Map<String, dynamic>? decoded;
    try {
      final maybe = jsonDecode(raw);
      if (maybe is Map<String, dynamic>) decoded = maybe;
    } catch (_) {
      decoded = null;
    }

    if (decoded == null) {
      // Plain-text metadata may still contain an embedded UI directive.
      // Always attempt to parse and execute it.
      _tryHandleEmbeddedUiActionFromText(raw);

      final displayText = _stripUiDirectiveFromText(raw);
      if (displayText.isNotEmpty) {
        setState(() {
          _aiResponse = displayText;
        });
        _addToTranscript('AI', displayText);
      }
      return;
    }

    final text = (decoded['text'] ?? decoded['message'] ?? '').toString();
    if (text.isNotEmpty) {
      // Support agents that embed UI actions inside a normal text response.
      // Format: SQUARE15_UI:{"action":"create_order_booking","payload":{...}}
      _tryHandleEmbeddedUiActionFromText(text);

      final displayText = _stripUiDirectiveFromText(text);
      if (displayText.isNotEmpty) {
        setState(() {
          _aiResponse = displayText;
        });
        _addToTranscript('AI', displayText);
      }
    }

    final type = (decoded['type'] ?? '').toString();
    final action = (decoded['action'] ?? decoded['ui_action'] ?? '').toString();
    final payload = decoded['payload'];
    if (type == 'square15_ui' && action.isNotEmpty) {
      debugPrint(
        '[ai_meta] square15_ui action=$action payloadType=${payload.runtimeType}',
      );

      final clientActionId = _extractClientActionId(payload);
      _handleUiAction(action: action, payload: payload).then((_) async {
        print('[ai_action] done action=$action');
        await _sendUiActionResultToAgent(
          action: action,
          clientActionId: clientActionId,
          ok: true,
        );
      }).catchError((e, st) async {
        print('[ai_action] error action=$action err=$e');
        print('$st');
        await _sendUiActionResultToAgent(
          action: action,
          clientActionId: clientActionId,
          ok: false,
          error: e.toString(),
        );
      });
    }
  }

  Future<void> _tryHandleEmbeddedUiActionFromText(String text) async {
    if (!mounted) return;
    if (text.trim().isEmpty) return;
    const markers = <String>['SQUARE15_UI:', 'square15_ui:'];
    int idx = -1;
    String marker = '';
    for (final m in markers) {
      final i = text.indexOf(m);
      if (i >= 0 && (idx < 0 || i < idx)) {
        idx = i;
        marker = m;
      }
    }
    if (idx < 0) return;

    final raw = text.substring(idx + marker.length).trim();
    if (raw.isEmpty) return;

    // Some agents may wrap JSON in code fences.
    String jsonText = raw;
    if (jsonText.startsWith('```')) {
      jsonText =
          jsonText.replaceAll('```json', '').replaceAll('```', '').trim();
    }

    try {
      final decoded = jsonDecode(jsonText);
      if (decoded is! Map) return;
      final map = decoded.map((k, v) => MapEntry(k.toString(), v));
      final action = (map['action'] ?? map['ui_action'] ?? '').toString();
      final payload = map['payload'];
      if (action.isEmpty) return;
      debugPrint(
        '[ai_meta] embedded action=$action payloadType=${payload.runtimeType}',
      );
      await _handleUiAction(action: action, payload: payload);
      await _sendUiActionResultToAgent(
        action: action,
        clientActionId: _extractClientActionId(payload),
        ok: true,
      );
      debugPrint('[ai_action] done action=$action (embedded)');
    } catch (e) {
      debugPrint('[ai_meta] failed_to_parse_embedded_action err=$e');
    }
  }

  String _extractClientActionId(dynamic payload) {
    try {
      final map = payload is Map
          ? payload.map((k, v) => MapEntry(k.toString(), v))
          : <String, dynamic>{};
      return (map['client_action_id'] ?? map['clientActionId'] ?? '')
          .toString()
          .trim();
    } catch (_) {
      return '';
    }
  }

  Future<void> _sendUiActionResultToAgent({
    required String action,
    required String clientActionId,
    required bool ok,
    String? error,
  }) async {
    if (!mounted) return;
    if (_room == null || _room!.localParticipant == null) return;

    final meta = jsonEncode({
      'type': 'square15_app',
      'action': 'ui_action_result',
      'payload': {
        'ui_action': action,
        'client_action_id': clientActionId,
        'ok': ok,
        if ((error ?? '').trim().isNotEmpty) 'error': error.toString(),
        'route': Get.currentRoute.toString(),
      },
      'ts': DateTime.now().toIso8601String(),
      'seq': ++_appMetadataSeq,
    });

    try {
      final dynamic lp = _room!.localParticipant!;
      final dynamic result = lp.setMetadata(meta);
      if (result is Future) {
        await result;
      }
      print(
          '[ai_app] ui_action_result action=$action ok=$ok id=$clientActionId');
    } catch (e) {
      print('[ai_app] ui_action_result_failed err=$e');
    }
  }

  String _stripUiDirectiveFromText(String text) {
    if (text.trim().isEmpty) return '';
    const markers = <String>['SQUARE15_UI:', 'square15_ui:'];
    int idx = -1;
    for (final m in markers) {
      final i = text.indexOf(m);
      if (i >= 0 && (idx < 0 || i < idx)) idx = i;
    }
    if (idx < 0) return text.trim();
    return text.substring(0, idx).trim();
  }

  Future<void> _handleUiAction({
    required String action,
    required dynamic payload,
  }) async {
    if (!mounted) return;

    debugPrint(
      '[ai_action] begin action=$action payloadType=${payload.runtimeType}',
    );

    // Artisan task actions
    if (action == 'accept_latest_request') {
      if (_isRespondingToRequest) return;
      _isRespondingToRequest = true;
      try {
        await _respondToRequest(accept: '1', payload: payload);
      } finally {
        _isRespondingToRequest = false;
      }
      return;
    }

    if (action == 'reject_latest_request') {
      if (_isRespondingToRequest) return;
      _isRespondingToRequest = true;
      try {
        await _respondToRequest(accept: '0', payload: payload);
      } finally {
        _isRespondingToRequest = false;
      }
      return;
    }

    if (action == 'respond_to_request') {
      if (_isRespondingToRequest) return;
      _isRespondingToRequest = true;
      try {
        await _respondToRequest(accept: null, payload: payload);
      } finally {
        _isRespondingToRequest = false;
      }
      return;
    }

    // Generic navigation / app control actions
    if (action == 'open_future_bookings') {
      if (_shouldDebounceUiAction(action)) return;
      await _openFutureBookings();
      return;
    }

    if (action == 'open_bookings_tab') {
      if (_shouldDebounceUiAction(action)) return;
      await _openBookingsTab();
      return;
    }

    if (action == 'open_artisan_requests') {
      if (_shouldDebounceUiAction(action)) return;
      await _openArtisanRequests();
      return;
    }

    if (action == 'open_artisan_appointments') {
      if (_shouldDebounceUiAction(action)) return;
      await _openArtisanAppointments();
      return;
    }

    if (action == 'open_artisan_wallet') {
      if (_shouldDebounceUiAction(action)) return;
      await _openArtisanWallet();
      return;
    }

    if (action == 'open_rfq_upload') {
      await _openPhotoUploadThenDispatch(payload);
      return;
    }

    if (action == 'create_order_booking' || action == 'dispatch_artisan') {
      if (_isCreatingOrderBooking) return;

      // Voice-first flow: skip photo gate entirely.
      // Photos are optional and can be added post-booking from booking history.
      _isCreatingOrderBooking = true;
      try {
        await _createOrderBookingFromPayload(payload);
      } finally {
        _isCreatingOrderBooking = false;
      }
      return;
    }

    if (action == 'get_booking_status' || action == 'check_booking_status') {
      await _sendBookingStatusToAgentFromPayload(payload);
      return;
    }

    if (action == 'reschedule_booking') {
      await _rescheduleBookingFromPayload(payload);
      return;
    }

    if (action == 'cancel_booking') {
      await _cancelBookingFromPayload(payload);
      return;
    }

    if (action == 'reassign_booking') {
      await _reassignBookingFromPayload(payload);
      return;
    }

    if (action == 'mark_booking_in_progress') {
      await _markBookingInProgressFromPayload(payload);
      return;
    }

    if (action == 'artisan_cancel_and_reassign') {
      await _artisanCancelAndReassignFromPayload(payload);
      return;
    }

    if (action == 'admin_assign_artisan' ||
        action == 'rfq_approve' ||
        action == 'rfq_reject') {
      await _handlePrivilegedActionStub(action: action, payload: payload);
      return;
    }

    if (action == 'call_assigned_artisan' || action == 'call_artisan') {
      await _callAssignedArtisanFromPayload(payload);
      return;
    }

    // Additional app functionalities
    if (action == 'open_notifications') {
      if (_shouldDebounceUiAction(action)) return;
      Get.toNamed('/notifications');
      Get.snackbar(_assistantName, 'Opening notifications',
          backgroundColor: Colors.green, colorText: Colors.white);
      return;
    }

    if (action == 'open_profile') {
      if (_shouldDebounceUiAction(action)) return;
      Get.toNamed('/profile');
      Get.snackbar(_assistantName, 'Opening your profile',
          backgroundColor: Colors.green, colorText: Colors.white);
      return;
    }

    if (action == 'open_settings') {
      if (_shouldDebounceUiAction(action)) return;
      Get.toNamed('/settings');
      Get.snackbar(_assistantName, 'Opening settings',
          backgroundColor: Colors.green, colorText: Colors.white);
      return;
    }

    if (action == 'open_chat_support' || action == 'open_support') {
      if (_shouldDebounceUiAction(action)) return;
      Get.toNamed('/support');
      Get.snackbar(_assistantName, 'Opening customer support',
          backgroundColor: Colors.green, colorText: Colors.white);
      return;
    }

    if (action == 'open_user_wallet' || action == 'open_wallet') {
      if (_shouldDebounceUiAction(action)) return;
      Get.toNamed('/wallet');
      Get.snackbar(_assistantName, 'Opening your wallet',
          backgroundColor: Colors.green, colorText: Colors.white);
      return;
    }

    if (action == 'open_calendar' || action == 'open_artisan_calendar' || action == 'open_schedule' || action == 'open_artisan_schedule') {
      if (_shouldDebounceUiAction(action)) return;
      Get.to(() => const ClientCalendarScreen());
      Get.snackbar(_assistantName, 'Opening calendar',
          backgroundColor: Colors.green, colorText: Colors.white);
      return;
    }

    if (action == 'open_map' || action == 'show_location') {
      // Map screen is not implemented — ignore silently.
      // The agent instructions have been updated to not use this action.
      print('[voice] open_map action ignored — no map route registered');
      return;
    }

    if (action == 'open_help' || action == 'open_faq') {
      if (_shouldDebounceUiAction(action)) return;
      Get.snackbar(_assistantName,
          'Help: You can request services, check bookings, manage appointments, and more. What would you like help with?',
          backgroundColor: Colors.blue,
          colorText: Colors.white,
          duration: const Duration(seconds: 5));
      return;
    }

    if (action == 'go_home' || action == 'open_dashboard') {
      if (_shouldDebounceUiAction(action)) return;
      Get.offAllNamed('/dashboard');
      Get.snackbar(_assistantName, 'Going to home screen',
          backgroundColor: Colors.green, colorText: Colors.white);
      return;
    }

    if (action == 'go_back' || action == 'navigate_back') {
      try {
        final hasOverlay = (Get.isDialogOpen ?? false) ||
            (Get.isBottomSheetOpen ?? false) ||
            (Get.isSnackbarOpen ?? false);
        if (hasOverlay) {
          Get.back(closeOverlays: true);
          Get.snackbar(_assistantName, 'Closed window',
              backgroundColor: Colors.green, colorText: Colors.white);
          return;
        }
      } catch (_) {
        // ignore
      }

      if (Get.currentRoute != '/dashboard' && Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
        Get.snackbar(_assistantName, 'Going back',
            backgroundColor: Colors.green, colorText: Colors.white);
      } else {
        Get.snackbar(_assistantName, 'Already at the main screen',
            backgroundColor: Colors.orange, colorText: Colors.white);
      }
      return;
    }

    if (action == 'close_window' || action == 'close_dialog' || action == 'dismiss') {
      try {
        Get.back(closeOverlays: true);
        Get.snackbar(_assistantName, 'Closed window',
            backgroundColor: Colors.green, colorText: Colors.white);
      } catch (e) {
        Get.snackbar(_assistantName, 'Could not close window: $e',
            backgroundColor: Colors.red, colorText: Colors.white);
      }
      return;
    }
  }

  Future<bool> _confirmUiAction({
    required String title,
    required String message,
    String confirmText = 'Confirm',
    String cancelText = 'Cancel',
  }) async {
    if (!mounted) return false;

    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text(cancelText),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text(confirmText),
            ),
          ],
        );
      },
    );

    return result == true;
  }

  String _bookingIdFromPayload(dynamic payload) {
    final map = payload is Map
        ? payload.map((k, v) => MapEntry(k.toString(), v))
        : <String, dynamic>{};
    final raw = (map['booking_id'] ?? map['bookingId'] ?? '').toString().trim();
    if (raw.isNotEmpty) return raw;
    return _lastCreatedBookingId.trim();
  }

  Future<void> _sendBookingStatusToAgentFromPayload(dynamic payload) async {
    final bookingId = _bookingIdFromPayload(payload);
    if (bookingId.isEmpty) {
      await _sendSpeakToAgent(
        'Please tell me the booking ID, or open Future Bookings so I can reference the correct booking.',
      );
      return;
    }

    // Prefer backend-gated read so roles/ownership are enforced consistently.
    final backend = await _tryExecuteAssistantAction(
      action: 'get_booking_status',
      payload: {'booking_id': bookingId},
    );
    final backendResult = backend != null ? backend['result'] : null;
    if (backendResult is Map) {
      final data = backendResult.map((k, v) => MapEntry(k.toString(), v));
      final status = (data['status'] ?? '').toString().trim();
      final scheduledDate = (data['scheduled_date'] ?? '').toString().trim();
      final scheduledTime = (data['scheduled_time'] ?? '').toString().trim();
      final paymentStatus = (data['payment_status'] ?? '').toString().trim();
      final artisanConfirmed =
          (data['artisan_confirmed'] ?? '').toString().trim();

      final parts = <String>[];
      parts.add('Booking status is ${status.isNotEmpty ? status : 'unknown'}');
      if (scheduledDate.isNotEmpty || scheduledTime.isNotEmpty) {
        parts.add(
            'scheduled for ${scheduledDate.isNotEmpty ? scheduledDate : 'a date to be confirmed'}'
            '${scheduledTime.isNotEmpty ? ' at $scheduledTime' : ''}');
      }
      if (artisanConfirmed.isNotEmpty) {
        parts.add('artisan confirmation is $artisanConfirmed');
      }
      if (paymentStatus.isNotEmpty) {
        parts.add('payment status is $paymentStatus');
      }

      await _sendSpeakToAgent('${parts.join(', ')}.');
      return;
    }

    try {
      final snap = await FutureBookingService.futureBookingsRef.doc(bookingId).get();
      if (!snap.exists) {
        await _sendSpeakToAgent(
          'I could not find that booking. Please confirm the booking ID.',
        );
        return;
      }
      final data = snap.data() ?? <String, dynamic>{};
      final status = (data['status'] ?? '').toString().trim();
      final scheduledDate = (data['scheduled_date'] ?? '').toString().trim();
      final scheduledTime = (data['scheduled_time'] ?? '').toString().trim();
      final paymentStatus = (data['payment_status'] ?? '').toString().trim();
      final artisanConfirmed = (data['artisan_confirmed'] ?? '').toString().trim();

      final parts = <String>[];
      parts.add('Booking status is ${status.isNotEmpty ? status : 'unknown'}');
      if (scheduledDate.isNotEmpty || scheduledTime.isNotEmpty) {
        parts.add('scheduled for ${scheduledDate.isNotEmpty ? scheduledDate : 'a date to be confirmed'}'
            '${scheduledTime.isNotEmpty ? ' at $scheduledTime' : ''}');
      }
      if (artisanConfirmed.isNotEmpty) {
        parts.add('artisan confirmation is $artisanConfirmed');
      }
      if (paymentStatus.isNotEmpty) {
        parts.add('payment status is $paymentStatus');
      }

      await _sendSpeakToAgent('${parts.join(', ')}.');
    } catch (e) {
      await _sendSpeakToAgent('Sorry — I could not load that booking right now.');
      Get.snackbar(_assistantName, 'Could not load booking status: $e',
          backgroundColor: Colors.red, colorText: Colors.white);
    }
  }

  Future<void> _cancelBookingFromPayload(dynamic payload) async {
    final bookingId = _bookingIdFromPayload(payload);
    if (bookingId.isEmpty) {
      Get.snackbar(_assistantName, 'Missing booking ID to cancel.',
          backgroundColor: Colors.orange, colorText: Colors.white);
      await _sendSpeakToAgent('Please tell me the booking ID to cancel.');
      return;
    }

    final map = payload is Map
        ? payload.map((k, v) => MapEntry(k.toString(), v))
        : <String, dynamic>{};
    final reason = (map['reason'] ??
        map['cancel_reason'] ??
        map['additional_notes'] ??
        'client_cancelled')
        .toString()
        .trim();

    final okToProceed = await _confirmUiAction(
      title: 'Cancel booking?',
      message:
          'Cancel booking $bookingId now? If a wallet payment was already deducted, it will be refunded automatically when applicable.',
      confirmText: 'Cancel booking',
    );
    if (!okToProceed) return;

    try {
      final backend = await _tryExecuteAssistantAction(
        action: 'cancel_booking',
        payload: {
          'booking_id': bookingId,
          'reason': reason.isEmpty ? 'client_cancelled' : reason,
        },
      );
      final ok = backend != null && backend['success'] == true;
      if (ok) {
        Get.snackbar(_assistantName, 'Booking cancelled',
            backgroundColor: Colors.green, colorText: Colors.white);
        await _sendSpeakToAgent('Done — I cancelled that booking.');
      } else {
        Get.snackbar(_assistantName, 'Could not cancel booking',
            backgroundColor: Colors.red, colorText: Colors.white);
        await _sendSpeakToAgent(
            'Sorry — I could not cancel that booking right now. Please try again, or cancel from the booking screen.');
      }
    } catch (e) {
      Get.snackbar(_assistantName, 'Cancel failed: $e',
          backgroundColor: Colors.red, colorText: Colors.white);
      await _sendSpeakToAgent('Sorry — cancelling failed.');
    }
  }

  Future<void> _rescheduleBookingFromPayload(dynamic payload) async {
    final bookingId = _bookingIdFromPayload(payload);
    if (bookingId.isEmpty) {
      Get.snackbar(_assistantName, 'Missing booking ID to reschedule.',
          backgroundColor: Colors.orange, colorText: Colors.white);
      await _sendSpeakToAgent('Please tell me the booking ID to reschedule.');
      return;
    }

    final map = payload is Map
        ? payload.map((k, v) => MapEntry(k.toString(), v))
        : <String, dynamic>{};
    final date = (map['scheduled_date'] ?? map['scheduledDate'] ?? '')
        .toString()
        .trim();
    final time = (map['scheduled_time'] ?? map['scheduledTime'] ?? '')
        .toString()
        .trim();
    if (date.isEmpty || time.isEmpty) {
      Get.snackbar(_assistantName, 'Missing new date/time for reschedule.',
          backgroundColor: Colors.orange, colorText: Colors.white);
      await _sendSpeakToAgent('Please tell me the new date and time.');
      return;
    }

    final okToProceed = await _confirmUiAction(
      title: 'Reschedule booking?',
      message: 'Reschedule booking $bookingId to $date at $time?',
      confirmText: 'Reschedule',
    );
    if (!okToProceed) return;

    try {
      final backend = await _tryExecuteAssistantAction(
        action: 'reschedule_booking',
        payload: {
          'booking_id': bookingId,
          'scheduled_date': date,
          'scheduled_time': time,
          'reason': 'voice_assistant',
        },
      );
      final ok = backend != null && backend['success'] == true;
      if (ok) {
        Get.snackbar(_assistantName, 'Booking rescheduled',
            backgroundColor: Colors.green, colorText: Colors.white);
        await _sendSpeakToAgent('Done — I rescheduled your booking.');
      } else {
        Get.snackbar(_assistantName, 'Could not reschedule booking',
            backgroundColor: Colors.red, colorText: Colors.white);
        await _sendSpeakToAgent(
            'Sorry — I could not reschedule that booking right now. Please try again, or reschedule from the booking screen.');
      }
    } catch (e) {
      Get.snackbar(_assistantName, 'Reschedule failed: $e',
          backgroundColor: Colors.red, colorText: Colors.white);
      await _sendSpeakToAgent('Sorry — rescheduling failed.');
    }
  }

  Future<void> _markBookingInProgressFromPayload(dynamic payload) async {
    if (widget.role.toLowerCase().trim() != 'artisan') {
      Get.snackbar(_assistantName, 'This action is for artisans only.',
          backgroundColor: Colors.orange, colorText: Colors.white);
      await _sendSpeakToAgent('This action is only available for artisans.');
      return;
    }

    final bookingId = _bookingIdFromPayload(payload);
    if (bookingId.isEmpty) {
      Get.snackbar(_assistantName, 'Missing booking ID.',
          backgroundColor: Colors.orange, colorText: Colors.white);
      await _sendSpeakToAgent('Please tell me the booking ID.');
      return;
    }

    final okToProceed = await _confirmUiAction(
      title: 'Mark in progress?',
      message: 'Mark booking $bookingId as in progress now?',
      confirmText: 'Mark in progress',
    );
    if (!okToProceed) return;

    final backend = await _tryExecuteAssistantAction(
      action: 'mark_booking_in_progress',
      payload: {'booking_id': bookingId},
    );
    final ok = backend != null && backend['success'] == true;
    if (ok) {
      Get.snackbar(_assistantName, 'Marked as in progress',
          backgroundColor: Colors.green, colorText: Colors.white);
      await _sendSpeakToAgent('Done — booking is now in progress.');
    } else {
      Get.snackbar(_assistantName, 'Could not update booking',
          backgroundColor: Colors.red, colorText: Colors.white);
      await _sendSpeakToAgent(
          'Sorry — I could not update that booking right now. Please try again, or update it from your appointments screen.');
    }
  }

  Future<void> _artisanCancelAndReassignFromPayload(dynamic payload) async {
    if (widget.role.toLowerCase().trim() != 'artisan') {
      Get.snackbar(_assistantName, 'This action is for artisans only.',
          backgroundColor: Colors.orange, colorText: Colors.white);
      await _sendSpeakToAgent('This action is only available for artisans.');
      return;
    }

    final bookingId = _bookingIdFromPayload(payload);
    if (bookingId.isEmpty) {
      Get.snackbar(_assistantName, 'Missing booking ID.',
          backgroundColor: Colors.orange, colorText: Colors.white);
      await _sendSpeakToAgent('Please tell me the booking ID.');
      return;
    }

    final map = payload is Map
        ? payload.map((k, v) => MapEntry(k.toString(), v))
        : <String, dynamic>{};
    final reason = (map['reason'] ??
        map['cancel_reason'] ??
        map['additional_notes'] ??
        'artisan_cancelled')
        .toString()
        .trim();

    final okToProceed = await _confirmUiAction(
      title: 'Cancel & reassign?',
      message:
          'Cancel this appointment and reassign booking $bookingId to another artisan?',
      confirmText: 'Cancel & reassign',
    );
    if (!okToProceed) return;

    final backend = await _tryExecuteAssistantAction(
      action: 'artisan_cancel_and_reassign',
      payload: {
        'booking_id': bookingId,
        'reason': reason.isEmpty ? 'artisan_cancelled' : reason,
      },
    );
    final ok = backend?['success'] == true;
    final result = backend?['result'];
    final reassignment = (result is Map ? (result['reassignment'] ?? '') : '')
        .toString()
        .trim()
        .toLowerCase();

    if (ok && reassignment == 'auto_assigned') {
      Get.snackbar(_assistantName, 'Reassigned automatically',
          backgroundColor: Colors.green, colorText: Colors.white);
      await _sendSpeakToAgent(
          'Done — I reassigned the booking to another available artisan. They will confirm shortly.');
    } else if (ok) {
      Get.snackbar(_assistantName, 'Reassignment requested',
          backgroundColor: Colors.green, colorText: Colors.white);
      await _sendSpeakToAgent(
          'Done — I requested reassignment. If no nearby artisan was available, an admin will assign one soon.');
    } else {
      Get.snackbar(_assistantName, 'Could not request reassignment',
          backgroundColor: Colors.red, colorText: Colors.white);
      await _sendSpeakToAgent(
          'Sorry — I could not request reassignment right now. Please contact support or try again.');
    }
  }

  Future<void> _reassignBookingFromPayload(dynamic payload) async {
    // Role gating: allow artisan/admin workflows. Clients can request, but we
    // keep it as a controlled, confirm-before-write action.
    final bookingId = _bookingIdFromPayload(payload);
    if (bookingId.isEmpty) {
      Get.snackbar(_assistantName, 'Missing booking ID.',
          backgroundColor: Colors.orange, colorText: Colors.white);
      await _sendSpeakToAgent('Please tell me the booking ID.');
      return;
    }

    final okToProceed = await _confirmUiAction(
      title: 'Reassign booking?',
      message:
          'Reassign booking $bookingId to another available artisan (if possible)?',
      confirmText: 'Reassign',
    );
    if (!okToProceed) return;

    final backend = await _tryExecuteAssistantAction(
      action: 'reassign_booking',
      payload: {'booking_id': bookingId, 'reason': 'voice_assistant'},
    );

    final ok = backend?['success'] == true;
    final result = backend?['result'];
    final reassignment = (result is Map ? (result['reassignment'] ?? '') : '')
        .toString()
        .trim()
        .toLowerCase();

    if (ok && reassignment == 'auto_assigned') {
      Get.snackbar(_assistantName, 'Reassigned automatically',
          backgroundColor: Colors.green, colorText: Colors.white);
      await _sendSpeakToAgent(
          'Done — I reassigned the booking to another available artisan. They will confirm shortly.');
    } else if (ok) {
      Get.snackbar(_assistantName, 'Reassignment requested',
          backgroundColor: Colors.green, colorText: Colors.white);
      await _sendSpeakToAgent(
          'Done — I requested reassignment. If no nearby artisan was available, an admin will assign one soon.');
    } else {
      Get.snackbar(_assistantName, 'Could not request reassignment',
          backgroundColor: Colors.red, colorText: Colors.white);
      await _sendSpeakToAgent(
          'Sorry — I could not request reassignment right now. Please contact support or try again.');
    }
  }

  Future<void> _handlePrivilegedActionStub({
    required String action,
    required dynamic payload,
  }) async {
    final role = widget.role.toLowerCase().trim();
    if (role != 'admin') {
      Get.snackbar(_assistantName, 'This action requires admin access.',
          backgroundColor: Colors.orange, colorText: Colors.white);
      await _sendSpeakToAgent(
        'That action requires admin access. I can help you contact support or open the relevant screen.',
      );
      return;
    }

    // Admin tooling is implemented in the admin app; this client app only
    // exposes navigation + booking tools.
    Get.snackbar(_assistantName, 'Admin action not available in this app.',
        backgroundColor: Colors.orange, colorText: Colors.white);
    await _sendSpeakToAgent(
      'Admin actions are not available in this app. Please use the admin app to complete that action.',
    );
  }

  Future<void> _callAssignedArtisanFromPayload(dynamic payload) async {
    if (!mounted) return;

    final map = payload is Map
        ? payload.map((k, v) => MapEntry(k.toString(), v))
        : <String, dynamic>{};

    String artisanId =
        (map['artisan_id'] ?? map['artisanId'] ?? '').toString().trim();
    artisanId = artisanId.isNotEmpty
        ? artisanId
        : (map['service_provider_id'] ?? map['serviceProviderId'] ?? '')
            .toString()
            .trim();
    if (artisanId.isEmpty) {
      artisanId = _lastAssignedArtisanId.trim();
    }

    String phone = (map['phone'] ??
            map['phone_number'] ??
            map['phoneNumber'] ??
            map['contact'] ??
            '')
        .toString()
        .trim();

    if (phone.isEmpty && artisanId.isNotEmpty) {
      try {
        // Try doc(id) first, then uid/id fields.
        final direct = await FirebaseService.providerRef.doc(artisanId).get();
        Map<String, dynamic>? data;
        if (direct.exists) {
          data = direct.data();
        } else {
          QuerySnapshot<Map<String, dynamic>>? snap;
          try {
            snap = await FirebaseService.providerRef
                .where('uid', isEqualTo: artisanId)
                .limit(1)
                .get();
          } catch (_) {
            snap = null;
          }
          if (snap != null && snap.docs.isNotEmpty) {
            data = snap.docs.first.data();
          }
          if (data == null) {
            try {
              final snap2 = await FirebaseService.providerRef
                  .where('id', isEqualTo: artisanId)
                  .limit(1)
                  .get();
              if (snap2.docs.isNotEmpty) data = snap2.docs.first.data();
            } catch (_) {}
          }
        }

        if (data != null) {
          for (final k in <String>[
            'contact',
            'phone',
            'phone_number',
            'phoneNumber',
            'mobile',
            'mobileNumber',
            'tel',
          ]) {
            final v = (data[k] ?? '').toString().trim();
            if (v.isNotEmpty) {
              phone = v;
              break;
            }
          }
        }
      } catch (_) {
        // ignore
      }
    }

    if (phone.isEmpty) {
      final hint = _lastCreatedBookingId.trim().isNotEmpty
          ? 'No phone found for the assigned artisan. Open the booking (ID: $_lastCreatedBookingId) to view contact details.'
          : 'No phone found for the assigned artisan. Please open the booking to view contact details.';
      Get.snackbar(_assistantName, hint,
          backgroundColor: Colors.orange, colorText: Colors.white);
      return;
    }

    try {
      await FlutterPhoneDirectCaller.callNumber(phone);
      Get.snackbar(_assistantName, 'Calling artisan now...',
          backgroundColor: Colors.green, colorText: Colors.white);
    } catch (e) {
      Get.snackbar(_assistantName, 'Could not start call: $e',
          backgroundColor: Colors.red, colorText: Colors.white);
    }
  }

  Future<void> _respondToRequest({
    required String? accept,
    required dynamic payload,
  }) async {
    if (widget.role.toLowerCase().trim() != 'artisan') {
      Get.snackbar(_assistantName, 'This action is for artisans only.',
          backgroundColor: Colors.orange, colorText: Colors.white);
      return;
    }

    if (!Get.isRegistered<ServiceProviderController>()) {
      Get.snackbar(
          _assistantName, 'Artisan controller not ready. Open dashboard first.',
          backgroundColor: Colors.red, colorText: Colors.white);
      return;
    }

    final sp = Get.find<ServiceProviderController>();

    final map = payload is Map
        ? payload.map((k, v) => MapEntry(k.toString(), v))
        : <String, dynamic>{};

    final requestedAccept =
        (map['accept'] ?? map['decision'] ?? '').toString().trim();
    final effectiveAccept = (accept ?? requestedAccept).trim();
    final requestId = (map['request_id'] ?? map['id'] ?? '').toString().trim();

    if (effectiveAccept != '1' && effectiveAccept != '0') {
      Get.snackbar(_assistantName, 'Missing decision: accept or reject?',
          backgroundColor: Colors.orange, colorText: Colors.white);
      return;
    }

    TaskManagementModel? req;
    if (requestId.isNotEmpty) {
      for (final r in sp.requestList) {
        if ((r.id ?? '').toString().trim() == requestId) {
          req = r;
          break;
        }
      }
    } else {
      for (final r in sp.requestList) {
        if (((r.accept ?? '').toString().trim()).isEmpty) {
          req = r;
          break;
        }
      }
    }

    if (req == null) {
      Get.snackbar(_assistantName, 'No pending request found.',
          backgroundColor: Colors.orange, colorText: Colors.white);
      return;
    }

    final id = (req.id ?? '').toString().trim();
    final to = (req.userId ?? '').toString().trim();
    final from = (req.serviceProviderId ?? '').toString().trim().isNotEmpty
        ? (req.serviceProviderId ?? '').toString().trim()
        : widget.providerListenerId.trim();
    final taskId = (req.taskId ?? '').toString().trim();

    if (id.isEmpty || to.isEmpty || from.isEmpty) {
      Get.snackbar(_assistantName,
          'Request data incomplete; open Requests and try again.',
          backgroundColor: Colors.red, colorText: Colors.white);
      return;
    }

    try {
      await sp.responseToRequest(
        id: id,
        accept: effectiveAccept,
        to: to,
        from: from,
        taskId: taskId,
      );
    } catch (e) {
      Get.snackbar(_assistantName, 'Could not update request: $e',
          backgroundColor: Colors.red, colorText: Colors.white);
      rethrow;
    }
  }

  Future<void> _openFutureBookings() async {
    try {
      Get.to(
        () => const FutureBookingsListScreen(),
        transition: Transition.fadeIn,
      );
      await _sendSpeakToAgent('Opening your future bookings now.');
    } catch (e) {
      Get.snackbar(_assistantName, 'Could not open future bookings: $e',
          backgroundColor: Colors.red, colorText: Colors.white);
      await _sendSpeakToAgent('Sorry — I could not open future bookings.');
    }
  }

  Future<void> _openBookingsTab() async {
    try {
      // This app may not be using AppController.currentIndex for navigation.
      // Always navigate directly so the user sees the bookings screen.
      Get.to(() => const booking(), transition: Transition.fadeIn);
      await _sendSpeakToAgent('Opening your current bookings now.');
    } catch (e) {
      Get.snackbar(_assistantName, 'Could not open bookings: $e',
          backgroundColor: Colors.red, colorText: Colors.white);
      await _sendSpeakToAgent('Sorry — I could not open your bookings.');
    }
  }

  Future<void> _openArtisanRequests() async {
    if (widget.role.toLowerCase().trim() != 'artisan') {
      Get.snackbar(_assistantName, 'This action is for artisans only.',
          backgroundColor: Colors.orange, colorText: Colors.white);
      return;
    }
    if (widget.providerDoc == null) {
      Get.snackbar(
          _assistantName, 'Could not open requests: missing artisan profile.',
          backgroundColor: Colors.red, colorText: Colors.white);
      return;
    }
    try {
      Get.to(
        () => ServiceProviderRequestScreen(doc: widget.providerDoc),
        transition: Transition.fadeIn,
      );
    } catch (e) {
      Get.snackbar(_assistantName, 'Could not open requests: $e',
          backgroundColor: Colors.red, colorText: Colors.white);
    }
  }

  Future<void> _openArtisanAppointments() async {
    if (widget.role.toLowerCase().trim() != 'artisan') {
      Get.snackbar(_assistantName, 'This action is for artisans only.',
          backgroundColor: Colors.orange, colorText: Colors.white);
      return;
    }
    final id = widget.providerListenerId.trim();
    if (id.isEmpty) {
      Get.snackbar(
          _assistantName, 'Could not open appointments: missing artisan id.',
          backgroundColor: Colors.red, colorText: Colors.white);
      return;
    }
    try {
      Get.to(
        () => ArtisanAppointmentsScreen(artisanIds: <String>[id]),
        transition: Transition.fadeIn,
      );
    } catch (e) {
      Get.snackbar(_assistantName, 'Could not open appointments: $e',
          backgroundColor: Colors.red, colorText: Colors.white);
    }
  }

  Future<void> _openArtisanWallet() async {
    if (widget.role.toLowerCase().trim() != 'artisan') {
      Get.snackbar(_assistantName, 'This action is for artisans only.',
          backgroundColor: Colors.orange, colorText: Colors.white);
      return;
    }

    String walletId = '';
    try {
      final dynamic d = widget.providerDoc;
      final dynamic v = d['docId'];
      walletId = (v ?? '').toString().trim();
    } catch (_) {
      walletId = '';
    }

    if (walletId.isEmpty) {
      // Fallback to providerListenerId if docId field is absent.
      walletId = widget.providerListenerId.trim();
    }

    if (walletId.isEmpty) {
      Get.snackbar(_assistantName, 'Could not open wallet: missing artisan id.',
          backgroundColor: Colors.red, colorText: Colors.white);
      return;
    }

    try {
      Get.to(
        () => WalletPage(id: walletId),
        transition: Transition.fadeIn,
      );
    } catch (e) {
      Get.snackbar(_assistantName, 'Could not open wallet: $e',
          backgroundColor: Colors.red, colorText: Colors.white);
    }
  }

  Future<List<String>> _resolveCategoryIdCandidatesByName(
    String categoryName,
  ) async {
    try {
      final catSnap = await FirebaseService.categoryRef
          .where('status', isEqualTo: 'publish')
          .get();

      String normalize(String s) {
        return s
            .toLowerCase()
            .trim()
            .replaceAll(RegExp(r'[^a-z\s]'), ' ')
            .replaceAll(RegExp(r'\s+'), ' ')
            .trim();
      }

      final raw = categoryName.toLowerCase().trim();
      final normalizedInput = normalize(categoryName);

      // Map common client symptom words/phrases to service categories.
      const Map<String, String> symptomToCategory = {
        // Electrical
        'electricity': 'electrical',
        'electric': 'electrical',
        'power': 'electrical',
        'lights': 'electrical',
        'light': 'electrical',
        'plug': 'electrical',
        'socket': 'electrical',
        'wiring': 'electrical',
        'wire': 'electrical',
        'breaker': 'electrical',
        'trip': 'electrical',
        'tripping': 'electrical',
        'circuit': 'electrical',
        'outlet': 'electrical',
        'switch': 'electrical',
        'fuse': 'electrical',
        'fusebox': 'electrical',
        'panel': 'electrical',
        'generator': 'electrical',
        'inverter': 'electrical',
        'electrician': 'electrical',
        'ceiling fan': 'electrical',

        // Plumbing
        'plumber': 'plumbing',
        'plumbing': 'plumbing',
        'tap': 'plumbing',
        'taps': 'plumbing',
        'faucet': 'plumbing',
        'leak': 'plumbing',
        'leaking': 'plumbing',
        'leaky': 'plumbing',
        'pipe': 'plumbing',
        'pipes': 'plumbing',
        'toilet': 'plumbing',
        'geyser': 'plumbing',
        'drain': 'plumbing',
        'drainage': 'plumbing',
        'blocked': 'plumbing',
        'unblock': 'plumbing',
        'clogged': 'plumbing',
        'sewer': 'plumbing',
        'sewage': 'plumbing',
        'water heater': 'plumbing',
        'burst': 'plumbing',
        'basin': 'plumbing',
        'sink': 'plumbing',
        'shower': 'plumbing',
        'bath': 'plumbing',
        'bathtub': 'plumbing',
        'cistern': 'plumbing',
        'valve': 'plumbing',
        'stopcock': 'plumbing',
        'water pressure': 'plumbing',
        'garbage disposal': 'plumbing',

        // Painting
        'paint': 'painting',
        'painting': 'painting',
        'repaint': 'painting',
        'painter': 'painting',
        'wall paint': 'painting',
        'ceiling paint': 'painting',
        'stain': 'painting',
        'staining': 'painting',
        'wallpaper': 'painting',
        'primer': 'painting',
        'varnish': 'painting',
        'coating': 'painting',

        // Cleaning
        'clean': 'cleaning',
        'cleaning': 'cleaning',
        'dirty': 'cleaning',
        'deep clean': 'cleaning',
        'carpet clean': 'cleaning',
        'window clean': 'cleaning',
        'pressure wash': 'cleaning',
        'powerwash': 'cleaning',
        'sanitize': 'cleaning',
        'disinfect': 'cleaning',
        'maid': 'cleaning',
        'domestic': 'cleaning',
        'housekeeping': 'cleaning',
        'move out clean': 'cleaning',
        'move in clean': 'cleaning',
        'post construction clean': 'cleaning',

        // Tiling
        'tile': 'tiling',
        'tiling': 'tiling',
        'tiles': 'tiling',
        'retile': 'tiling',
        'grout': 'tiling',
        'grouting': 'tiling',

        // Roofing
        'roof': 'roofing',
        'roofing': 'roofing',
        'gutter': 'roofing',
        'gutters': 'roofing',
        'shingle': 'roofing',
        'shingles': 'roofing',
        'skylight': 'roofing',
        'roof leak': 'roofing',
        'waterproofing': 'roofing',
        'flashing': 'roofing',

        // HVAC / Air Conditioning
        'aircon': 'air conditioning',
        'air con': 'air conditioning',
        'air conditioner': 'air conditioning',
        'air conditioning': 'air conditioning',
        'ac': 'air conditioning',
        'hvac': 'air conditioning',
        'furnace': 'air conditioning',
        'heating': 'air conditioning',
        'ventilation': 'air conditioning',
        'thermostat': 'air conditioning',
        'duct': 'air conditioning',
        'ducting': 'air conditioning',
        'cooling': 'air conditioning',

        // Carpentry
        'carpenter': 'carpentry',
        'carpentry': 'carpentry',
        'wood': 'carpentry',
        'wooden': 'carpentry',
        'door': 'carpentry',
        'doors': 'carpentry',
        'cabinet': 'carpentry',
        'cabinets': 'carpentry',
        'cupboard': 'carpentry',
        'cupboards': 'carpentry',
        'shelf': 'carpentry',
        'shelves': 'carpentry',
        'shelving': 'carpentry',
        'deck': 'carpentry',
        'decking': 'carpentry',
        'furniture': 'carpentry',
        'wardrobe': 'carpentry',
        'trim': 'carpentry',
        'skirting': 'carpentry',
        'staircase': 'carpentry',
        'stairs': 'carpentry',
        'window frame': 'carpentry',

        // Flooring
        'floor': 'flooring',
        'flooring': 'flooring',
        'hardwood': 'flooring',
        'laminate': 'flooring',
        'vinyl': 'flooring',
        'carpet': 'flooring',
        'parquet': 'flooring',
        'subfloor': 'flooring',
        'baseboard': 'flooring',
        'sanding': 'flooring',
        'refinish': 'flooring',

        // Landscaping
        'garden': 'landscaping',
        'gardener': 'landscaping',
        'gardening': 'landscaping',
        'landscaping': 'landscaping',
        'lawn': 'landscaping',
        'mowing': 'landscaping',
        'tree': 'landscaping',
        'trees': 'landscaping',
        'trimming': 'landscaping',
        'hedge': 'landscaping',
        'hedges': 'landscaping',
        'irrigation': 'landscaping',
        'sprinkler': 'landscaping',
        'fence': 'landscaping',
        'fencing': 'landscaping',
        'patio': 'landscaping',
        'paving': 'landscaping',
        'sod': 'landscaping',

        // Car Detailing
        'car wash': 'car detailing',
        'car detailing': 'car detailing',
        'car detail': 'car detailing',
        'vehicle': 'car detailing',
        'car clean': 'car detailing',
        'car polish': 'car detailing',
        'car valet': 'car detailing',
        'valet': 'car detailing',
        'auto detail': 'car detailing',
        'car interior': 'car detailing',

        // Solar Energy Solutions
        'solar': 'solar energy solutions',
        'solar panel': 'solar energy solutions',
        'solar panels': 'solar energy solutions',
        'solar geyser': 'solar energy solutions',
        'pv solar': 'solar energy solutions',
        'photovoltaic': 'solar energy solutions',
        'solar installation': 'solar energy solutions',
        'solar maintenance': 'solar energy solutions',
        'solar energy': 'solar energy solutions',

        // General Maintenance
        'maintenance': 'general maintenance',
        'general maintenance': 'general maintenance',
        'handyman': 'general maintenance',
        'odd job': 'general maintenance',
        'odd jobs': 'general maintenance',
        'emergency': 'general maintenance',
        // Compound phrases for common service requests
        'blocked toilet': 'plumbing',
        'blocked drain': 'plumbing',
        'blocked sink': 'plumbing',
        'blocked pipe': 'plumbing',
        'blocked sewer': 'plumbing',
        'unblock toilet': 'plumbing',
        'unblock drain': 'plumbing',
        'clogged toilet': 'plumbing',
        'clogged drain': 'plumbing',
        'leaking tap': 'plumbing',
        'leaking pipe': 'plumbing',
        'leaking geyser': 'plumbing',
        'burst pipe': 'plumbing',
        'burst geyser': 'plumbing',
        'tripping power': 'electrical',
        'tripping electricity': 'electrical',
        'no power': 'electrical',
        'no electricity': 'electrical',
        'broken door': 'carpentry',
        'broken window': 'carpentry',
        'leaking roof': 'roofing',
      };

      // Sort entries by key length descending so multi-word phrases
      // (e.g. "blocked toilet") match before single words (e.g. "blocked").
      final sortedEntries = symptomToCategory.entries.toList()
        ..sort((a, b) => b.key.length.compareTo(a.key.length));

      String inferred = normalizedInput;
      for (final entry in sortedEntries) {
        if (normalizedInput == entry.key ||
            normalizedInput.contains(entry.key)) {
          inferred = entry.value;
          print('[ai_cat] symptom "${entry.key}" → category "${entry.value}" from input "$normalizedInput"');
          break;
        }
      }

      final candidates = <String>{
        normalize(raw),
        normalizedInput,
        normalize(inferred),
      };

      if (candidates.contains('electrical')) candidates.addAll({'electrician', 'electrics'});
      if (candidates.contains('plumbing')) candidates.addAll({'plumber', 'plumbers'});
      if (candidates.contains('painting')) candidates.addAll({'painter', 'painters'});
      if (candidates.contains('cleaning')) candidates.addAll({'cleaner', 'cleaners'});
      if (candidates.contains('carpentry')) candidates.addAll({'carpenter', 'carpenters'});
      if (candidates.contains('roofing')) candidates.addAll({'roofer', 'roofers'});
      if (candidates.contains('flooring')) candidates.addAll({'floor', 'floors'});
      if (candidates.contains('landscaping')) candidates.addAll({'landscaper', 'gardener', 'garden'});
      if (candidates.contains('tiling')) candidates.addAll({'tiler', 'tilers'});
      if (candidates.contains('air conditioning')) candidates.addAll({'hvac', 'aircon', 'ac'});
      if (candidates.contains('car detailing')) candidates.addAll({'car wash', 'valet'});
      if (candidates.contains('solar energy solutions')) candidates.addAll({'solar', 'solar energy'});
      if (candidates.contains('general maintenance')) candidates.addAll({'maintenance', 'handyman'});

      List<String> idsFromDoc(QueryDocumentSnapshot<Map<String, dynamic>> doc) {
        final data = doc.data();
        final stored = (data['id'] ?? '').toString().trim();
        final docId = doc.id.toString().trim();
        final out = <String>[];
        if (stored.isNotEmpty) out.add(stored);
        if (docId.isNotEmpty && docId != stored) out.add(docId);
        return out.toSet().toList();
      }

      // Exact match first.
      for (final doc in catSnap.docs) {
        final data = doc.data();
        final name = (data['name'] ?? '').toString();
        final n = normalize(name);
        if (candidates.contains(n)) {
          final ids = idsFromDoc(doc);
          if (ids.isNotEmpty) {
            print('[ai_cat] matched name="$name" ids=${ids.join('|')}');
            return ids;
          }
        }
      }

      // Partial match fallback.
      for (final doc in catSnap.docs) {
        final data = doc.data();
        final name = (data['name'] ?? '').toString();
        final n = normalize(name);
        for (final c in candidates) {
          if (c.isEmpty) continue;
          if (n.contains(c) || c.contains(n)) {
            final ids = idsFromDoc(doc);
            if (ids.isNotEmpty) {
              print('[ai_cat] partial name="$name" ids=${ids.join('|')}');
              return ids;
            }
          }
        }
      }
    } catch (_) {
      // ignore
    }

    return <String>[];
  }

  Future<Map<String, dynamic>?> _resolveTaskForCategory({
    required List<String> categoryIds,
    required String taskNameHint,
  }) async {
    try {
      final ids = categoryIds
          .map((e) => e.toString().trim())
          .where((e) => e.isNotEmpty)
          .toList();
      if (ids.isEmpty) return null;

      QuerySnapshot<Map<String, dynamic>>? snap;

      Future<QuerySnapshot<Map<String, dynamic>>?> tryQuery(
        String field,
        String value,
      ) async {
        try {
          final r = await FirebaseService.taskRef
              .where('status', isEqualTo: 'publish')
              .where(field, isEqualTo: value)
              .get();
          print('[ai_task] try field=$field id=$value count=${r.docs.length}');
          return r;
        } catch (_) {
          return null;
        }
      }

      // Try the most common schema first: tasks.categoryId
      for (final id in ids) {
        final r = await tryQuery('categoryId', id);
        if (r != null && r.docs.isNotEmpty) {
          snap = r;
          break;
        }
      }

      // Fallback: some schemas use tasks.category_id
      if (snap == null || snap.docs.isEmpty) {
        for (final id in ids) {
          final r = await tryQuery('category_id', id);
          if (r != null && r.docs.isNotEmpty) {
            snap = r;
            break;
          }
        }
      }

      if (snap == null || snap.docs.isEmpty) return null;

      Map<String, dynamic> withId(
          QueryDocumentSnapshot<Map<String, dynamic>> doc) {
        final data = Map<String, dynamic>.from(doc.data());
        final existing = (data['id'] ?? '').toString().trim();
        if (existing.isEmpty) {
          final fallback = doc.id.toString().trim();
          if (fallback.isNotEmpty) data['id'] = fallback;
        }
        return data;
      }

      final hint = taskNameHint.trim().toLowerCase();

      List<String> tokens(String s) {
        final raw = s
            .toLowerCase()
            .replaceAll(RegExp(r'[^a-z0-9\s]'), ' ')
            .split(RegExp(r'\s+'))
            .map((e) => e.trim())
            .where((e) => e.isNotEmpty)
            .toList();
        // Only remove truly meaningless words; keep action words like
        // fix/repair/install as they help match task names.
        const stop = <String>{
          'a',
          'an',
          'and',
          'the',
          'to',
          'of',
          'for',
          'in',
          'on',
          'at',
          'my',
          'our',
          'i',
          'me',
          'we',
          'please',
          'need',
          'help',
          'with',
          'want',
          'would',
          'like',
          'can',
          'could',
          'get',
          'got',
          'have',
          'has',
          'had',
          'is',
          'am',
          'are',
          'was',
          'be',
          'been',
          'it',
          'its',
          'that',
          'this',
          'there',
          'do',
          'does',
          'did',
          'so',
          'but',
          'if',
          'or',
          'not',
          'no',
        };
        return raw.where((t) => !stop.contains(t)).toList();
      }

      // Synonym groups: any word in a group matches any other in that group.
      const List<Set<String>> synonymGroups = [
        // ── Plumbing ──
        {'unblock', 'unblocking', 'blocked', 'block', 'blockage', 'clogged', 'clog'},
        {'toilet', 'toilets', 'loo', 'lavatory', 'wc'},
        {'drain', 'drains', 'drainage', 'draining', 'drainpipe'},
        {'sewer', 'sewage', 'sewerage', 'sewers'},
        {'leak', 'leaking', 'leaky', 'leaks', 'leaked'},
        {'pipe', 'pipes', 'piping', 'pipeline'},
        {'tap', 'taps', 'faucet', 'faucets'},
        {'geyser', 'geysers', 'water heater', 'boiler', 'boilers'},
        {'burst', 'bursting', 'bursted', 'ruptured', 'rupture'},
        {'valve', 'valves', 'stopcock', 'stopcocks'},
        {'sink', 'sinks', 'basin', 'basins', 'washbasin'},
        {'shower', 'showers', 'showerhead'},
        {'cistern', 'cisterns', 'flush', 'flushing'},
        {'plumbing', 'plumber', 'plumbers'},

        // ── Electrical ──
        {'electrical', 'electric', 'electrician', 'electrics', 'electricity'},
        {'wiring', 'wire', 'wires', 'rewire', 'rewiring'},
        {'breaker', 'breakers', 'circuit', 'circuits', 'trip', 'tripping', 'tripped'},
        {'socket', 'sockets', 'outlet', 'outlets', 'plug', 'plugs'},
        {'switch', 'switches', 'dimmer', 'dimmers'},
        {'fuse', 'fuses', 'fusebox', 'fuseboard'},
        {'light', 'lights', 'lighting', 'lamp', 'lamps', 'bulb', 'bulbs'},
        {'panel', 'panels', 'distribution', 'db'},
        {'generator', 'generators', 'genset'},
        {'inverter', 'inverters', 'ups'},
        {'ceiling fan', 'fan', 'fans', 'extractor'},

        // ── Painting ──
        {'paint', 'painting', 'repaint', 'repainting', 'painted'},
        {'primer', 'priming', 'undercoat'},
        {'varnish', 'varnishing', 'lacquer'},
        {'stain', 'staining', 'stained', 'woodstain'},
        {'wallpaper', 'wallpapering', 'wallpapers'},
        {'coating', 'coatings', 'sealant'},
        {'wall', 'walls'},
        {'ceiling', 'ceilings'},
        {'painter', 'painters'},

        // ── Carpentry ──
        {'carpenter', 'carpenters', 'carpentry', 'woodwork', 'woodworking'},
        {'door', 'doors', 'doorframe', 'doorframes'},
        {'cabinet', 'cabinets', 'cupboard', 'cupboards'},
        {'shelf', 'shelves', 'shelving'},
        {'furniture', 'furnishings'},
        {'deck', 'decking', 'decks'},
        {'wardrobe', 'wardrobes', 'closet', 'closets'},
        {'staircase', 'staircases', 'stairs', 'stair', 'banister', 'banisters'},
        {'skirting', 'baseboard', 'baseboards'},
        {'trim', 'trimming', 'moulding', 'molding'},
        {'window frame', 'window frames', 'windowsill'},

        // ── Tiling ──
        {'tile', 'tiling', 'tiles', 'retile', 'retiling', 'tiled'},
        {'grout', 'grouting', 'regrouting', 'regrout'},
        {'mosaic', 'mosaics'},

        // ── Roofing ──
        {'roof', 'roofing', 'roofs', 'rooftop'},
        {'gutter', 'gutters', 'guttering', 'downpipe', 'downpipes'},
        {'shingle', 'shingles'},
        {'skylight', 'skylights'},
        {'flashing', 'flashings'},
        {'waterproof', 'waterproofing', 'damp', 'dampproofing'},
        {'roofer', 'roofers'},

        // ── HVAC / Air Conditioning ──
        {'aircon', 'ac', 'hvac', 'air conditioner', 'air conditioning'},
        {'furnace', 'furnaces', 'heater', 'heaters', 'heating'},
        {'ventilation', 'ventilate', 'vent', 'vents'},
        {'thermostat', 'thermostats'},
        {'duct', 'ducts', 'ducting', 'ductwork'},
        {'cooling', 'coolant', 'refrigerant'},
        {'compressor', 'compressors', 'condenser'},

        // ── Flooring ──
        {'floor', 'floors', 'flooring'},
        {'hardwood', 'timber', 'wooden'},
        {'laminate', 'laminates', 'laminated'},
        {'vinyl', 'vinyls', 'lino', 'linoleum'},
        {'carpet', 'carpets', 'carpeting', 'rug', 'rugs'},
        {'parquet', 'parquetry'},
        {'subfloor', 'subfloors', 'underfloor'},
        {'sanding', 'sand', 'sanded'},
        {'refinish', 'refinishing', 'polishing', 'polish'},

        // ── Landscaping ──
        {'garden', 'gardens', 'gardening', 'gardener', 'gardeners'},
        {'landscaping', 'landscape', 'landscaper', 'landscapers'},
        {'lawn', 'lawns', 'grass'},
        {'mow', 'mowing', 'mowed', 'mower'},
        {'tree', 'trees', 'shrub', 'shrubs', 'bush', 'bushes'},
        {'hedge', 'hedges', 'hedging'},
        {'irrigation', 'irrigate', 'sprinkler', 'sprinklers'},
        {'fence', 'fences', 'fencing'},
        {'patio', 'patios', 'paving', 'pavers', 'paved'},
        {'sod', 'turf', 'turfing'},

        // ── Cleaning ──
        {'clean', 'cleaning', 'cleaner', 'cleaners'},
        {'deep clean', 'deep cleaning', 'thorough clean'},
        {'pressure wash', 'pressure washing', 'powerwash', 'powerwashing'},
        {'sanitize', 'sanitizing', 'sanitise', 'disinfect', 'disinfecting'},
        {'housekeeping', 'housekeeper', 'domestic', 'maid'},

        // ── Car Detailing ──
        {'car wash', 'carwash', 'car cleaning'},
        {'car detailing', 'car detail', 'auto detailing', 'auto detail'},
        {'polish', 'polishing', 'buffing', 'buff'},
        {'valet', 'valeting'},
        {'wax', 'waxing'},

        // ── Solar Energy Solutions ──
        {'solar', 'solar panel', 'solar panels', 'photovoltaic', 'pv'},
        {'solar geyser', 'solar heater', 'solar water heater'},
        {'battery', 'batteries', 'powerwall', 'energy storage'},

        // ── General Maintenance ──
        {'maintenance', 'maintain', 'upkeep'},
        {'handyman', 'handymen', 'odd job', 'odd jobs'},

        // ── Common action synonyms ──
        {'install', 'installation', 'installing', 'setup', 'set up'},
        {'repair', 'repairing', 'repairs', 'mend', 'mending'},
        {'replace', 'replacement', 'replacing', 'swap', 'swapping'},
        {'fix', 'fixing', 'fixed'},
        {'remove', 'removal', 'removing', 'demolish', 'demolition'},
        {'inspect', 'inspection', 'inspecting', 'check', 'checking'},
        {'upgrade', 'upgrading', 'upgrades'},
        {'service', 'servicing', 'serviced'},
        {'assembly', 'assemble', 'assembling'},
      ];

      /// Check if two tokens are synonyms of each other.
      bool areSynonyms(String a, String b) {
        if (a == b) return true;
        for (final group in synonymGroups) {
          if (group.contains(a) && group.contains(b)) return true;
        }
        // Stem-like: one starts with the other (min 4 chars).
        if (a.length >= 4 && b.length >= 4) {
          if (a.startsWith(b) || b.startsWith(a)) return true;
        }
        return false;
      }

      int scoreTask(String name, String hintLower, List<String> hintTokens) {
        final n = name.toLowerCase().trim();
        if (hintLower.isNotEmpty && n == hintLower) return 100;
        if (hintLower.isNotEmpty && n.contains(hintLower)) return 90;
        if (hintLower.isNotEmpty && hintLower.contains(n) && n.length >= 4) {
          return 85;
        }

        if (hintTokens.isEmpty) return 0;
        final nameTokens = tokens(n).toSet();
        // Also include raw tokens from the name (without stop-word removal)
        // to catch meaningful words like "repair", "install", etc.
        final nameTokensRaw = n
            .replaceAll(RegExp(r'[^a-z0-9\s]'), ' ')
            .split(RegExp(r'\s+'))
            .map((e) => e.trim())
            .where((e) => e.isNotEmpty)
            .toSet();
        final allNameTokens = {...nameTokens, ...nameTokensRaw};

        int overlap = 0;
        int synonymHits = 0;
        for (final t in hintTokens) {
          if (allNameTokens.contains(t)) {
            overlap++;
          } else {
            // Check synonym/stem match against all name tokens.
            for (final nt in allNameTokens) {
              if (areSynonyms(t, nt)) {
                synonymHits++;
                break;
              }
            }
          }
        }

        // Also check hint words against raw name tokens for substring matches.
        int substringHits = 0;
        for (final t in hintTokens) {
          if (t.length < 4) continue;
          for (final nt in allNameTokens) {
            if (nt.length < 4) continue;
            if (nt.contains(t) || t.contains(nt)) {
              substringHits++;
              break;
            }
          }
        }

        // Strong intent words for common service types across ALL categories.
        final strong = <String>{
          // Plumbing
          'unblock', 'unblocking', 'blocked', 'blockage', 'clogged',
          'toilet', 'drain', 'sewer', 'sewage',
          'leak', 'leaking', 'burst', 'pipe', 'geyser',
          'tap', 'faucet', 'cistern', 'valve',
          // Electrical
          'wiring', 'rewire', 'circuit', 'breaker', 'tripping',
          'socket', 'outlet', 'fuse', 'fusebox',
          'generator', 'inverter', 'panel',
          // Painting
          'paint', 'painting', 'repaint', 'wallpaper', 'varnish', 'stain',
          // Carpentry
          'door', 'cabinet', 'cupboard', 'shelf', 'shelving',
          'deck', 'decking', 'wardrobe', 'staircase', 'furniture',
          // Tiling
          'tile', 'tiling', 'retile', 'grout', 'grouting',
          // Roofing
          'roof', 'roofing', 'gutter', 'shingle', 'skylight',
          'waterproofing', 'flashing',
          // HVAC
          'aircon', 'hvac', 'furnace', 'thermostat', 'duct',
          'ventilation', 'compressor',
          // Flooring
          'floor', 'flooring', 'hardwood', 'laminate', 'vinyl',
          'carpet', 'parquet', 'sanding', 'refinish',
          // Landscaping
          'garden', 'lawn', 'mowing', 'tree', 'hedge',
          'irrigation', 'fence', 'fencing', 'patio', 'paving',
          // Cleaning
          'deep clean', 'pressure wash', 'sanitize',
          // Car Detailing
          'car wash', 'car detailing', 'polish', 'valet',
          // Solar
          'solar', 'solar panel', 'solar geyser', 'photovoltaic',
          // General
          'emergency', 'handyman',
        };
        int strongHits = 0;
        for (final t in hintTokens) {
          if (!strong.contains(t)) continue;
          if (allNameTokens.contains(t)) {
            strongHits++;
          } else {
            for (final nt in allNameTokens) {
              if (areSynonyms(t, nt)) {
                strongHits++;
                break;
              }
            }
          }
        }

        return overlap * 10 + synonymHits * 12 + substringHits * 8 + strongHits * 15;
      }

      final hintTokens = tokens(hint);

      Map<String, dynamic>? best;
      int bestScore = -1;
      double bestCost = 0.0;
      for (final doc in snap.docs) {
        final data = withId(doc);
        final name = (data['name'] ?? '').toString();
        final s = scoreTask(name, hint, hintTokens);
        final c = _toAmount(
              data['cost'] ??
                  data['price'] ??
                  data['amount'] ??
                  data['unit_price'],
            ) ??
            0.0;

        print('[ai_task_score] name="$name" score=$s cost=$c hint="$hint"');

        if (s > bestScore) {
          best = data;
          bestScore = s;
          bestCost = c;
          continue;
        }

        // Tie-breaker: prefer priced tasks.
        if (s == bestScore && c > 0 && bestCost <= 0) {
          best = data;
          bestCost = c;
        }
      }

      print('[ai_task] Best score=$bestScore name="${best?['name']}" cost=$bestCost');

      // Minimum score threshold: if the best match scored below 10,
      // the match is too weak to trust — return null so the user can
      // manually select the correct service via the future booking workflow.
      if (bestScore >= 0 && bestScore < 10) {
        print('[ai_task] Best score ($bestScore) below threshold 10 — no confident match');
        return null;
      }
      best ??= withId(snap.docs.first);
      return best;
    } catch (e) {
      debugPrint('❌ Task resolve failed: $e');
      return null;
    }
  }

  Future<void> _createOrderBookingFromPayload(dynamic payload) async {
    final map = payload is Map
        ? payload.map((k, v) => MapEntry(k.toString(), v))
        : <String, dynamic>{};

    final categoryName =
        (map['category_name'] ?? map['categoryName'] ?? '').toString().trim();
    final description =
        (map['problem_description'] ?? map['description'] ?? '').toString();
    final notes = (map['additional_notes'] ?? map['notes'] ?? '').toString();
    String address =
        (map['service_address'] ?? map['address'] ?? '').toString();
    String lat = (map['service_lat'] ?? map['lat'] ?? '').toString();
    String lng = (map['service_lng'] ?? map['lng'] ?? '').toString();
    final scheduledDate =
        (map['scheduled_date'] ?? map['scheduledDate'] ?? '').toString().trim();
    final scheduledTime =
        (map['scheduled_time'] ?? map['scheduledTime'] ?? '').toString().trim();
    final taskNameHint =
        (map['task_name'] ?? map['taskName'] ?? '').toString().trim();
    final materialsResponsibility = (map['materials_responsibility'] ??
            map['materialsResponsibility'] ??
            'artisan')
        .toString()
        .trim();

    bool containsEmergencyIntent(String s) {
      final v = s.toLowerCase();
      if (v.isEmpty) return false;
      return v.contains('emergency') ||
          v.contains('urgent') ||
          v.contains('asap') ||
          RegExp(r'\bnow\b').hasMatch(v) ||
          v.contains('right now') ||
          v.contains('immediately');
    }

    bool isNowToken(String s) {
      final v = s.trim().toLowerCase();
      return v == 'now' || v == 'asap' || v == 'urgent' || v == 'emergency';
    }

    final emergencyFromPayload = _boolValue(
      map['is_emergency'] ?? map['isEmergency'] ?? map['emergency'],
      defaultValue: false,
    );
    final emergencyFromText = containsEmergencyIntent(
          '${map['urgency'] ?? ''} ${map['requested_time'] ?? ''}',
        ) ||
        containsEmergencyIntent(description) ||
        containsEmergencyIntent(notes) ||
        isNowToken(scheduledDate) ||
        isNowToken(scheduledTime);
    final bool isEmergency = emergencyFromPayload || emergencyFromText;

    // Voice-first flow: requirePhotos is always false.
    // Photos are optional and can be added post-booking.

    List<String> extractStringList(dynamic v) {
      if (v == null) return <String>[];
      if (v is List) {
        return v
            .where((e) => e != null)
            .map((e) => e.toString().trim())
            .where((s) => s.isNotEmpty)
            .toList();
      }
      final s = v.toString().trim();
      if (s.isEmpty) return <String>[];
      return s
          .split(',')
          .map((x) => x.trim())
          .where((x) => x.isNotEmpty)
          .toList();
    }

    final workImageUrls = extractStringList(
      map['work_image_urls'] ??
          map['workImageUrls'] ??
          map['image_urls'] ??
          map['imageUrls'] ??
          map['images'],
    );

    if (categoryName.isEmpty) {
      Get.snackbar(_assistantName, 'Could not create booking: missing category',
          backgroundColor: Colors.red, colorText: Colors.white);
      await _sendSpeakToAgent(
          'I can’t create the booking yet — the category is missing.');
      return;
    }

    AppController? app;
    if (Get.isRegistered<AppController>()) {
      app = Get.find<AppController>();
    }
    if (app == null) {
      Get.snackbar(_assistantName, 'Could not create booking: app not ready',
          backgroundColor: Colors.red, colorText: Colors.white);
      await _sendSpeakToAgent(
          'Sorry — the app is not ready yet. Please try again in a moment.');
      return;
    }
    if (app.userId.value.trim().isEmpty) {
      Get.snackbar(_assistantName, 'Please sign in to create a booking.',
          backgroundColor: Colors.red, colorText: Colors.white);
      await _sendSpeakToAgent(
          'Please sign in first, then ask me to dispatch again.');
      return;
    }

    // Ensure we have the device location for the user.
    if (app.userLat.value.trim().isEmpty || app.userLng.value.trim().isEmpty) {
      try {
        await app.getCurrentPosition(context);
      } catch (_) {}
    }
    if (app.userLat.value.trim().isEmpty || app.userLng.value.trim().isEmpty) {
      Get.snackbar(
          _assistantName, 'Please enable location to dispatch an artisan.',
          backgroundColor: Colors.red, colorText: Colors.white);
      await _sendSpeakToAgent(
          'Please enable location services so I can dispatch the nearest artisan.');
      return;
    }

    final parsedLat = double.tryParse(app.userLat.value.trim()) ?? 0.0;
    final parsedLng = double.tryParse(app.userLng.value.trim()) ?? 0.0;
    if (parsedLat == 0.0 || parsedLng == 0.0) {
      Get.snackbar(_assistantName, 'Location is not available yet. Try again.',
          backgroundColor: Colors.red, colorText: Colors.white);
      await _sendSpeakToAgent(
          'Your location is not available yet. Please wait a moment and try again.');
      return;
    }

    final categoryIds = await _resolveCategoryIdCandidatesByName(categoryName);
    if (categoryIds.isEmpty) {
      Get.snackbar(
          _assistantName, 'Could not find "$categoryName" category in the app.',
          backgroundColor: Colors.red, colorText: Colors.white);
      await _sendSpeakToAgent(
          'Sorry — I could not find that service category in the app.');
      return;
    }

    bool looksLikeCurrentLocation(String raw) {
      final s = raw.trim().toLowerCase();
      if (s.isEmpty) return true;
      return s == 'current location' ||
          s == 'my current location' ||
          s == 'my location' ||
          s == 'current' ||
          s == 'here' ||
          s == 'use current location' ||
          s.contains('current location');
    }

    Future<String> reverseGeocodeAddress({
      required String lat,
      required String lng,
    }) async {
      final dLat = double.tryParse(lat);
      final dLng = double.tryParse(lng);
      if (dLat == null || dLng == null) return '';
      try {
        final places = await placemarkFromCoordinates(dLat, dLng);
        if (places.isEmpty) return '';
        final p = places.first;
        final parts = <String?>[
          p.name,
          p.street,
          p.subLocality,
          p.locality,
          p.administrativeArea,
          p.postalCode,
          p.country,
        ].whereType<String>().map((e) => e.trim()).where((e) => e.isNotEmpty);
        return parts.join(', ');
      } catch (_) {
        return '';
      }
    }

    final rawAddress = address.trim();
    final serviceOnCurrentLocation =
        rawAddress.isEmpty || looksLikeCurrentLocation(rawAddress);

    // If service is at current location, resolve an actual address for display.
    // Dispatch uses GPS coords, but users/admin/artisans need a real address.
    if (serviceOnCurrentLocation) {
      final resolved = await reverseGeocodeAddress(
        lat: app.userLat.value,
        lng: app.userLng.value,
      );
      if (resolved.trim().isNotEmpty) {
        address = resolved;
      }

      // Ensure we don't accidentally treat a string like "current location" as a physical address.
      lat = '';
      lng = '';
    }

    // If the job is at a provided address but we did not receive coordinates,
    // try geocoding the address so "nearest" dispatch uses the correct area.
    if (!serviceOnCurrentLocation &&
        address.trim().isNotEmpty &&
        (lat.trim().isEmpty || lng.trim().isEmpty)) {
      try {
        final locations = await locationFromAddress(address);
        if (locations.isNotEmpty) {
          lat = locations.first.latitude.toString();
          lng = locations.first.longitude.toString();
          print('[geocode] Resolved "$address" -> $lat,$lng');
        }
      } catch (e) {
        print('[geocode] Failed for "$address": $e');
      }
    }

    // Voice-first flow: photos are optional.
    // Users can add photos post-booking from booking history.
    // The photo gate is completely bypassed.

    // Default schedule if AI did not provide.
    final now = DateTime.now();

    // Smart time handling: use smart defaults if not specified
    // (Don't reject after photos uploaded - just use sensible defaults)
    late String effectiveDate;
    late String effectiveTime;

    final bool missingSchedule = scheduledDate.isEmpty ||
        scheduledTime.isEmpty ||
        isNowToken(scheduledDate) ||
        isNowToken(scheduledTime);

    if (missingSchedule) {
      // If we're here after photos uploaded (workImageUrls.length >= 3),
      // use smart defaults instead of asking again (bad UX)
      if (workImageUrls.length >= 3) {
        if (isEmergency) {
          // Emergency/"now" should always be within the next hour.
          final dt = now.add(const Duration(hours: 1));
          effectiveDate = _formatDate(dt);
          final hh = dt.hour.toString().padLeft(2, '0');
          final mm = dt.minute.toString().padLeft(2, '0');
          effectiveTime = '$hh:$mm:00';
        } else {
          // Default: ASAP = today at next round hour or tomorrow 9am if late
          if (now.hour < 16) {
            // Before 4pm - schedule for today at 9am if before that, else next hour
            final roundHour = now.hour < 9 ? 9 : (now.hour + 1);
            effectiveDate = _formatDate(now);
            effectiveTime = '$roundHour:00:00'.padLeft(8, '0');
          } else {
            // After 4pm - schedule for tomorrow at 9am
            final tomorrow = now.add(const Duration(days: 1));
            effectiveDate = _formatDate(tomorrow);
            effectiveTime = '09:00:00';
          }
        }
        print(
            '[booking_time] Using smart default: $effectiveDate at $effectiveTime');
      } else {
        // Photos not yet uploaded - ask for time before continuing
        final msgDate = 'I need to know when you want the service scheduled.';
        setState(() {
          _aiResponse = msgDate;
        });
        _addToTranscript('AI', msgDate);
        await _sendSpeakToAgent(
          'When would you like me to schedule this service? Please tell me the date and time, or say "as soon as possible".',
        );
        return; // Return early - wait for user response
      }
    } else {
      // Validate the AI-provided date is not in the past.
      // AI agents sometimes hallucinate old dates (e.g. October 2023).
      DateTime? parsedScheduled;
      try {
        final dateParts = scheduledDate.split('-');
        if (dateParts.length == 3) {
          final y = int.tryParse(dateParts[0]) ?? 0;
          final m = int.tryParse(dateParts[1]) ?? 0;
          final d = int.tryParse(dateParts[2]) ?? 0;
          if (y > 0 && m > 0 && d > 0) {
            // Parse time too for full comparison.
            final timeParts = scheduledTime.split(':');
            final h = int.tryParse(timeParts.isNotEmpty ? timeParts[0] : '0') ?? 0;
            final min = int.tryParse(timeParts.length > 1 ? timeParts[1] : '0') ?? 0;
            parsedScheduled = DateTime(y, m, d, h, min);
          }
        }
      } catch (_) {
        // ignore parse errors
      }

      if (parsedScheduled != null && parsedScheduled.isBefore(now)) {
        // Date is in the past — use smart defaults instead.
        print('[booking_time] AI provided past date ($scheduledDate $scheduledTime), using smart default');
        if (isEmergency) {
          final dt = now.add(const Duration(hours: 1));
          effectiveDate = _formatDate(dt);
          final hh = dt.hour.toString().padLeft(2, '0');
          final mm = dt.minute.toString().padLeft(2, '0');
          effectiveTime = '$hh:$mm:00';
        } else if (now.hour < 16) {
          final roundHour = now.hour < 9 ? 9 : (now.hour + 1);
          effectiveDate = _formatDate(now);
          effectiveTime = '$roundHour:00:00'.padLeft(8, '0');
        } else {
          final tomorrow = now.add(const Duration(days: 1));
          effectiveDate = _formatDate(tomorrow);
          effectiveTime = '09:00:00';
        }
      } else {
        effectiveDate = scheduledDate;
        effectiveTime = scheduledTime;
      }
    }

    // Build a rich hint by combining all available text fields.
    // Previously we only used ONE field (taskNameHint → description → categoryName),
    // but the AI agent sometimes sends a generic task_name (e.g. "plumbing") while
    // the specific words ("blocked toilet") are in categoryName or description.
    // Combining all sources ensures the scoring algorithm has all keywords available.
    final hintParts = <String>[
      taskNameHint.trim(),
      categoryName.trim(),
      description.trim(),
      notes.trim(),
    ].where((s) => s.isNotEmpty).toSet(); // deduplicate identical values
    final resolvedHint = hintParts.join(' ');

    print('[ai_task] resolvedHint="$resolvedHint" parts=${hintParts.length}');

    var task = await _resolveTaskForCategory(
      categoryIds: categoryIds,
      taskNameHint: resolvedHint,
    );

    // Retry with just categoryName if the combined hint didn't match
    // (sometimes too many words dilute the score).
    if (task == null && categoryName.trim().isNotEmpty && hintParts.length > 1) {
      print('[ai_task] Retrying with categoryName only: "$categoryName"');
      task = await _resolveTaskForCategory(
        categoryIds: categoryIds,
        taskNameHint: categoryName,
      );
    }

    double extractTaskCost(Map<String, dynamic> taskData) {
      return _toAmount(
            taskData['cost'] ??
                taskData['price'] ??
                taskData['amount'] ??
                taskData['unit_price'],
          ) ??
          0.0;
    }

    Future<Map<String, dynamic>?> findFirstPricedTaskInCategories() async {
      QuerySnapshot<Map<String, dynamic>>? snap;

      for (final catId in categoryIds) {
        try {
          final r = await FirebaseService.taskRef
              .where('status', isEqualTo: 'publish')
              .where('categoryId', isEqualTo: catId)
              .limit(10)
              .get();
          if (r.docs.isNotEmpty) {
            snap = r;
            break;
          }
        } catch (_) {}
      }

      if (snap == null || snap.docs.isEmpty) {
        for (final catId in categoryIds) {
          try {
            final r = await FirebaseService.taskRef
                .where('status', isEqualTo: 'publish')
                .where('category_id', isEqualTo: catId)
                .limit(10)
                .get();
            if (r.docs.isNotEmpty) {
              snap = r;
              break;
            }
          } catch (_) {}
        }
      }

      if (snap == null || snap.docs.isEmpty) return null;

      for (final d in snap.docs) {
        final data = d.data();
        data['id'] ??= d.id;
        final cost = extractTaskCost(data);
        if (cost > 0) return data;
      }

      final data = snap.docs.first.data();
      data['id'] ??= snap.docs.first.id;
      return data;
    }

    print(
        '[ai_task] resolve_result: ${task != null ? 'found' : 'null'} hint="$taskNameHint" categoryIds=${categoryIds.length}');
    if (task != null) {
      print('[ai_task] task_id="${task['id']}" name="${task['name']}"');
    }

    List<String> jobIds;
    final Map<String, String> taskNamesById = {};
    final Map<String, double> taskCostsById = {};
    bool isRFQRequested = false;
    String rfqReason = '';

    if (task == null) {
      // No specific task found by exact matching.
      // Look for ANY published task in any of the category IDs as a fallback.
      print(
          '[ai_task] No exact match, searching for any published task in categories');

      final fallbackTask = await findFirstPricedTaskInCategories();
      if (fallbackTask != null) {
        final taskId = (fallbackTask['id'] ?? '').toString().trim();
        final taskName = (fallbackTask['name'] ?? categoryName).toString();
        final cost = extractTaskCost(fallbackTask);

        print(
            '[ai_task] Using fallback task=$taskId name=$taskName cost=$cost');
        if (taskId.isEmpty || cost <= 0) {
          rfqReason = 'unpriced_task';
          jobIds = <String>[];
        } else {
          jobIds = <String>[taskId];
          taskNamesById[taskId] = taskName;
          taskCostsById[taskId] = cost;
        }
      } else {
        // No published task found
        // IMPORTANT: Do not create RTBD/unknown-price orders.
        // Let the user pick a priced service from the catalog or explicitly request RFQ.
        print(
            '[ai_task] No published task found for categories; require selection');
        rfqReason = 'no_matching_task';
        jobIds = <String>[];
      }
    } else {
      final taskId = (task['id'] ?? '').toString();
      final taskName = (task['name'] ?? '').toString();
      double cost = extractTaskCost(task);

      if (taskId.trim().isEmpty) {
        print('[ai_task] task resolve returned empty id; require selection');
        rfqReason = 'invalid_task_id';
        jobIds = <String>[];
      } else {
        String chosenTaskId = taskId.trim();
        String chosenTaskName = taskName;
        double chosenCost = cost;

        if (chosenCost <= 0) {
          final fallbackTask = await findFirstPricedTaskInCategories();
          if (fallbackTask != null) {
            final fbId = (fallbackTask['id'] ?? '').toString().trim();
            final fbName = (fallbackTask['name'] ?? '').toString().trim();
            final fbCost = extractTaskCost(fallbackTask);
            if (fbId.isNotEmpty && fbCost > 0) {
              print(
                  '[ai_task] Resolved task had no price, using priced fallback task=$fbId cost=$fbCost');
              chosenTaskId = fbId;
              chosenTaskName = fbName.isNotEmpty ? fbName : categoryName;
              chosenCost = fbCost;
            }
          }
        }

        if (chosenCost <= 0) {
          print('[ai_task] task has no saved price; require selection');
          rfqReason = 'unpriced_task';
          jobIds = <String>[];
        } else {
          jobIds = <String>[chosenTaskId];
          taskNamesById[chosenTaskId] = chosenTaskName;
          taskCostsById[chosenTaskId] = chosenCost;
        }
      }
    }

    final effectiveDescription = description.trim().isNotEmpty
        ? description
        : 'Voice request: $categoryName${notes.trim().isNotEmpty ? " - $notes" : ""}';

    print(
        '[dispatch_flow] Creating booking with jobIds=${jobIds.length} isRFQ=$isRFQRequested photos=${workImageUrls.length}');

    // Voice-first flow: if no priced task found, auto-create an RFQ
    // instead of redirecting to a manual booking form.
    // The user already described the job — we have all the data needed.
    if (jobIds.isEmpty && !isRFQRequested) {
      isRFQRequested = true;
      rfqReason = rfqReason.isEmpty ? 'no_matching_task' : rfqReason;
      print('[voice_rfq] Auto-creating RFQ: reason=$rfqReason category=$categoryName');

      setState(() {
        _aiResponse =
            'I could not find exact pricing for $categoryName. Creating a request for quotes from available artisans...';
      });
      _addToTranscript(
        'AI',
        'No exact pricing found for $categoryName. Auto-creating RFQ.',
      );
      await _sendSpeakToAgent(
        'I could not find the exact pricing for this service, '
        'so I am creating a request for quotes. '
        'Available artisans in your area will send you their prices.',
      );
      // Fall through to the booking creation below with isRFQRequested = true
    }

    // Voice-first flow: trust AI-provided date/time.
    // No date/time picker dialogs — the AI already extracted or defaulted them.
    // The smart defaults above already handle missing/past dates.
    print('[voice_booking] Using date=$effectiveDate time=$effectiveTime (emergency=$isEmergency)');

    final locationSummary = serviceOnCurrentLocation
        ? 'at your current location'
        : (address.trim().isNotEmpty ? 'at $address' : 'at the provided location');

    // Voice-first flow: no confirmation dialog.
    // The AI reads a summary aloud and proceeds directly.
    // The user already confirmed verbally during the conversation.
    final modeSummary = isRFQRequested
        ? 'Creating a request for quotes'
        : 'Creating an order booking';

    print('[voice_booking] $modeSummary for $categoryName on $effectiveDate at $effectiveTime');

    // Build a human-readable summary for the voice readback.
    final totalCost = taskCostsById.values.fold(0.0, (a, b) => a + b);
    final taskNamesSummary = taskNamesById.values.isNotEmpty
        ? taskNamesById.values.join(', ')
        : categoryName;
    final costSummary = totalCost > 0
        ? 'for R${totalCost.toStringAsFixed(0)}'
        : '';
    final dateSummary = effectiveDate.isNotEmpty
        ? 'on $effectiveDate at ${effectiveTime.substring(0, 5)}'
        : 'as soon as possible';

    final voiceSummary = isRFQRequested
        ? 'Creating a request for quotes for $taskNamesSummary $dateSummary $locationSummary. '
          'Available artisans will send you their prices.'
        : 'Creating your booking for $taskNamesSummary $costSummary $dateSummary $locationSummary. '
          'I will send the request to the nearest available artisan.';

    setState(() {
      _aiResponse = voiceSummary;
    });
    _addToTranscript('AI', voiceSummary);
    await _sendSpeakToAgent(voiceSummary);

    try {
      final backend = await _tryExecuteAssistantAction(
        action: 'create_order_booking',
        payload: {
          'job_ids': jobIds,
          'scheduled_date': effectiveDate,
          'scheduled_time': effectiveTime,
          'service_on_current_location': serviceOnCurrentLocation,
          'user_lat': app.userLat.value,
          'user_lng': app.userLng.value,
          'provided_address': address,
          'other_lat': lat,
          'other_lng': lng,
          'work_image_urls': workImageUrls,
          'problem_description': effectiveDescription,
          'additional_notes': notes,
          'category_id': categoryIds.first,
          'category_name': categoryName,
          'materials_responsibility': materialsResponsibility.isEmpty
              ? 'artisan'
              : materialsResponsibility,
          'is_rfq_requested': isRFQRequested,
          'rfq_reason': rfqReason,
          'require_photos': false,
          'created_by': 'voice_ai',
          'is_emergency': isEmergency,
        },
      );

      final ok = backend?['success'] == true;
      final result = backend?['result'];
      if (!ok || result is! Map) {
        throw StateError('Backend booking creation failed');
      }

      final bookingId =
          (result['booking_id'] ?? result['bookingId'] ?? '').toString();
      final isRFQ = (result['is_rfq'] ?? result['isRFQ'] ?? false) == true;
      final assigned = (result['assigned_artisan_id'] ??
              result['assignedArtisanId'] ??
              '')
          .toString();

      print(
          '[dispatch_result] bookingId=$bookingId isRFQ=$isRFQ assigned=$assigned');

      _lastCreatedBookingId = bookingId;
      _lastAssignedArtisanId = assigned;

      await _sendAppContextToAgent(reason: 'booking_created');

      if (!isRFQ && bookingId.trim().isNotEmpty) {
        _watchBookingUntilConfirmed(bookingId: bookingId);
      }

      final msg = isRFQ
          ? 'Request created (RFQ). Admin will assign the best available artisan.'
          : (assigned.isNotEmpty
              ? 'Booking created. Request sent to a nearby artisan. Waiting for acceptance.'
              : 'Booking created. Still finding an available artisan to accept.');

      setState(() {
        _aiResponse = msg;
      });

      _addToTranscript('System', 'Booking created: $bookingId');
      _addToTranscript('AI', msg);

      // Ensure the user hears the real outcome (not just the agent's "done" message).
      await _sendSpeakToAgent(msg);

      Get.snackbar(_assistantName, msg,
          backgroundColor: Colors.green, colorText: Colors.white);
    } catch (e) {
      debugPrint('❌ backend create_order_booking failed: $e');
      print(
          '[dispatch_error] Booking creation failed: $e (Stack: ${StackTrace.current})');

      final errorMsg = 'Could not create booking: $e';
      Get.snackbar(_assistantName, errorMsg,
          backgroundColor: Colors.red, colorText: Colors.white);

      setState(() {
        _aiResponse = 'Sorry, there was an error. Please try again.';
      });
      _addToTranscript('AI', 'Error occurred while creating booking.');

      await _sendSpeakToAgent(
          'Sorry — I encountered an error creating the booking. Please try again.');
    }
  }

  Future<void> _openPhotoUploadThenDispatch(dynamic payload) async {
    if (!mounted) return;

    if (_isOpeningPhotoUpload) return;
    _isOpeningPhotoUpload = true;

    Future<void> waitForNavigatorReady() async {
      // Navigation can be briefly unavailable during startup/resume.
      for (int i = 0; i < 120; i++) {
        if (!mounted) return;
        if (Get.key.currentState != null || Get.context != null) return;
        await Future.delayed(const Duration(milliseconds: 50));
      }
      throw Exception('Navigator not ready');
    }

    bool looksLikeCurrentLocation(String raw) {
      final s = raw.trim().toLowerCase();
      if (s.isEmpty) return true;
      return s == 'current location' ||
          s == 'my current location' ||
          s == 'my location' ||
          s == 'current' ||
          s == 'here' ||
          s == 'use current location' ||
          s.contains('current location');
    }

    Future<String> reverseGeocodeAddress({
      required String lat,
      required String lng,
    }) async {
      final dLat = double.tryParse(lat);
      final dLng = double.tryParse(lng);
      if (dLat == null || dLng == null) return '';
      try {
        final places = await placemarkFromCoordinates(dLat, dLng);
        if (places.isEmpty) return '';
        final p = places.first;
        final parts = <String?>[
          p.name,
          p.street,
          p.subLocality,
          p.locality,
          p.administrativeArea,
          p.postalCode,
          p.country,
        ].whereType<String>().map((e) => e.trim()).where((e) => e.isNotEmpty);
        return parts.join(', ');
      } catch (_) {
        return '';
      }
    }

    try {
      final map = payload is Map
          ? payload.map((k, v) => MapEntry(k.toString(), v))
          : <String, dynamic>{};

      final categoryName =
          (map['category_name'] ?? map['categoryName'] ?? '').toString().trim();
      final description =
          (map['problem_description'] ?? map['description'] ?? '').toString();
      final notes = (map['additional_notes'] ?? map['notes'] ?? '').toString();
      String address =
          (map['service_address'] ?? map['address'] ?? '').toString();

      if (categoryName.isEmpty) {
        Get.snackbar(_assistantName, 'Could not open upload: missing category',
            backgroundColor: Colors.red, colorText: Colors.white);
        await _sendSpeakToAgent(
            'Sorry — I cannot open photo upload yet because the category is missing.');
        return;
      }

      // If the agent/user said "current location", show a real address instead.
      final isCurrent = looksLikeCurrentLocation(address);
      if (isCurrent) {
        AppController? app;
        if (Get.isRegistered<AppController>()) {
          app = Get.find<AppController>();
        }
        if (app != null) {
          if (app.userLat.value.trim().isEmpty ||
              app.userLng.value.trim().isEmpty) {
            try {
              await app.getCurrentPosition(context);
            } catch (_) {}
          }
          final resolved = await reverseGeocodeAddress(
            lat: app.userLat.value,
            lng: app.userLng.value,
          );
          if (resolved.trim().isNotEmpty) {
            address = resolved;
          }
        }
      }

      List<String>? urls;
      try {
        await waitForNavigatorReady();

        // Try navigation a few times (Get routing can fail during transient UI states).
        Object? lastError;
        for (int attempt = 0; attempt < 3; attempt++) {
          try {
            final navFuture = Future.microtask(() => Get.to<List<String>>(
                  () => AiPhotoUploadScreen(
                    categoryName: categoryName,
                    problemDescription: description,
                    additionalNotes: notes,
                    serviceOnCurrentLocation: isCurrent,
                    serviceAddress: address,
                    minPhotos: 3,
                  ),
                  transition: Transition.fadeIn,
                ));

            // Announce after navigation has been initiated.
            if (!mounted) return;
            setState(() {
              _aiResponse =
                  'I have opened the photo upload, please upload the photos of the issue.';
            });
            _addToTranscript('System', 'Opening photo upload screen.');
            await _sendSpeakToAgent(
              'I have opened the photo upload, please upload the photos of the issue.',
            );

            urls = await navFuture;
            break;
          } catch (e) {
            lastError = e;
            await Future.delayed(const Duration(milliseconds: 250));
          }
        }

        // Fallback: if Get routing failed, try Navigator.push directly.
        if (urls == null) {
          try {
            final ctx = Get.context ?? context;
            final navFuture = Navigator.of(ctx).push<List<String>>(
              MaterialPageRoute(
                builder: (_) => AiPhotoUploadScreen(
                  categoryName: categoryName,
                  problemDescription: description,
                  additionalNotes: notes,
                  serviceOnCurrentLocation: isCurrent,
                  serviceAddress: address,
                  minPhotos: 3,
                ),
              ),
            );

            // Announce again as we attempt fallback navigation.
            if (!mounted) return;
            setState(() {
              _aiResponse =
                  'Opening the photo upload screen now. Please upload at least 3 photos.';
            });
            _addToTranscript(
                'System', 'Opening photo upload screen (fallback).');
            await _sendSpeakToAgent(
              'Opening the photo upload screen now. Please upload at least 3 photos.',
            );

            urls = await navFuture;
          } catch (e) {
            lastError = e;
          }
        }

        if (urls == null && lastError != null) {
          throw lastError;
        }
      } catch (e) {
        Get.snackbar(_assistantName, 'Could not open photo upload: $e',
            backgroundColor: Colors.red, colorText: Colors.white);
        await _sendSpeakToAgent(
            'Sorry — I could not open the photo upload screen. Please try again.');
        return;
      }

      if (!mounted) return;

      if (urls == null || urls.length < 3) {
        const msg =
            'Photo upload cancelled or incomplete. Please upload at least 3 photos to dispatch an artisan.';

        setState(() {
          _aiResponse = msg;
        });
        _addToTranscript('AI', msg);

        Get.snackbar(_assistantName, 'Photo upload cancelled or incomplete.',
            backgroundColor: Colors.orange, colorText: Colors.white);

        await _sendSpeakToAgent(msg);
        return;
      }

      final merged = <String, dynamic>{...map};
      merged['require_photos'] = false;
      merged['work_image_urls'] = urls;

      setState(() {
        _aiResponse =
            'Photos uploaded successfully. Creating your booking and sending the request now...';
      });
      _addToTranscript('AI',
          'Photos uploaded successfully. Creating booking and sending request now...');

      await _sendSpeakToAgent(
        'Thanks. Your photos were uploaded successfully. I am creating the booking now and sending the request to the nearest available artisan.',
      );

      // If a booking is already being created, wait briefly so we don't drop the
      // dispatch after photos are uploaded.
      if (_isCreatingOrderBooking) {
        final started = DateTime.now();
        while (_isCreatingOrderBooking &&
            mounted &&
            DateTime.now().difference(started) < const Duration(seconds: 8)) {
          await Future.delayed(const Duration(milliseconds: 200));
        }
      }

      if (_isCreatingOrderBooking) {
        Get.snackbar(
            _assistantName, 'Still processing your request. Please try again.',
            backgroundColor: Colors.orange, colorText: Colors.white);
        await _sendSpeakToAgent(
            'I am still processing your request. Please try again.');
        return;
      }

      _isCreatingOrderBooking = true;
      try {
        await _createOrderBookingFromPayload(merged);
      } finally {
        _isCreatingOrderBooking = false;
      }
    } finally {
      _isOpeningPhotoUpload = false;
    }
  }

  void _watchBookingUntilConfirmed({required String bookingId}) {
    _bookingStatusSubscription?.cancel();
    _watchBookingLastProviderId = '';
    String lastSpokenStatus = '';
    bool hasAnnouncedAcceptance = false;
    bool hasAnnouncedPaymentComplete = false;

    _bookingStatusSubscription = FutureBookingService.futureBookingsRef
        .doc(bookingId)
        .snapshots()
        .listen((snap) async {
      if (!mounted) return;
      if (!snap.exists) return;

      final data = snap.data() ?? <String, dynamic>{};
      final isRfq = (data['is_rfq'] ?? '').toString().trim().toLowerCase();
      if (isRfq == 'yes') return;

      final status = (data['status'] ?? '').toString().trim().toLowerCase();
      final artisanConfirmed =
          (data['artisan_confirmed'] ?? '').toString().trim().toLowerCase();
      final artisanId = (data['service_provider_id'] ?? '').toString().trim();

      // Check payment status in both futureBookings and tasksManagement
      bool isPaid = false;
      try {
        final bookingPaymentStatus =
            (data['payment_status'] ?? '').toString().trim().toLowerCase();
        if (bookingPaymentStatus == 'paid' ||
            bookingPaymentStatus == 'success') {
          isPaid = true;
        }

        if (!isPaid) {
          // Also check in tasksManagement
          final tmId = await _resolveTasksManagementIdForBooking(
            bookingId: bookingId,
            bookingData: data,
          );
          if (tmId != null && tmId.trim().isNotEmpty) {
            final tmDoc = await FirebaseFirestore.instance
                .collection('tasksManagement')
                .doc(tmId)
                .get();
            if (tmDoc.exists) {
              final tmData = tmDoc.data() ?? <String, dynamic>{};
              final tmPaymentStatus = (tmData['payment_status'] ?? '')
                  .toString()
                  .trim()
                  .toLowerCase();
              if (tmPaymentStatus == 'paid' || tmPaymentStatus == 'success') {
                isPaid = true;
              }
            }
          }
        }
      } catch (_) {}

      // If payment is complete and we haven't announced it yet, announce and stop watching
      if (isPaid && !hasAnnouncedPaymentComplete) {
        hasAnnouncedPaymentComplete = true;
        final completionMsg =
            'Thank you, your booking process is complete. Please monitor the booking on the Future Bookings tab.';

        setState(() {
          _aiResponse = completionMsg;
        });
        _addToTranscript('AI', completionMsg);

        await _sendSpeakToAgent(completionMsg);

        Get.snackbar(_assistantName, completionMsg,
            backgroundColor: Colors.green, colorText: Colors.white);

        await _bookingStatusSubscription?.cancel();
        _bookingStatusSubscription = null;
        return;
      }

      bool acceptedByTasksManagement = false;
      if ((status == 'pending' || status == 'pending_assignment') &&
          artisanConfirmed != 'yes' &&
          artisanId.isNotEmpty &&
          artisanId != 'admin') {
        try {
          final tmId = await _resolveTasksManagementIdForBooking(
            bookingId: bookingId,
            bookingData: data,
          );
          if (tmId != null && tmId.trim().isNotEmpty) {
            final tmDoc = await FirebaseFirestore.instance
                .collection('tasksManagement')
                .doc(tmId)
                .get();
            final tmData = tmDoc.data() ?? <String, dynamic>{};
            final tmStatus =
                (tmData['status'] ?? '').toString().trim().toLowerCase();
            acceptedByTasksManagement =
                _isTruthy(tmData['accept']) || tmStatus == 'pending_payment';
          }
        } catch (_) {}
      }

      // Keep the client engaged, but avoid repeating the same status over and over.
      Future<void> speakOnceForStatus(String statusKey, String message) async {
        if (statusKey.isEmpty) return;
        if (lastSpokenStatus == statusKey) return;
        lastSpokenStatus = statusKey;
        setState(() {
          _aiResponse = message;
        });
        _addToTranscript('AI', message);
        await _sendSpeakToAgent(message);
      }

      if (_watchBookingLastProviderId.isNotEmpty &&
          artisanId.isNotEmpty &&
          artisanId != 'admin' &&
          artisanId != _watchBookingLastProviderId &&
          status != 'confirmed' &&
          artisanConfirmed != 'yes') {
        setState(() {
          _aiResponse =
              'The previous artisan was not available. Dispatching another nearby artisan now...';
        });
        _addToTranscript(
          'AI',
          'The previous artisan was not available. Dispatching another nearby artisan now...',
        );
        await _sendSpeakToAgent(
          'The previous artisan was not available. I am dispatching another nearby artisan now.',
        );
      }

      if (artisanId.isNotEmpty) {
        _watchBookingLastProviderId = artisanId;
      }

      if ((status == 'confirmed' ||
              status == 'pending_payment' ||
              artisanConfirmed == 'yes' ||
              acceptedByTasksManagement) &&
          !hasAnnouncedAcceptance) {
        hasAnnouncedAcceptance = true;

        String artisanName = '';
        try {
          if (artisanId.isNotEmpty && artisanId != 'admin') {
            final doc = await FirebaseService.providerRef.doc(artisanId).get();
            final d = doc.data() ?? <String, dynamic>{};
            artisanName = (d['name'] ?? d['fullName'] ?? '').toString().trim();
          }
        } catch (_) {}

        final scheduledDate = (data['scheduled_date'] ?? '').toString().trim();
        final scheduledTime = (data['scheduled_time'] ?? '').toString().trim();
        final categoryName =
            (data['category_name'] ?? data['categoryName'] ?? '')
                .toString()
                .trim();

        final taskCostInfo = await _getTaskCostInfo(
          bookingId: bookingId,
          bookingData: data,
        );

        final costMsg = taskCostInfo != null && taskCostInfo['amount'] != null
            ? ' The cost for this service is ${taskCostInfo['amountFormatted']}.'
            : '';

        final msg =
            'Great news! The booking has been accepted by the artisan. ${artisanName.isNotEmpty ? artisanName : 'Your artisan'} will arrive on $scheduledDate at $scheduledTime for $categoryName.$costMsg Please pay now to confirm your booking. Note: You will be refunded if the work is not completed. I am opening the payment screen for you now.';

        setState(() {
          _aiResponse = msg;
        });
        _addToTranscript('AI', msg);

        await _sendSpeakToAgent(msg);

        // If payment is still required, open the existing payment workflow.
        Future.microtask(() async {
          final opened = await _maybeOpenPaymentForConfirmedBooking(
            bookingId: bookingId,
            bookingData: data,
          );
          if (!opened) {
            await _sendSpeakToAgent(
              'If the payment options do not appear, please open Future Bookings and tap Pay to confirm Order.',
            );
          }
        });

        try {
          if (Get.isRegistered<AppController>()) {
            final app = Get.find<AppController>();
            app.currentIndex.value = 2;
          }
        } catch (_) {}

        Get.snackbar(_assistantName, msg,
            backgroundColor: Colors.green, colorText: Colors.white);

        // DO NOT CANCEL - continue watching for payment completion
        return;
      }

      if (status == 'pending_assignment') {
        await speakOnceForStatus(
          'pending_assignment',
          'I am still finding an available artisan nearby. Please hold on.',
        );
        return;
      }

      if (status == 'pending') {
        await speakOnceForStatus(
          'pending',
          'Request sent. Waiting for the artisan to confirm.',
        );
      }
    });
  }

  static bool _isTruthy(dynamic v) {
    if (v == null) return false;
    if (v is bool) return v;
    if (v is num) return v != 0;
    final s = v.toString().trim().toLowerCase();
    return s == '1' || s == 'yes' || s == 'y' || s == 'true' || s == 'paid';
  }

  static double? _toAmount(dynamic v) {
    if (v == null) return null;
    if (v is num) return v.toDouble();
    final s = v.toString().trim();
    if (s.isEmpty) return null;
    final cleaned = s.replaceAll(RegExp(r'[^0-9.\-]'), '');
    return double.tryParse(cleaned);
  }

  Future<String?> _resolveTasksManagementIdForBooking({
    required String bookingId,
    required Map<String, dynamic> bookingData,
  }) async {
    final raw = (bookingData['tasks_management_id'] ??
            bookingData['tasksManagementId'] ??
            '')
        .toString()
        .trim();
    if (raw.isNotEmpty) return raw;

    // Fallback: look up by future_booking_id.
    try {
      final q = await FirebaseFirestore.instance
          .collection('tasksManagement')
          .where('future_booking_id', isEqualTo: bookingId)
          .limit(1)
          .get();
      if (q.docs.isNotEmpty) return q.docs.first.id;
    } catch (_) {}
    return null;
  }

  Future<Map<String, dynamic>?> _getTaskCostInfo({
    required String bookingId,
    required Map<String, dynamic> bookingData,
  }) async {
    try {
      final tasksManagementId = (await _resolveTasksManagementIdForBooking(
        bookingId: bookingId,
        bookingData: bookingData,
      ))
          ?.trim();
      if (tasksManagementId == null || tasksManagementId.isEmpty) return null;

      final tmDoc = await FirebaseFirestore.instance
          .collection('tasksManagement')
          .doc(tasksManagementId)
          .get();
      if (!tmDoc.exists) return null;

      final tmData = tmDoc.data() ?? <String, dynamic>{};
      final amount = _toAmount(tmData['cost']);
      if (amount == null || amount <= 0) return null;

      return {
        'amount': amount,
        'amountFormatted': 'R${amount.toStringAsFixed(2)}',
        'tasksManagementId': tasksManagementId,
      };
    } catch (_) {
      return null;
    }
  }

  Future<bool> _maybeOpenPaymentForConfirmedBooking({
    required String bookingId,
    required Map<String, dynamic> bookingData,
  }) async {
    if (!mounted) return false;
    if (_isOpeningPaymentSheet) return false;

    final tasksManagementId = (await _resolveTasksManagementIdForBooking(
      bookingId: bookingId,
      bookingData: bookingData,
    ))
        ?.trim();
    if (tasksManagementId == null || tasksManagementId.isEmpty) return false;
    if (_openedPaymentSheetForTasksManagementId == tasksManagementId) {
      return false;
    }

    _isOpeningPaymentSheet = true;
    try {
      final tmDoc = await FirebaseFirestore.instance
          .collection('tasksManagement')
          .doc(tasksManagementId)
          .get();
      if (!tmDoc.exists) return false;

      final tmData = tmDoc.data() ?? <String, dynamic>{};
      var record = TaskManagementModel.fromDocument(tmData, docId: tmDoc.id);

      final acceptVal = (record.accept ?? tmData['accept']);
      if (!_isTruthy(acceptVal)) return false;

      final paymentStatus =
          (record.paymentStatus ?? tmData['payment_status'] ?? '')
              .toString()
              .trim()
              .toLowerCase();
      if (paymentStatus == 'paid' || paymentStatus == 'success') return false;

      double? amount = _toAmount(record.cost ?? tmData['cost']);
      if (amount == null || amount <= 0) {
        // Fallback: sum job costs if top-level cost is missing/TBD.
        try {
          final jobsSnap = await FirebaseFirestore.instance
              .collection('tasksManagement')
              .doc(tasksManagementId)
              .collection('jobs')
              .get();
          double sum = 0.0;
          for (final d in jobsSnap.docs) {
            final data = d.data();
            final c = _toAmount(data['cost']);
            if (c != null && c > 0) sum += c;
          }
          if (sum > 0) {
            amount = sum;
            await FirebaseFirestore.instance
                .collection('tasksManagement')
                .doc(tasksManagementId)
                .update({'cost': sum.toStringAsFixed(2)});

            final refreshed = await FirebaseFirestore.instance
                .collection('tasksManagement')
                .doc(tasksManagementId)
                .get();
            if (refreshed.exists) {
              final refreshedData = refreshed.data() ?? <String, dynamic>{};
              record = TaskManagementModel.fromDocument(refreshedData,
                  docId: refreshed.id);
            }
          }
        } catch (_) {}
      }
      if (amount == null || amount <= 0) return false;

      _openedPaymentSheetForTasksManagementId = tasksManagementId;

      // Give navigation a moment to settle.
      await Future.delayed(const Duration(milliseconds: 250));
      if (!mounted) return false;

      // Use the same bottom sheet as the normal bookings flow.
      // If the user cancels, they can still pay later from Bookings.
      // ignore: use_build_context_synchronously
      showModalBottomSheet(
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.only(
            topLeft: Radius.circular(16),
            topRight: Radius.circular(16),
          ),
        ),
        context: context,
        builder: (BuildContext context) {
          return ModelBottomSheet(record: record);
        },
      );
      return true;
    } catch (e) {
      // Allow retry on next confirmed update if something went wrong.
      _openedPaymentSheetForTasksManagementId = '';
      debugPrint('$_assistantName payment auto-open failed: $e');
      return false;
    } finally {
      _isOpeningPaymentSheet = false;
    }
  }

  String _formatDate(DateTime date) {
    final mm = date.month.toString().padLeft(2, '0');
    final dd = date.day.toString().padLeft(2, '0');
    return '${date.year}-$mm-$dd';
  }

  /// Add message to transcript
  void _addToTranscript(String speaker, String text) {
    setState(() {
      _transcript.add({
        'speaker': speaker,
        'text': text,
        'time': DateTime.now().toString().substring(11, 19),
      });
    });

    // Auto-scroll to bottom
    Future.delayed(const Duration(milliseconds: 100), () {
      if (_transcriptScrollController.hasClients) {
        _transcriptScrollController.animateTo(
          _transcriptScrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  // NOTE: Token generation is intentionally NOT done on-device.
  // The LiveKit API secret must never ship inside the mobile app.

  // ignore: unused_element
  Future<bool> _dispatchAgent(String roomName) async {
    // Kept for backward compatibility in case other code paths call it,
    // but the primary flow uses /api/voice/start which dispatches already.
    try {
      final resp = await http
          .post(
            Uri.parse('$backendBaseUrl/api/dispatch-agent'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'roomName': roomName}),
          )
          .timeout(const Duration(seconds: 10));
      return resp.statusCode >= 200 && resp.statusCode < 300;
    } catch (_) {
      return false;
    }
  }

  /// Toggle microphone mute/unmute
  Future<void> _toggleMute() async {
    if (_localParticipant == null) return;

    setState(() {
      _isMuted = !_isMuted;
    });

    await _localParticipant!.setMicrophoneEnabled(!_isMuted);

    if (_isMuted) {
      _waveAnimationController.stop();
    } else {
      _waveAnimationController.repeat(reverse: true);
    }
  }

  /// Disconnect from Livekit room
  Future<void> _disconnect() async {
    if (_room == null) return;
    if (_isDisconnecting) return;
    _isDisconnecting = true;

    _disconnectDebounce?.cancel();
    _disconnectDebounce = null;

    _metadataPoller?.cancel();
    _metadataPoller = null;

    _disposeTypedRoomListener();
    await _disposeRoomEventsListener();
    _lastMetadataByParticipant.clear();

    _waveAnimationController.stop();
    _pulseAnimationController.stop();

    await _room!.disconnect();
    await _room!.dispose();

    setState(() {
      _room = null;
      _localParticipant = null;
      _isConnected = false;
      _isMuted = false;
      _connectionStatus = 'Disconnected';
      _aiResponse = 'Tap the microphone to start talking...';
      _transcript.clear();
    });

    debugPrint('🔌 Disconnected from Livekit');
    _isDisconnecting = false;
  }

  /// Handle unexpected disconnection
  void _handleDisconnection() {
    if (!mounted) return;

    setState(() {
      _isConnected = false;
      _connectionStatus = 'Disconnected';
      _aiResponse = 'Connection lost. Please reconnect.';
    });

    _waveAnimationController.stop();
    _pulseAnimationController.stop();
  }

  void _showErrorDialog(String title, String message) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _bookingStatusSubscription?.cancel();
    _bookingStatusSubscription = null;

    // Best-effort: stop any leftover system TTS so users don't hear another
    // assistant voice after leaving this screen.
    _stopAnyBackgroundTts();

    _artisanRequestsWorker?.dispose();
    _artisanRequestsWorker = null;
    _waveAnimationController.dispose();
    _pulseAnimationController.dispose();
    _disconnect();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1B5E20), // Square 15 Green
      appBar: AppBar(
        backgroundColor: const Color(0xFF2E7D32), // Darker Green
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () {
            _disconnect();
            Navigator.pop(context);
          },
        ),
        title: const Text(
          'Lizzy',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        centerTitle: true,
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            children: [
              // Status Indicator
              _buildStatusCard(),

              const SizedBox(height: 32),

              // AI Response Display
              Expanded(
                child: _buildResponseCard(),
              ),

              const SizedBox(height: 32),

              // Voice Control Panel
              _buildControlPanel(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStatusCard() {
    Color statusColor = _isConnected
        ? Colors.green
        : _isConnecting
            ? Colors.orange
            : Colors.red;

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: const Color(0xFF1B5E20).withOpacity(0.7), // Square 15 Green
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: statusColor.withOpacity(0.5),
          width: 2,
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 12,
            height: 12,
            decoration: BoxDecoration(
              color: statusColor,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: statusColor.withOpacity(0.5),
                  blurRadius: 8,
                  spreadRadius: 2,
                ),
              ],
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Text(
              _connectionStatus,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          if (_isConnected)
            Icon(
              _isMuted ? Icons.mic_off : Icons.mic,
              color: _isMuted ? Colors.red : Colors.green,
              size: 24,
            ),
        ],
      ),
    );
  }

  Widget _buildResponseCard() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: const Color(0xFF2E7D32), // Square 15 Green
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: const Color(0xFFFFD700), // Gold accent
          width: 2,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text(
                'Conversation',
                style: TextStyle(
                  color: Color(0xFFFFD700), // Gold color
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const Spacer(),
              if (_transcript.isNotEmpty)
                IconButton(
                  icon:
                      const Icon(Icons.clear, color: Colors.white70, size: 20),
                  onPressed: () {
                    setState(() {
                      _transcript.clear();
                    });
                  },
                  tooltip: 'Clear transcript',
                ),
            ],
          ),
          const SizedBox(height: 16),
          Expanded(
            child: _transcript.isEmpty
                ? Center(
                    child: Text(
                      _aiResponse,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 16,
                        height: 1.6,
                      ),
                    ),
                  )
                : ListView.builder(
                    controller: _transcriptScrollController,
                    itemCount: _transcript.length,
                    itemBuilder: (context, index) {
                      final message = _transcript[index];
                      final isUser = message['speaker'] == 'You';

                      return Padding(
                        padding: const EdgeInsets.only(bottom: 16),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Container(
                              padding: const EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                color: isUser
                                    ? const Color(0xFF1B5E20)
                                    : const Color(0xFFFFD700).withOpacity(0.2),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Icon(
                                isUser ? Icons.person : Icons.smart_toy,
                                color: isUser
                                    ? Colors.white
                                    : const Color(0xFFFFD700),
                                size: 20,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Text(
                                        message['speaker']!,
                                        style: TextStyle(
                                          color: isUser
                                              ? Colors.white
                                              : const Color(0xFFFFD700),
                                          fontSize: 14,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      Text(
                                        message['time']!,
                                        style: const TextStyle(
                                          color: Colors.white54,
                                          fontSize: 12,
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    message['text']!,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 15,
                                      height: 1.4,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildControlPanel() {
    return Column(
      children: [
        // Main microphone button
        GestureDetector(
          onTap: _isConnected ? null : _connectToLivekit,
          child: AnimatedBuilder(
            animation: _isConnected
                ? _pulseAnimation
                : const AlwaysStoppedAnimation(1.0),
            builder: (context, child) {
              return Transform.scale(
                scale: _pulseAnimation.value,
                child: Container(
                  width: 120,
                  height: 120,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: const LinearGradient(
                      colors: [
                        Color(0xFF2E7D32),
                        Color(0xFF66BB6A)
                      ], // Green gradient
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: const Color(0xFFFFD700)
                            .withOpacity(0.3), // Gold glow
                        blurRadius: 20,
                        spreadRadius: 5,
                      ),
                    ],
                  ),
                  child: _isConnecting
                      ? const Center(
                          child: CircularProgressIndicator(
                            color: Colors.white,
                          ),
                        )
                      : const Icon(
                          Icons.mic,
                          size: 56,
                          color: Colors.white,
                        ),
                ),
              );
            },
          ),
        ),

        const SizedBox(height: 24),

        // Control buttons
        if (_isConnected)
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Mute/Unmute button
              _buildControlButton(
                icon: _isMuted ? Icons.mic_off : Icons.mic,
                label: _isMuted ? 'Unmute' : 'Mute',
                onTap: _toggleMute,
                color: _isMuted ? Colors.red : Colors.green,
              ),

              const SizedBox(width: 20),

              // Disconnect button
              _buildControlButton(
                icon: Icons.call_end,
                label: 'End',
                onTap: _disconnect,
                color: Colors.red,
              ),
            ],
          ),

        const SizedBox(height: 16),

        // Instructions
        Text(
          _isConnected
              ? 'Speak naturally to interact with the AI assistant'
              : 'Tap the microphone to connect',
          style: const TextStyle(
            color: Colors.white60,
            fontSize: 14,
          ),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }

  Widget _buildControlButton({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    required Color color,
  }) {
    return Column(
      children: [
        InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(30),
          child: Container(
            width: 60,
            height: 60,
            decoration: BoxDecoration(
              color: color.withOpacity(0.2),
              shape: BoxShape.circle,
              border: Border.all(
                color: color,
                width: 2,
              ),
            ),
            child: Icon(
              icon,
              color: color,
              size: 28,
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          label,
          style: TextStyle(
            color: color,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}
