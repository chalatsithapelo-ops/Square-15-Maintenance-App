import 'package:flutter/material.dart';
import 'package:livekit_client/livekit_client.dart' hide ConnectionState;
import 'package:livekit_client/livekit_client.dart' as livekit;
import 'package:permission_handler/permission_handler.dart';
import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:get/get.dart';
import 'package:maintenanceapp/controller/app_controller.dart';
import 'package:maintenanceapp/controller/service_provider_controller.dart';
import 'package:maintenanceapp/model/task_management_model.dart';
import 'package:flutter_phone_direct_caller/flutter_phone_direct_caller.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:maintenanceapp/screens/home/booking/booking.dart';
import 'package:maintenanceapp/screens/home/booking/future_bookings_list_screen.dart';
import 'package:maintenanceapp/screens/home/booking/ai_photo_upload_screen.dart';
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

  const _VoiceStartInfo({
    required this.roomName,
    required this.token,
    required this.livekitUrl,
  });
}

class _RoomEventHandler {
  final dynamic eventType;
  final Function(dynamic) handler;

  const _RoomEventHandler(this.eventType, this.handler);
}

class _LivekitVoiceAssistantState extends State<LivekitVoiceAssistant>
    with TickerProviderStateMixin {
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
    _initializeAnimations();
    _requestPermissions();
    _ensureArtisanRequestsSubscription();
    _attachArtisanRequestAnnouncements();
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
      sp.getRequests(providerId: providerId);
    } catch (_) {
      // Best-effort: Voice AI can still navigate even if requests aren't live.
    }
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

    setState(() {
      _isConnecting = true;
      _connectionStatus = 'Connecting to AI Assistant...';
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
            'AI agent is being started by the backend.\n\n'
            'Start speaking to interact with the voice assistant!\n\n'
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

      // Tell the agent it can start speaking (and confirm metadata path).
      // This is best-effort and safe to ignore.
      await _sendSpeakToAgent(
        'You are connected. You can speak and guide me step by step.',
      );

      _waveAnimationController.repeat(reverse: true);
      _pulseAnimationController.repeat(reverse: true);

      debugPrint('✅ Connected to Livekit Voice Assistant');
    } catch (e) {
      debugPrint('❌ Error connecting to Livekit: $e');
      setState(() {
        _isConnecting = false;
        _connectionStatus = 'Connection Failed';
        _aiResponse = 'Failed to connect to AI Assistant. Please try again.';
      });

      _showErrorDialog(
          'Connection Error', 'Failed to connect to AI Assistant: $e');
    }
  }

  Future<void> _sendSpeakToAgent(String text) async {
    final t = text.trim();
    if (t.isEmpty) return;
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
      'role': widget.role,
      'user_id': userId,
      'provider_id': widget.providerListenerId,
      'ts': DateTime.now().toIso8601String(),
    });

    http.Response? resp;
    Object? lastError;

    for (int attempt = 0; attempt < 2; attempt++) {
      try {
        resp = await http
            .post(
              uri,
              headers: {'Content-Type': 'application/json'},
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

    if (roomName.isEmpty || token.isEmpty || url.isEmpty) {
      throw Exception(
          'Backend voice start returned invalid response: ${resp.body}');
    }

    return _VoiceStartInfo(roomName: roomName, token: token, livekitUrl: url);
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
          _connectionStatus = 'AI Assistant Active';
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
      setState(() {
        _aiResponse = raw;
      });
      _addToTranscript('AI', raw);
      return;
    }

    final text = (decoded['text'] ?? decoded['message'] ?? '').toString();
    if (text.isNotEmpty) {
      setState(() {
        _aiResponse = text;
      });
      _addToTranscript('AI', text);

      // Support agents that embed UI actions inside a normal text response.
      // Format: SQUARE15_UI:{"action":"create_order_booking","payload":{...}}
      _tryHandleEmbeddedUiActionFromText(text);
    }

    final type = (decoded['type'] ?? '').toString();
    final action = (decoded['action'] ?? decoded['ui_action'] ?? '').toString();
    final payload = decoded['payload'];
    if (type == 'square15_ui' && action.isNotEmpty) {
      debugPrint(
        '[ai_meta] square15_ui action=$action payloadType=${payload.runtimeType}',
      );

      _handleUiAction(action: action, payload: payload).then((_) {
        print('[ai_action] done action=$action');
      }).catchError((e, st) {
        print('[ai_action] error action=$action err=$e');
        print('$st');
      });
    }
  }

  Future<void> _tryHandleEmbeddedUiActionFromText(String text) async {
    if (!mounted) return;
    if (text.trim().isEmpty) return;
    final marker = 'SQUARE15_UI:';
    final idx = text.indexOf(marker);
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
      debugPrint('[ai_action] done action=$action (embedded)');
    } catch (e) {
      debugPrint('[ai_meta] failed_to_parse_embedded_action err=$e');
    }
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
      if (_shouldDebounceUiAction(action)) return;
      await _openPhotoUploadThenDispatch(payload);
      return;
    }

    if (action == 'create_order_booking' || action == 'dispatch_artisan') {
      if (_isCreatingOrderBooking) return;

      // Check if photos are required
      final map = payload is Map
          ? payload.map((k, v) => MapEntry(k.toString(), v))
          : <String, dynamic>{};
      final requirePhotos = (map['require_photos'] ?? true) == true;

      if (requirePhotos) {
        // Open photo upload first, then dispatch after photos are uploaded
        if (_shouldDebounceUiAction(action)) return;
        await _openPhotoUploadThenDispatch(payload);
        return;
      }

      // Direct dispatch without photos (legacy path)
      _isCreatingOrderBooking = true;
      try {
        await _createOrderBookingFromPayload(payload);
      } finally {
        _isCreatingOrderBooking = false;
      }
      return;
    }

    if (action == 'call_assigned_artisan' || action == 'call_artisan') {
      await _callAssignedArtisanFromPayload(payload);
      return;
    }
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
      Get.snackbar('Voice AI', hint,
          backgroundColor: Colors.orange, colorText: Colors.white);
      return;
    }

    try {
      await FlutterPhoneDirectCaller.callNumber(phone);
      Get.snackbar('Voice AI', 'Calling artisan now...',
          backgroundColor: Colors.green, colorText: Colors.white);
    } catch (e) {
      Get.snackbar('Voice AI', 'Could not start call: $e',
          backgroundColor: Colors.red, colorText: Colors.white);
    }
  }

  Future<void> _respondToRequest({
    required String? accept,
    required dynamic payload,
  }) async {
    if (widget.role.toLowerCase().trim() != 'artisan') {
      Get.snackbar('Voice AI', 'This action is for artisans only.',
          backgroundColor: Colors.orange, colorText: Colors.white);
      return;
    }

    if (!Get.isRegistered<ServiceProviderController>()) {
      Get.snackbar(
          'Voice AI', 'Artisan controller not ready. Open dashboard first.',
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
      Get.snackbar('Voice AI', 'Missing decision: accept or reject?',
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
      Get.snackbar('Voice AI', 'No pending request found.',
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
      Get.snackbar(
          'Voice AI', 'Request data incomplete; open Requests and try again.',
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
      Get.snackbar('Voice AI', 'Could not update request: $e',
          backgroundColor: Colors.red, colorText: Colors.white);
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
      Get.snackbar('Voice AI', 'Could not open future bookings: $e',
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
      Get.snackbar('Voice AI', 'Could not open bookings: $e',
          backgroundColor: Colors.red, colorText: Colors.white);
      await _sendSpeakToAgent('Sorry — I could not open your bookings.');
    }
  }

  Future<void> _openArtisanRequests() async {
    if (widget.role.toLowerCase().trim() != 'artisan') {
      Get.snackbar('Voice AI', 'This action is for artisans only.',
          backgroundColor: Colors.orange, colorText: Colors.white);
      return;
    }
    if (widget.providerDoc == null) {
      Get.snackbar(
          'Voice AI', 'Could not open requests: missing artisan profile.',
          backgroundColor: Colors.red, colorText: Colors.white);
      return;
    }
    try {
      Get.to(
        () => ServiceProviderRequestScreen(doc: widget.providerDoc),
        transition: Transition.fadeIn,
      );
    } catch (e) {
      Get.snackbar('Voice AI', 'Could not open requests: $e',
          backgroundColor: Colors.red, colorText: Colors.white);
    }
  }

  Future<void> _openArtisanAppointments() async {
    if (widget.role.toLowerCase().trim() != 'artisan') {
      Get.snackbar('Voice AI', 'This action is for artisans only.',
          backgroundColor: Colors.orange, colorText: Colors.white);
      return;
    }
    final id = widget.providerListenerId.trim();
    if (id.isEmpty) {
      Get.snackbar(
          'Voice AI', 'Could not open appointments: missing artisan id.',
          backgroundColor: Colors.red, colorText: Colors.white);
      return;
    }
    try {
      Get.to(
        () => ArtisanAppointmentsScreen(artisanIds: <String>[id]),
        transition: Transition.fadeIn,
      );
    } catch (e) {
      Get.snackbar('Voice AI', 'Could not open appointments: $e',
          backgroundColor: Colors.red, colorText: Colors.white);
    }
  }

  Future<void> _openArtisanWallet() async {
    if (widget.role.toLowerCase().trim() != 'artisan') {
      Get.snackbar('Voice AI', 'This action is for artisans only.',
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
      Get.snackbar('Voice AI', 'Could not open wallet: missing artisan id.',
          backgroundColor: Colors.red, colorText: Colors.white);
      return;
    }

    try {
      Get.to(
        () => WalletPage(id: walletId),
        transition: Transition.fadeIn,
      );
    } catch (e) {
      Get.snackbar('Voice AI', 'Could not open wallet: $e',
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
        'plug': 'electrical',
        'socket': 'electrical',
        'wiring': 'electrical',
        'breaker': 'electrical',
        'trip': 'electrical',

        // Plumbing
        'plumber': 'plumbing',
        'tap': 'plumbing',
        'leak': 'plumbing',
        'leaking': 'plumbing',
        'pipe': 'plumbing',
        'toilet': 'plumbing',
        'geyser': 'plumbing',
        'drain': 'plumbing',
        'blocked': 'plumbing',

        // Painting
        'paint': 'painting',
        'painting': 'painting',
        'repaint': 'painting',
        'wall': 'painting',
        'ceiling': 'painting',

        // Cleaning
        'clean': 'cleaning',
        'cleaning': 'cleaning',
        'dirty': 'cleaning',
        'deep clean': 'cleaning',
        'carpet': 'cleaning',

        // Tiling
        'tile': 'tiling',
        'tiling': 'tiling',
        'tiles': 'tiling',

        // Roofing
        'roof': 'roofing',
        'roofing': 'roofing',

        // HVAC (if present)
        'aircon': 'air conditioning',
        'air con': 'air conditioning',
        'ac': 'air conditioning',
      };

      String inferred = normalizedInput;
      for (final entry in symptomToCategory.entries) {
        if (normalizedInput == entry.key ||
            normalizedInput.contains(entry.key)) {
          inferred = entry.value;
          break;
        }
      }

      final candidates = <String>{
        normalize(raw),
        normalizedInput,
        normalize(inferred),
      };

      if (candidates.contains('electrical')) candidates.addAll({'electrician'});
      if (candidates.contains('plumbing')) candidates.addAll({'plumber'});
      if (candidates.contains('painting')) candidates.addAll({'painter'});
      if (candidates.contains('cleaning')) candidates.addAll({'cleaner'});

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

      Map<String, dynamic>? best;
      if (taskNameHint.trim().isNotEmpty) {
        final wanted = taskNameHint.toLowerCase().trim();
        for (final doc in snap.docs) {
          final data = withId(doc);
          final name = (data['name'] ?? '').toString();
          final normalized = name.toLowerCase().trim();
          if (normalized == wanted) {
            best = data;
            break;
          }
        }

        if (best == null) {
          for (final doc in snap.docs) {
            final data = withId(doc);
            final name = (data['name'] ?? '').toString();
            final normalized = name.toLowerCase().trim();
            if (normalized.contains(wanted) || wanted.contains(normalized)) {
              best = data;
              break;
            }
          }
        }
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
    final address = (map['service_address'] ?? map['address'] ?? '').toString();
    final lat = (map['service_lat'] ?? map['lat'] ?? '').toString();
    final lng = (map['service_lng'] ?? map['lng'] ?? '').toString();
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

    final requirePhotosRaw = map['require_photos'] ?? map['requirePhotos'];
    final bool requirePhotos = requirePhotosRaw == null
        ? true
        : (requirePhotosRaw == true ||
            (requirePhotosRaw ?? '').toString().trim().toLowerCase() ==
                'true' ||
            (requirePhotosRaw ?? '').toString().trim() == '1' ||
            (requirePhotosRaw ?? '').toString().trim().toLowerCase() == 'yes');

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
      Get.snackbar('Voice AI', 'Could not create booking: missing category',
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
      Get.snackbar('Voice AI', 'Could not create booking: app not ready',
          backgroundColor: Colors.red, colorText: Colors.white);
      await _sendSpeakToAgent(
          'Sorry — the app is not ready yet. Please try again in a moment.');
      return;
    }
    if (app.userId.value.trim().isEmpty) {
      Get.snackbar('Voice AI', 'Please sign in to create a booking.',
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
      Get.snackbar('Voice AI', 'Please enable location to dispatch an artisan.',
          backgroundColor: Colors.red, colorText: Colors.white);
      await _sendSpeakToAgent(
          'Please enable location services so I can dispatch the nearest artisan.');
      return;
    }

    final categoryIds = await _resolveCategoryIdCandidatesByName(categoryName);
    if (categoryIds.isEmpty) {
      Get.snackbar(
          'Voice AI', 'Could not find "$categoryName" category in the app.',
          backgroundColor: Colors.red, colorText: Colors.white);
      await _sendSpeakToAgent(
          'Sorry — I could not find that service category in the app.');
      return;
    }

    final serviceOnCurrentLocation = address.trim().isEmpty;

    // Photos-first workflow: once the AI has all job info, it should open upload
    // and require at least 3 photos before dispatch.
    if (requirePhotos && workImageUrls.length < 3) {
      await _openPhotoUploadThenDispatch(map);
      return;
    }

    // Default schedule if AI did not provide.
    final now = DateTime.now();
    final fallbackDate = DateTime(now.year, now.month, now.day).add(
      const Duration(days: 1),
    );
    final effectiveDate =
        scheduledDate.isNotEmpty ? scheduledDate : _formatDate(fallbackDate);
    final effectiveTime = scheduledTime.isNotEmpty ? scheduledTime : '09:00:00';

    final task = await _resolveTaskForCategory(
      categoryIds: categoryIds,
      taskNameHint: taskNameHint,
    );

    print('[ai_task] resolve_result: ${task != null ? 'found' : 'null'} hint="$taskNameHint" categoryIds=${categoryIds.length}');
    if (task != null) {
      print('[ai_task] task_id="${task['id']}" name="${task['name']}"');
    }

    final List<String> jobIds;
    final Map<String, String> taskNamesById = {};
    final Map<String, double> taskCostsById = {};
    bool isRFQRequested = false;
    String rfqReason = '';

    if (task == null) {
      // No specific task found, but we have a valid category.
      // Create a booking with a generic task for this category instead of RFQ.
      print('[ai_task] No specific task found, creating generic booking for category');
      
      // Use the category as a fallback task
      final genericTaskId = categoryIds.first;
      jobIds = <String>[genericTaskId];
      taskNamesById[genericTaskId] = categoryName;
      taskCostsById[genericTaskId] = 0.0;
      isRFQRequested = false;
      rfqReason = '';
    } else {
      final taskId = (task['id'] ?? '').toString();
      final taskName = (task['name'] ?? '').toString();
      final costStr = (task['cost'] ?? '').toString();
      final cost = double.tryParse(costStr) ?? 0.0;

      if (taskId.trim().isEmpty) {
        print('[ai_task] RFQ: invalid_task_id taskId_empty');
        isRFQRequested = true;
        rfqReason = 'invalid_task_id';
        jobIds = <String>[];
      } else {
        jobIds = <String>[taskId];
        taskNamesById[taskId] = taskName;
        taskCostsById[taskId] = cost;
      }
    }

    final effectiveDescription = description.trim().isNotEmpty
        ? description
        : 'Voice request: $categoryName${notes.trim().isNotEmpty ? " - $notes" : ""}';

    try {
      final result = await FutureBookingService.createBookingAndNotify(
        userId: app.userId.value,
        jobIds: jobIds,
        taskNamesById: taskNamesById,
        taskCostsById: taskCostsById,
        scheduledDate: effectiveDate,
        scheduledTime: effectiveTime,
        serviceOnCurrentLocation: serviceOnCurrentLocation,
        userLat: app.userLat.value,
        userLng: app.userLng.value,
        providedAddress: address,
        otherLat: lat,
        otherLng: lng,
        workImageUrls: workImageUrls,
        description: effectiveDescription,
        categoryId: categoryIds.first,
        categoryName: categoryName,
        materialsResponsibility: materialsResponsibility.isEmpty
            ? 'artisan'
            : materialsResponsibility,
        isRFQRequested: isRFQRequested,
        rfqReason: rfqReason,
        createdBy: 'voice_ai',
      );

      final bookingId = (result['bookingId'] ?? '').toString();
      final isRFQ = (result['isRFQ'] ?? false) == true;
      final assigned = (result['assignedArtisanId'] ?? '').toString();

      _lastCreatedBookingId = bookingId;
      _lastAssignedArtisanId = assigned;

      if (!isRFQ && bookingId.trim().isNotEmpty) {
        _watchBookingUntilConfirmed(bookingId: bookingId);
      }

      final msg = isRFQ
          ? 'Request created (RFQ). Admin will assign the best available artisan.'
          : (assigned.isNotEmpty
              ? 'Booking created. A nearby artisan has been notified.'
              : 'Booking created. Waiting for an available artisan to accept.');

      setState(() {
        _aiResponse = msg;
      });

      _addToTranscript('System', 'Booking created: $bookingId');
      _addToTranscript('AI', msg);

      // Ensure the user hears the real outcome (not just the agent's "done" message).
      await _sendSpeakToAgent(msg);

      Get.snackbar('Voice AI', msg,
          backgroundColor: Colors.green, colorText: Colors.white);
    } catch (e) {
      debugPrint('❌ createBookingAndNotify failed: $e');
      Get.snackbar('Voice AI', 'Could not create booking: $e',
          backgroundColor: Colors.red, colorText: Colors.white);
      await _sendSpeakToAgent(
          'Sorry — I could not create the booking. Please try again.');
    }
  }

  Future<void> _openPhotoUploadThenDispatch(dynamic payload) async {
    if (!mounted) return;

    final map = payload is Map
        ? payload.map((k, v) => MapEntry(k.toString(), v))
        : <String, dynamic>{};

    final categoryName =
        (map['category_name'] ?? map['categoryName'] ?? '').toString().trim();
    final description =
        (map['problem_description'] ?? map['description'] ?? '').toString();
    final notes = (map['additional_notes'] ?? map['notes'] ?? '').toString();
    final address = (map['service_address'] ?? map['address'] ?? '').toString();

    if (categoryName.isEmpty) {
      Get.snackbar('Voice AI', 'Could not open upload: missing category',
          backgroundColor: Colors.red, colorText: Colors.white);
      return;
    }

    setState(() {
      _aiResponse =
          'Please upload at least 3 photos of the issue, then I will dispatch the nearest artisan.';
    });
    _addToTranscript('AI', 'Please upload at least 3 photos of the issue.');

    await _sendSpeakToAgent(
      'Please upload at least 3 clear photos of the issue. Then I will dispatch the nearest available artisan.',
    );

    // Give the user a moment to hear/see the instruction before navigating.
    await Future.delayed(const Duration(milliseconds: 1600));

    final urls = await Navigator.of(context).push<List<String>>(
      MaterialPageRoute(
        builder: (_) => AiPhotoUploadScreen(
          categoryName: categoryName,
          problemDescription: description,
          additionalNotes: notes,
          serviceOnCurrentLocation: address.trim().isEmpty,
          serviceAddress: address,
          minPhotos: 3,
        ),
      ),
    );

    if (!mounted) return;

    if (urls == null || urls.length < 3) {
      const msg =
          'Photo upload cancelled or incomplete. Please upload at least 3 photos to dispatch an artisan.';

      setState(() {
        _aiResponse = msg;
      });
      _addToTranscript('AI', msg);

      Get.snackbar('Voice AI', 'Photo upload cancelled or incomplete.',
          backgroundColor: Colors.orange, colorText: Colors.white);

      await _sendSpeakToAgent(msg);
      return;
    }

    final merged = <String, dynamic>{...map};
    merged['require_photos'] = false;
    merged['work_image_urls'] = urls;

    setState(() {
      _aiResponse = 'Photos uploaded. Dispatching now...';
    });
    _addToTranscript('AI', 'Photos uploaded. Dispatching now...');

    await _sendSpeakToAgent('Thanks. Photos uploaded. Dispatching now.');

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
          'Voice AI', 'Still processing your request. Please try again.',
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
  }

  void _watchBookingUntilConfirmed({required String bookingId}) {
    _bookingStatusSubscription?.cancel();
    _watchBookingLastProviderId = '';
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

      if (status == 'confirmed' || artisanConfirmed == 'yes') {
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

        final msg =
            'Booking confirmed. Order number: $bookingId. Artisan: ${artisanName.isNotEmpty ? artisanName : artisanId}. $categoryName on $scheduledDate at $scheduledTime.';

        setState(() {
          _aiResponse = msg;
        });
        _addToTranscript('AI', msg);

        await _sendSpeakToAgent(msg);

        try {
          if (Get.isRegistered<AppController>()) {
            final app = Get.find<AppController>();
            app.currentIndex.value = 2;
          }
        } catch (_) {}

        Get.snackbar('Voice AI', msg,
            backgroundColor: Colors.green, colorText: Colors.white);

        await _bookingStatusSubscription?.cancel();
        _bookingStatusSubscription = null;
        return;
      }

      if (status == 'pending_assignment') {
        setState(() {
          _aiResponse =
              'Still finding an available artisan nearby. Please hold on...';
        });
        await _sendSpeakToAgent(
          'I am still finding an available artisan nearby. Please hold on.',
        );
        return;
      }

      if (status == 'pending') {
        setState(() {
          _aiResponse = 'Request sent. Waiting for artisan confirmation...';
        });
        await _sendSpeakToAgent(
          'Request sent. Waiting for the artisan to confirm.',
        );
      }
    });
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
          'Voice AI Assistant',
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
