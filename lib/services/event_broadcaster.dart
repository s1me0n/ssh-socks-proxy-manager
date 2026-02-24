import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Manages WebSocket connections and broadcasts events to all connected clients.
class EventBroadcaster {
  final Set<WebSocket> _clients = {};

  void addClient(WebSocket ws) {
    _clients.add(ws);
    ws.done.then((_) => _clients.remove(ws)).catchError((_) => _clients.remove(ws));
  }

  void broadcast(Map<String, dynamic> event) {
    final json = jsonEncode(event);
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
    for (final ws in Set<WebSocket>.from(_clients)) {
      try {
        ws.close();
      } catch (_) {}
    }
    _clients.clear();
  }
}
