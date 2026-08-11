import 'package:flutter/material.dart';

import '../../../../core/config/env_config.dart';
import '../../../../core/models/call_log.dart';
import '../../../../core/services/exotel_service.dart';
import '../../../../core/services/local_storage_service.dart';
import '../../../../core/services/on_device_ai_service.dart';
import 'call_history_screen.dart';
import 'call_screen.dart';

/// Minimalistic Home Screen for VoIP POC
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _fromController = TextEditingController();
  final _toController = TextEditingController();

  // final KrispService _krispService = KrispService();
  final OnDeviceAIService _onDeviceAI = OnDeviceAIService();
  final LocalStorageService _localStorage = LocalStorageService();
  final ExotelService _exotel = ExotelService();

  bool _isInitializing = false;
  bool _isInitialized = false;
  String? _error;
  // ignore: unused_field - Used for tracking active call state
  CallLog? _activeCall;

  @override
  void initState() {
    super.initState();
    _initializeServices();
  }

  Future<void> _initializeServices() async {
    setState(() {
      _isInitializing = true;
      _error = null;
    });

    try {
      // Initialize local storage
      await _localStorage.init();

      // Initialize Krisp (will bypass if no credentials)
      // await _krispService.initialize();

      // Initialize On-Device AI (will bypass if no credentials)
      await _onDeviceAI.initialize();

      setState(() {
        _isInitialized = true;
        _isInitializing = false;
      });

      // Check for active call after initialization
      await _checkForActiveCall();
    } catch (e) {
      setState(() {
        _isInitializing = false;
        _error = e.toString();
      });
    }
  }

  /// Check for active call from previous session
  Future<void> _checkForActiveCall() async {
    final activeCall = await _localStorage.getActiveCall();
    if (activeCall == null) return;

    debugPrint('HomeScreen: Found active call - ${activeCall.callSid}');

    // Check with Exotel if call is still in progress (if not in demo mode)
    if (!EnvConfig.isDemoMode && EnvConfig.hasExotelCredentials) {
      try {
        final status = await _exotel.getCallDetails(activeCall.callSid);
        if (status != null) {
          if (status.status == ExotelCallStatus.inProgress ||
              status.status == ExotelCallStatus.ringing) {
            // Call is still active - navigate directly to CallScreen
            setState(() => _activeCall = activeCall);
            _navigateToCallScreen(activeCall);
          } else {
            // Call has ended - save final state and clear
            final finalCall = activeCall.copyWith(
              status: status.status,
              endTime: DateTime.now(),
              durationSeconds: status.duration,
            );
            await _localStorage.clearActiveCall();
            await _localStorage.saveCallLog(finalCall);
            debugPrint('HomeScreen: Saved ended call to history');
          }
        }
      } catch (e) {
        debugPrint('HomeScreen: Error checking call status - $e');
        // Assume call ended on error
        await _localStorage.clearActiveCall();
        await _localStorage.saveCallLog(activeCall.copyWith(
          status: ExotelCallStatus.unknown,
          endTime: DateTime.now(),
        ));
      }
    } else {
      // Demo mode - check if call was in progress
      if (activeCall.isActive) {
        // Navigate directly to CallScreen
        setState(() => _activeCall = activeCall);
        _navigateToCallScreen(activeCall);
      } else {
        // Call ended, clear active
        await _localStorage.clearActiveCall();
      }
    }
  }

  /// Navigate to call screen with existing call
  void _navigateToCallScreen(CallLog call) {
    if (!mounted) return;

    debugPrint('HomeScreen: Navigating to active call - ${call.callSid}');
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => CallScreen(
          fromNumber: call.fromNumber,
          toNumber: call.toNumber,
        ),
      ),
    );
  }

  Future<void> _startCall() async {
    final from = _fromController.text.trim();
    final to = _toController.text.trim();

    if (from.isEmpty || to.isEmpty) {
      _showError('Please enter both phone numbers');
      return;
    }

    if (!EnvConfig.hasExotelCredentials) {
      _showError('Exotel credentials not configured');
      return;
    }

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => CallScreen(
          fromNumber: from,
          toNumber: to,
        ),
      ),
    );
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: Colors.red),
    );
  }

  @override
  void dispose() {
    _fromController.dispose();
    _toController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF121212),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header with history button
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'VoIP POC',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 32,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  IconButton(
                    onPressed: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (context) => const CallHistoryScreen(),
                        ),
                      );
                    },
                    icon: Icon(
                      Icons.history,
                      color: Colors.white.withValues(alpha: 0.7),
                      size: 28,
                    ),
                    tooltip: 'Call History',
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                'Exotel + AI-Coustic AI + On-Device AI',
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.6),
                  fontSize: 14,
                ),
              ),

              const SizedBox(height: 32),

              // Status indicators
              _buildStatusSection(),

              const SizedBox(height: 32),

              // Phone inputs
              _buildPhoneInput(
                controller: _fromController,
                label: 'From Number',
                hint: '+91XXXXXXXXXX',
              ),

              const SizedBox(height: 16),

              _buildPhoneInput(
                controller: _toController,
                label: 'To Number',
                hint: '+91XXXXXXXXXX',
              ),

              const Spacer(),

              // Call button
              SizedBox(
                width: double.infinity,
                height: 56,
                child: ElevatedButton(
                  onPressed:
                      _isInitialized && !_isInitializing ? _startCall : null,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.green,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.call, size: 24),
                      const SizedBox(width: 12),
                      Text(
                        _isInitializing ? 'Initializing...' : 'Connect Call',
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStatusSection() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          // Mode indicator
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
            margin: const EdgeInsets.only(bottom: 12),
            decoration: BoxDecoration(
              color: EnvConfig.isDemoMode
                  ? Colors.orange.withValues(alpha: 0.2)
                  : Colors.green.withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                Icon(
                  EnvConfig.isDemoMode ? Icons.science : Icons.phone_enabled,
                  color: EnvConfig.isDemoMode ? Colors.orange : Colors.green,
                  size: 16,
                ),
                const SizedBox(width: 8),
                Text(
                  EnvConfig.isDemoMode
                      ? 'DEMO MODE (simulated calls)'
                      : 'LIVE MODE (real Exotel calls)',
                  style: TextStyle(
                    color: EnvConfig.isDemoMode ? Colors.orange : Colors.green,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          _buildStatusRow(
            'Exotel API',
            EnvConfig.hasExotelCredentials,
            EnvConfig.hasExotelCredentials ? 'Configured' : 'Not configured',
          ),
          const SizedBox(height: 12),
          _buildStatusRow(
            'Audio Stream',
            EnvConfig.hasStreamingConfigured,
            EnvConfig.hasStreamingConfigured ? 'Configured' : 'Not configured',
          ),
          // const SizedBox(height: 12),
          // _buildStatusRow(
          //   'Krisp AI',
          //   _krispService.isInitialized,
          //   _krispService.isBypassed ? 'Server-side' : 'Ready',
          // ),
          const SizedBox(height: 12),
          _buildStatusRow(
            'On-Device AI',
            _onDeviceAI.isInitialized,
            _onDeviceAI.isBypassed ? 'Bypassed' : 'Ready',
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(
              _error!,
              style: const TextStyle(color: Colors.red, fontSize: 12),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildStatusRow(String label, bool isActive, String status) {
    return Row(
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            color: isActive ? Colors.green : Colors.orange,
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: 12),
        Text(
          label,
          style: const TextStyle(color: Colors.white, fontSize: 14),
        ),
        const Spacer(),
        Text(
          status,
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.6),
            fontSize: 12,
          ),
        ),
      ],
    );
  }

  Widget _buildPhoneInput({
    required TextEditingController controller,
    required String label,
    required String hint,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.8),
            fontSize: 14,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: controller,
          keyboardType: TextInputType.phone,
          style: const TextStyle(color: Colors.white, fontSize: 16),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: TextStyle(color: Colors.white.withValues(alpha: 0.3)),
            filled: true,
            fillColor: Colors.white.withValues(alpha: 0.1),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide.none,
            ),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 14,
            ),
          ),
        ),
      ],
    );
  }
}
