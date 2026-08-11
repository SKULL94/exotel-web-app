import 'dart:convert';

import '../services/exotel_service.dart';

/// Represents a leg of the call (Leg 1 = Sales, Leg 2 = Lead)
class LegDetail {
  final int id;
  final int onCallDuration;
  final String? status;
  final String? answeredBy;

  LegDetail({
    required this.id,
    required this.onCallDuration,
    this.status,
    this.answeredBy,
  });

  factory LegDetail.fromJson(Map<String, dynamic> json) {
    final leg = json['Leg'] ?? json;
    return LegDetail(
      id: int.tryParse(leg['Id']?.toString() ?? '0') ?? 0,
      onCallDuration: int.tryParse(leg['OnCallDuration']?.toString() ?? '0') ?? 0,
      status: leg['Status'],
      answeredBy: leg['AnsweredBy'],
    );
  }

  Map<String, dynamic> toJson() => {
        'Id': id,
        'OnCallDuration': onCallDuration,
        'Status': status,
        'AnsweredBy': answeredBy,
      };

  LegDetail copyWith({
    int? id,
    int? onCallDuration,
    String? status,
    String? answeredBy,
  }) {
    return LegDetail(
      id: id ?? this.id,
      onCallDuration: onCallDuration ?? this.onCallDuration,
      status: status ?? this.status,
      answeredBy: answeredBy ?? this.answeredBy,
    );
  }
}

/// Complete call log entry for persistence
class CallLog {
  final String id;
  final String callSid;
  final String fromNumber;
  final String toNumber;
  final ExotelCallStatus status;
  final String? answeredBy;
  final String? leg1Status;
  final String? leg2Status;
  final DateTime startTime;
  final DateTime? endTime;
  final int? durationSeconds;
  final int? conversationDurationSeconds;
  final String? recordingUrl;
  final List<String> transcripts;
  final List<String> insights;
  final List<LegDetail>? legs;
  final bool isSynced;

  CallLog({
    required this.id,
    required this.callSid,
    required this.fromNumber,
    required this.toNumber,
    required this.status,
    this.answeredBy,
    this.leg1Status,
    this.leg2Status,
    required this.startTime,
    this.endTime,
    this.durationSeconds,
    this.conversationDurationSeconds,
    this.recordingUrl,
    List<String>? transcripts,
    List<String>? insights,
    this.legs,
    this.isSynced = false,
  })  : transcripts = transcripts ?? [],
        insights = insights ?? [];

  /// Create from ExotelCallResponse
  factory CallLog.fromExotelResponse(ExotelCallResponse response) {
    return CallLog(
      id: '${response.sid}_${DateTime.now().millisecondsSinceEpoch}',
      callSid: response.sid,
      fromNumber: response.from,
      toNumber: response.to,
      status: response.status,
      answeredBy: response.answeredBy,
      leg1Status: response.leg1Status,
      leg2Status: response.leg2Status,
      startTime: DateTime.tryParse(response.startTime ?? response.dateCreated) ?? DateTime.now(),
      endTime: response.endTime != null ? DateTime.tryParse(response.endTime!) : null,
      durationSeconds: response.duration,
      conversationDurationSeconds: response.conversationDuration,
      recordingUrl: response.recordingUrl,
      legs: response.legs,
      isSynced: false,
    );
  }

  /// Create from JSON (for local storage)
  factory CallLog.fromJson(Map<String, dynamic> json) {
    return CallLog(
      id: json['id'] ?? '',
      callSid: json['callSid'] ?? '',
      fromNumber: json['fromNumber'] ?? '',
      toNumber: json['toNumber'] ?? '',
      status: _parseStatus(json['status']),
      answeredBy: json['answeredBy'],
      leg1Status: json['leg1Status'],
      leg2Status: json['leg2Status'],
      startTime: DateTime.tryParse(json['startTime'] ?? '') ?? DateTime.now(),
      endTime: json['endTime'] != null ? DateTime.tryParse(json['endTime']) : null,
      durationSeconds: json['durationSeconds'],
      conversationDurationSeconds: json['conversationDurationSeconds'],
      recordingUrl: json['recordingUrl'],
      transcripts: List<String>.from(json['transcripts'] ?? []),
      insights: List<String>.from(json['insights'] ?? []),
      legs: json['legs'] != null
          ? (json['legs'] as List).map((l) => LegDetail.fromJson(l)).toList()
          : null,
      isSynced: json['isSynced'] ?? false,
    );
  }

  /// Convert to JSON (for local storage)
  Map<String, dynamic> toJson() => {
        'id': id,
        'callSid': callSid,
        'fromNumber': fromNumber,
        'toNumber': toNumber,
        'status': _statusToString(status),
        'answeredBy': answeredBy,
        'leg1Status': leg1Status,
        'leg2Status': leg2Status,
        'startTime': startTime.toIso8601String(),
        'endTime': endTime?.toIso8601String(),
        'durationSeconds': durationSeconds,
        'conversationDurationSeconds': conversationDurationSeconds,
        'recordingUrl': recordingUrl,
        'transcripts': transcripts,
        'insights': insights,
        'legs': legs?.map((l) => l.toJson()).toList(),
        'isSynced': isSynced,
      };

