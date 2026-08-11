import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'audio_stream_receiver.dart';

/// Krisp AI Status
enum KrispStatus {
  notInitialized,
  initializing,
  ready,
  processing,
  bypassed, // When no credentials available
  error,
}

/// Noise Cancellation Service (Placeholder)
/// Noise cancellation is handled server-side via ai-coustics Sparrow SDK.
/// This class tracks NC status on the Flutter side; the actual processing
/// happens in sparrow_processor.py on the Python server.
class KrispService {
  static final KrispService _instance = KrispService._internal();
  factory KrispService() => _instance;
  KrispService._internal();

  final _statusController = StreamController<KrispStatus>.broadcast();
  Stream<KrispStatus> get statusStream => _statusController.stream;

  KrispStatus _currentStatus = KrispStatus.notInitialized;
  KrispStatus get currentStatus => _currentStatus;

  bool _isEnabled = true;
  bool get isEnabled => _isEnabled && _currentStatus == KrispStatus.ready;
  bool get isInitialized =>
      _currentStatus == KrispStatus.ready ||
      _currentStatus == KrispStatus.bypassed;
  bool get isBypassed => _currentStatus == KrispStatus.bypassed;

  // Statistics
  int _processedChunks = 0;
  int get processedChunks => _processedChunks;
  double _noiseReductionLevel = 0.0;
  double get noiseReductionLevel => _noiseReductionLevel;

  /// Initialize noise cancellation status.
  /// NC is handled server-side (ai-coustics Sparrow). This just marks ready.
  Future<bool> initialize() async {
    try {
      _updateStatus(KrispStatus.initializing);
      debugPrint('NCService: Initializing (Sparrow NC is server-side)...');

      // Noise cancellation runs on the Python server via ai-coustics Sparrow SDK.
      // No client-side SDK initialization needed.
      await Future.delayed(const Duration(milliseconds: 100));

      debugPrint('NCService: Ready (Sparrow NC active on server)');
      _updateStatus(KrispStatus.ready);
      return true;
    } catch (e) {
      debugPrint('NCService: Initialization error - $e');
      _updateStatus(KrispStatus.error);
      return false;
    }
  }

  /// Audio chunks arrive already processed by Sparrow on the server.
  /// This passes them through — kept for interface compatibility.
  Future<Uint8List> processAudioChunk(AudioChunk chunk) async {
    if (!_isEnabled || _currentStatus == KrispStatus.bypassed) {
      return chunk.data; // Pass through unchanged
    }

    if (_currentStatus != KrispStatus.ready) {
      return chunk.data;
    }

    try {
      _updateStatus(KrispStatus.processing);

      // NC already applied server-side by ai-coustics Sparrow SDK.
      // Pass audio through unchanged on the client side.
      final processedData = _simulateNoiseReduction(chunk.data);

      _processedChunks++;
      _updateStatus(KrispStatus.ready);

      return processedData;
    } catch (e) {
      debugPrint('KrispService: Processing error - $e');
      return chunk.data; // Return original on error
    }
  }

  /// Pass-through — actual NC is done by Sparrow on the server.
  Uint8List _simulateNoiseReduction(Uint8List audioData) {
    _noiseReductionLevel = 0.0; // NC is server-side; no client-side reduction
    return audioData;
  }

  /// Enable or disable noise cancellation
  void setEnabled(bool enabled) {
    _isEnabled = enabled;
    debugPrint(
        'KrispService: Noise cancellation ${enabled ? 'enabled' : 'disabled'}');
  }

  /// Reset statistics
  void resetStats() {
    _processedChunks = 0;
    _noiseReductionLevel = 0.0;
  }

  /// Update status and notify listeners
  void _updateStatus(KrispStatus status) {
    _currentStatus = status;
    _statusController.add(status);
  }

  /// Dispose resources
  Future<void> dispose() async {
    // await KrispSDK.dispose();

    await _statusController.close();
    debugPrint('KrispService: Disposed');
  }
}
