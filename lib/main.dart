import 'package:flutter/material.dart';

import 'core/config/env_config.dart';
import 'features/call/presentation/screens/home_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // final LLMInsightsService _llmInsights = LLMInsightsService();
  // _llmInsights.initialize();

  // Log configuration for debugging
  debugPrint('VoIP POC Starting...');
  debugPrint('Exotel API Configured: ${EnvConfig.hasExotelCredentials}');
  debugPrint('Krisp AI Configured: ${EnvConfig.hasKrispCredentials}');
  debugPrint('On-Device AI Configured: ${EnvConfig.hasOnDeviceAiCredentials}');

  runApp(const VoIPPocApp());
}

class VoIPPocApp extends StatelessWidget {
  const VoIPPocApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'VoIP POC',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.blue,
          brightness: Brightness.dark,
        ),
        scaffoldBackgroundColor: const Color(0xFF121212),
      ),
      home: const HomeScreen(),
    );
  }
}
