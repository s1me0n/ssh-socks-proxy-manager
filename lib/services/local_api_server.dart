import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import '../models/server_config.dart';
import '../models/quick_profile.dart';
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

  int? get activePort => _activePort;
  bool get isRunning => _running;
  void Function(int port)? onReady;

  LocalApiServer(this.proxyService);

  Future<void> start() async {
    if (_running) {
      debugPrint(
          '⚠️ API server already running on port $_activePort, skipping duplicate start');
      return;
    }
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

  Future<void> _startWithRetry() async {
    for (int attempt = 1; attempt <= _maxRetries; attempt++) {
      try {
        _server = await HttpServer.bind(InternetAddress.anyIPv4, port);
        _activePort = port;
        _running = true;
        _attachListener();
        await _logSuccess();
        return;
      } catch (e) {
        debugPrint('❌ Failed to bind port $port (attempt $attempt): $e');
      }
      try {
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
      if (attempt < _maxRetries) {
        await Future.delayed(_retryDelay);
      }
    }
    _running = false;
  }

  void _attachListener() {
    _server!.listen(_handleRequest,
        onError: (e) => debugPrint('❌ API stream error: $e'), onDone: () {
      _running = false;
      _startCompleter = null;
    });
  }

  Future<void> _logSuccess() async {
    _startTime = DateTime.now();
    final p = _activePort ?? port;
    debugPrint('✅ API server started successfully on port $p');
    final ip = await getLocalIp();
    debugPrint('🌐 Device IP: $ip — access via http://$ip:$p');
    onReady?.call(p);
  }

  Future<void> stop() async {
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

  static Future<String> getLocalIp() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          if (!addr.isLoopback) return addr.address;
        }
      }
    } catch (e) {
      debugPrint('Failed to get local IP: $e');
    }
    return '127.0.0.1';
  }

  /// Check API token authentication. Returns true if authorized.
  bool _checkAuth(HttpRequest req) {
    if (!proxyService.apiAuthEnabled) return true;

    // Extract token from header or query param
    final authHeader = req.headers.value('authorization');
    String? token;
    if (authHeader != null && authHeader.startsWith('Bearer ')) {
      token = authHeader.substring(7);
    }
    token ??= req.uri.queryParameters['token'];

    return token != null && token == proxyService.apiToken;
  }

  Future<void> _handleRequest(HttpRequest req) async {
    req.response.headers.set('Content-Type', 'application/json');
    req.response.headers.set('Access-Control-Allow-Origin', '*');

    if (req.method == 'OPTIONS') {
      req.response.headers
          .set('Access-Control-Allow-Methods', 'GET, POST, PUT, DELETE, OPTIONS');
      req.response.headers
          .set('Access-Control-Allow-Headers', 'Content-Type, Authorization');
      req.response.statusCode = 204;
      try {
        await req.response.close();
      } catch (_) {}
      return;
    }

    final path = req.uri.path;
    final method = req.method;

    try {
      // ─── WebSocket upgrade (/ws/events) ──────────────────────
      if (path == '/ws/events' && WebSocketTransformer.isUpgradeRequest(req)) {
        // Check auth for WebSocket
        if (proxyService.apiAuthEnabled) {
          final token = req.uri.queryParameters['token'];
          if (token == null || token != proxyService.apiToken) {
            req.response.statusCode = 401;
            await _writeJson(req, {'error': 'Unauthorized', 'code': 401});
            return;
          }
        }
        final ws = await WebSocketTransformer.upgrade(req);
        proxyService.eventBroadcaster.addClient(ws);

        // Send current state of all active tunnels
        final tunnelSnapshots = proxyService.activeTunnels
            .where((t) => !t.isExternal)
            .map((t) => _tunnelToJson(t))
            .toList();
        proxyService.eventBroadcaster.sendInitialState(ws, tunnelSnapshots);

        // Handle client messages (pong responses)
        ws.listen(
          (data) {
            // Client sends pong in response to server ping — acknowledged
            // Client can also send JSON {"event": "pong"}
          },
          onDone: () {},
          onError: (_) {},
        );
        return;
      }

      // /ping works without auth
      if (path == '/ping' && method == 'GET') {
        await _writeJson(req, {
          'pong': true,
          'port': _activePort ?? port,
          'uptime': _startTime != null
              ? DateTime.now().difference(_startTime!).inSeconds
              : 0,
        });
        return;
      }

      // All other endpoints require auth
      if (!_checkAuth(req)) {
        req.response.statusCode = 401;
        await _writeJson(req, {'error': 'Unauthorized', 'code': 401});
        return;
      }

      if (path == '/status' && method == 'GET') {
        await _writeJson(req, {
          'status': 'running',
          'version': '5.0.0',
          'servers': proxyService.servers
              .map((s) => _serverToJson(s))
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
              .map((s) => _serverToJson(s))
              .toList(),
        });
        return;
      } else if (path == '/servers/add' && method == 'POST') {
        final body = await utf8.decoder.bind(req).join();
        final data = jsonDecode(body) as Map<String, dynamic>;

        if (data['host'] == null || (data['host'] as String).isEmpty) {
          req.response.statusCode = 400;
          await _writeJson(req, {'success': false, 'error': 'host is required'});
          return;
        }
        if (data['username'] == null || (data['username'] as String).isEmpty) {
          req.response.statusCode = 400;
          await _writeJson(req, {'success': false, 'error': 'username is required'});
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
          proxyUsername: data['proxyAuth'] != null
              ? data['proxyAuth']['username']
              : data['proxyUsername'],
          proxyPassword: data['proxyAuth'] != null
              ? data['proxyAuth']['password']
              : data['proxyPassword'],
        );
        await proxyService.addServer(server);
        await _writeJson(req, {'success': true, 'id': server.id});
        return;

        // ─── PUT /servers/{id} — Server update/edit (#2) ──────────
      } else if (path.startsWith('/servers/') &&
          !path.startsWith('/servers/add') &&
          !path.startsWith('/servers/delete/') &&
          method == 'PUT') {
        final id = path.replaceFirst('/servers/', '');
        final existing = proxyService.servers.where((s) => s.id == id).firstOrNull;
        if (existing == null) {
          req.response.statusCode = 404;
          await _writeJson(req, {'success': false, 'error': 'Server not found'});
          return;
        }
        final body = await utf8.decoder.bind(req).join();
        final data = jsonDecode(body) as Map<String, dynamic>;

        // Update fields (keep existing values for fields not provided)
        final updated = ServerConfig(
          id: id,
          name: data['name'] ?? existing.name,
          host: data['host'] ?? existing.host,
          sshPort: data['sshPort'] ?? existing.sshPort,
          username: data['username'] ?? existing.username,
          password: data['password'] ?? existing.password,
          socksPort: data['socksPort'] ?? existing.socksPort,
          authType: data['authType'] ?? existing.authType,
          privateKey: data.containsKey('privateKey')
              ? data['privateKey']
              : existing.privateKey,
          keyPassphrase: data.containsKey('keyPassphrase')
              ? data['keyPassphrase']
              : existing.keyPassphrase,
          keyPath: data.containsKey('keyPath') ? data['keyPath'] : existing.keyPath,
          autoReconnect: data['autoReconnect'] ?? existing.autoReconnect,
          connectOnStartup: data['connectOnStartup'] ?? existing.connectOnStartup,
          notificationsEnabled:
              data['notificationsEnabled'] ?? existing.notificationsEnabled,
          proxyUsername: data['proxyAuth'] != null
              ? data['proxyAuth']['username']
              : (data['proxyUsername'] ?? existing.proxyUsername),
          proxyPassword: data['proxyAuth'] != null
              ? data['proxyAuth']['password']
              : (data['proxyPassword'] ?? existing.proxyPassword),
        );
        updated.isEnabled = existing.isEnabled;

        await proxyService.updateServer(updated);
        await _writeJson(req, {'success': true, 'id': id});
        return;

      } else if (path.startsWith('/servers/delete/') && method == 'POST') {
        final id = path.replaceFirst('/servers/delete/', '');
        await proxyService.deleteServer(id);
        await _writeJson(req, {'success': true});
        return;
      } else if (path.startsWith('/servers/') &&
          !path.startsWith('/servers/add') &&
          !path.startsWith('/servers/delete/') &&
          method == 'DELETE') {
        final id = path.replaceFirst('/servers/', '');
        await proxyService.deleteServer(id);
        await _writeJson(req, {'success': true});
        return;

        // ─── Stats history (#5) ───────────────────────────────────
      } else if (path.startsWith('/stats/') && method == 'GET') {
        final id = path.replaceFirst('/stats/', '');
        final period = req.uri.queryParameters['period'] ?? '24h';
        final stats = await proxyService.statsDb.getStats(id, period);
        await _writeJson(req, stats);
        return;

        // ─── Quick-connect profiles (#8) ──────────────────────────
      } else if (path == '/profiles' && method == 'GET') {
        await _writeJson(req, {
          'profiles': proxyService.profiles.map((p) => p.toJson()).toList(),
        });
        return;
      } else if (path == '/profiles/add' && method == 'POST') {
        final body = await utf8.decoder.bind(req).join();
        final data = jsonDecode(body) as Map<String, dynamic>;
        if (data['serverId'] == null || data['name'] == null) {
          req.response.statusCode = 400;
          await _writeJson(req, {'success': false, 'error': 'serverId and name required'});
          return;
        }
        // Verify server exists
        final serverExists =
            proxyService.servers.any((s) => s.id == data['serverId']);
        if (!serverExists) {
          req.response.statusCode = 404;
          await _writeJson(req, {'success': false, 'error': 'Server not found'});
          return;
        }
        final profile = QuickProfile(
          id: generateUniqueId(),
          serverId: data['serverId'],
          name: data['name'],
          socksPort: data['socksPort'] ?? 1080,
        );
        await proxyService.addProfile(profile);
        await _writeJson(req, {'success': true, 'id': profile.id});
        return;
      } else if (path.startsWith('/profiles/connect/') && method == 'POST') {
        final profileId = path.replaceFirst('/profiles/connect/', '');
        try {
          await proxyService.connectProfile(profileId);
          await _writeJson(req, {'success': true, 'message': 'Connected via profile'});
        } catch (e) {
          req.response.statusCode = 500;
          await _writeJson(req, {'success': false, 'error': e.toString()});
        }
        return;
      } else if (path.startsWith('/profiles/') && method == 'DELETE') {
        final id = path.replaceFirst('/profiles/', '');
        await proxyService.deleteProfile(id);
        await _writeJson(req, {'success': true});
        return;

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
        proxyService.disconnectTunnel(serverId, reason: 'api_disconnect');
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
          if (!t.isExternal) proxyService.disconnectTunnel(t.serverId, reason: 'api_disconnect_all');
        }
        await _writeJson(req,
            {'success': true, 'message': 'All tunnels disconnected'});
        return;
      } else if (path == '/help' && method == 'GET') {
        final p = _activePort ?? port;
        await _writeJson(req, {
          'api': 'SSH Proxy Manager API v5',
          'port': p,
          'endpoints': [
            'GET  /ping                       — readiness probe (no auth required)',
            'GET  /status                     — full status',
            'GET  /tunnels                    — active tunnels with health info',
            'GET  /servers                    — saved servers',
            'POST /servers/add                — add server (JSON body)',
            'PUT  /servers/{id}               — update server',
            'POST /servers/delete/{id}        — delete server by id',
            'DELETE /servers/{id}             — delete server by id',
            'POST /connect/{id}              — connect server by ID',
            'POST /disconnect/{id}           — disconnect server by ID',
            'POST /disconnect-all            — stop all tunnels',
            'GET  /stats/{id}?period=1h|24h|7d — connection stats history',
            'GET  /profiles                   — list quick-connect profiles',
            'POST /profiles/add              — add profile',
            'POST /profiles/connect/{id}     — connect via profile',
            'DELETE /profiles/{id}           — delete profile',
            'WS   /ws/events                 — real-time WebSocket events',
            'POST /scan                      — scan all ports',
            'GET  /scan/progress             — scan progress',
            'GET  /logs?limit=100            — connection logs',
            'GET  /export?includeKeys=true   — export servers',
            'POST /import                    — import/merge servers',
            'GET  /help                      — this help',
          ],
          'auth': 'All endpoints except /ping require Authorization: Bearer <token> or ?token=<token> (when auth is enabled)',
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

  Future<void> _writeJson(HttpRequest req, Map<String, dynamic> data) async {
    try {
      await req.drain<void>();
    } catch (_) {}
    final body = jsonEncode(data);
    final bytes = utf8.encode(body);
    req.response.headers.contentLength = bytes.length;
    req.response.add(bytes);
    await req.response.close();
  }

  Map<String, dynamic> _serverToJson(ServerConfig s) {
    return {
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
      'notificationsEnabled': s.notificationsEnabled,
      'hasProxyAuth': s.proxyUsername != null && s.proxyUsername!.isNotEmpty,
    };
  }

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
      'latencyMs': t.latencyMs,
      'lastKeepaliveAt': t.lastKeepaliveAt?.toIso8601String(),
      'totalUptime': t.effectiveTotalUptime.inSeconds,
      'totalUptimeStr': t.totalUptimeString,
    };
  }
}
