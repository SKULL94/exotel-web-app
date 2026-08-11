import 'dart:async';

import 'package:deepgram_speech_to_text/deepgram_speech_to_text.dart';
import 'package:flutter/material.dart';

import '../config/env_config.dart';
import 'audio_stream_receiver.dart';

/// Deepgram real-time STT service.
///
/// Receives PCM16 audio chunks from [AudioStreamReceiver] (already
/// noise-cancelled by Sparrow on the server) and streams them to
/// Deepgram's live transcription API.
///
/// Supports Hindi + English (Hinglish) via the nova-3 model.
/// Includes auto-reconnect and keepalive mechanisms.
class DeepgramSttService {
  static final DeepgramSttService _instance = DeepgramSttService._internal();
  factory DeepgramSttService() => _instance;
  DeepgramSttService._internal();

  final _transcriptController = StreamController<TranscriptEvent>.broadcast();

  Stream<TranscriptEvent> get transcriptStream => _transcriptController.stream;

  StreamSubscription? _deepgramSub;
  StreamSubscription? _audioSub;
  bool _isRunning = false;
  bool _shouldReconnect = false;
  int _reconnectAttempts = 0;
  static const int _maxReconnectAttempts = 5;
  Timer? _keepAliveTimer;
  DateTime? _lastAudioTime;

  // Store stream reference for reconnection
  Stream<AudioChunk>? _audioChunkStream;

  bool get isRunning => _isRunning;

  /// Deepgram streaming params for 8kHz telephony Hinglish audio.
  /// Added keepalive and utterance_end_ms for better silence handling.
  static const Map<String, dynamic> _queryParams = {
    'encoding': 'linear16',
    'sample_rate': 8000,
    'channels': 1,
    'model': 'nova-3',
    'language': 'hi', // nova-3 Hindi handles Hindi + English code-switching
    'punctuate': true,
    'interim_results': true,
    // Increased silence threshold to avoid premature utterance ends
    'utterance_end_ms': 3000, // 3 seconds of silence before utterance end
    'vad_events': true, // Get VAD events from Deepgram
    'endpointing': 500, // 500ms endpointing
  };

  int _chunksSent = 0;

  /// Start streaming [audioChunkStream] to Deepgram for transcription.
  ///
  /// Call this once the call is connected and audio is flowing.
  /// Safe to call multiple times — stops any previous session first.
  void startTranscription(Stream<AudioChunk> audioChunkStream) {
    debugPrint('=== DeepgramSttService.startTranscription CALLED ===');

    if (!EnvConfig.hasDeepgramCredentials) {
      debugPrint('DeepgramSttService: No API key — transcription disabled. '
          'Set DEEPGRAM_API_KEY.');
      return;
    }

    // Store stream reference for potential reconnection
    _audioChunkStream = audioChunkStream.asBroadcastStream();
    _shouldReconnect = true;
    _reconnectAttempts = 0;

    _startDeepgramConnection();
  }

