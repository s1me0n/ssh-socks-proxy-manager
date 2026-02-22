import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import '../models/server_config.dart';
import '../utils/id_generator.dart';
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
      _server = await HttpServer.bind(InternetAddress.anyIPv4, port,
          shared: true);
      _activePort = port;
      debugPrint('🌐 API Server started on 0.0.0.0:$port');
      debugPrint('🌐 API Server URL: http://0.0.0.0:$port');
      final ip = await getLocalIp();
      debugPrint('🌐 Device IP: $ip — access via http://$ip:$port');
      _server!.listen(_handleRequest,
          onError: (e) => debugPrint('API error: $e'));
    } catch (e) {
      debugPrint('Failed to start API server on $port: $e');
      // Try fallback port
      try {
        _server = await HttpServer.bind(InternetAddress.anyIPv4, 7071,
            shared: true);
        _activePort = 7071;
        debugPrint('🌐 API Server started on 0.0.0.0:7071 (fallback)');
        debugPrint('🌐 API Server URL: http://0.0.0.0:7071');
        _server!.listen(_handleRequest,
            onError: (e) => debugPrint('API error: $e'));
      } catch (e2) {
        debugPrint('API server completely failed: $e2');
      }
    }
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
    _activePort = null;
  }

  /// Get the API listen address for display.
  /// Returns the first non-loopback IPv4 address found on the device.
  static Future<String> getLocalIp() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          if (!addr.isLoopback) {
            return addr.address;
          }
        }
      }
    } catch (e) {
      debugPrint('Failed to get local IP: $e');
    }
    return '127.0.0.1';
  }

  Future<void> _handleRequest(HttpRequest req) async {
    req.response.headers.set('Content-Type', 'application/json');
    req.response.headers.set('Access-Control-Allow-Origin', '*');

    // Handle CORS preflight
    if (req.method == 'OPTIONS') {
      req.response.headers
          .set('Access-Control-Allow-Methods', 'GET, POST, DELETE, OPTIONS');
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
          'version': '2.0.0',
          'servers': proxyService.servers
              .map((s) => {
                    'id': s.id,
                    'name': s.name,
                    'host': s.host,
                    'sshPort': s.sshPort,
                    'socksPort': s.socksPort,
                    'username': s.username,
                    'authType': s.authType,
                    'enabled': s.isEnabled,
                  })
              .toList(),
          'activeTunnels': proxyService.activeTunnels
              .map((t) => {
                    'serverId': t.serverId,
                    'name': t.serverName,
                    'socksPort': t.socksPort,
                    'uptime': t.uptime.inSeconds,
                    'uptimeStr': t.uptimeString,
                    'isExternal': t.isExternal,
                    'restartCount': t.restartCount,
                    'proxyType': t.proxyType,
                    'authType': t.authType,
                    'bytesIn': t.bytesIn,
                    'bytesOut': t.bytesOut,
                    'bandwidth': t.bandwidthString,
                  })
              .toList(),
          'externalPorts': proxyService.activeTunnels
              .where((t) => t.isExternal)
              .map((t) => t.socksPort)
              .toList(),
        }));
      } else if (path == '/tunnels' && method == 'GET') {
        req.response.write(jsonEncode({
          'tunnels': proxyService.activeTunnels
              .map((t) => {
                    'serverId': t.serverId,
                    'name': t.serverName,
                    'socksPort': t.socksPort,
                    'uptime': t.uptime.inSeconds,
                    'isExternal': t.isExternal,
                    'proxyType': t.proxyType,
                    'authType': t.authType,
                    'bytesIn': t.bytesIn,
                    'bytesOut': t.bytesOut,
                    'bandwidth': t.bandwidthString,
                  })
              .toList(),
        }));
      } else if (path == '/servers' && method == 'GET') {
        req.response.write(jsonEncode({
          'servers': proxyService.servers
              .map((s) => {
                    'id': s.id,
                    'name': s.name,
                    'host': s.host,
                    'sshPort': s.sshPort,
                    'socksPort': s.socksPort,
                    'authType': s.authType,
                    'enabled': s.isEnabled,
                  })
              .toList(),
        }));

        // ─── POST /servers/add ─────────────────────────────────────
      } else if (path == '/servers/add' && method == 'POST') {
        final body = await utf8.decoder.bind(req).join();
        final data = jsonDecode(body) as Map<String, dynamic>;
        final server = ServerConfig(
          id: generateUniqueId(),
          name: data['name'] ?? 'Server',
          host: data['host'],
          sshPort: data['sshPort'] ?? 22,
          username: data['username'],
          password: data['password'] ?? '',
          privateKey: data['privateKey'],
          keyPassphrase: data['keyPassphrase'],
          authType: data['authType'] ??
              (data['privateKey'] != null ? 'key' : 'password'),
          socksPort: data['socksPort'] ?? 1080,
        );
        proxyService.addServer(server);
        req.response
            .write(jsonEncode({'success': true, 'id': server.id}));

        // ─── POST /servers/delete/{id} ─────────────────────────────
      } else if (path.startsWith('/servers/delete/') && method == 'POST') {
        final id = path.replaceFirst('/servers/delete/', '');
        proxyService.deleteServer(id);
        req.response.write(jsonEncode({'success': true}));

        // ─── DELETE /servers/{id} (also supported) ─────────────────
      } else if (path.startsWith('/servers/') &&
          !path.startsWith('/servers/add') &&
          !path.startsWith('/servers/delete/') &&
          method == 'DELETE') {
        final id = path.replaceFirst('/servers/', '');
        proxyService.deleteServer(id);
        req.response.write(jsonEncode({'success': true}));

        // ─── GET /scan/progress ────────────────────────────────────
      } else if (path == '/scan/progress' && method == 'GET') {
        req.response.write(jsonEncode({
          'scanning': proxyService.isScanning,
          'progress': proxyService.scanProgress,
          'scannedPorts': proxyService.scannedPorts,
          'totalPorts': 65535,
          'found': proxyService.activeTunnels
              .where((t) => t.isExternal)
              .length,
        }));

        // ─── GET /export ───────────────────────────────────────────
      } else if (path == '/export' && method == 'GET') {
        req.response.write(jsonEncode({
          'servers': proxyService.exportServers(),
          'exportedAt': DateTime.now().toIso8601String(),
          'count': proxyService.servers.length,
        }));

        // ─── POST /import ──────────────────────────────────────────
      } else if (path == '/import' && method == 'POST') {
        final body = await utf8.decoder.bind(req).join();
        final data = jsonDecode(body);
        List<dynamic> serverList;
        if (data is Map && data.containsKey('servers')) {
          serverList = data['servers'] as List<dynamic>;
        } else if (data is List) {
          serverList = data;
        } else {
          req.response.statusCode = 400;
          req.response.write(jsonEncode({
            'success': false,
            'error':
                'Expected JSON array or object with "servers" key',
          }));
          await req.response.close();
          return;
        }
        final added = proxyService.importServers(serverList);
        req.response.write(jsonEncode({
          'success': true,
          'added': added,
          'total': proxyService.servers.length,
        }));

        // ─── GET /logs ─────────────────────────────────────────────
      } else if (path == '/logs' && method == 'GET') {
        final limit =
            int.tryParse(req.uri.queryParameters['limit'] ?? '100') ?? 100;
        req.response.write(jsonEncode({
          'logs': proxyService.logs
              .take(limit)
              .map((l) => {
                    'timestamp': l.timestamp.toIso8601String(),
                    'server': l.serverName,
                    'event': l.event,
                    'details': l.details,
                  })
              .toList(),
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
          req.response
              .write(jsonEncode({'success': false, 'error': e.toString()}));
        }
      } else if (path.startsWith('/disconnect/') && method == 'POST') {
        final serverId = path.replaceFirst('/disconnect/', '');
        proxyService.disconnectTunnel(serverId);
        req.response
            .write(jsonEncode({'success': true, 'message': 'Disconnected'}));
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
          'api': 'SSH Proxy Manager API v2',
          'port': _activePort ?? port,
          'endpoints': [
            'GET  /status              — full status',
            'GET  /tunnels             — active tunnels',
            'GET  /servers             — saved servers',
            'POST /servers/add         — add server (JSON body)',
            'POST /servers/delete/{id} — delete server by id',
            'DELETE /servers/{id}      — delete server by id',
            'POST /connect/{id}       — connect server by ID',
            'POST /disconnect/{id}    — disconnect server by ID',
            'POST /disconnect-all     — stop all tunnels',
            'POST /scan               — scan all ports',
            'GET  /scan/progress      — scan progress',
            'GET  /logs?limit=100     — connection logs',
            'GET  /export             — export servers (no secrets)',
            'POST /import             — import/merge servers (JSON body)',
          ],
          'termux_examples': [
            'curl localhost:${_activePort ?? port}/status',
            'curl -X POST -H "Content-Type: application/json" -d \'{"name":"My Server","host":"1.2.3.4","username":"root","password":"pass"}\' localhost:${_activePort ?? port}/servers/add',
            'curl -X POST localhost:${_activePort ?? port}/connect/{serverId}',
            'curl -X POST localhost:${_activePort ?? port}/servers/delete/{serverId}',
            'curl localhost:${_activePort ?? port}/scan/progress',
            'curl localhost:${_activePort ?? port}/logs',
            'curl localhost:${_activePort ?? port}/export',
            'curl -X POST -H "Content-Type: application/json" -d @servers.json localhost:${_activePort ?? port}/import',
          ],
        }));
      } else {
        req.response.statusCode = 404;
        req.response.write(jsonEncode({
          'error': 'Unknown endpoint',
          'hint': 'Try GET /help for available endpoints',
        }));
      }
    } catch (e) {
      req.response.statusCode = 500;
      req.response.write(jsonEncode({'error': e.toString()}));
    }

    await req.response.close();
  }
}
