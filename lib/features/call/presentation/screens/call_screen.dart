import 'dart:async';

import 'package:flutter/material.dart';

import '../../../../core/config/env_config.dart';
import '../../../../core/models/call_log.dart';
import '../../../../core/services/audio_stream_receiver.dart';
import '../../../../core/services/exotel_service.dart';
import '../../../../core/services/deepgram_stt_service.dart';
import '../../../../core/services/firestore_service.dart';
import '../../../../core/services/llm_insights_service.dart';
import '../../../../core/services/local_storage_service.dart';

/// Call Screen with Live Transcription + AI Insights
/// Shows real-time transcription (Deepgram) and LLM-powered insights (Gemma)
class CallScreen extends StatefulWidget {
  final String fromNumber;
  final String toNumber;

  const CallScreen({
    super.key,
    required this.fromNumber,
    required this.toNumber,
  });

  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen> {
  final ExotelService _exotel = ExotelService();
  final AudioStreamReceiver _audioReceiver = AudioStreamReceiver();
  final DeepgramSttService _deepgramStt = DeepgramSttService();
  final LLMInsightsService _llmInsights = LLMInsightsService();
  final LocalStorageService _localStorage = LocalStorageService();
  final FirestoreService _firestoreService = FirestoreService();

  ExotelCallStatus _callStatus = ExotelCallStatus.queued;
  // ignore: unused_field - Used for future stream state display
  StreamConnectionState _streamState = StreamConnectionState.disconnected;
  Duration _callDuration = Duration.zero;
  Timer? _durationTimer;
  Timer? _persistTimer;
  bool _streamConnected = false;

  // Leg status tracking
  String? _leg1Status;
  String? _leg2Status;
  String? _answeredBy;
  bool _timerStarted = false;
  int? _conversationDuration; // Actual talk time from Exotel (seconds)

  // Call log for persistence
  CallLog? _currentCallLog;

  // Transcription state
  final List<TranscriptEntry> _transcripts = [];
  String? _partialTranscript;

  // LLM Insights state
  final List<LLMInsight> _insights = [];
  String? _currentSentiment;

  // Audio level
  double _audioLevel = 0.0;

  // Subscriptions
  StreamSubscription? _callStatusSub;
  StreamSubscription? _streamStateSub;
  StreamSubscription? _audioChunkSub;
  StreamSubscription? _transcriptSub;
  StreamSubscription? _insightsSub;
  StreamSubscription? _legStatusSub;

  @override
  void initState() {
    super.initState();
    _initServices();
    _setupListeners();
    _initiateCall();
  }

  Future<void> _initServices() async {
    await _localStorage.init();
  }

  void _setupListeners() {
    // Listen to Exotel call status
    _callStatusSub = _exotel.statusStream.listen((status) {
      debugPrint('>>> Exotel call status changed: $status');
      setState(() => _callStatus = status);

      // Update leg status and answeredBy from current call
      _updateLegStatusFromExotel();

      if (status == ExotelCallStatus.inProgress) {
        debugPrint('>>> Call is IN PROGRESS - connecting audio stream...');
        _startPersistTimer();
        if (!_streamConnected) {
          _streamConnected = true;
          _connectAudioStream();
        }
        // NOTE: Don't start timer here - timer should only start when leg2 answers
        // (i.e., when the actual conversation begins). The leg status event will
        // trigger timer start via _handleLegStatusEvent when leg2 is answered.
      } else if (status == ExotelCallStatus.completed ||
          status == ExotelCallStatus.failed ||
          status == ExotelCallStatus.busy ||
          status == ExotelCallStatus.noAnswer) {
        debugPrint('>>> Call ended with status: $status');
        _stopDurationTimer();
        _stopPersistTimer();
        _handleCallEnd(status);
      }
    });

    // Listen to audio stream state
    _streamStateSub = _audioReceiver.stateStream.listen((state) {
      setState(() => _streamState = state);
    });

    // Listen to audio chunks for level visualization
    _audioChunkSub = _audioReceiver.audioChunkStream.listen((chunk) {
      setState(() {
        _audioLevel = _calculateAudioLevel(chunk.data);
      });
    });

    // Listen to transcripts from Deepgram
    _transcriptSub = _deepgramStt.transcriptStream.listen((transcript) {
      setState(() {
        if (transcript.isFinal) {
          // Final transcript - add to list
          _transcripts.add(TranscriptEntry(
            text: transcript.text,
            speaker: transcript.speaker,
            timestamp: transcript.timestamp,
            isFinal: true,
          ));
          _partialTranscript = null;

          // Keep only last 50 transcripts
          if (_transcripts.length > 50) {
            _transcripts.removeAt(0);
          }

          // Add to CallLog
          if (_currentCallLog != null) {
            final speakerLabel = transcript.speaker ?? 'unknown';
            _currentCallLog = _currentCallLog!.addTranscript(
              '[$speakerLabel] ${transcript.text}',
            );
          }

          // Send to LLM for analysis
          _llmInsights.processTranscription(
            transcript.text,
            speaker: transcript.speaker,
          );
        } else {
          // Partial transcript
          _partialTranscript = transcript.text;
        }
      });
    });

    // Listen to LLM insights
    _insightsSub = _llmInsights.insightsStream.listen((insight) {
      setState(() {
        // Update sentiment separately for quick access
        if (insight.type == LLMInsightType.sentiment) {
          _currentSentiment = insight.content;
        }

        // Add to insights list
        _insights.add(insight);

        // Keep only last 20 insights
        if (_insights.length > 20) {
          _insights.removeAt(0);
        }

        // Add to CallLog
        if (_currentCallLog != null) {
          _currentCallLog = _currentCallLog!.addInsight(
            '[${insight.type.name}] ${insight.content}',
          );
        }
      });
    });

    // Listen to real-time leg status events from StatusCallback (via WebSocket)
    _legStatusSub = _audioReceiver.legStatusStream.listen((event) {
      debugPrint('>>> Received leg status event: $event');
      _handleLegStatusEvent(event);
    });
  }

  /// Handle real-time leg status events from Exotel StatusCallback
  void _handleLegStatusEvent(LegStatusEvent event) {
    setState(() {
      if (event.legNumber == 1) {
        // Leg 1 (From/Sales person)
        if (event.eventType == 'answered') {
          // Use actual leg_status from event ('in-progress' when active)
          _leg1Status = event.legStatus ?? 'in-progress';
          debugPrint('>>> Leg 1 (Sales) answered - status: $_leg1Status');
        } else if (event.eventType == 'terminal') {
          _leg1Status = event.legStatus ?? 'completed';
          debugPrint('>>> Leg 1 (Sales) terminal: ${event.legStatus}');
        }
      } else if (event.legNumber == 2) {
        // Leg 2 (To/Lead)
        if (event.eventType == 'answered') {
          // Use actual leg_status from event ('in-progress' when active)
          _leg2Status = event.legStatus ?? 'in-progress';
          _answeredBy = event.answeredBy;
          debugPrint('>>> Leg 2 (Lead) answered - status: $_leg2Status, answeredBy: ${event.answeredBy}');

          // Start timer when both legs are connected (leg 2 answered)
          // This is the correct time to start - when conversation begins
          if (!_timerStarted) {
            debugPrint('>>> Starting call timer on Leg 2 answered (conversation started)');
            _timerStarted = true;
            _startDurationTimer();
          }
        } else if (event.eventType == 'terminal') {
          _leg2Status = event.legStatus ?? 'completed';
          debugPrint('>>> Leg 2 (Lead) terminal: ${event.legStatus}');
        }
      }
    });

    // Update call log
    if (_currentCallLog != null) {
      _currentCallLog = _currentCallLog!.copyWith(
        leg1Status: _leg1Status,
        leg2Status: _leg2Status,
        answeredBy: _answeredBy,
      );
    }
  }

  /// Update leg status from Exotel current call
  void _updateLegStatusFromExotel() {
    final currentCall = _exotel.currentCall;
    if (currentCall != null) {
      setState(() {
        _leg1Status = currentCall.leg1Status;
        _leg2Status = currentCall.leg2Status;
        _answeredBy = currentCall.answeredBy;
        // Store conversation duration when available (only after call ends)
        if (currentCall.conversationDuration != null) {
          _conversationDuration = currentCall.conversationDuration;
        }
      });

      debugPrint('>>> Leg status update: leg1=${currentCall.leg1Status}, leg2=${currentCall.leg2Status}, answeredBy=${currentCall.answeredBy}, convDuration=${currentCall.conversationDuration}');

      // Update call log with new status
      if (_currentCallLog != null) {
        _currentCallLog = _currentCallLog!.copyWith(
          status: currentCall.status,
          leg1Status: currentCall.leg1Status,
          leg2Status: currentCall.leg2Status,
          answeredBy: currentCall.answeredBy,
          durationSeconds: currentCall.conversationDuration ?? currentCall.duration,
          conversationDurationSeconds: currentCall.conversationDuration,
        );
      }
    }
  }

  /// Start periodic persistence timer
  void _startPersistTimer() {
    _persistTimer?.cancel();
    _persistTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      _persistCallState();
    });
  }

  /// Stop persistence timer
  void _stopPersistTimer() {
    _persistTimer?.cancel();
    _persistTimer = null;
  }

  /// Persist current call state to local storage
  Future<void> _persistCallState() async {
    if (_currentCallLog != null) {
      await _localStorage.updateActiveCall(_currentCallLog!);
      debugPrint('CallScreen: Persisted call state');
    }
  }

  /// Handle call end - save to history and sync
  Future<void> _handleCallEnd(ExotelCallStatus finalStatus) async {
    if (_currentCallLog == null) return;

    // Get final details from Exotel
    final finalDetails = _exotel.currentCall;
    final conversationDuration = finalDetails?.conversationDuration;

    // Use conversation duration from Exotel if available, otherwise use our timer
    final duration = conversationDuration ?? _callDuration.inSeconds;

    debugPrint('>>> Call ended - Timer: ${_callDuration.inSeconds}s, Exotel conversationDuration: $conversationDuration');

    // Update final status
    final finalCallLog = _currentCallLog!.copyWith(
      status: finalStatus,
      endTime: DateTime.now(),
      durationSeconds: duration,
      conversationDurationSeconds: conversationDuration,
      leg1Status: finalDetails?.leg1Status ?? _leg1Status,
      leg2Status: finalDetails?.leg2Status ?? _leg2Status,
      answeredBy: finalDetails?.answeredBy ?? _answeredBy,
    );

    // Clear active call and save to history
    await _localStorage.clearActiveCall();
    await _localStorage.saveCallLog(finalCallLog);

    // Add to pending sync queue
    await _localStorage.addToPendingSync(finalCallLog);

    // Placeholder: Sync to Firestore
    await _firestoreService.syncCallLog(finalCallLog);

    // Sync insights
    if (_insights.isNotEmpty) {
      await _firestoreService.syncInsights(finalCallLog.callSid, _insights);
    }

    debugPrint('CallScreen: Call saved to history - ${finalCallLog.callSid}');
  }

  Future<void> _initiateCall() async {
    // Initialize LLM service
    await _llmInsights.initialize();
    _llmInsights.startProcessing();

    // Make the call via Exotel
    final streamUrl = EnvConfig.exotelStreamUrl;
    final statusCallbackUrl = EnvConfig.hasStatusCallbackConfigured
        ? EnvConfig.exotelStatusCallbackUrl
        : null;

    debugPrint('CallScreen: StatusCallback URL: $statusCallbackUrl');

    final response = await _exotel.connectCall(
      fromNumber: widget.fromNumber,
      toNumber: widget.toNumber,
      streamUrl: streamUrl,
      streamBegin: 'atLeg1connect',  // lowercase 'c' per Exotel API
      record: true,
      statusCallback: statusCallbackUrl,
    );

    if (response == null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Failed to initiate call'),
          backgroundColor: Colors.red,
        ),
      );
      Navigator.of(context).pop();
      return;
    }

    // Create CallLog and save as active call
    if (response != null) {
      _currentCallLog = CallLog.fromExotelResponse(response);
      await _localStorage.saveActiveCall(_currentCallLog!);
      debugPrint('CallScreen: Created call log - ${_currentCallLog!.callSid}');

      // Update leg status
      setState(() {
        _leg1Status = response.leg1Status;
        _leg2Status = response.leg2Status;
        _answeredBy = response.answeredBy;
      });
    }
  }

  Future<void> _connectAudioStream() async {
    final callSid = _exotel.currentCall?.sid;

    debugPrint('=== _connectAudioStream DEBUG ===');
    debugPrint('callSid: $callSid');
    debugPrint('hasStreamingConfigured: ${EnvConfig.hasStreamingConfigured}');

    if (callSid != null && EnvConfig.hasStreamingConfigured) {
      debugPrint(
          'Connecting to audio stream at ${EnvConfig.audioStreamWsUrl}...');
      final connected = await _audioReceiver.connect(
        wsUrl: EnvConfig.audioStreamWsUrl,
        callSid: callSid,
      );
      debugPrint('AudioReceiver connect result: $connected');

      if (connected) {
        debugPrint('Starting Deepgram transcription...');
        _deepgramStt.startTranscription(_audioReceiver.audioChunkStream);
      } else {
        debugPrint('ERROR: Failed to connect to audio stream!');
      }
    }
  }

  void _startDurationTimer() {
    _durationTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      setState(() {
        _callDuration = _callDuration + const Duration(seconds: 1);
      });
    });
  }

  void _stopDurationTimer() {
    _durationTimer?.cancel();
    _durationTimer = null;
  }

  double _calculateAudioLevel(List<int> data) {
    if (data.isEmpty) return 0.0;
    double sum = 0;
    for (int i = 0; i < data.length - 1; i += 2) {
      int sample = data[i] | (data[i + 1] << 8);
      if (sample > 32767) sample -= 65536;
      sum += sample.abs();
    }
    return (sum / (data.length / 2) / 32768.0).clamp(0.0, 1.0);
  }

  Future<void> _endCall() async {
    debugPrint('>>> Ending call, cleaning up...');
    _deepgramStt.stopAndDisableReconnect();
    _llmInsights.stopProcessing();
    await _audioReceiver.disconnect();
    _exotel.endCall();
    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  String _formatDuration(Duration duration) {
    final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  @override
  void dispose() {
    _callStatusSub?.cancel();
    _streamStateSub?.cancel();
    _audioChunkSub?.cancel();
    _transcriptSub?.cancel();
    _insightsSub?.cancel();
    _legStatusSub?.cancel();
    _stopDurationTimer();
    _stopPersistTimer();
    _deepgramStt.dispose();
    _audioReceiver.dispose();
    _llmInsights.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0D0D0D),
      body: SafeArea(
        child: Column(
          children: [
            // Top bar with status and duration
            _buildTopBar(),

            // Call info section with leg status
            _buildCallInfoSection(),

            // Audio level indicator
            _buildAudioLevel(),

            const SizedBox(height: 8),

            // Main content: Transcription + Insights
            Expanded(
              child: _buildMainContent(),
            ),

            // End call button
            _buildEndCallButton(),

            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }

  Widget _buildTopBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.03),
        border: Border(
          bottom: BorderSide(color: Colors.white.withValues(alpha: 0.1)),
        ),
      ),
      child: Row(
        children: [
          // Status indicator
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: _getStatusColor().withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                    color: _getStatusColor(),
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  _getStatusText(),
                  style: TextStyle(
                    color: _getStatusColor(),
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(width: 8),

          // AnsweredBy badge
          if (_answeredBy != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: _answeredBy == 'Human'
                    ? Colors.green.withValues(alpha: 0.15)
                    : Colors.orange.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    _answeredBy == 'Human' ? Icons.person : Icons.smart_toy,
                    size: 12,
                    color: _answeredBy == 'Human' ? Colors.green : Colors.orange,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    _answeredBy!,
                    style: TextStyle(
                      color: _answeredBy == 'Human' ? Colors.green : Colors.orange,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),

          const Spacer(),

          // Call info
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                '${widget.fromNumber} → ${widget.toNumber}',
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.6),
                  fontSize: 11,
                ),
              ),
              // Show timer during call, conversationDuration after call ends
              if (_callStatus == ExotelCallStatus.inProgress)
                Text(
                  _formatDuration(_callDuration),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                )
              else if (_callStatus == ExotelCallStatus.completed && _conversationDuration != null)
                Text(
                  'Talk: ${_formatDuration(Duration(seconds: _conversationDuration!))}',
                  style: const TextStyle(
                    color: Colors.green,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  /// Build call info section with leg status indicators
  Widget _buildCallInfoSection() {
    // Determine connection status from leg status events
    // Leg is connected when status is 'in-progress' (active) or 'completed' (ended successfully)
    final leg1Connected = _leg1Status == 'in-progress' ||
        _leg1Status == 'completed' ||
        _callStatus == ExotelCallStatus.ringing;  // Fallback: ringing means leg1 is being called
    final leg2Connected = _leg2Status == 'in-progress' ||
        _leg2Status == 'completed';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.02),
        border: Border(
          bottom: BorderSide(color: Colors.white.withValues(alpha: 0.05)),
        ),
      ),
      child: Row(
        children: [
          // Leg 1 (Sales)
          Expanded(
            child: _buildLegStatus(
              legNumber: 1,
              label: 'Sales',
              phoneNumber: widget.fromNumber,
              status: _getLeg1DisplayStatus(),
              isConnected: leg1Connected,
            ),
          ),

          // Arrow
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Icon(
              Icons.arrow_forward,
              color: Colors.white.withValues(alpha: 0.3),
              size: 16,
            ),
          ),

          // Leg 2 (Lead)
          Expanded(
            child: _buildLegStatus(
              legNumber: 2,
              label: 'Lead',
              phoneNumber: widget.toNumber,
              status: _getLeg2DisplayStatus(),
              isConnected: leg2Connected,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLegStatus({
    required int legNumber,
    required String label,
    required String phoneNumber,
    required String status,
    required bool isConnected,
  }) {
    final color = isConnected ? Colors.green : Colors.amber;

    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  'LEG $legNumber',
                  style: TextStyle(
                    color: color,
                    fontSize: 9,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.7),
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const Spacer(),
              if (isConnected)
                Icon(
                  Icons.check_circle,
                  color: Colors.green,
                  size: 14,
                ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            phoneNumber,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.5),
              fontSize: 10,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            status,
            style: TextStyle(
              color: color,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  String _getLeg1DisplayStatus() {
    // Exotel only provides leg status after call ends
    // During call, infer from overall status
    if (_leg1Status != null) {
      return _formatLegStatus(_leg1Status!);
    }
    switch (_callStatus) {
      case ExotelCallStatus.queued:
        return 'Calling...';
      case ExotelCallStatus.ringing:
        return 'Ringing...';
      case ExotelCallStatus.inProgress:
        return 'In Progress';  // If inProgress, leg1 is actively connected
      case ExotelCallStatus.completed:
        return 'Completed';
      case ExotelCallStatus.failed:
      case ExotelCallStatus.busy:
      case ExotelCallStatus.noAnswer:
        return 'Failed';
      default:
        return 'Pending';
    }
  }

  String _getLeg2DisplayStatus() {
    // Exotel only provides leg status after call ends
    // During call, infer from overall status
    if (_leg2Status != null) {
      return _formatLegStatus(_leg2Status!);
    }
    switch (_callStatus) {
      case ExotelCallStatus.queued:
        return 'Waiting';
      case ExotelCallStatus.ringing:
        return 'Connecting...';  // Leg1 answered, connecting to leg2
      case ExotelCallStatus.inProgress:
        return 'In Progress';  // If inProgress, both legs are actively talking
      case ExotelCallStatus.completed:
        return 'Completed';
      case ExotelCallStatus.failed:
      case ExotelCallStatus.busy:
      case ExotelCallStatus.noAnswer:
        return 'Failed';
      default:
        return 'Waiting';
    }
  }

  String _formatLegStatus(String status) {
    switch (status.toLowerCase()) {
      case 'in-progress':
        return 'In Progress';  // Active call - both legs talking
      case 'completed':
        return 'Completed';  // Call ended successfully
      case 'ringing':
        return 'Ringing...';
      case 'busy':
        return 'Busy';
      case 'no-answer':
        return 'No Answer';
      case 'failed':
        return 'Failed';
      case 'canceled':
        return 'Canceled';
      default:
        return status;
    }
  }

  Widget _buildAudioLevel() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      height: 3,
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(2),
      ),
      child: FractionallySizedBox(
        alignment: Alignment.centerLeft,
        widthFactor: _audioLevel.clamp(0.0, 1.0),
        child: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [Colors.green, Colors.greenAccent.shade400],
            ),
            borderRadius: BorderRadius.circular(2),
          ),
        ),
      ),
    );
  }

  Widget _buildMainContent() {
    return LayoutBuilder(
      builder: (context, constraints) {
        // Use side-by-side layout on wider screens
        if (constraints.maxWidth > 600) {
          return Row(
            children: [
              // Transcription panel (60%)
              Expanded(
                flex: 6,
                child: _buildTranscriptionPanel(),
              ),
              // Divider
              Container(
                width: 1,
                color: Colors.white.withValues(alpha: 0.1),
              ),
              // Insights panel (40%)
              Expanded(
                flex: 4,
                child: _buildInsightsPanel(),
              ),
            ],
          );
        } else {
          // Stack layout on narrow screens
          return Column(
            children: [
              // Transcription (60%)
              Expanded(
                flex: 6,
                child: _buildTranscriptionPanel(),
              ),
              // Divider
              Container(
                height: 1,
                color: Colors.white.withValues(alpha: 0.1),
              ),
              // Insights (40%)
              Expanded(
                flex: 4,
                child: _buildInsightsPanel(),
              ),
            ],
          );
        }
      },
    );
  }

  Widget _buildTranscriptionPanel() {
    return Container(
      margin: const EdgeInsets.all(8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.03),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Row(
            children: [
              const Icon(Icons.mic, color: Colors.blue, size: 16),
              const SizedBox(width: 6),
              const Text(
                'Live Transcription',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              // Deepgram status
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: _deepgramStt.isRunning
                      ? Colors.green.withValues(alpha: 0.2)
                      : Colors.orange.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_deepgramStt.isRunning)
                      Container(
                        width: 5,
                        height: 5,
                        margin: const EdgeInsets.only(right: 4),
                        decoration: const BoxDecoration(
                          color: Colors.greenAccent,
                          shape: BoxShape.circle,
                        ),
                      ),
                    Text(
                      _deepgramStt.isRunning ? 'Live' : 'Standby',
                      style: TextStyle(
                        color: _deepgramStt.isRunning
                            ? Colors.greenAccent
                            : Colors.orange,
                        fontSize: 10,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),

          const SizedBox(height: 12),

          // Transcripts
          Expanded(
            child: (_transcripts.isEmpty && _partialTranscript == null)
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.record_voice_over,
                          color: Colors.white.withValues(alpha: 0.2),
                          size: 32,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          _callStatus == ExotelCallStatus.inProgress
                              ? 'Listening...'
                              : 'Waiting for call',
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.4),
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  )
                : ListView.builder(
                    itemCount: _transcripts.length +
                        (_partialTranscript != null ? 1 : 0),
                    itemBuilder: (context, index) {
                      final isPartial = index == _transcripts.length;

                      if (isPartial) {
                        return _buildTranscriptBubble(
                          _partialTranscript!,
                          null,
                          isPartial: true,
                        );
                      }

                      final entry = _transcripts[index];
                      return _buildTranscriptBubble(
                        entry.text,
                        entry.speaker,
                        isPartial: false,
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildTranscriptBubble(String text, String? speaker,
      {bool isPartial = false}) {
    final isAgent = speaker == 'agent';
    final color = isAgent ? Colors.blue : Colors.green;

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (isPartial)
            Container(
              width: 2,
              height: 16,
              margin: const EdgeInsets.only(right: 6, top: 2),
              decoration: BoxDecoration(
                color: Colors.greenAccent.withValues(alpha: 0.7),
                borderRadius: BorderRadius.circular(1),
              ),
            ),
          if (speaker != null && !isPartial)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              margin: const EdgeInsets.only(right: 6),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                speaker.toUpperCase(),
                style: TextStyle(
                  color: color,
                  fontSize: 9,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                color: isPartial
                    ? Colors.white.withValues(alpha: 0.5)
                    : Colors.white.withValues(alpha: 0.9),
                fontSize: 13,
                fontStyle: isPartial ? FontStyle.italic : FontStyle.normal,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInsightsPanel() {
    return Container(
      margin: const EdgeInsets.all(8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.03),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header with sentiment
          Row(
            children: [
              const Icon(Icons.psychology, color: Colors.purple, size: 16),
              const SizedBox(width: 6),
              const Text(
                'AI Insights',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              // Sentiment indicator
              if (_currentSentiment != null)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: _getSentimentColor(_currentSentiment!)
                        .withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        _getSentimentIcon(_currentSentiment!),
                        color: _getSentimentColor(_currentSentiment!),
                        size: 12,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        _currentSentiment!,
                        style: TextStyle(
                          color: _getSentimentColor(_currentSentiment!),
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              // LLM status
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: _llmInsights.isModelLoaded
                      ? Colors.purple.withValues(alpha: 0.2)
                      : Colors.orange.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  _llmInsights.isModelLoaded ? 'LLM Ready' : 'LLM Loading...',
                  style: TextStyle(
                    color: _llmInsights.isModelLoaded
                        ? Colors.purple
                        : Colors.orange,
                    fontSize: 9,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),

          const SizedBox(height: 12),

          // Insights list
          Expanded(
            child: _insights.isEmpty
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.lightbulb_outline,
                          color: Colors.white.withValues(alpha: 0.2),
                          size: 32,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Insights will appear here',
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.4),
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  )
                : ListView.builder(
                    itemCount: _insights.length,
                    itemBuilder: (context, index) {
                      // Show newest first
                      final insight = _insights[_insights.length - 1 - index];
                      return _buildInsightCard(insight);
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildInsightCard(LLMInsight insight) {
    final color = _getInsightColor(insight.type);
    final icon = _getInsightIcon(insight.type);

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Type label
          Row(
            children: [
              Icon(icon, color: color, size: 12),
              const SizedBox(width: 4),
              Text(
                insight.type.toString().split('.').last.toUpperCase(),
                style: TextStyle(
                  color: color,
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                ),
              ),
              ...[
                const Spacer(),
                Text(
                  '${(insight.confidence * 100).toInt()}%',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.4),
                    fontSize: 9,
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 4),
          // Content
          Text(
            insight.content,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.85),
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEndCallButton() {
    return GestureDetector(
      onTap: _endCall,
      child: Container(
        width: 56,
        height: 56,
        decoration: BoxDecoration(
          color: Colors.red,
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: Colors.red.withValues(alpha: 0.4),
              blurRadius: 12,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: const Icon(
          Icons.call_end,
          color: Colors.white,
          size: 24,
        ),
      ),
    );
  }

  Color _getStatusColor() {
    switch (_callStatus) {
      case ExotelCallStatus.inProgress:
        return Colors.green;
      case ExotelCallStatus.ringing:
      case ExotelCallStatus.queued:
        return Colors.amber;
      case ExotelCallStatus.completed:
        return Colors.blue;
      default:
        return Colors.red;
    }
  }

  String _getStatusText() {
    switch (_callStatus) {
      case ExotelCallStatus.queued:
        return 'Queued';
      case ExotelCallStatus.ringing:
        return 'Ringing';
      case ExotelCallStatus.inProgress:
        return 'In Progress';  // Both legs talking
      case ExotelCallStatus.completed:
        return 'Completed';
      case ExotelCallStatus.failed:
        return 'Failed';
      case ExotelCallStatus.busy:
        return 'Busy';
      case ExotelCallStatus.noAnswer:
        return 'No Answer';
      default:
        return 'Unknown';
    }
  }

  Color _getSentimentColor(String sentiment) {
    switch (sentiment.toLowerCase()) {
      case 'positive':
        return Colors.green;
      case 'negative':
        return Colors.red;
      default:
        return Colors.grey;
    }
  }

  IconData _getSentimentIcon(String sentiment) {
    switch (sentiment.toLowerCase()) {
      case 'positive':
        return Icons.sentiment_satisfied;
      case 'negative':
        return Icons.sentiment_dissatisfied;
      default:
        return Icons.sentiment_neutral;
    }
  }

  Color _getInsightColor(LLMInsightType type) {
    switch (type) {
      case LLMInsightType.sentiment:
        return Colors.blue;
      case LLMInsightType.summary:
        return Colors.purple;
      case LLMInsightType.keyPoints:
        return Colors.teal;
      case LLMInsightType.suggestion:
        return Colors.amber;
      case LLMInsightType.objectionHandling:
        return Colors.orange;
      case LLMInsightType.nextAction:
        return Colors.green;
    }
  }

  IconData _getInsightIcon(LLMInsightType type) {
    switch (type) {
      case LLMInsightType.sentiment:
        return Icons.mood;
      case LLMInsightType.summary:
        return Icons.summarize;
      case LLMInsightType.keyPoints:
        return Icons.format_list_bulleted;
      case LLMInsightType.suggestion:
        return Icons.lightbulb;
      case LLMInsightType.objectionHandling:
        return Icons.warning_amber;
      case LLMInsightType.nextAction:
        return Icons.arrow_forward;
    }
  }
}

/// Entry for a transcript in the list
class TranscriptEntry {
  final String text;
  final String? speaker;
  final DateTime timestamp;
  final bool isFinal;

  TranscriptEntry({
    required this.text,
    this.speaker,
    required this.timestamp,
    required this.isFinal,
  });
}
