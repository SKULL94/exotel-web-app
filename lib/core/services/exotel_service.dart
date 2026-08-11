import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../config/env_config.dart';
import '../models/call_log.dart';

/// Exotel Call Status
enum ExotelCallStatus {
  queued,
  inProgress,
  ringing,
  completed,
  failed,
  busy,
  noAnswer,
  unknown,
  demo, // Demo mode status
}

/// Exotel Call Response Model
class ExotelCallResponse {
  final String sid;
  final String? parentCallSid;
  final String dateCreated;
  final String dateUpdated;
  final String accountSid;
  final String to;
  final String from;
  final String phoneNumberSid;
  final ExotelCallStatus status;
  final String? startTime;
  final String? endTime;
  final int? duration;
  final double? price;
  final String direction;
  final String? recordingUrl;
  final String uri;

  // Additional fields from Exotel API (with ?details=true)
  final String? answeredBy; // Human, Machine, NotSure
  final String? leg1Status; // completed, busy, failed, no-answer, canceled
  final String? leg2Status;
  final int? conversationDuration; // Actual talk time in seconds
  final List<LegDetail>? legs; // Per-leg details

  ExotelCallResponse({
    required this.sid,
    this.parentCallSid,
    required this.dateCreated,
    required this.dateUpdated,
    required this.accountSid,
    required this.to,
    required this.from,
    required this.phoneNumberSid,
    required this.status,
    this.startTime,
    this.endTime,
    this.duration,
    this.price,
    required this.direction,
    this.recordingUrl,
    required this.uri,
    this.answeredBy,
    this.leg1Status,
    this.leg2Status,
    this.conversationDuration,
    this.legs,
  });

  factory ExotelCallResponse.fromJson(Map<String, dynamic> json) {
    final call = json['Call'] ?? json;
    final details = call['Details'] as Map<String, dynamic>?;

    // Parse legs array
    List<LegDetail>? legs;
    if (details != null && details['Legs'] != null) {
      final legsData = details['Legs'] as List;
      legs = legsData.map((l) => LegDetail.fromJson(l)).toList();
    }

    return ExotelCallResponse(
      sid: call['Sid'] ?? '',
      parentCallSid: call['ParentCallSid'],
      dateCreated: call['DateCreated'] ?? '',
      dateUpdated: call['DateUpdated'] ?? '',
      accountSid: call['AccountSid'] ?? '',
      to: call['To'] ?? '',
      from: call['From'] ?? '',
      phoneNumberSid: call['PhoneNumberSid'] ?? '',
      status: _parseStatus(call['Status']),
      startTime: call['StartTime'],
      endTime: call['EndTime'],
      duration: call['Duration'] != null
          ? int.tryParse(call['Duration'].toString())
          : null,
      price: call['Price'] != null
          ? double.tryParse(call['Price'].toString())
          : null,
      direction: call['Direction'] ?? '',
      recordingUrl: call['RecordingUrl'],
      uri: call['Uri'] ?? '',
      // Additional fields
      answeredBy: call['AnsweredBy'],
      leg1Status: details?['Leg1Status'],
      leg2Status: details?['Leg2Status'],
      conversationDuration: details?['ConversationDuration'] != null
          ? int.tryParse(details!['ConversationDuration'].toString())
          : null,
      legs: legs,
    );
  }

  /// Create a demo response for testing
  factory ExotelCallResponse.demo({
    required String from,
    required String to,
    ExotelCallStatus status = ExotelCallStatus.demo,
    String? leg1Status,
    String? leg2Status,
    String? answeredBy,
  }) {
    final now = DateTime.now();
    return ExotelCallResponse(
      sid: 'demo_${now.millisecondsSinceEpoch}',
      dateCreated: now.toIso8601String(),
      dateUpdated: now.toIso8601String(),
      accountSid: EnvConfig.exotelAccountSid,
      to: to,
      from: from,
      phoneNumberSid: EnvConfig.exotelCallerId,
      status: status,
      direction: 'outbound-api',
      uri: '/demo',
      answeredBy: answeredBy,
      leg1Status: leg1Status,
      leg2Status: leg2Status,
    );
  }