  void _startDeepgramConnection() {
    stop(); // cancel any previous session
    _chunksSent = 0;

    debugPrint('DeepgramSttService: Starting live transcription (nova-3, hi)');
    debugPrint(
        'DeepgramSttService: API key prefix = ${EnvConfig.deepgramApiKey.substring(0, 8)}...');

    final deepgram = Deepgram(EnvConfig.deepgramApiKey);

    // Convert AudioChunk stream → Stream<List<int>> for Deepgram
    debugPrint('DeepgramSttService: Setting up audio stream pipeline...');

    // Create a new controller for this connection
    final audioStreamController = StreamController<List<int>>();

    // Subscribe to audio chunks
    _audioSub = _audioChunkStream?.listen(
      (chunk) {
        if (chunk.data.isEmpty) {
          return;
        }

        _lastAudioTime = DateTime.now();
        _chunksSent++;

        if (_chunksSent == 1 || _chunksSent % 50 == 0) {
          // Calculate audio level for diagnostics
          double sum = 0;
          for (int i = 0; i < chunk.data.length - 1; i += 2) {
            int sample = chunk.data[i] | (chunk.data[i + 1] << 8);
            if (sample > 32767) sample -= 65536;
            sum += sample.abs();
          }
          final level = (sum / (chunk.data.length / 2) / 32768.0);

          debugPrint('DeepgramSttService: Chunk #$_chunksSent — '
              '${chunk.data.length} bytes, level=${level.toStringAsFixed(3)}');
        }

        audioStreamController.add(chunk.data.toList());
      },
      onError: (e) {
        debugPrint('DeepgramSttService: Audio stream error — $e');
        audioStreamController.addError(e);
      },
      onDone: () {
        debugPrint('DeepgramSttService: Audio stream ended');
        audioStreamController.close();
      },
    );

    debugPrint('DeepgramSttService: Connecting to Deepgram websocket...');

    final sttStream = deepgram.listen
        .live(audioStreamController.stream, queryParams: _queryParams);

    _isRunning = true;

    // Start keepalive monitoring
    _startKeepAliveMonitor();

    _deepgramSub = sttStream.listen(
      (result) {
        final transcript = result.transcript;

        // Log periodically (not every empty result)
        if (transcript != null && transcript.isNotEmpty) {
          debugPrint('DeepgramSttService: result — "$transcript" '
              'isFinal=${result.isFinal} speechFinal=${result.speechFinal}');
        }

        if (transcript == null || transcript.isEmpty) return;

        final isFinal = result.isFinal;
        final speechFinal = result.speechFinal;

        _transcriptController.add(TranscriptEvent(
          text: transcript,
          isFinal: isFinal || speechFinal,
          speaker: 'caller', // single-channel stream; no diarization
          language: 'hi',
        ));

        if (isFinal) {
          debugPrint('DeepgramSttService: [FINAL] $transcript');
        }
      },
      onError: (error) {
        debugPrint('DeepgramSttService: *** Stream error *** — $error');
        _isRunning = false;
        _attemptReconnect();
      },
      onDone: () {
        debugPrint(
            'DeepgramSttService: Stream closed (sent $_chunksSent chunks total)');
        _isRunning = false;
        _attemptReconnect();
      },
    );
  }

  /// Monitor connection health and attempt reconnect if needed
  void _startKeepAliveMonitor() {
    _keepAliveTimer?.cancel();
    _keepAliveTimer = Timer.periodic(const Duration(seconds: 10), (timer) {
      if (!_isRunning) {
        debugPrint(
            'DeepgramSttService: KeepAlive detected not running, attempting reconnect');
        _attemptReconnect();
        return;
      }

      // Check if we've received audio recently
      if (_lastAudioTime != null) {
        final elapsed = DateTime.now().difference(_lastAudioTime!);
        if (elapsed.inSeconds > 30) {
          debugPrint(
              'DeepgramSttService: No audio for ${elapsed.inSeconds}s, connection may be stale');
        }
      }

      debugPrint(
          'DeepgramSttService: KeepAlive check — running=$_isRunning, chunks=$_chunksSent');
    });
  }

  /// Attempt to reconnect to Deepgram
  void _attemptReconnect() {
    if (!_shouldReconnect) {
      debugPrint('DeepgramSttService: Reconnection disabled, not reconnecting');
      return;
    }

    if (_reconnectAttempts >= _maxReconnectAttempts) {
      debugPrint(
          'DeepgramSttService: Max reconnect attempts ($_maxReconnectAttempts) reached');
      _shouldReconnect = false;
      return;
    }

    if (_audioChunkStream == null) {
      debugPrint(
          'DeepgramSttService: No audio stream available for reconnection');
      return;
    }

    _reconnectAttempts++;
    final delay =
        Duration(seconds: _reconnectAttempts * 2); // Exponential backoff

    debugPrint(
        'DeepgramSttService: Reconnecting in ${delay.inSeconds}s (attempt $_reconnectAttempts/$_maxReconnectAttempts)');

    Future.delayed(delay, () {
      if (_shouldReconnect && !_isRunning) {
        debugPrint('DeepgramSttService: Executing reconnect...');
        _startDeepgramConnection();
      }
    });
  }

  /// Stop the active Deepgram transcription session.
  void stop() {
    _keepAliveTimer?.cancel();
    _keepAliveTimer = null;
    _audioSub?.cancel();
    _audioSub = null;
    _deepgramSub?.cancel();
    _deepgramSub = null;
    _isRunning = false;
    debugPrint('DeepgramSttService: Stopped');
  }

  /// Fully stop and prevent reconnection
  void stopAndDisableReconnect() {
    _shouldReconnect = false;
    _audioChunkStream = null;
    stop();
    debugPrint('DeepgramSttService: Stopped with reconnect disabled');
  }

  /// Dispose all resources. Call when the service is no longer needed.
  void dispose() {
    stopAndDisableReconnect();
    _transcriptController.close();
  }
}
