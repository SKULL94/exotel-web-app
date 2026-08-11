import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/call_log.dart';

/// Local storage service for call state persistence
/// Uses SharedPreferences for simple key-value storage
class LocalStorageService {
  static final LocalStorageService _instance = LocalStorageService._internal();
  factory LocalStorageService() => _instance;
  LocalStorageService._internal();

  static const String _activeCallKey = 'active_call';
  static const String _callHistoryKey = 'call_history';
  static const String _pendingSyncKey = 'pending_sync';

  SharedPreferences? _prefs;

  /// Initialize SharedPreferences
  Future<void> init() async {
    _prefs ??= await SharedPreferences.getInstance();
    debugPrint('LocalStorageService: Initialized');
  }

  /// Ensure preferences are initialized
  Future<SharedPreferences> _getPrefs() async {
    _prefs ??= await SharedPreferences.getInstance();
    return _prefs!;
  }

  // ============ Active Call State ============

  /// Save the current active call (for app kill/relaunch recovery)
  Future<void> saveActiveCall(CallLog call) async {
    final prefs = await _getPrefs();
    await prefs.setString(_activeCallKey, call.toJsonString());
    debugPrint('LocalStorageService: Saved active call ${call.callSid}');
  }

  /// Get the active call if any
  Future<CallLog?> getActiveCall() async {
    final prefs = await _getPrefs();
    final json = prefs.getString(_activeCallKey);
    if (json == null || json.isEmpty) return null;

    try {
      final call = CallLog.fromJsonString(json);
      debugPrint('LocalStorageService: Retrieved active call ${call.callSid}');
      return call;
    } catch (e) {
      debugPrint('LocalStorageService: Error parsing active call - $e');
      return null;
    }
  }

  /// Clear the active call
  Future<void> clearActiveCall() async {
    final prefs = await _getPrefs();
    await prefs.remove(_activeCallKey);
    debugPrint('LocalStorageService: Cleared active call');
  }

  /// Update the active call (e.g., adding transcripts/insights)
  Future<void> updateActiveCall(CallLog updatedCall) async {
    await saveActiveCall(updatedCall);
  }

  // ============ Call History ============

  /// Save a completed call to history
  Future<void> saveCallLog(CallLog log) async {
    final prefs = await _getPrefs();
    final history = await getCallHistory();

    // Remove existing entry with same ID if exists
    history.removeWhere((c) => c.id == log.id || c.callSid == log.callSid);

    // Add new entry at the beginning
    history.insert(0, log);

    // Keep only last 100 calls
    if (history.length > 100) {
      history.removeRange(100, history.length);
    }

    // Save to storage
    final jsonList = history.map((c) => c.toJson()).toList();
    await prefs.setString(_callHistoryKey, jsonEncode(jsonList));
    debugPrint('LocalStorageService: Saved call log ${log.callSid}');
  }

  /// Get call history
  Future<List<CallLog>> getCallHistory({int limit = 50}) async {
    final prefs = await _getPrefs();
    final json = prefs.getString(_callHistoryKey);
    if (json == null || json.isEmpty) return [];

    try {
      final List<dynamic> jsonList = jsonDecode(json);
      final history = jsonList.map((j) => CallLog.fromJson(j)).toList();

      // Return limited results
      if (history.length > limit) {
        return history.sublist(0, limit);
      }
      return history;
    } catch (e) {
      debugPrint('LocalStorageService: Error parsing call history - $e');
      return [];
    }
  }

  /// Get a specific call log by ID
  Future<CallLog?> getCallLogById(String id) async {
    final history = await getCallHistory(limit: 100);
    try {
      return history.firstWhere((c) => c.id == id);
    } catch (_) {
      return null;
    }
  }

  /// Get a specific call log by call SID
  Future<CallLog?> getCallLogBySid(String callSid) async {
    final history = await getCallHistory(limit: 100);
    try {
      return history.firstWhere((c) => c.callSid == callSid);
    } catch (_) {
      return null;
    }
  }

  /// Delete a call log by ID
  Future<void> deleteCallLog(String id) async {
    final prefs = await _getPrefs();
    final history = await getCallHistory(limit: 100);
    history.removeWhere((c) => c.id == id);

    final jsonList = history.map((c) => c.toJson()).toList();
    await prefs.setString(_callHistoryKey, jsonEncode(jsonList));
    debugPrint('LocalStorageService: Deleted call log $id');
  }

  /// Clear all call history
  Future<void> clearCallHistory() async {
    final prefs = await _getPrefs();
    await prefs.remove(_callHistoryKey);
    debugPrint('LocalStorageService: Cleared call history');
  }

  // ============ Pending Sync Queue (for Firestore) ============

  /// Add a call to the pending sync queue
  Future<void> addToPendingSync(CallLog log) async {
    final prefs = await _getPrefs();
    final pending = await getPendingSyncQueue();

    // Remove existing entry with same ID if exists
    pending.removeWhere((c) => c.id == log.id);

    // Add to queue
    pending.add(log.copyWith(isSynced: false));

    final jsonList = pending.map((c) => c.toJson()).toList();
    await prefs.setString(_pendingSyncKey, jsonEncode(jsonList));
    debugPrint('LocalStorageService: Added ${log.callSid} to pending sync');
  }

  /// Get all calls pending sync
  Future<List<CallLog>> getPendingSyncQueue() async {
    final prefs = await _getPrefs();
    final json = prefs.getString(_pendingSyncKey);
    if (json == null || json.isEmpty) return [];

    try {
      final List<dynamic> jsonList = jsonDecode(json);
      return jsonList.map((j) => CallLog.fromJson(j)).toList();
    } catch (e) {
      debugPrint('LocalStorageService: Error parsing pending sync queue - $e');
      return [];
    }
  }

  /// Remove a call from pending sync queue (after successful sync)
  Future<void> removeFromPendingSync(String id) async {
    final prefs = await _getPrefs();
    final pending = await getPendingSyncQueue();
    pending.removeWhere((c) => c.id == id);

    final jsonList = pending.map((c) => c.toJson()).toList();
    await prefs.setString(_pendingSyncKey, jsonEncode(jsonList));
    debugPrint('LocalStorageService: Removed $id from pending sync');
  }

  /// Mark a call as synced in history
  Future<void> markAsSynced(String id) async {
    final prefs = await _getPrefs();
    final history = await getCallHistory(limit: 100);

    final index = history.indexWhere((c) => c.id == id);
    if (index != -1) {
      history[index] = history[index].copyWith(isSynced: true);
      final jsonList = history.map((c) => c.toJson()).toList();
      await prefs.setString(_callHistoryKey, jsonEncode(jsonList));
      debugPrint('LocalStorageService: Marked $id as synced');
    }

    // Also remove from pending sync
    await removeFromPendingSync(id);
  }

  /// Clear pending sync queue
  Future<void> clearPendingSyncQueue() async {
    final prefs = await _getPrefs();
    await prefs.remove(_pendingSyncKey);
    debugPrint('LocalStorageService: Cleared pending sync queue');
  }

  // ============ Stats ============

  /// Get storage stats
  Future<Map<String, int>> getStats() async {
    final history = await getCallHistory(limit: 100);
    final pending = await getPendingSyncQueue();
    final activeCall = await getActiveCall();

    return {
      'totalCalls': history.length,
      'pendingSync': pending.length,
      'hasActiveCall': activeCall != null ? 1 : 0,
    };
  }
}
