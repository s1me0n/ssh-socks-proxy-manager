class ConnectionLog {
  final DateTime timestamp;
  final String serverName;
  final String event; // 'connected', 'disconnected', 'error', 'reconnected', 'info'
  final String? details;

  ConnectionLog({
    required this.timestamp,
    required this.serverName,
    required this.event,
    this.details,
  });

  String get timeString {
    final h = timestamp.hour.toString().padLeft(2, '0');
    final m = timestamp.minute.toString().padLeft(2, '0');
    final s = timestamp.second.toString().padLeft(2, '0');
    return '$h:$m:$s';
  }
}