  /// Copy with updated fields
  ExotelCallResponse copyWith({
    String? sid,
    String? parentCallSid,
    String? dateCreated,
    String? dateUpdated,
    String? accountSid,
    String? to,
    String? from,
    String? phoneNumberSid,
    ExotelCallStatus? status,
    String? startTime,
    String? endTime,
    int? duration,
    double? price,
    String? direction,
    String? recordingUrl,
    String? uri,
    String? answeredBy,
    String? leg1Status,
    String? leg2Status,
    int? conversationDuration,
    List<LegDetail>? legs,
  }) {
    return ExotelCallResponse(
      sid: sid ?? this.sid,
      parentCallSid: parentCallSid ?? this.parentCallSid,
      dateCreated: dateCreated ?? this.dateCreated,
      dateUpdated: dateUpdated ?? this.dateUpdated,
      accountSid: accountSid ?? this.accountSid,
      to: to ?? this.to,
      from: from ?? this.from,
      phoneNumberSid: phoneNumberSid ?? this.phoneNumberSid,
      status: status ?? this.status,
      startTime: startTime ?? this.startTime,
      endTime: endTime ?? this.endTime,
      duration: duration ?? this.duration,
      price: price ?? this.price,
      direction: direction ?? this.direction,
      recordingUrl: recordingUrl ?? this.recordingUrl,
      uri: uri ?? this.uri,
      answeredBy: answeredBy ?? this.answeredBy,
      leg1Status: leg1Status ?? this.leg1Status,
      leg2Status: leg2Status ?? this.leg2Status,
      conversationDuration: conversationDuration ?? this.conversationDuration,
      legs: legs ?? this.legs,
    );
  }

  static ExotelCallStatus _parseStatus(String? status) {
    switch (status?.toLowerCase()) {
      case 'queued':
        return ExotelCallStatus.queued;
      case 'in-progress':
        return ExotelCallStatus.inProgress;
      case 'ringing':
        return ExotelCallStatus.ringing;
      case 'completed':
        return ExotelCallStatus.completed;
      case 'failed':
        return ExotelCallStatus.failed;
      case 'busy':
        return ExotelCallStatus.busy;
      case 'no-answer':
        return ExotelCallStatus.noAnswer;
      default:
        return ExotelCallStatus.unknown;
    }
  }
}

/// Exotel v1 API Service
/// Handles direct API calls to Exotel for connecting two numbers
/// with audio streaming support
class ExotelService {
  static final ExotelService _instance = ExotelService._internal();
  factory ExotelService() => _instance;
  ExotelService._internal();

  StreamController<ExotelCallStatus>? _statusController;
  Stream<ExotelCallStatus> get statusStream {
    _statusController ??= StreamController<ExotelCallStatus>.broadcast();
    return _statusController!.stream;
  }

  ExotelCallResponse? _currentCall;
  ExotelCallResponse? get currentCall => _currentCall;

  Timer? _pollTimer;
  Timer? _demoTimer;
  bool _isDisposed = false;

