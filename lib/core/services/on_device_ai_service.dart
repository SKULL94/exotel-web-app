import 'dart:async';
import 'dart:developer';
import 'dart:typed_data';

import 'audio_stream_receiver.dart';

/// On-Device AI Status
enum OnDeviceAIStatus {
  notInitialized,
  initializing,
  ready,
  processing,
  bypassed,
  error,
}

/// AI Insight types returned by the on-device AI
enum InsightType {
  transcript,
  sentiment,
  suggestion,
  speakerChange,
  silenceDetected,
  noiseLevel,
}

/// Represents an insight from the AI processing
class AIInsight {
  final InsightType type;
  final String? text;
  final String? speaker;
  final double? confidence;
  final Map<String, dynamic>? metadata;
  final DateTime timestamp;

  AIInsight({
    required this.type,
    this.text,
    this.speaker,
    this.confidence,
    this.metadata,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();
}

/// Sentiment analysis result
class SentimentResult {
  final String sentiment; // positive, negative, neutral
  final double confidence;
  final Map<String, double> scores;

  SentimentResult({
    required this.sentiment,
    required this.confidence,
    required this.scores,
  });
}

/// On-Device AI Service
/// Handles sentiment analysis and suggestions
/// STT is now handled by the Python server (Vosk)
class OnDeviceAIService {
  static final OnDeviceAIService _instance = OnDeviceAIService._internal();
  factory OnDeviceAIService() => _instance;
  OnDeviceAIService._internal();

  final _statusController = StreamController<OnDeviceAIStatus>.broadcast();
  Stream<OnDeviceAIStatus> get statusStream => _statusController.stream;

  final _insightsController = StreamController<AIInsight>.broadcast();
  Stream<AIInsight> get insightsStream => _insightsController.stream;

  OnDeviceAIStatus _currentStatus = OnDeviceAIStatus.notInitialized;
  OnDeviceAIStatus get currentStatus => _currentStatus;

  bool _isProcessing = false;
  bool get isProcessing => _isProcessing;
  bool get isInitialized =>
      _currentStatus == OnDeviceAIStatus.ready ||
      _currentStatus == OnDeviceAIStatus.bypassed;
  bool get isBypassed => _currentStatus == OnDeviceAIStatus.bypassed;

  // Conversation context for suggestions
  final List<String> _transcripts = [];
  int _transcriptCount = 0;

  /// Initialize the on-device AI service
  /// STT is now on the server, so this just initializes sentiment analysis
  Future<bool> initialize() async {
    try {
      _updateStatus(OnDeviceAIStatus.initializing);
      log('OnDeviceAIService: Initializing (STT on server)...');

      // No heavy initialization needed since STT is on server
      await Future.delayed(const Duration(milliseconds: 100));

      log('OnDeviceAIService: Ready (sentiment analysis + suggestions)');
      _updateStatus(OnDeviceAIStatus.ready);
      return true;
    } catch (e) {
      log('OnDeviceAIService: Initialization error - $e');
      _updateStatus(OnDeviceAIStatus.error);
      return false;
    }
  }

  /// Start processing
  void startProcessing() {
    if (!isInitialized) {
      log('OnDeviceAIService: Not initialized');
      return;
    }
    _isProcessing = true;
    _transcripts.clear();
    _transcriptCount = 0;
    log('OnDeviceAIService: Started processing');
  }

  /// Analyze text for sentiment (called when transcript is received)
  void analyzeText(String text) {
    if (!_isProcessing || text.isEmpty) return;

    _transcripts.add(text);
    _transcriptCount++;

    // Analyze sentiment periodically
    if (_transcriptCount % 2 == 0) {
      final sentiment = _analyzeSentiment(text);
      _insightsController.add(AIInsight(
        type: InsightType.sentiment,
        text: sentiment.sentiment,
        confidence: sentiment.confidence,
        metadata: {'scores': sentiment.scores},
      ));
    }

    // Generate suggestions periodically
    if (_transcriptCount % 4 == 0 && _transcripts.length >= 2) {
      final suggestion = _generateSuggestion();
      if (suggestion != null) {
        _insightsController.add(AIInsight(
          type: InsightType.suggestion,
          text: suggestion,
          confidence: 0.75,
        ));
      }
    }
  }

  /// Process audio chunk for noise level only
  Future<void> processAudioChunk(AudioChunk chunk, {String? speaker}) async {
    if (!_isProcessing) return;

    // Calculate and emit noise level
    final noiseLevel = _calculateNoiseLevel(chunk.data);
    _insightsController.add(AIInsight(
      type: InsightType.noiseLevel,
      confidence: noiseLevel,
    ));
  }

  /// Calculate noise level from audio
  double _calculateNoiseLevel(Uint8List audioData) {
    if (audioData.isEmpty) return 0.0;
    double sum = 0;
    for (int i = 0; i < audioData.length - 1; i += 2) {
      int sample = audioData[i] | (audioData[i + 1] << 8);
      if (sample > 32767) sample -= 65536;
      sum += sample.abs();
    }
    return (sum / (audioData.length / 2) / 32768.0).clamp(0.0, 1.0);
  }

  /// Analyze sentiment
  SentimentResult _analyzeSentiment(String text) {
    final positiveWords = [
      'good', 'great', 'yes', 'thanks', 'interested', 'okay', 'sure',
      'अच्छा', 'बहुत अच्छा', 'हाँ', 'धन्यवाद', 'ठीक है'
    ];
    final negativeWords = [
      'no', 'problem', 'concern', 'expensive', 'bad', 'wrong',
      'नहीं', 'समस्या', 'महंगा', 'गलत'
    ];

    final lowerText = text.toLowerCase();
    int positive = positiveWords.where((w) => lowerText.contains(w)).length;
    int negative = negativeWords.where((w) => lowerText.contains(w)).length;

    String sentiment = 'neutral';
    double confidence = 0.6;

    if (positive > negative) {
      sentiment = 'positive';
      confidence = 0.7 + (positive * 0.05);
    } else if (negative > positive) {
      sentiment = 'negative';
      confidence = 0.7 + (negative * 0.05);
    }

    return SentimentResult(
      sentiment: sentiment,
      confidence: confidence.clamp(0.0, 1.0),
      scores: {
        'positive': (positive / 5.0).clamp(0.0, 1.0),
        'negative': (negative / 5.0).clamp(0.0, 1.0),
        'neutral': (1.0 - (positive + negative) / 5.0).clamp(0.0, 1.0),
      },
    );
  }

  /// Generate suggestions
  String? _generateSuggestion() {
    final suggestions = [
      "Ask about their specific needs",
      "Highlight the key benefits",
      "Offer to send more information",
      "Schedule a follow-up call",
      "Address their concerns directly",
      "Summarize the key points",
    ];
    return suggestions[_transcriptCount % suggestions.length];
  }

  /// Stop processing
  Future<void> stopProcessing() async {
    _isProcessing = false;
    log('OnDeviceAIService: Stopped processing');
  }

  /// Get conversation transcripts
  List<String> getTranscripts() => List.unmodifiable(_transcripts);

  /// Update status
  void _updateStatus(OnDeviceAIStatus status) {
    _currentStatus = status;
    _statusController.add(status);
  }

  /// Dispose resources
  Future<void> dispose() async {
    await stopProcessing();
    await _statusController.close();
    await _insightsController.close();
    log('OnDeviceAIService: Disposed');
  }
}
