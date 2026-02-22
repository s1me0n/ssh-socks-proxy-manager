import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'proxy_service.dart';

class LocalApiServer {
  HttpServer? _server;
  final ProxyService proxyService;
  static const int port = 7070;

  LocalApiServer(this.proxyService);

  Future<void> start() async {
    _server = await HttpServer.bind('127.0.0.1', port);
    _server!.listen(_handleRequest);
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
  }

  Future<void> _handleRequest(HttpRequest req) async {
    req.response.headers.set('Content-Type', 'application/json');
    req.response.headers.set('Access-Control-Allow-Origin', '*');

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
