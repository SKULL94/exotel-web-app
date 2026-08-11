// ignore_for_file: avoid_web_libraries_in_flutter

import 'dart:async';
import 'dart:js_interop';
import 'package:flutter/foundation.dart';

enum LLMInsightType {
  sentiment,
  suggestion,
  objectionHandling,
  keyPoints,
  nextAction,
  summary,
}

class LLMInsight {
  final LLMInsightType type;
  final String content;
  final double confidence;
  final DateTime timestamp;

  LLMInsight({
    required this.type,
    required this.content,
    required this.confidence,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();
}

// JavaScript interop bindings
@JS('window.llamaFunctions')
external JSObject? get _llamaFunctionsJS;

@JS('window.llamaFunctions.init')
external JSPromise<JSObject> _initJS(String modelKey, JSFunction onProgress);

@JS('window.llamaFunctions.generate')
external JSPromise<JSObject> _generateJS(String prompt, JSObject options);

@JS('window.llamaFunctions.status')
external JSObject _statusJS();

@JS('window.llamaFunctions.unload')
external JSPromise<JSObject> _unloadJS();

@JS('window.llamaFunctions.reset')
external void _resetJS();

@JS('window.llamaFunctions.memory')
external JSObject _memoryJS();

@JS('window.llamaFunctions.clearCache')
external JSPromise<JSAny?> _clearCacheJS();

// Helper extension to access JS object properties
extension JSObjectExtension on JSObject {
  external JSAny? operator [](String key);
  external void operator []=(String key, JSAny? value);
}

class LLMInsightsService {
  static final LLMInsightsService _instance = LLMInsightsService._internal();
  factory LLMInsightsService() => _instance;
  LLMInsightsService._internal();

  final _insightsController = StreamController<LLMInsight>.broadcast();
  Stream<LLMInsight> get insightsStream => _insightsController.stream;

  final _statusController = StreamController<String>.broadcast();
  Stream<String> get statusStream => _statusController.stream;

  bool _isInitialized = false;
  bool _isProcessing = false;
  bool _isModelLoaded = false;
  bool _isModelLoading = false;
  String _currentStatus = 'Not initialized';
  double _loadProgress = 0.0;
  String _currentModel = '';

  Map<String, dynamic> _modelStats = {};

  // Updated models with Gemma 2 as primary
  final Map<String, Map<String, dynamic>> availableModels = {
    'gemma-2b': {
      'id': 'gemma-2-2b-it-q4f16_1-MLC',
      'size': '~1.3GB',
      'ram': '~2.5GB',
      'speed': 'Very Fast (150-500ms)',
      'description': 'Google Gemma 2 - Perfect for real-time sales insights',
    },
    'gemma-9b': {
      'id': 'gemma-2-9b-it-q4f16_1-MLC',
      'size': '~5.2GB',
      'ram': '~8GB',
      'speed': 'Slower (800-1500ms)',
      'description': 'Larger Gemma for deeper analysis',
    },
    'llama-1b': {
      'id': 'Llama-3.2-1B-Instruct-q4f16_1-MLC',
      'size': '~0.8GB',
      'ram': '~2GB',
      'speed': 'Very Fast',
      'description': 'Quick responses, minimal RAM',
    },
    'llama-3b': {
      'id': 'Llama-3.2-3B-Instruct-q4f16_1-MLC',
      'size': '~2.1GB',
      'ram': '~4GB',
      'speed': 'Good',
      'description': 'Balanced option',
    },
  };

  String _selectedModel = 'gemma-2b';
  final List<String> _conversationHistory = [];
  Timer? _debounceTimer;
  String _pendingText = '';
  final Map<String, double> _performanceMetrics = {};

  bool get isInitialized => _isInitialized;
  bool get isProcessing => _isProcessing;
  bool get isModelLoaded => _isModelLoaded;
  bool get isModelLoading => _isModelLoading;
  String get currentStatus => _currentStatus;
  double get loadProgress => _loadProgress;
  String get currentModel => _currentModel;
  Map<String, dynamic> get modelStats => _modelStats;

  void _updateStatus(String status) {
    _currentStatus = status;
    _statusController.add(status);
    debugPrint('[LLMInsightsService] $status');
  }

  void setModel(String modelKey) {
    if (availableModels.containsKey(modelKey)) {
      _selectedModel = modelKey;
      _updateStatus(
          'Model set to: $modelKey (${availableModels[modelKey]!['size']})');
    } else {
      debugPrint('[LLMInsightsService] Unknown model: $modelKey');
    }
  }

  // Helper to get string from JSObject property
  String? _getJsString(JSObject obj, String key) {
    final value = obj[key];
    if (value == null) return null;
    if (value.isA<JSString>()) {
      return (value as JSString).toDart;
    }
    return value.toString();
  }

  // Helper to get bool from JSObject property
  bool _getJsBool(JSObject obj, String key, {bool defaultValue = false}) {
    final value = obj[key];
    if (value == null) return defaultValue;
    if (value.isA<JSBoolean>()) {
      return (value as JSBoolean).toDart;
    }
    return defaultValue;
  }

  // Helper to get double from JSObject property
  double _getJsDouble(JSObject obj, String key, {double defaultValue = 0.0}) {
    final value = obj[key];
    if (value == null) return defaultValue;
    if (value.isA<JSNumber>()) {
      return (value as JSNumber).toDartDouble;
    }
    return defaultValue;
  }

  // Helper to create JS options object
  JSObject _createOptions(Map<String, dynamic> options) {
    final jsObj = JSObject();
    options.forEach((key, value) {
      if (value is int) {
        jsObj[key] = value.toJS;
      } else if (value is double) {
        jsObj[key] = value.toJS;
      } else if (value is String) {
        jsObj[key] = value.toJS;
      } else if (value is bool) {
        jsObj[key] = value.toJS;
      }
    });
    return jsObj;
  }

  Future<bool> initialize() async {
    if (_isInitialized && _isModelLoaded) {
      debugPrint('[LLMInsightsService] Already initialized');
      return true;
    }

    if (_isModelLoading) {
      debugPrint('[LLMInsightsService] Model is currently loading...');
      return false;
    }

    _updateStatus('Initializing Gemma 2 for sales insights...');

    try {
      _updateStatus('Checking WebLLM availability...');

      if (_llamaFunctionsJS == null) {
        _updateStatus(
            'WebLLM not loaded. Make sure index.html is configured correctly.');
        _isInitialized = true;
        return false;
      }

      final modelSize = availableModels[_selectedModel]!['size'];
      _updateStatus('Selected model: $_selectedModel ($modelSize)');
      _isModelLoading = true;

      // Progress callback
      void onProgress(JSNumber progress, JSString text) {
        _loadProgress = progress.toDartDouble;
        _updateStatus(
            'Loading: ${(_loadProgress * 100).toStringAsFixed(1)}% - ${text.toDart}');
      }

      final result = await _initJS(_selectedModel, onProgress.toJS).toDart;

      final success = _getJsBool(result, 'success');

      if (success) {
        final modelId = _getJsString(result, 'model') ?? 'unknown';
        final loadTime = _getJsDouble(result, 'loadTime');

        _currentModel = modelId;
        _isModelLoaded = true;
        _isModelLoading = false;
        _loadProgress = 1.0;

        _updateStatus('Gemma 2 loaded in ${loadTime.toStringAsFixed(1)}s');
        debugPrint('[LLMInsightsService] Model ready: $modelId');
      } else {
        final error = _getJsString(result, 'error') ?? 'Unknown error';
        _isModelLoading = false;
        _updateStatus('Failed to load model: $error');
        debugPrint('[LLMInsightsService] Init error: $error');
      }

      _isInitialized = true;
      return _isModelLoaded;
    } catch (e) {
      _isModelLoading = false;
      _updateStatus('Error: $e');
      debugPrint('[LLMInsightsService] Exception: $e');
      _isInitialized = true;
      return false;
    }
  }

  void startProcessing() {
    _isProcessing = true;
    _conversationHistory.clear();
    _performanceMetrics.clear();
    _updateStatus('Processing started - Gemma 2 ready for real-time insights');
    debugPrint(
        '[LLMInsightsService] Processing started, model loaded: $_isModelLoaded');
  }

  void processTranscription(String text, {String? speaker}) {
    if (!_isProcessing || text.trim().isEmpty) {
      return;
    }

    if (!_isModelLoaded || _llamaFunctionsJS == null) {
      debugPrint('[LLMInsightsService] Model not loaded, cannot process');
      return;
    }

    debugPrint(
        '[LLMInsightsService] Processing: "${text.substring(0, text.length > 50 ? 50 : text.length)}..."');

    final entry = speaker != null ? '[$speaker]: $text' : text;
    _conversationHistory.add(entry);
    _pendingText = text;

    _debounceTimer?.cancel();
    _debounceTimer = Timer(const Duration(milliseconds: 1500), () {
      _analyzeWithLLM();
    });
  }

  Future<void> _analyzeWithLLM() async {
    if (_conversationHistory.isEmpty ||
        !_isModelLoaded ||
        _llamaFunctionsJS == null) return;

    debugPrint('[LLMInsightsService] Analyzing with Gemma 2...');
    final stopwatch = Stopwatch()..start();

    final recentHistory = _conversationHistory.length > 5
        ? _conversationHistory.sublist(_conversationHistory.length - 5)
        : _conversationHistory;
    final context = recentHistory.join('\n');

    try {
      await Future.wait([
        _generateSentimentInsight(context)
            .catchError((e) => debugPrint('Sentiment error: $e')),
        _generateSuggestionInsight(context)
            .catchError((e) => debugPrint('Suggestion error: $e')),
        _generateObjectionInsight(_pendingText)
            .catchError((e) => debugPrint('Objection error: $e')),
      ]);

      _performanceMetrics['analysis_time'] =
          stopwatch.elapsedMilliseconds / 1000.0;

      if (_conversationHistory.length % 5 == 0 &&
          _conversationHistory.length >= 3) {
        await _generateKeyPointsInsight(context)
            .catchError((e) => debugPrint('Key points error: $e'));
      }
      if (_conversationHistory.length % 7 == 0 &&
          _conversationHistory.length >= 4) {
        await _generateNextActionInsight(context)
            .catchError((e) => debugPrint('Next action error: $e'));
      }
    } catch (e) {
      debugPrint('[LLMInsightsService] Analysis error: $e');
    }
  }

  Future<void> _generateSentimentInsight(String context) async {
    final prompt = '''Analyze the sentiment of this sales conversation.
Reply with ONLY one word: Positive, Negative, or Neutral.

Conversation:
$context

Sentiment:''';

    try {
      final startTime = DateTime.now();
      final options = _createOptions({'maxTokens': 10, 'temperature': 0.3});
      final result = await _generateJS(prompt, options).toDart;
      final success = _getJsBool(result, 'success');

      if (success) {
        String response = _getJsString(result, 'response') ?? '';
        String sentiment = response.trim();

        if (sentiment.toLowerCase().contains('positive')) {
          sentiment = 'Positive';
        } else if (sentiment.toLowerCase().contains('negative')) {
          sentiment = 'Negative';
        } else {
          sentiment = 'Neutral';
        }

        final elapsed =
            DateTime.now().difference(startTime).inMilliseconds / 1000.0;
        _performanceMetrics['sentiment_time'] = elapsed;

        _insightsController.add(LLMInsight(
          type: LLMInsightType.sentiment,
          content: sentiment,
          confidence: 0.85,
        ));
        debugPrint('[LLMInsightsService] Sentiment: $sentiment (${elapsed}s)');
      }
    } catch (e) {
      debugPrint('[LLMInsightsService] Sentiment error: $e');
    }
  }

  Future<void> _generateSuggestionInsight(String context) async {
    final prompt = '''You are a sales coach helping during a live call.
Based on this conversation, provide ONE brief actionable suggestion (max 15 words).
Keep it natural and conversational.

Conversation:
$context

Suggestion:''';

    try {
      final startTime = DateTime.now();
      final options = _createOptions({'maxTokens': 40, 'temperature': 0.5});
      final result = await _generateJS(prompt, options).toDart;
      final success = _getJsBool(result, 'success');

      if (success) {
        final response = _getJsString(result, 'response');
        if (response != null && response.trim().isNotEmpty) {
          final elapsed =
              DateTime.now().difference(startTime).inMilliseconds / 1000.0;
          _performanceMetrics['suggestion_time'] = elapsed;

          _insightsController.add(LLMInsight(
            type: LLMInsightType.suggestion,
            content: response.trim(),
            confidence: 0.8,
          ));
          debugPrint(
              '[LLMInsightsService] Suggestion: ${response.trim()} (${elapsed}s)');
        }
      }
    } catch (e) {
      debugPrint('[LLMInsightsService] Suggestion error: $e');
    }
  }

  Future<void> _generateObjectionInsight(String text) async {
    final prompt = '''Is there a sales objection in this statement?
If yes, provide a brief handling tip (max 20 words).
If no objection, reply with exactly "NO_OBJECTION".

Statement: $text

Response:''';

    try {
      final startTime = DateTime.now();
      final options = _createOptions({'maxTokens': 50, 'temperature': 0.4});
      final result = await _generateJS(prompt, options).toDart;
      final success = _getJsBool(result, 'success');

      if (success) {
        final response = _getJsString(result, 'response');
        if (response != null &&
            response.trim().isNotEmpty &&
            !response.trim().contains('NO_OBJECTION')) {
          final elapsed =
              DateTime.now().difference(startTime).inMilliseconds / 1000.0;
          _performanceMetrics['objection_time'] = elapsed;

          _insightsController.add(LLMInsight(
            type: LLMInsightType.objectionHandling,
            content: response.trim(),
            confidence: 0.85,
          ));
          debugPrint(
              '[LLMInsightsService] Objection handling: ${response.trim()} (${elapsed}s)');
        }
      }
    } catch (e) {
      debugPrint('[LLMInsightsService] Objection error: $e');
    }
  }

  Future<void> _generateKeyPointsInsight(String context) async {
    final prompt = '''List 2-3 key points discussed in this sales conversation.
Be very brief (max 25 words total).

Conversation:
$context

Key Points:''';

    try {
      final options = _createOptions({'maxTokens': 50, 'temperature': 0.5});
      final result = await _generateJS(prompt, options).toDart;
      final success = _getJsBool(result, 'success');

      if (success) {
        final response = _getJsString(result, 'response');
        if (response != null && response.trim().isNotEmpty) {
          _insightsController.add(LLMInsight(
            type: LLMInsightType.keyPoints,
            content: response.trim(),
            confidence: 0.75,
          ));
          debugPrint('[LLMInsightsService] Key points: ${response.trim()}');
        }
      }
    } catch (e) {
      debugPrint('[LLMInsightsService] Key points error: $e');
    }
  }

  Future<void> _generateNextActionInsight(String context) async {
    final prompt =
        '''Based on this sales conversation, what should the salesperson do next?
Reply in max 12 words.

Conversation:
$context

Next Action:''';

    try {
      final options = _createOptions({'maxTokens': 30, 'temperature': 0.5});
      final result = await _generateJS(prompt, options).toDart;
      final success = _getJsBool(result, 'success');

      if (success) {
        final response = _getJsString(result, 'response');
        if (response != null && response.trim().isNotEmpty) {
          _insightsController.add(LLMInsight(
            type: LLMInsightType.nextAction,
            content: response.trim(),
            confidence: 0.75,
          ));
          debugPrint('[LLMInsightsService] Next action: ${response.trim()}');
        }
      }
    } catch (e) {
      debugPrint('[LLMInsightsService] Next action error: $e');
    }
  }

  Future<String?> generateSummary() async {
    if (_conversationHistory.isEmpty) return null;
    if (!_isModelLoaded || _llamaFunctionsJS == null) {
      debugPrint('[LLMInsightsService] Model not loaded for summary');
      return null;
    }

    final context = _conversationHistory.join('\n');
    final prompt = '''Summarize this sales call in 2-3 sentences.
Include: main topic, customer sentiment, and recommended next step.

Conversation:
$context

Summary:''';

    try {
      final startTime = DateTime.now();
      final options = _createOptions({'maxTokens': 120, 'temperature': 0.5});
      final result = await _generateJS(prompt, options).toDart;
      final success = _getJsBool(result, 'success');

      if (success) {
        final response = _getJsString(result, 'response');
        if (response != null && response.trim().isNotEmpty) {
          final elapsed =
              DateTime.now().difference(startTime).inMilliseconds / 1000.0;

          _insightsController.add(LLMInsight(
            type: LLMInsightType.summary,
            content: response.trim(),
            confidence: 0.8,
          ));

          debugPrint('[LLMInsightsService] Summary generated in ${elapsed}s');
          return response.trim();
        }
      }
    } catch (e) {
      debugPrint('[LLMInsightsService] Summary error: $e');
    }
    return null;
  }

  Map<String, dynamic> getMemoryInfo() {
    if (_llamaFunctionsJS == null) return {};

    try {
      final result = _memoryJS();
      return {
        'used': _getJsString(result, 'used') ?? 'Unknown',
        'total': _getJsString(result, 'total') ?? 'Unknown',
        'peak': _getJsString(result, 'peak') ?? 'Unknown',
      };
    } catch (e) {
      debugPrint('[LLMInsightsService] Memory info error: $e');
      return {};
    }
  }

  Map<String, dynamic> getModelStatus() {
    if (_llamaFunctionsJS == null) return {'ready': false};

    try {
      final result = _statusJS();
      _modelStats = {
        'status': _getJsString(result, 'status'),
        'ready': _getJsBool(result, 'ready'),
        'progress': _getJsDouble(result, 'progress'),
        'error': _getJsString(result, 'error'),
      };
      return _modelStats;
    } catch (e) {
      return {'ready': false, 'error': e.toString()};
    }
  }

  Future<bool> unloadModel() async {
    if (_llamaFunctionsJS == null) return false;

    try {
      final result = await _unloadJS().toDart;
      final success = _getJsBool(result, 'success');

      if (success) {
        _isModelLoaded = false;
        _updateStatus('Model unloaded');
      }

      return success;
    } catch (e) {
      debugPrint('[LLMInsightsService] Unload error: $e');
      return false;
    }
  }

  void resetModelConversation() {
    if (_llamaFunctionsJS != null) {
      _resetJS();
      debugPrint('[LLMInsightsService] Model conversation reset');
    }
  }

  void stopProcessing() {
    _isProcessing = false;
    _debounceTimer?.cancel();
    _updateStatus('Processing stopped');
  }

  List<String> getConversationHistory() =>
      List.unmodifiable(_conversationHistory);

  void clearHistory() {
    _conversationHistory.clear();
    resetModelConversation();
  }

  Map<String, double> getPerformanceMetrics() =>
      Map.unmodifiable(_performanceMetrics);

  Future<bool> clearModelCache() async {
    if (_llamaFunctionsJS == null) return false;

    try {
      await _clearCacheJS().toDart;
      return true;
    } catch (e) {
      debugPrint('[LLMInsightsService] Cache clear error: $e');
      return false;
    }
  }

  Future<void> dispose() async {
    stopProcessing();

    try {
      await unloadModel();
      debugPrint('[LLMInsightsService] Model unloaded');
    } catch (e) {
      debugPrint('[LLMInsightsService] Dispose error: $e');
    }

    await _insightsController.close();
    await _statusController.close();
    debugPrint('[LLMInsightsService] Disposed');
  }
}
