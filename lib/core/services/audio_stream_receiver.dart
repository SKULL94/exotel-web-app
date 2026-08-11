import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../config/env_config.dart';

/// Audio chunk received from Exotel stream
class AudioChunk {
  final Uint8List data;
  final DateTime timestamp;
  final String? callSid;
  final int sequenceNumber;
  final String? speaker; // 'caller', 'agent', or null for mixed

  AudioChunk({
    required this.data,
    required this.timestamp,
    this.callSid,
    required this.sequenceNumber,
    this.speaker,
  });
}

/// Transcript received from server (real-time STT)
class TranscriptEvent {
  final String text;
  final bool isFinal; // true = complete utterance, false = partial
  final String? speaker; // 'caller' or 'agent'
  final String? language;
  final DateTime timestamp;

  TranscriptEvent({
    required this.text,
    required this.isFinal,
    this.speaker,
    this.language,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();
}

/// Leg status event from Exotel StatusCallback (via Python server)
class LegStatusEvent {
  final String callSid;
  final String eventType; // 'answered' or 'terminal'
  final int legNumber; // 1 = From (Sales), 2 = To (Lead)
  final String? legStatus; // 'completed', 'busy', 'no-answer', etc.
  final String? answeredBy; // 'Human', 'Machine', 'NotSure'
  final int? onCallDuration;
  final DateTime timestamp;

  LegStatusEvent({
    required this.callSid,
    required this.eventType,
    required this.legNumber,
    this.legStatus,
    this.answeredBy,
    this.onCallDuration,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();

  factory LegStatusEvent.fromJson(Map<String, dynamic> json) {
    return LegStatusEvent(
      callSid: json['call_sid'] ?? json['CallSid'] ?? '',
      eventType: json['event_type'] ?? json['EventType'] ?? 'unknown',
      legNumber: json['leg_number'] ?? json['LegNumber'] ?? 0,
      legStatus: json['leg_status'] ?? json['Status'],
      answeredBy: json['answered_by'] ?? json['AnsweredBy'],
      onCallDuration: json['on_call_duration'] ?? json['OnCallDuration'],
    );
  }

  @override
  String toString() => 'LegStatusEvent(callSid: $callSid, event: $eventType, leg: $legNumber, status: $legStatus, answeredBy: $answeredBy)';
}

/// WebSocket connection state
enum StreamConnectionState {
  disconnected,
  connecting,
  connected,
  error,
}

/// Audio Stream Receiver Service
/// Receives audio streams from Exotel via WebSocket
/// and forwards to Krisp AI and On-Device AI for processing
class AudioStreamReceiver {
  static final AudioStreamReceiver _instance = AudioStreamReceiver._internal();
  factory AudioStreamReceiver() => _instance;
  AudioStreamReceiver._internal();

  WebSocketChannel? _channel;
  StreamSubscription? _subscription;

  StreamController<StreamConnectionState>? _stateController;
  Stream<StreamConnectionState> get stateStream {
    _stateController ??= StreamController<StreamConnectionState>.broadcast();
    return _stateController!.stream;
  }

  StreamConnectionState _currentState = StreamConnectionState.disconnected;
  StreamConnectionState get currentState => _currentState;

  StreamController<AudioChunk>? _audioChunkController;
  Stream<AudioChunk> get audioChunkStream {
    _audioChunkController ??= StreamController<AudioChunk>.broadcast();
    return _audioChunkController!.stream;
  }

  StreamController<TranscriptEvent>? _transcriptController;
  Stream<TranscriptEvent> get transcriptStream {
    _transcriptController ??= StreamController<TranscriptEvent>.broadcast();
    return _transcriptController!.stream;
  }

  StreamController<LegStatusEvent>? _legStatusController;
  Stream<LegStatusEvent> get legStatusStream {
    _legStatusController ??= StreamController<LegStatusEvent>.broadcast();
    return _legStatusController!.stream;
  }

  int _sequenceNumber = 0;
  String? _currentCallSid;
  bool _isDisposed = false;

  // Audio processing callbacks
  Function(AudioChunk)? onAudioChunkReceived;
  Function(Uint8List)? onProcessedAudioReady;

  /// Connect to WebSocket server for receiving audio stream
  Future<bool> connect({
    String? wsUrl,
    String? callSid,
  }) async {
    if (_isDisposed) {
      _reset();
    }

    if (_currentState == StreamConnectionState.connected) {
      debugPrint('AudioStreamReceiver: Already connected');
      return true;
    }

    _currentCallSid = callSid;
    _sequenceNumber = 0;

    final url = wsUrl ?? EnvConfig.audioStreamWsUrl;

    try {
      debugPrint('AudioStreamReceiver: Connecting to $url');
      _updateState(StreamConnectionState.connecting);

      _channel = WebSocketChannel.connect(Uri.parse(url));

      // Wait for connection to be established
      await _channel!.ready;

      _subscription = _channel!.stream.listen(
        _handleMessage,
        onError: _handleError,
        onDone: _handleDone,
      );

      _updateState(StreamConnectionState.connected);
      debugPrint('AudioStreamReceiver: Connected successfully');

      // Send initial handshake if call SID is provided
      if (callSid != null) {
        _sendHandshake(callSid);
      }

      return true;
    } catch (e) {
      debugPrint('AudioStreamReceiver: Connection error - $e');
      _updateState(StreamConnectionState.error);
      return false;
    }
  }

  /// Reset controllers after disposal
  void _reset() {
    _stateController = StreamController<StreamConnectionState>.broadcast();
    _audioChunkController = StreamController<AudioChunk>.broadcast();
    _transcriptController = StreamController<TranscriptEvent>.broadcast();
    _legStatusController = StreamController<LegStatusEvent>.broadcast();
    _isDisposed = false;
    _currentState = StreamConnectionState.disconnected;
  }

  /// Send handshake message to server
  void _sendHandshake(String callSid) {
    final message = jsonEncode({
      'call_sid': callSid,
      'timestamp': DateTime.now().toIso8601String(),
    });
    _channel?.sink.add(message);
    debugPrint('AudioStreamReceiver: Sent handshake for call $callSid');
  }

  /// Handle incoming WebSocket messages
  void _handleMessage(dynamic message) {
    if (_isDisposed) return;

    try {
      if (message is Uint8List) {
        _handleAudioData(message);
      } else if (message is String) {
        _handleControlMessage(message);
      } else if (message is List<int>) {
        _handleAudioData(Uint8List.fromList(message));
      }
    } catch (e) {
      debugPrint('AudioStreamReceiver: Error handling message - $e');
    }
  }

  /// Handle binary audio data
  void _handleAudioData(Uint8List data, {String? speaker}) {
    if (_isDisposed) return;

    _sequenceNumber++;

    final chunk = AudioChunk(
      data: data,
      timestamp: DateTime.now(),
      callSid: _currentCallSid,
      sequenceNumber: _sequenceNumber,
      speaker: speaker,
    );

    _audioChunkController?.add(chunk);
    onAudioChunkReceived?.call(chunk);

    if (_sequenceNumber % 100 == 0) {
      debugPrint(
          'AudioStreamReceiver: Received ${chunk.data.length} bytes (seq: $_sequenceNumber, speaker: $speaker)');
    }
  }

  /// Handle JSON control messages
  void _handleControlMessage(String message) {
    try {
      final json = jsonDecode(message);
      // Server uses 'event' field, not 'type'
      final event = json['event'] ?? json['type'];

      switch (event) {
        case 'audio':
          // Server sends base64-encoded audio in 'audio' field
          final audioBase64 = json['audio'];
          if (audioBase64 != null) {
            final audioData = base64Decode(audioBase64);

            // Log first audio chunk to verify data flow
            if (_sequenceNumber == 0) {
              debugPrint('AudioStreamReceiver: *** First audio chunk received ***');
              debugPrint('AudioStreamReceiver: base64 length=${audioBase64.length}, decoded=${audioData.length} bytes');
              if (audioData.length >= 10) {
                debugPrint('AudioStreamReceiver: first 10 bytes=${audioData.sublist(0, 10)}');
              }
            }

            // Extract speaker info from metadata if available
            // Exotel dual-channel: 'caller' (leg1) or 'agent' (leg2)
            final metadata = json['metadata'];
            String? speaker;
            if (metadata != null) {
              speaker = metadata['speaker'] ?? metadata['channel'];
              final hasVoice = metadata['has_voice'] ?? true;
              final audioLevel = metadata['audio_level'] ?? 0.0;
              // Log every 50th chunk
              if (_sequenceNumber % 50 == 0) {
                debugPrint(
                    'AudioStreamReceiver: seq=$_sequenceNumber, VAD=$hasVoice, level=$audioLevel, bytes=${audioData.length}');
              }
            }

            _handleAudioData(Uint8List.fromList(audioData), speaker: speaker);
          } else {
            debugPrint('AudioStreamReceiver: audio event with no audio field!');
          }
          break;
        case 'connected':
          debugPrint('AudioStreamReceiver: Connected to server');
          final streamActive = json['stream_active'] ?? false;
          debugPrint('AudioStreamReceiver: Stream active: $streamActive');
          break;
        case 'waiting':
          debugPrint('AudioStreamReceiver: Waiting for Exotel stream...');
          break;
        case 'stream_start':
          debugPrint(
              'AudioStreamReceiver: Stream started for call ${json['call_sid']}');
          _currentCallSid = json['call_sid'];
          break;
        case 'stream_end':
          debugPrint('AudioStreamReceiver: Stream ended');
          break;
        case 'ping':
          // Respond to server ping with pong
          _channel?.sink.add(jsonEncode({'command': 'ping'}));
          break;
        case 'pong':
          // Server responded to our ping
          break;
        case 'start':
          debugPrint(
              'AudioStreamReceiver: Stream started for call ${json['callSid'] ?? json['call_sid']}');
          _currentCallSid = json['callSid'] ?? json['call_sid'];
          break;
        case 'stop':
          debugPrint('AudioStreamReceiver: Stream stopped');
          break;
        case 'metadata':
          debugPrint('AudioStreamReceiver: Received metadata - $json');
          break;
        case 'stats':
          debugPrint('AudioStreamReceiver: Stats - ${json['stats']}');
          break;
        case 'leg_status':
          // StatusCallback event forwarded from Python server
          debugPrint('AudioStreamReceiver: Leg status event - $json');
          final legStatusEvent = LegStatusEvent.fromJson(json);
          debugPrint('AudioStreamReceiver: Parsed leg status - $legStatusEvent');
          _legStatusController?.add(legStatusEvent);
          break;
        default:
          debugPrint('AudioStreamReceiver: Unknown event - $event: $json');
      }
    } catch (e) {
      debugPrint('AudioStreamReceiver: Error parsing control message - $e');
    }
  }

  /// Handle WebSocket errors
  void _handleError(dynamic error) {
    debugPrint('AudioStreamReceiver: WebSocket error - $error');
    if (!_isDisposed) {
      _updateState(StreamConnectionState.error);
    }
  }

  /// Handle WebSocket close
  void _handleDone() {
    debugPrint('AudioStreamReceiver: WebSocket closed');
    if (!_isDisposed) {
      _updateState(StreamConnectionState.disconnected);
    }
  }

  /// Send processed audio back (if needed)
  void sendProcessedAudio(Uint8List audioData) {
    if (_currentState != StreamConnectionState.connected) return;
    _channel?.sink.add(audioData);
  }

  /// Disconnect from WebSocket
  Future<void> disconnect() async {
    debugPrint('AudioStreamReceiver: Disconnecting');

    await _subscription?.cancel();
    _subscription = null;

    await _channel?.sink.close();
    _channel = null;

    _currentCallSid = null;
    _sequenceNumber = 0;

    if (!_isDisposed) {
      _currentState = StreamConnectionState.disconnected;
      _stateController?.add(StreamConnectionState.disconnected);
    }
  }

  /// Update connection state
  void _updateState(StreamConnectionState state) {
    if (_isDisposed) return;
    _currentState = state;
    _stateController?.add(state);
  }

  /// Dispose resources
  void dispose() {
    _isDisposed = true;
    disconnect();
    _stateController?.close();
    _stateController = null;
    _audioChunkController?.close();
    _audioChunkController = null;
    _transcriptController?.close();
    _transcriptController = null;
    _legStatusController?.close();
    _legStatusController = null;
  }
}
