import 'package:flutter/material.dart';

import '../../../../core/models/call_log.dart';
import '../../../../core/services/exotel_service.dart';
import '../../../../core/services/local_storage_service.dart';

/// Call History Screen showing past calls
class CallHistoryScreen extends StatefulWidget {
  const CallHistoryScreen({super.key});

  @override
  State<CallHistoryScreen> createState() => _CallHistoryScreenState();
}

class _CallHistoryScreenState extends State<CallHistoryScreen> {
  final LocalStorageService _localStorage = LocalStorageService();
  List<CallLog> _callHistory = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadCallHistory();
  }

  Future<void> _loadCallHistory() async {
    setState(() => _isLoading = true);

    await _localStorage.init();
    final history = await _localStorage.getCallHistory(limit: 50);

    setState(() {
      _callHistory = history;
      _isLoading = false;
    });
  }

  Future<void> _deleteCall(CallLog call) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text(
          'Delete Call',
          style: TextStyle(color: Colors.white),
        ),
        content: Text(
          'Delete call to ${call.toNumber}?',
          style: TextStyle(color: Colors.white.withValues(alpha: 0.7)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(
              'Cancel',
              style: TextStyle(color: Colors.white.withValues(alpha: 0.6)),
            ),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await _localStorage.deleteCallLog(call.id);
      await _loadCallHistory();
    }
  }

  Future<void> _clearAllHistory() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text(
          'Clear All History',
          style: TextStyle(color: Colors.white),
        ),
        content: Text(
          'Are you sure you want to delete all call history?',
          style: TextStyle(color: Colors.white.withValues(alpha: 0.7)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(
              'Cancel',
              style: TextStyle(color: Colors.white.withValues(alpha: 0.6)),
            ),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
            ),
            child: const Text('Clear All'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await _localStorage.clearCallHistory();
      await _loadCallHistory();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF121212),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1E1E1E),
        title: const Text(
          'Call History',
          style: TextStyle(color: Colors.white),
        ),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () => Navigator.of(context).pop(),
        ),
        actions: [
          if (_callHistory.isNotEmpty)
            IconButton(
              icon: Icon(
                Icons.delete_sweep,
                color: Colors.white.withValues(alpha: 0.7),
              ),
              onPressed: _clearAllHistory,
              tooltip: 'Clear All',
            ),
        ],
      ),
      body: _isLoading
          ? const Center(
              child: CircularProgressIndicator(color: Colors.white),
            )
          : _callHistory.isEmpty
              ? _buildEmptyState()
              : _buildCallList(),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.call_end,
            size: 64,
            color: Colors.white.withValues(alpha: 0.2),
          ),
          const SizedBox(height: 16),
          Text(
            'No Call History',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.5),
              fontSize: 18,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Your call history will appear here',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.3),
              fontSize: 14,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCallList() {
    return RefreshIndicator(
      onRefresh: _loadCallHistory,
      color: Colors.white,
      backgroundColor: const Color(0xFF1E1E1E),
      child: ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: _callHistory.length,
        itemBuilder: (context, index) {
          final call = _callHistory[index];
          return _buildCallCard(call);
        },
      ),
    );
  }

  Widget _buildCallCard(CallLog call) {
    final statusColor = _getStatusColor(call.status);
    final timeAgo = _getTimeAgo(call.startTime);

    return Dismissible(
      key: Key(call.id),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        margin: const EdgeInsets.only(bottom: 12),
        decoration: BoxDecoration(
          color: Colors.red.withValues(alpha: 0.2),
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Icon(Icons.delete, color: Colors.red),
      ),
      onDismissed: (_) async {
        await _localStorage.deleteCallLog(call.id);
        setState(() {
          _callHistory.removeWhere((c) => c.id == call.id);
        });
      },
      child: GestureDetector(
        onLongPress: () => _deleteCall(call),
        child: Container(
          margin: const EdgeInsets.only(bottom: 12),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: statusColor.withValues(alpha: 0.2),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Top row: Phone icon + numbers + status
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: statusColor.withValues(alpha: 0.1),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    _getStatusIcon(call.status),
                    color: statusColor,
                    size: 20,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        call.toNumber,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'From: ${call.fromNumber}',
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.5),
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                // Status badge
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: statusColor.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    _getStatusText(call.status),
                    style: TextStyle(
                      color: statusColor,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),

            const SizedBox(height: 12),

            // Middle row: Duration, AnsweredBy, Transcripts
            Row(
              children: [
                // Duration
                if (call.durationSeconds != null && call.durationSeconds! > 0)
                  _buildInfoChip(
                    icon: Icons.timer,
                    label: call.formattedDuration,
                    color: Colors.blue,
                  ),

                // AnsweredBy
                if (call.answeredBy != null) ...[
                  const SizedBox(width: 8),
                  _buildInfoChip(
                    icon: call.answeredBy == 'Human'
                        ? Icons.person
                        : Icons.smart_toy,
                    label: call.answeredBy!,
                    color: call.answeredBy == 'Human'
                        ? Colors.green
                        : Colors.orange,
                  ),
                ],

                // Transcripts count
                if (call.transcripts.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  _buildInfoChip(
                    icon: Icons.notes,
                    label: '${call.transcripts.length} transcripts',
                    color: Colors.purple,
                  ),
                ],

                const Spacer(),

                // Time ago
                Text(
                  timeAgo,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.4),
                    fontSize: 11,
                  ),
                ),
              ],
            ),

            // Insights preview (if any)
            if (call.insights.isNotEmpty) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.purple.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.psychology,
                      color: Colors.purple.withValues(alpha: 0.7),
                      size: 14,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        '${call.insights.length} AI insights',
                        style: TextStyle(
                          color: Colors.purple.withValues(alpha: 0.8),
                          fontSize: 11,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],

            // Sync status
            if (!call.isSynced) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  Icon(
                    Icons.cloud_off,
                    color: Colors.orange.withValues(alpha: 0.6),
                    size: 12,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    'Not synced',
                    style: TextStyle(
                      color: Colors.orange.withValues(alpha: 0.6),
                      fontSize: 10,
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
        ),
      ),
    );
  }

  Widget _buildInfoChip({
    required IconData icon,
    required String label,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 10,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  Color _getStatusColor(ExotelCallStatus status) {
    switch (status) {
      case ExotelCallStatus.completed:
        return Colors.green;
      case ExotelCallStatus.inProgress:
        return Colors.blue;
      case ExotelCallStatus.ringing:
      case ExotelCallStatus.queued:
        return Colors.amber;
      case ExotelCallStatus.failed:
      case ExotelCallStatus.busy:
      case ExotelCallStatus.noAnswer:
        return Colors.red;
      default:
        return Colors.grey;
    }
  }

  IconData _getStatusIcon(ExotelCallStatus status) {
    switch (status) {
      case ExotelCallStatus.completed:
        return Icons.call_made;
      case ExotelCallStatus.inProgress:
        return Icons.call;
      case ExotelCallStatus.ringing:
      case ExotelCallStatus.queued:
        return Icons.ring_volume;
      case ExotelCallStatus.failed:
        return Icons.call_end;
      case ExotelCallStatus.busy:
        return Icons.phone_disabled;
      case ExotelCallStatus.noAnswer:
        return Icons.phone_missed;
      default:
        return Icons.call;
    }
  }

  String _getStatusText(ExotelCallStatus status) {
    switch (status) {
      case ExotelCallStatus.completed:
        return 'Completed';
      case ExotelCallStatus.inProgress:
        return 'In Progress';
      case ExotelCallStatus.ringing:
        return 'Ringing';
      case ExotelCallStatus.queued:
        return 'Queued';
      case ExotelCallStatus.failed:
        return 'Failed';
      case ExotelCallStatus.busy:
        return 'Busy';
      case ExotelCallStatus.noAnswer:
        return 'No Answer';
      case ExotelCallStatus.demo:
        return 'Demo';
      default:
        return 'Unknown';
    }
  }

  String _getTimeAgo(DateTime time) {
    final now = DateTime.now();
    final difference = now.difference(time);

    if (difference.inSeconds < 60) {
      return 'Just now';
    } else if (difference.inMinutes < 60) {
      final mins = difference.inMinutes;
      return '$mins min${mins > 1 ? 's' : ''} ago';
    } else if (difference.inHours < 24) {
      final hours = difference.inHours;
      return '$hours hour${hours > 1 ? 's' : ''} ago';
    } else if (difference.inDays < 7) {
      final days = difference.inDays;
      return '$days day${days > 1 ? 's' : ''} ago';
    } else {
      return '${time.day}/${time.month}/${time.year}';
    }
  }
}
