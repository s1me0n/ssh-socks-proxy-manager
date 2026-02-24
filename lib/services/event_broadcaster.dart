import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Manages WebSocket connections and broadcasts events to all connected clients.
class EventBroadcaster {
  final Set<WebSocket> _clients = {};
  Timer? _pingTimer;

  /// Start periodic ping heartbeat (call once after construction).
  void startPingTimer() {
    _pingTimer?.cancel();
    _pingTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      _sendToAll(jsonEncode({
        'event': 'ping',
        'timestamp': DateTime.now().toUtc().toIso8601String(),
      }));
    });
  }

  void addClient(WebSocket ws) {
    _clients.add(ws);
    ws.done.then((_) => _clients.remove(ws)).catchError((_) => _clients.remove(ws));
    // Start ping timer on first client
    if (_clients.length == 1 && _pingTimer == null) {
      startPingTimer();
    }
  }

  /// Send initial state snapshot to a newly connected client.
  void sendInitialState(WebSocket ws, List<Map<String, dynamic>> tunnels) {
    final ts = DateTime.now().toUtc().toIso8601String();
    for (final t in tunnels) {
      try {
        ws.add(jsonEncode({
          'event': 'connected',
          'serverId': t['serverId'],
          'name': t['name'],
          'socksPort': t['socksPort'],
          'timestamp': ts,
        }));
      } catch (_) {
        _clients.remove(ws);
        return;
      }
    }
  }

  void broadcast(Map<String, dynamic> event) {
    final json = jsonEncode({
      ...event,
      'timestamp': DateTime.now().toUtc().toIso8601String(),
    });
    _sendToAll(json);
  }

  void _sendToAll(String json) {
    for (final ws in Set<WebSocket>.from(_clients)) {
      try {
        ws.add(json);
      } catch (_) {
        _clients.remove(ws);
      }
    }
  }

  void emit(String event, Map<String, dynamic> data) {
    broadcast({'event': event, ...data});
  }

  int get clientCount => _clients.length;

  void closeAll() {
    _pingTimer?.cancel();
    _pingTimer = null;
    for (final ws in Set<WebSocket>.from(_clients)) {
      try {
        ws.close();
      } catch (_) {}
    }
    _clients.clear();
  }
}