  /// Serialize to JSON string
  String toJsonString() => jsonEncode(toJson());

  /// Deserialize from JSON string
  static CallLog fromJsonString(String jsonString) {
    return CallLog.fromJson(jsonDecode(jsonString));
  }

  /// Copy with updated fields
  CallLog copyWith({
    String? id,
    String? callSid,
    String? fromNumber,
    String? toNumber,
    ExotelCallStatus? status,
    String? answeredBy,
    String? leg1Status,
    String? leg2Status,
    DateTime? startTime,
    DateTime? endTime,
    int? durationSeconds,
    int? conversationDurationSeconds,
    String? recordingUrl,
    List<String>? transcripts,
    List<String>? insights,
    List<LegDetail>? legs,
    bool? isSynced,
  }) {
    return CallLog(
      id: id ?? this.id,
      callSid: callSid ?? this.callSid,
      fromNumber: fromNumber ?? this.fromNumber,
      toNumber: toNumber ?? this.toNumber,
      status: status ?? this.status,
      answeredBy: answeredBy ?? this.answeredBy,
      leg1Status: leg1Status ?? this.leg1Status,
      leg2Status: leg2Status ?? this.leg2Status,
      startTime: startTime ?? this.startTime,
      endTime: endTime ?? this.endTime,
      durationSeconds: durationSeconds ?? this.durationSeconds,
      conversationDurationSeconds: conversationDurationSeconds ?? this.conversationDurationSeconds,
      recordingUrl: recordingUrl ?? this.recordingUrl,
      transcripts: transcripts ?? List.from(this.transcripts),
      insights: insights ?? List.from(this.insights),
      legs: legs ?? this.legs,
      isSynced: isSynced ?? this.isSynced,
    );
  }

  /// Add a transcript to the log
  CallLog addTranscript(String transcript) {
    final updatedTranscripts = List<String>.from(transcripts)..add(transcript);
    return copyWith(transcripts: updatedTranscripts);
  }

  /// Add an insight to the log
  CallLog addInsight(String insight) {
    final updatedInsights = List<String>.from(insights)..add(insight);
    return copyWith(insights: updatedInsights);
  }

  /// Check if the call is still active
  bool get isActive =>
      status == ExotelCallStatus.queued ||
      status == ExotelCallStatus.ringing ||
      status == ExotelCallStatus.inProgress;

  /// Check if the call has ended
  bool get hasEnded =>
      status == ExotelCallStatus.completed ||
      status == ExotelCallStatus.failed ||
      status == ExotelCallStatus.busy ||
      status == ExotelCallStatus.noAnswer;

  /// Get formatted duration string
  String get formattedDuration {
    final seconds = durationSeconds ?? 0;
    final minutes = seconds ~/ 60;
    final remainingSeconds = seconds % 60;
    return '${minutes.toString().padLeft(2, '0')}:${remainingSeconds.toString().padLeft(2, '0')}';
  }

  /// Get leg 1 display info (Sales)
  String get leg1DisplayStatus {
    if (leg1Status == null) {
      if (status == ExotelCallStatus.queued) return 'Queued';
      if (status == ExotelCallStatus.ringing) return 'Ringing...';
      return 'Pending';
    }
    return _formatLegStatus(leg1Status!);
  }

  /// Get leg 2 display info (Lead)
  String get leg2DisplayStatus {
    if (leg2Status == null) {
      if (status == ExotelCallStatus.queued) return 'Waiting';
      if (status == ExotelCallStatus.ringing) return 'Waiting';
      if (status == ExotelCallStatus.inProgress && leg1Status == 'completed') {
        return 'Ringing...';
      }
      return 'Pending';
    }
    return _formatLegStatus(leg2Status!);
  }

  static String _formatLegStatus(String status) {
    switch (status.toLowerCase()) {
      case 'completed':
        return 'Connected';
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

  static ExotelCallStatus _parseStatus(String? status) {
    switch (status?.toLowerCase()) {
      case 'queued':
        return ExotelCallStatus.queued;
      case 'in-progress':
      case 'inprogress':
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
      case 'noanswer':
        return ExotelCallStatus.noAnswer;
      default:
        return ExotelCallStatus.unknown;
    }
  }

  static String _statusToString(ExotelCallStatus status) {
    switch (status) {
      case ExotelCallStatus.queued:
        return 'queued';
      case ExotelCallStatus.inProgress:
        return 'in-progress';
      case ExotelCallStatus.ringing:
        return 'ringing';
      case ExotelCallStatus.completed:
        return 'completed';
      case ExotelCallStatus.failed:
        return 'failed';
      case ExotelCallStatus.busy:
        return 'busy';
      case ExotelCallStatus.noAnswer:
        return 'no-answer';
      case ExotelCallStatus.demo:
        return 'demo';
      default:
        return 'unknown';
    }
  }
}
