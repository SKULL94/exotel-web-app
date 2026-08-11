/// Environment configuration for VoIP POC
/// Exotel v1 API + Krisp AI + On-Device AI Integration
class EnvConfig {
  // ═══════════════════════════════════════════════════════════════
  // Exotel v1 API Configuration
  // Get credentials from: https://my.exotel.com/settings/api-settings
  // ═══════════════════════════════════════════════════════════════
  static const String exotelApiKey =
      'ceef3e2e6a61eab182bcd2393ca3c53d373c24c2eaa5989c';

  static const String exotelApiToken =
      'ff0eb2e260cc1e6d4c47b743616660b906ad0fac03c72415';

  static const String exotelAccountSid = 'herovired1m';

  static const String exotelCallerId = '01140183372';

  // Exotel subdomain based on region
  // Singapore: api.exotel.com
  // Mumbai: api.in.exotel.com
  static const String exotelSubdomain = 'api.in.exotel.com';

  // ═══════════════════════════════════════════════════════════════
  // CORS Proxy Configuration (for browser-based testing)
  // ═══════════════════════════════════════════════════════════════
  // Set to true to use a CORS proxy for browser testing
  // In production, use a backend server instead
  static const bool useCorsProxy = bool.fromEnvironment(
    'USE_CORS_PROXY',
    defaultValue: true, // Enable for browser testing
  );

  // CORS proxy URL - use your own or a public one
  // Options:
  // - Deploy your own: https://github.com/AntaresFS/cors-anywhere (set password protection)
  // - Local: Run `npx cors-anywhere` on localhost:8080
  static const String corsProxyUrl = String.fromEnvironment(
    'CORS_PROXY_URL',
    defaultValue: '', // Empty = demo mode (simulated calls)
  );

  // Demo mode - simulate calls without actual API
  static bool get isDemoMode => useCorsProxy && corsProxyUrl.isEmpty;

  /// Exotel API Base URL (with optional CORS proxy)
  static String get exotelBaseUrl {
    final baseUrl = 'https://$exotelSubdomain/v1/Accounts/$exotelAccountSid';
    if (useCorsProxy && corsProxyUrl.isNotEmpty) {
      return '$corsProxyUrl/$baseUrl';
    }
    return baseUrl;
  }

  /// Exotel API Auth Header (Basic Auth)
  static String get exotelAuthHeader {
    final credentials = '$exotelApiKey:$exotelApiToken';
    final encoded = Uri.encodeComponent(credentials);
    return 'Basic $encoded';
  }

  // ═══════════════════════════════════════════════════════════════
  // Krisp AI SDK Configuration (Placeholder)
  // Get your SDK token from: https://developer.krisp.ai
  // ═══════════════════════════════════════════════════════════════
  static const String krispSdkToken = String.fromEnvironment(
    'KRISP_SDK_TOKEN',
    defaultValue:
        'krisp_prod_mOFW578T9S83eTY_1QW6BVyJX5ct7Ddd', // Add your Krisp SDK token here
  );

  static bool get hasKrispCredentials => krispSdkToken.isNotEmpty;

  // ═══════════════════════════════════════════════════════════════
  // Deepgram STT Configuration
  // Get your API key from: https://console.deepgram.com
  // ═══════════════════════════════════════════════════════════════
  static const String deepgramApiKey = String.fromEnvironment(
    'DEEPGRAM_API_KEY',
    defaultValue:
        '36e8ede79bb2d89e27bcd77947856ecd338c50f7', // Add your Deepgram API key here
  );

  static bool get hasDeepgramCredentials => deepgramApiKey.isNotEmpty;

  // ═══════════════════════════════════════════════════════════════
  // Ollama LLM Configuration
  // For production: Set OLLAMA_BASE_URL to your LC's local server IP
  // Example: http://192.168.1.100:11434
  // ═══════════════════════════════════════════════════════════════
  static const String ollamaBaseUrl = String.fromEnvironment(
    'OLLAMA_BASE_URL',
    defaultValue: 'http://localhost:11434', // Local dev, change for production
  );