  /// Connect two numbers using Exotel v1 API
  ///
  /// [fromNumber] - The phone number that will be called first (agent/user)
  /// [toNumber] - The customer's phone number
  /// [streamUrl] - WebSocket URL for audio streaming (optional)
  /// [record] - Whether to record the call
  /// [statusCallback] - URL for call status webhooks
  Future<ExotelCallResponse?> connectCall({
    required String fromNumber,
    required String toNumber,
    String? streamUrl,
    String? streamBegin,
    bool record = false,
    String? statusCallback,
    int? timeLimit,
    int? timeout,
  }) async {
    _ensureControllerOpen();

    if (!EnvConfig.hasExotelCredentials) {
      debugPrint('ExotelService: Missing Exotel credentials');
      _statusController?.add(ExotelCallStatus.failed);
      return null;
    }

    // Demo mode - simulate the call flow
    if (EnvConfig.isDemoMode) {
      return _simulateDemoCall(fromNumber, toNumber);
    }

    try {
      debugPrint('ExotelService: Connecting $fromNumber to $toNumber');
      _statusController?.add(ExotelCallStatus.queued);

      final url = Uri.parse('${EnvConfig.exotelBaseUrl}/Calls/connect.json');
      debugPrint('ExotelService: API URL: $url');

      // Prepare form data
      final formData = <String, String>{
        'From': fromNumber,
        'To': toNumber,
        'CallerId': EnvConfig.exotelCallerId,
      };

      // Optional parameters
      if (streamUrl != null && streamUrl.isNotEmpty) {
        formData['StreamUrl'] = streamUrl;
        formData['StreamBegin'] = streamBegin ?? 'atLeg1connect';  // lowercase 'c' per Exotel API
        debugPrint('ExotelService: Audio streaming enabled to $streamUrl');
      }

      if (record) {
        formData['Record'] = 'true';
        formData['RecordingChannels'] = 'dual';
        formData['RecordingFormat'] = 'mp3';
      }

      if (statusCallback != null && statusCallback.isNotEmpty) {
        formData['StatusCallback'] = statusCallback;
        formData['StatusCallbackContentType'] = 'application/json';
        formData['StatusCallbackEvents[0]'] = 'terminal';
        formData['StatusCallbackEvents[1]'] = 'answered';
      }

      // Enable Answering Machine Detection to get AnsweredBy (Human/Machine)
      formData['MachineDetection'] = 'Enable';
      // formData['MachineDetectionSilenceTimeout'] = '5000'; // 5 seconds silence = machine

      if (timeLimit != null) {
        formData['TimeLimit'] = timeLimit.toString();
      }

      if (timeout != null) {
        formData['TimeOut'] = timeout.toString();
      }

      // Create Basic Auth header
      final credentials = base64Encode(
          utf8.encode('${EnvConfig.exotelApiKey}:${EnvConfig.exotelApiToken}'));

      // Debug: Log all form data being sent
      debugPrint('ExotelService: Form data being sent:');
      formData.forEach((key, value) {
        if (key.contains('Callback') || key.contains('Stream') || key.contains('Machine')) {
          debugPrint('  $key: $value');
        }
      });

      final response = await http.post(
        url,
        headers: {
          'Authorization': 'Basic $credentials',
          'Content-Type': 'application/x-www-form-urlencoded',
          // Required for cors-anywhere proxy
          'X-Requested-With': 'XMLHttpRequest',
        },
        body: formData,
      );

      debugPrint('ExotelService: Response status: ${response.statusCode}');
      debugPrint('ExotelService: Response body: ${response.body}');

      if (response.statusCode == 200) {
        final json = jsonDecode(response.body);
        _currentCall = ExotelCallResponse.fromJson(json);
        _statusController?.add(_currentCall!.status);
        debugPrint('ExotelService: Call initiated - SID: ${_currentCall!.sid}');

        // Start polling for status updates
        _startPolling();

        return _currentCall;
      } else {
        debugPrint(
            'ExotelService: API error - ${response.statusCode}: ${response.body}');
        _statusController?.add(ExotelCallStatus.failed);
        return null;
      }
    } catch (e) {
      debugPrint('ExotelService: Error connecting call - $e');

      // Check if it's a CORS error
      if (e.toString().contains('Failed to fetch') ||
          e.toString().contains('XMLHttpRequest')) {
        debugPrint('''
╔════════════════════════════════════════════════════════════════╗
║  CORS ERROR: Browser blocks direct Exotel API calls            ║
║                                                                ║
║  Solutions:                                                    ║
║  1. Set CORS_PROXY_URL to a CORS proxy server                  ║
║  2. Run: npx cors-anywhere (local proxy on :8080)              ║
║  3. Use a backend server to proxy Exotel API calls             ║
║  4. Demo mode: Leave CORS_PROXY_URL empty to simulate calls    ║
╚════════════════════════════════════════════════════════════════╝
''');
      }

      _statusController?.add(ExotelCallStatus.failed);
      return null;
    }
  }

