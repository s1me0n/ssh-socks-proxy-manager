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
  static const int _fallbackPort = 7071;
  static const int _maxRetries = 5;
  static const Duration _retryDelay = Duration(seconds: 2);
  int? _activePort;
  bool _running = false;
  Completer<void>? _startCompleter;
  DateTime? _startTime;

  /// Returns the port the server is actually listening on (or null).
  int? get activePort => _activePort;

  /// Whether the server is currently running.
  bool get isRunning => _running;

  /// Callback fired when server is ready (port is bound and listening).
  void Function(int port)? onReady;

  LocalApiServer(this.proxyService);

  /// Start the API server with retry logic and mutex protection.
  /// Safe to call concurrently — only the first call does actual work;
  /// subsequent calls await the same Future.
  Future<void> start() async {
    if (_running) {
      debugPrint(
          '⚠️ API server already running on port $_activePort, skipping duplicate start');
      return;
    }

    // Mutex: if another start() is already in progress, wait for it
    if (_startCompleter != null && !_startCompleter!.isCompleted) {
      debugPrint('⏳ API server start already in progress, waiting...');
      await _startCompleter!.future;
      return;
    }

    _startCompleter = Completer<void>();
    try {
      await _startWithRetry();
      _startCompleter!.complete();
    } catch (e) {
      _startCompleter!.completeError(e);
      _startCompleter = null;
      rethrow;
    }
  }

  /// Internal: attempt to bind with retries on both primary and fallback ports.
  Future<void> _startWithRetry() async {
    for (int attempt = 1; attempt <= _maxRetries; attempt++) {
      // Try primary port
      try {
        debugPrint(
            '🔌 Starting API server on 0.0.0.0:$port (attempt $attempt/$_maxRetries)...');
        _server = await HttpServer.bind(InternetAddress.anyIPv4, port);
        _activePort = port;
        _running = true;
        _attachListener();
        await _logSuccess();
        return;
      } catch (e) {
        debugPrint('❌ Failed to bind port $port (attempt $attempt): $e');
      }

      // Try fallback port
      try {
        debugPrint(
            '🔌 Trying fallback port $_fallbackPort (attempt $attempt/$_maxRetries)...');
        _server = await HttpServer.bind(
            InternetAddress.anyIPv4, _fallbackPort);
        _activePort = _fallbackPort;
        _running = true;
        _attachListener();
        await _logSuccess();
        return;
      } catch (e) {
        debugPrint(
            '❌ Failed to bind port $_fallbackPort (attempt $attempt): $e');
      }

      // Wait before retrying (except on last attempt)
      if (attempt < _maxRetries) {
        debugPrint('⏳ Retrying in ${_retryDelay.inSeconds}s...');
        await Future.delayed(_retryDelay);
      }
    }

    debugPrint('❌ API server completely failed after $_maxRetries attempts');
    _running = false;
  }

  void _attachListener() {
    _server!.listen(_handleRequest,
        onError: (e) => debugPrint('❌ API stream error: $e'), onDone: () {
      debugPrint('⚠️ API server stream closed on port $_activePort');
      _running = false;
      _startCompleter = null; // Allow restart
    });
  }

  Future<void> _logSuccess() async {
    _startTime = DateTime.now();
    final p = _activePort ?? port;
    debugPrint('✅ API server started successfully on port $p');
    final ip = await getLocalIp();
    debugPrint('🌐 Device IP: $ip — access via http://$ip:$p');
    debugPrint('🌐 Termux: curl http://127.0.0.1:$p/help');
    // Notify listeners (e.g. ProxyService → background notification)
    onReady?.call(p);
  }

  Future<void> stop() async {
    debugPrint('🛑 Stopping API server on port $_activePort...');
    try {
      await _server?.close(force: true);
    } catch (e) {
      debugPrint('❌ Error stopping API server: $e');
    }
    _server = null;
    _activePort = null;
    _running = false;
    _startTime = null;
    _startCompleter = null;
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
      req.response.headers
          .set('Access-Control-Allow-Headers', 'Content-Type');
      req.response.statusCode = 204;
      try {
        await req.response.close();
      } catch (_) {}
      return;
    }

    final path = req.uri.path;
    final method = req.method;

    try {
      // Lightweight readiness probe — returns instantly, minimal payload.
      if (path == '/ping' && method == 'GET') {
        await _writeJson(req, {
          'pong': true,
          'port': _activePort ?? port,
          'uptime': _startTime != null
              ? DateTime.now().difference(_startTime!).inSeconds
              : 0,
        });
        return;
      } else if (path == '/status' && method == 'GET') {
        await _writeJson(req, {
          'status': 'running',
          'version': '4.1.0',
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
                    'autoReconnect': s.autoReconnect,
                    'connectOnStartup': s.connectOnStartup,
                    'keyPath': s.keyPath,
                  })
              .toList(),
          'activeTunnels': proxyService.activeTunnels
              .map((t) => _tunnelToJson(t))
              .toList(),
          'externalPorts': proxyService.activeTunnels
              .where((t) => t.isExternal)
              .map((t) => t.socksPort)
              .toList(),
        });
        return;
      } else if (path == '/tunnels' && method == 'GET') {
        await _writeJson(req, {
          'tunnels': proxyService.activeTunnels
              .map((t) => _tunnelToJson(t))
              .toList(),
        });
        return;
      } else if (path == '/servers' && method == 'GET') {
        await _writeJson(req, {
          'servers': proxyService.servers
              .map((s) => {
                    'id': s.id,
                    'name': s.name,
                    'host': s.host,
                    'sshPort': s.sshPort,
                    'socksPort': s.socksPort,
                    'authType': s.authType,
                    'enabled': s.isEnabled,
                    'autoReconnect': s.autoReconnect,
                    'connectOnStartup': s.connectOnStartup,
                    'keyPath': s.keyPath,
                  })
              .toList(),
        });
        return;

        // ─── POST /servers/add ─────────────────────────────────────
      } else if (path == '/servers/add' && method == 'POST') {
        final body = await utf8.decoder.bind(req).join();
        final data = jsonDecode(body) as Map<String, dynamic>;

        // Validate required fields
        if (data['host'] == null || (data['host'] as String).isEmpty) {
          req.response.statusCode = 400;
          await _writeJson(req, {'success': false, 'error': 'host is required'});
          return;
        }
        if (data['username'] == null ||
            (data['username'] as String).isEmpty) {
          req.response.statusCode = 400;
          await _writeJson(
              req, {'success': false, 'error': 'username is required'});
          return;
        }

        final server = ServerConfig(
          id: generateUniqueId(),
          name: data['name'] ?? 'Server',
          host: data['host'],
          sshPort: data['sshPort'] ?? 22,
          username: data['username'],
          password: data['password'] ?? '',
          privateKey: data['privateKey'],
          keyPassphrase: data['keyPassphrase'],
          keyPath: data['keyPath'],
          authType: data['authType'] ??
              (data['privateKey'] != null || data['keyPath'] != null
                  ? 'key'
                  : 'password'),
          socksPort: data['socksPort'] ?? 1080,
          autoReconnect: data['autoReconnect'] ?? true,
          connectOnStartup: data['connectOnStartup'] ?? false,
        );
        await proxyService.addServer(server);
        await _writeJson(req, {'success': true, 'id': server.id});
        return;

        // ─── POST /servers/delete/{id} ─────────────────────────────
      } else if (path.startsWith('/servers/delete/') && method == 'POST') {
        final id = path.replaceFirst('/servers/delete/', '');
        await proxyService.deleteServer(id);
        await _writeJson(req, {'success': true});
        return;

        // ─── DELETE /servers/{id} (also supported) ─────────────────
      } else if (path.startsWith('/servers/') &&
          !path.startsWith('/servers/add') &&
          !path.startsWith('/servers/delete/') &&
          method == 'DELETE') {
        final id = path.replaceFirst('/servers/', '');
        await proxyService.deleteServer(id);
        await _writeJson(req, {'success': true});
        return;

        // ─── GET /scan/progress ────────────────────────────────────
      } else if (path == '/scan/progress' && method == 'GET') {
        await _writeJson(req, {
          'scanning': proxyService.isScanning,
          'progress': proxyService.scanProgress,
          'scannedPorts': proxyService.scannedPorts,
          'totalPorts': 65535,
          'found':
              proxyService.activeTunnels.where((t) => t.isExternal).length,
        });
        return;

        // ─── GET /export ───────────────────────────────────────────
      } else if (path == '/export' && method == 'GET') {
        final includeKeys =
            req.uri.queryParameters['includeKeys'] == 'true';
        await _writeJson(req, {
          'servers':
              proxyService.exportServers(includeKeys: includeKeys),
          'exportedAt': DateTime.now().toIso8601String(),
          'count': proxyService.servers.length,
          'includesKeys': includeKeys,
        });
        return;

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
          await _writeJson(req, {
            'success': false,
            'error': 'Expected JSON array or object with "servers" key',
          });
          return;
        }
        final added = proxyService.importServers(serverList);
        await _writeJson(req, {
          'success': true,
          'added': added,
          'total': proxyService.servers.length,
        });
        return;

        // ─── GET /logs ─────────────────────────────────────────────
      } else if (path == '/logs' && method == 'GET') {
        final limit =
            int.tryParse(req.uri.queryParameters['limit'] ?? '100') ??
                100;
        await _writeJson(req, {
          'logs': proxyService.logs
              .take(limit)
              .map((l) => {
                    'timestamp': l.timestamp.toIso8601String(),
                    'server': l.serverName,
                    'event': l.event,
                    'details': l.details,
                  })
              .toList(),
        });
        return;
      } else if (path.startsWith('/connect/') && method == 'POST') {
        final serverId = path.replaceFirst('/connect/', '');
        final server = proxyService.servers
            .where((s) => s.id == serverId)
            .firstOrNull;
        if (server == null) {
          req.response.statusCode = 404;
          await _writeJson(req, {
            'success': false,
            'error': 'Server not found: $serverId',
            'availableIds':
                proxyService.servers.map((s) => s.id).toList(),
          });
          return;
        }
        try {
          await proxyService.connectTunnel(server);
          await _writeJson(req, {
            'success': true,
            'message': 'Connected to ${server.name}',
            'tunnel': {
              'serverId': server.id,
              'socksPort': server.socksPort,
            },
          });
        } catch (e) {
          req.response.statusCode = 500;
          await _writeJson(
              req, {'success': false, 'error': e.toString()});
        }
        return;
      } else if (path.startsWith('/disconnect/') && method == 'POST') {
        final serverId = path.replaceFirst('/disconnect/', '');
        proxyService.disconnectTunnel(serverId);
        await _writeJson(
            req, {'success': true, 'message': 'Disconnected'});
        return;
      } else if (path == '/scan' && method == 'POST') {
        proxyService.scanAllPorts();
        await _writeJson(req,
            {'success': true, 'message': 'Port scan started'});
        return;
      } else if (path == '/disconnect-all' && method == 'POST') {
        for (final t in List.from(proxyService.activeTunnels)) {
          if (!t.isExternal) proxyService.disconnectTunnel(t.serverId);
        }
        await _writeJson(req,
            {'success': true, 'message': 'All tunnels disconnected'});
        return;
      } else if (path == '/help' && method == 'GET') {
        final p = _activePort ?? port;
        await _writeJson(req, {
          'api': 'SSH Proxy Manager API v4',
          'port': p,
          'endpoints': [
            'GET  /ping                    — readiness probe (lightweight)',
            'GET  /status                  — full status',
            'GET  /tunnels                 — active tunnels with health info',
            'GET  /servers                 — saved servers',
            'POST /servers/add             — add server (JSON body)',
            'POST /servers/delete/{id}     — delete server by id',
            'DELETE /servers/{id}          — delete server by id',
            'POST /connect/{id}            — connect server by ID',
            'POST /disconnect/{id}         — disconnect server by ID',
            'POST /disconnect-all          — stop all tunnels',
            'POST /scan                    — scan all ports',
            'GET  /scan/progress           — scan progress',
            'GET  /logs?limit=100          — connection logs',
            'GET  /export?includeKeys=true — export servers (optional: with keys)',
            'POST /import                  — import/merge servers (JSON body)',
            'GET  /help                    — this help',
          ],
          'serverAddFields': {
            'required': ['host', 'username'],
            'optional': [
              'name',
              'sshPort (default: 22)',
              'socksPort (default: 1080)',
              'password',
              'privateKey (PEM string)',
              'keyPath (path to key file)',
              'keyPassphrase',
              'authType (password|key)',
              'autoReconnect (default: true)',
              'connectOnStartup (default: false)',
            ],
          },
          'termux_examples': [
            '# Wait for API ready:',
            'while ! curl -sf localhost:$p/ping; do sleep 1; done',
            'curl localhost:$p/status',
            'curl -X POST -H "Content-Type: application/json" '
                '-d \'{"name":"My Server","host":"1.2.3.4","username":"root","password":"pass"}\' '
                'localhost:$p/servers/add',
            'curl -X POST -H "Content-Type: application/json" '
                '-d \'{"name":"Key Server","host":"1.2.3.4","username":"root","keyPath":"/data/data/com.termux/files/home/.ssh/id_ed25519"}\' '
                'localhost:$p/servers/add',
            'curl -X POST localhost:$p/connect/{serverId}',
            'curl localhost:$p/tunnels',
            'curl "localhost:$p/export?includeKeys=true"',
          ],
        });
        return;
      } else {
        req.response.statusCode = 404;
        await _writeJson(req, {
          'error': 'Unknown endpoint',
          'hint': 'Try GET /help for available endpoints',
        });
        return;
      }
    } catch (e) {
      req.response.statusCode = 500;
      try {
        req.response.write(jsonEncode({'error': e.toString()}));
        await req.response.close();
      } catch (_) {}
    }
  }

  /// Write a JSON response and close it immediately.
  /// Each handler that calls this should `return` afterward.
  Future<void> _writeJson(HttpRequest req, Map<String, dynamic> data) async {
    // Drain any unread request body first — if the input stream is not
    // consumed, response.close() can hang on some Dart VM / Android builds.
    try {
      await req.drain<void>();
    } catch (_) {}
    final body = jsonEncode(data);
    final bytes = utf8.encode(body);
    req.response.headers.contentLength = bytes.length;
    req.response.add(bytes);
    await req.response.close();
  }

  /// Convert an ActiveTunnel to a JSON map with full health info.
  Map<String, dynamic> _tunnelToJson(dynamic t) {
    return {
      'serverId': t.serverId,
      'name': t.serverName,
      'socksPort': t.socksPort,
      'uptime': t.uptime.inSeconds,
      'uptimeStr': t.uptimeString,
      'isExternal': t.isExternal,
      'reconnectCount': t.reconnectCount,
      'proxyType': t.proxyType,
      'authType': t.authType,
      'bytesIn': t.bytesIn,
      'bytesOut': t.bytesOut,
      'bandwidth': t.bandwidthString,
      // Health monitoring fields
      'latencyMs': t.latencyMs,
      'lastKeepaliveAt': t.lastKeepaliveAt?.toIso8601String(),
      'totalUptime': t.effectiveTotalUptime.inSeconds,
      'totalUptimeStr': t.totalUptimeString,
    };
  }
}