  static const String ollamaModelName = String.fromEnvironment(
    'OLLAMA_MODEL_NAME',
    defaultValue: 'llama3.2:3b', // Fast 3B model, consistent across platforms
  );

  // ═══════════════════════════════════════════════════════════════
  // On-Device AI Configuration (Sherpa-ONNX Whisper)
  // Supports 99 languages including Hindi & English
  // Run scripts/download_models.sh to get the model
  // ═══════════════════════════════════════════════════════════════
  static const String sherpaModelName = String.fromEnvironment(
    'SHERPA_MODEL_NAME',
    defaultValue: 'sherpa-onnx-whisper-tiny', // Multilingual Whisper model
  );

  static const String onDeviceAiModelPath = String.fromEnvironment(
    'ON_DEVICE_AI_MODEL_PATH',
    defaultValue: 'assets/models', // Path to model directory
  );

  // Sherpa-ONNX doesn't need API key - fully on-device
  static bool get hasOnDeviceAiCredentials => true; // Always try to load model

  // Check if Ollama is configured
  static bool get hasOllamaConfigured => ollamaBaseUrl.isNotEmpty;

  // ═══════════════════════════════════════════════════════════════
  // WebSocket Configuration for Audio Streaming
  // This is where Exotel will stream audio via StreamUrl parameter
  // ═══════════════════════════════════════════════════════════════

  // Local WebSocket server URL (for Flutter app connection)
  // Use localhost for same-machine testing, or your server's LAN IP for device testing
  static const String audioStreamWsUrl = String.fromEnvironment(
    'AUDIO_STREAM_WS_URL',
    defaultValue: 'ws://172.16.33.26:8765/audio-stream',
  );

  // Exotel StreamUrl - where Exotel sends audio
  // For local testing, use ngrok to expose your local server
  // For production, use your deployed server URL
  static const String exotelStreamUrl = String.fromEnvironment(
    'EXOTEL_STREAM_URL',
    defaultValue:
        'wss://superhuman-salvatore-prognostically.ngrok-free.dev/exotel-stream', // Empty = no streaming, set to your server URL
  );

  // Exotel StatusCallback URL - where Exotel sends call status webhooks
  // This should be your Python server's HTTP endpoint exposed via ngrok
  // The server will forward status updates to Flutter via WebSocket
  static const String exotelStatusCallbackUrl = String.fromEnvironment(
    'EXOTEL_STATUS_CALLBACK_URL',
    defaultValue:
        'https://superhuman-salvatore-prognostically.ngrok-free.dev/exotel-status', // Set to your server's webhook endpoint
  );

  // Check if streaming is configured
  static bool get hasStreamingConfigured =>
      exotelStreamUrl.isNotEmpty &&
      !exotelStreamUrl.contains('your-websocket-server');

  // Check if status callback is configured
  static bool get hasStatusCallbackConfigured =>
      exotelStatusCallbackUrl.isNotEmpty &&
      !exotelStatusCallbackUrl.contains('your-server');

  // ═══════════════════════════════════════════════════════════════
  // Audio Configuration
  // ═══════════════════════════════════════════════════════════════
  static const int sampleRate = 8000; // Exotel uses 8kHz
  static const int bitDepth = 16;
  static const int bitRate = 128; // kbps
  static const int channelCount = 1; // Mono

  // ═══════════════════════════════════════════════════════════════
  // Feature Flags
  // ═══════════════════════════════════════════════════════════════
  static const bool enableNoiseCancellation = true;
  static const bool enableOnDeviceAi = true;
  static const bool enableAudioStreaming = true;

  // ═══════════════════════════════════════════════════════════════
  // Validation
  // ═══════════════════════════════════════════════════════════════
  static bool get hasExotelCredentials =>
      exotelApiKey.isNotEmpty &&
      exotelApiToken.isNotEmpty &&
      exotelAccountSid.isNotEmpty &&
      exotelCallerId.isNotEmpty;
}