  /// Simulate a demo call flow (for testing without actual API)
  Future<ExotelCallResponse?> _simulateDemoCall(
      String fromNumber, String toNumber) async {
    debugPrint('ExotelService: [DEMO MODE] Simulating call flow');
    debugPrint(
        'ExotelService: [DEMO] To use real API, set CORS_PROXY_URL environment variable');

    _currentCall = ExotelCallResponse.demo(
      from: fromNumber,
      to: toNumber,
      status: ExotelCallStatus.queued,
    );

    _statusController?.add(ExotelCallStatus.queued);

    // Simulate call flow with delays
    _demoTimer?.cancel();
    int step = 0;

    _demoTimer = Timer.periodic(const Duration(seconds: 2), (timer) {
      step++;
      switch (step) {
        case 1:
          debugPrint('ExotelService: [DEMO] Ringing...');
          _statusController?.add(ExotelCallStatus.ringing);
          break;
        case 2:
          debugPrint('ExotelService: [DEMO] Connected!');
          _statusController?.add(ExotelCallStatus.inProgress);
          break;
        default:
          // Keep in progress
          break;
      }
    });

    return _currentCall;
  }

  /// Ensure stream controller is open
  void _ensureControllerOpen() {
    if (_isDisposed || _statusController?.isClosed == true) {
      _statusController = StreamController<ExotelCallStatus>.broadcast();
      _isDisposed = false;
    }
  }

  /// Get call details by SID
  Future<ExotelCallResponse?> getCallDetails(String callSid) async {
    if (!EnvConfig.hasExotelCredentials) return null;
    if (EnvConfig.isDemoMode) return _currentCall; // Return demo call as-is

    try {
      final url = Uri.parse(
          '${EnvConfig.exotelBaseUrl}/Calls/$callSid.json?details=true');

      final credentials = base64Encode(
          utf8.encode('${EnvConfig.exotelApiKey}:${EnvConfig.exotelApiToken}'));

      final response = await http.get(
        url,
        headers: {
          'Authorization': 'Basic $credentials',
          'X-Requested-With': 'XMLHttpRequest',
        },
      );

      if (response.statusCode == 200) {
        final json = jsonDecode(response.body);
        debugPrint('ExotelService: API Response: ${response.body}');
        final callResponse = ExotelCallResponse.fromJson(json);
        debugPrint('ExotelService: Parsed - status=${callResponse.status}, leg1=${callResponse.leg1Status}, leg2=${callResponse.leg2Status}, answeredBy=${callResponse.answeredBy}, convDuration=${callResponse.conversationDuration}');
        return callResponse;
      } else {
        debugPrint('ExotelService: API error ${response.statusCode}: ${response.body}');
      }
    } catch (e) {
      debugPrint('ExotelService: Error getting call details - $e');
    }
    return null;
  }

  /// Start polling for call status updates
  void _startPolling() {
    if (EnvConfig.isDemoMode) return; // Don't poll in demo mode

    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(seconds: 3), (_) async {
      if (_currentCall == null || _isDisposed) {
        _pollTimer?.cancel();
        return;
      }

      final details = await getCallDetails(_currentCall!.sid);
      if (details != null) {
        _currentCall = details;
        _statusController?.add(details.status);

        // Stop polling if call ended
        if (details.status == ExotelCallStatus.completed ||
            details.status == ExotelCallStatus.failed ||
            details.status == ExotelCallStatus.busy ||
            details.status == ExotelCallStatus.noAnswer) {
          _pollTimer?.cancel();
          debugPrint('ExotelService: Call ended - Status: ${details.status}');
        }
      }
    });
  }

  /// End current call (Note: Exotel v1 API doesn't have direct call termination)
  void endCall() {
    _pollTimer?.cancel();
    _demoTimer?.cancel();
    _currentCall = null;
    if (!_isDisposed) {
      _statusController?.add(ExotelCallStatus.completed);
    }
    debugPrint('ExotelService: Call marked as ended locally');
  }

  /// Dispose resources
  void dispose() {
    _isDisposed = true;
    _pollTimer?.cancel();
    _demoTimer?.cancel();
    _statusController?.close();
    _statusController = null;
  }
}
