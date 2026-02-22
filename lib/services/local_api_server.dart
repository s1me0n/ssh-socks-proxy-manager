import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'proxy_service.dart';

class LocalApiServer {
  HttpServer? _server;
  final ProxyService proxyService;
  static const int port = 7070;
  int? _activePort;

  /// Returns the port the server is actually listening on (or null).
  int? get activePort => _activePort;

  LocalApiServer(this.proxyService);

  Future<void> start() async {
    try {
      _server = await HttpServer.bind(InternetAddress.anyIPv4, port, shared: true);
      _activePort = port;
      print('API server started on 0.0.0.0:$port');
      _server!.listen(_handleRequest, onError: (e) => print('API error: $e'));
    } catch (e) {
      print('Failed to start API server on $port: $e');
      // Try fallback port
      try {
        _server = await HttpServer.bind(InternetAddress.anyIPv4, 7071, shared: true);
        _activePort = 7071;
        print('API server started on 0.0.0.0:7071 (fallback)');
        _server!.listen(_handleRequest, onError: (e) => print('API error: $e'));
      } catch (e2) {
        print('API server completely failed: $e2');
      }
    }
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
    _activePort = null;
  }

  /// Get the local non-loopback IPv4 address for display.
  static Future<String> getLocalIp() async {
    try {
      final interfaces = await NetworkInterface.list(type: InternetAddressType.IPv4);
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          if (!addr.isLoopback) return addr.address;
        }
      }
    } catch (_) {}
    return 'localhost';
  }

  Future<void> _handleRequest(HttpRequest req) async {
    req.response.headers.set('Content-Type', 'application/json');
    req.response.headers.set('Access-Control-Allow-Origin', '*');

    // Handle CORS preflight
    if (req.method == 'OPTIONS') {
      req.response.headers.set('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
      req.response.headers.set('Access-Control-Allow-Headers', 'Content-Type');
      req.response.statusCode = 204;
      await req.response.close();
      return;
    }

    final path = req.uri.path;
    final method = req.method;

    try {
      if (path == '/status' && method == 'GET') {
        req.response.write(jsonEncode({
          'status': 'running',
          'servers': proxyService.servers.map((s) => {
            'id': s.id,
            'name': s.name,
            'host': s.host,
            'sshPort': s.sshPort,
            'socksPort': s.socksPort,
            'username': s.username,
            'enabled': s.isEnabled,
          }).toList(),
          'activeTunnels': proxyService.activeTunnels.map((t) => {
            'serverId': t.serverId,
            'name': t.serverName,
            'socksPort': t.socksPort,
            'uptime': t.uptime.inSeconds,
            'uptimeStr': t.uptimeString,
            'isExternal': t.isExternal,
            'restartCount': t.restartCount,
            'proxyType': t.proxyType,
            'authType': t.authType,
          }).toList(),
          'externalPorts': proxyService.activeTunnels
              .where((t) => t.isExternal)
              .map((t) => t.socksPort)
              .toList(),
        }));
      } else if (path == '/tunnels' && method == 'GET') {
        req.response.write(jsonEncode({
          'tunnels': proxyService.activeTunnels.map((t) => {
            'serverId': t.serverId,
            'name': t.serverName,
            'socksPort': t.socksPort,
            'uptime': t.uptime.inSeconds,
            'isExternal': t.isExternal,
            'proxyType': t.proxyType,
            'authType': t.authType,
          }).toList(),
        }));
      } else if (path == '/servers' && method == 'GET') {
        req.response.write(jsonEncode({
          'servers': proxyService.servers.map((s) => {
            'id': s.id,
            'name': s.name,
            'host': s.host,
            'sshPort': s.sshPort,
            'socksPort': s.socksPort,
            'enabled': s.isEnabled,
          }).toList(),
        }));
      } else if (path.startsWith('/connect/') && method == 'POST') {
        final serverId = path.replaceFirst('/connect/', '');
        try {
          final server =
              proxyService.servers.firstWhere((s) => s.id == serverId);
          await proxyService.connectTunnel(server);
          req.response.write(jsonEncode(
              {'success': true, 'message': 'Connected to ${server.name}'}));
        } catch (e) {
          req.response.statusCode = 400;
          req.response.write(
              jsonEncode({'success': false, 'error': e.toString()}));
        }
      } else if (path.startsWith('/disconnect/') && method == 'POST') {
        final serverId = path.replaceFirst('/disconnect/', '');
        proxyService.disconnectTunnel(serverId);
        req.response.write(
            jsonEncode({'success': true, 'message': 'Disconnected'}));
      } else if (path == '/scan' && method == 'POST') {
        proxyService.scanAllPorts();
        req.response.write(
            jsonEncode({'success': true, 'message': 'Port scan started'}));
      } else if (path == '/disconnect-all' && method == 'POST') {
        for (final t in List.from(proxyService.activeTunnels)) {
          if (!t.isExternal) proxyService.disconnectTunnel(t.serverId);
        }
        req.response.write(jsonEncode(
            {'success': true, 'message': 'All tunnels disconnected'}));
      } else if (path == '/help' && method == 'GET') {
        req.response.write(jsonEncode({
          'api': 'SSH Proxy Manager API v1',
          'port': _activePort ?? port,
          'termux_examples': [
            'curl localhost:${_activePort ?? port}/status',
            'curl localhost:${_activePort ?? port}/servers',
            'curl localhost:${_activePort ?? port}/tunnels',
            'curl -X POST localhost:${_activePort ?? port}/connect/{serverId}',
            'curl -X POST localhost:${_activePort ?? port}/disconnect/{serverId}',
            'curl -X POST localhost:${_activePort ?? port}/disconnect-all',
            'curl -X POST localhost:${_activePort ?? port}/scan',
          ],
          'tip': 'Get server IDs from /servers endpoint'
        }));
      } else {
        req.response.statusCode = 404;
        req.response.write(jsonEncode({
          'error': 'Unknown endpoint',
          'endpoints': [
            'GET  /status         — full status',
            'GET  /tunnels        — active tunnels',
            'GET  /servers        — saved servers',
            'POST /connect/{id}   — connect server by ID',
            'POST /disconnect/{id}— disconnect server by ID',
            'POST /disconnect-all — stop all tunnels',
            'POST /scan           — scan all ports',
          ]
        }));
      }
    } catch (e) {
      req.response.statusCode = 500;
      req.response.write(jsonEncode({'error': e.toString()}));
    }

    await req.response.close();
  }
}
