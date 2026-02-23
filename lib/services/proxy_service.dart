import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../models/server_config.dart';
import '../models/active_tunnel.dart';
import '../models/connection_log.dart';
import '../utils/id_generator.dart';
import 'local_api_server.dart';

class ProxyService extends ChangeNotifier {
  List<ServerConfig> servers = [];
  List<ActiveTunnel> activeTunnels = [];
  bool isScanning = false;
  double scanProgress = 0.0;
  int scannedPorts = 0;

  final List<ConnectionLog> logs = [];

  final Map<String, SSHClient> _clients = {};
  final Map<String, ServerSocket> _serverSockets = {};
  Timer? _healthCheckTimer;
  StreamSubscription? _connectivitySub;
  LocalApiServer? _apiServer;
  final FlutterSecureStorage _secureStorage = const FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  // ─── Auto-reconnect state ────────────────────────────────────────
  final Map<String, Timer> _reconnectTimers = {};
  final Map<String, int> _reconnectAttempts = {};
  final Set<String> _disconnecting = {};
  final Set<String> _activeReconnects = {};

  /// Callback for updating background service notification.
  void Function(int activeTunnelCount)? onTunnelCountChanged;

  /// Callback for updating notification with arbitrary content.
  void Function(String content)? onNotificationUpdate;

  /// Public access to the API server instance.
  LocalApiServer? get apiServer => _apiServer;

  /// Future that completes when the API server is ready.
  /// Allows callers to await API readiness.
  Future<void> get apiReady => _apiReadyCompleter.future;
  final Completer<void> _apiReadyCompleter = Completer<void>();

  /// Guards against concurrent _loadServers / _saveServers races.
  Completer<void>? _serversLoaded;

  /// When [startApi] is false the local HTTP API server is NOT started.
  /// Use this in the UI isolate where the API should live in the
  /// long-lived background service isolate instead.
  ProxyService({bool startApi = true}) {
    _startHealthCheck();
    _listenNetworkChanges();
    // _loadServers is async — we must ensure it completes BEFORE the API
    // server starts accepting requests, otherwise requests see empty state.
    _serversLoaded = Completer<void>();
    _initSequence(startApi);
    _log('System', 'info', 'SSH Proxy Manager started (API: $startApi)');
  }

  Future<void> _initSequence(bool startApi) async {
    await _loadServers();
    _serversLoaded!.complete();
    if (startApi) {
      await _initApiServer();
    } else {
      if (!_apiReadyCompleter.isCompleted) {
        _apiReadyCompleter.complete();
      }
    }
  }

  /// Initialize and start the local REST API server.
  /// Called once from constructor; safe to call again (idempotent).
  Future<void> _initApiServer() async {
    try {
      _apiServer = LocalApiServer(this);
      _apiServer!.onReady = (port) {
        _log('System', 'info', 'API server ready on port $port');
        // Update notification to show API is ready
        onNotificationUpdate?.call('API ready on port $port');
        if (!_apiReadyCompleter.isCompleted) {
          _apiReadyCompleter.complete();
        }
      };
      await _apiServer!.start();
      debugPrint('✅ ProxyService: API server initialized');
    } catch (e) {
      debugPrint('❌ ProxyService: API server init error: $e');
      if (!_apiReadyCompleter.isCompleted) {
        _apiReadyCompleter.completeError(e);
      }
    }
  }

  /// Start or restart the API server. Safe to call multiple times.
  /// Uses the same mutex inside LocalApiServer.start() so concurrent
  /// calls are safe — they just await the in-progress start.
  Future<void> startApiServer() async {
    try {
      if (_apiServer == null) {
        _apiServer = LocalApiServer(this);
        _apiServer!.onReady = (port) {
          _log('System', 'info', 'API server ready on port $port');
          onNotificationUpdate?.call('API ready on port $port');
          if (!_apiReadyCompleter.isCompleted) {
            _apiReadyCompleter.complete();
          }
        };
      }
      // start() has its own mutex — safe to call even if _initApiServer()
      // is already in progress. It will await the existing start.
      await _apiServer!.start();
    } catch (e) {
      debugPrint('❌ ProxyService.startApiServer error: $e');
    }
  }

  // ─── Logging ──────────────────────────────────────────────────────

  /// Clear all logs. Use this instead of calling notifyListeners() externally.
  void clearLogs() {
    logs.clear();
    notifyListeners();
  }

  void _log(String serverName, String event, [String? details]) {
    logs.insert(
      0,
      ConnectionLog(
        timestamp: DateTime.now(),
        serverName: serverName,
        event: event,
        details: details,
      ),
    );
    if (logs.length > 500) logs.removeLast();
    notifyListeners();
  }

  void _notifyTunnelCount() {
    final count = activeTunnels.where((t) => !t.isExternal).length;
    onTunnelCountChanged?.call(count);
  }

  // ─── Server persistence ───────────────────────────────────────────

  Future<void> _loadServers() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final data = prefs.getStringList('servers') ?? [];
      servers = data.map((s) => ServerConfig.fromJson(jsonDecode(s))).toList();

      // Load secrets from secure storage
      for (final s in servers) {
        try {
          s.password =
              await _secureStorage.read(key: 'password_${s.id}') ?? '';
          s.privateKey =
              await _secureStorage.read(key: 'privateKey_${s.id}');
          s.keyPassphrase =
              await _secureStorage.read(key: 'keyPassphrase_${s.id}');
        } catch (e) {
          debugPrint('Failed to read secrets for ${s.id}: $e');
          // Continue with empty credentials — user can re-enter them
        }
      }

      notifyListeners();
      _reconnectEnabledTunnels();
    } catch (e) {
      debugPrint('Failed to load servers: $e');
      _log('System', 'error', 'Failed to load servers: $e');
    }
  }

  Future<void> _saveServers() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
        'servers', servers.map((s) => jsonEncode(s.toJson())).toList());
  }

  Future<void> _saveSecrets(ServerConfig s) async {
    try {
      await _secureStorage.write(key: 'password_${s.id}', value: s.password);
      if (s.privateKey != null) {
        await _secureStorage.write(
            key: 'privateKey_${s.id}', value: s.privateKey!);
      } else {
        await _secureStorage.delete(key: 'privateKey_${s.id}');
      }
      if (s.keyPassphrase != null && s.keyPassphrase!.isNotEmpty) {
        await _secureStorage.write(
            key: 'keyPassphrase_${s.id}', value: s.keyPassphrase!);
      } else {
        await _secureStorage.delete(key: 'keyPassphrase_${s.id}');
      }
    } catch (e) {
      debugPrint('Failed to save secrets for ${s.id}: $e');
    }
  }

  Future<void> _deleteSecrets(String id) async {
    try {
      await _secureStorage.delete(key: 'password_$id');
      await _secureStorage.delete(key: 'privateKey_$id');
      await _secureStorage.delete(key: 'keyPassphrase_$id');
    } catch (e) {
      debugPrint('Failed to delete secrets for $id: $e');
    }
  }

  Future<void> addServer(ServerConfig s) async {
    // Wait for initial load to finish so we don't race with _loadServers
    if (_serversLoaded != null && !_serversLoaded!.isCompleted) {
      await _serversLoaded!.future;
    }
    servers.add(s);
    await _saveServers();
    await _saveSecrets(s);
    _log(s.name, 'info', 'Server added');
    notifyListeners();
  }

  Future<void> updateServer(ServerConfig s) async {
    final i = servers.indexWhere((x) => x.id == s.id);
    if (i >= 0) {
      servers[i] = s;
      await _saveServers();
      await _saveSecrets(s);
      _log(s.name, 'info', 'Server updated');
      notifyListeners();
    }
  }

  Future<void> deleteServer(String id) async {
    final name =
        servers.where((s) => s.id == id).map((s) => s.name).firstOrNull ?? id;
    disconnectTunnel(id);
    servers.removeWhere((s) => s.id == id);
    await _saveServers();
    await _deleteSecrets(id);
    _log(name, 'info', 'Server deleted');
    notifyListeners();
  }

  // ─── Private key resolution ───────────────────────────────────────

  /// Resolve the private key for a server.
  /// If the key is in memory, use it. Otherwise, try to read from keyPath.
  Future<String?> _resolvePrivateKey(ServerConfig server) async {
    if (server.privateKey != null && server.privateKey!.isNotEmpty) {
      return server.privateKey;
    }
    if (server.keyPath != null && server.keyPath!.isNotEmpty) {
      try {
        final file = File(server.keyPath!);
        if (await file.exists()) {
          final key = await file.readAsString();
          // Cache in memory for future connections
          server.privateKey = key;
          return key;
        } else {
          _log(server.name, 'error',
              'Key file not found: ${server.keyPath}');
        }
      } catch (e) {
        _log(server.name, 'error',
            'Failed to read key from ${server.keyPath}: $e');
      }
    }
    return null;
  }

  // ─── Import / Export ──────────────────────────────────────────────

  /// Export all servers as JSON.
  /// When [includeKeys] is true, secrets (privateKey, password, keyPassphrase) are included.
  List<Map<String, dynamic>> exportServers({bool includeKeys = false}) {
    return servers.map((s) {
      final json = s.toJson();
      if (includeKeys) {
        if (s.privateKey != null && s.privateKey!.isNotEmpty) {
          json['privateKey'] = s.privateKey;
        }
        if (s.password.isNotEmpty) {
          json['password'] = s.password;
        }
        if (s.keyPassphrase != null && s.keyPassphrase!.isNotEmpty) {
          json['keyPassphrase'] = s.keyPassphrase;
        }
      }
      return json;
    }).toList();
  }

  /// Import servers from JSON list, merging by host+username+sshPort.
  /// Returns count of newly added servers.
  int importServers(List<dynamic> jsonList) {
    int added = 0;
    for (final item in jsonList) {
      final data = item as Map<String, dynamic>;
      // Check for duplicates by host + username + sshPort
      final exists = servers.any((s) =>
          s.host == data['host'] &&
          s.username == (data['username'] ?? '') &&
          s.sshPort == (data['sshPort'] ?? 22));
      if (!exists) {
        final server = ServerConfig(
          id: generateUniqueId(),
          name: data['name'] ?? 'Imported',
          host: data['host'],
          sshPort: data['sshPort'] ?? 22,
          username: data['username'] ?? '',
          password: data['password'] ?? '',
          socksPort: data['socksPort'] ?? 1080,
          authType: data['authType'] ?? 'password',
          privateKey: data['privateKey'],
          keyPassphrase: data['keyPassphrase'],
          keyPath: data['keyPath'],
          autoReconnect: data['autoReconnect'] ?? true,
          connectOnStartup: data['connectOnStartup'] ?? false,
        );
        servers.add(server);
        _saveSecrets(server);
        added++;
      }
    }
    if (added > 0) {
      _saveServers();
      _log('System', 'info', 'Imported $added new server(s)');
      notifyListeners();
    }
    return added;
  }

  // ─── SOCKS5 Tunnel ───────────────────────────────────────────────

  Future<void> connectTunnel(ServerConfig server) async {
    // Wait for initial load to finish
    if (_serversLoaded != null && !_serversLoaded!.isCompleted) {
      await _serversLoaded!.future;
    }
    if (_clients.containsKey(server.id)) return;
    try {
      _log(server.name, 'info',
          'Connecting to ${server.host}:${server.sshPort}...');

      final socket = await SSHSocket.connect(server.host, server.sshPort,
          timeout: const Duration(seconds: 15));

      final SSHClient client;
      if (server.authType == 'key') {
        final key = await _resolvePrivateKey(server);
        if (key != null && key.isNotEmpty) {
          final passphrase =
              (server.keyPassphrase != null && server.keyPassphrase!.isNotEmpty)
                  ? server.keyPassphrase
                  : null;
          client = SSHClient(
            socket,
            username: server.username,
            identities: [
              ...SSHKeyPair.fromPem(key, passphrase)
            ],
            keepAliveInterval: const Duration(seconds: 15),
          );
        } else {
          throw Exception('No private key available for ${server.name}');
        }
      } else {
        client = SSHClient(
          socket,
          username: server.username,
          onPasswordRequest: () => server.password,
          keepAliveInterval: const Duration(seconds: 15),
        );
      }

      await client.authenticated;
      _log(server.name, 'connected',
          'SSH authenticated (${server.authType})');

      // Bind local SOCKS5 server
      final serverSocket =
          await ServerSocket.bind(InternetAddress.anyIPv4, server.socksPort);
      _serverSockets[server.id] = serverSocket;

      final tunnel = ActiveTunnel(
        serverId: server.id,
        serverName: server.name,
        socksPort: server.socksPort,
        startedAt: DateTime.now(),
        proxyType: 'SOCKS5',
        authType: 'no-auth',
      );

      serverSocket.listen(
        (Socket localSocket) {
          _handleSocksConnection(localSocket, client, server.name, tunnel);
        },
        onError: (e) {
          _log(server.name, 'error', 'ServerSocket error: $e');
        },
      );

      _clients[server.id] = client;
      server.isEnabled = true;
      await _saveServers();

      activeTunnels.removeWhere((t) => t.serverId == server.id);
      activeTunnels.add(tunnel);
      _log(server.name, 'connected',
          'SOCKS5 proxy listening on 0.0.0.0:${server.socksPort}');

      // Listen for unexpected SSH disconnection
      _listenForDisconnect(server.id, client, server.name);

      // Reset reconnect attempts on successful connection
      _reconnectAttempts.remove(server.id);

      _notifyTunnelCount();
      notifyListeners();
    } catch (e) {
      _log(server.name, 'error', 'Connection failed: $e');
      rethrow;
    }
  }

  /// Listen to SSHClient.done to detect unexpected disconnections.
  void _listenForDisconnect(
      String serverId, SSHClient client, String serverName) {
    client.done.then((_) {
      if (!_disconnecting.contains(serverId)) {
        _handleUnexpectedDisconnect(serverId, 'SSH connection closed');
      }
    }).catchError((e) {
      if (!_disconnecting.contains(serverId)) {
        _handleUnexpectedDisconnect(serverId, 'SSH error: $e');
      }
    });
  }

  /// Handle an unexpected disconnection (not user-initiated).
  /// Cleans up resources and schedules auto-reconnect if enabled.
  void _handleUnexpectedDisconnect(String serverId, String reason) {
    if (_disconnecting.contains(serverId)) return;
    if (_activeReconnects.contains(serverId)) return;

    final tunnel =
        activeTunnels.where((t) => t.serverId == serverId).firstOrNull;
    _cleanupConnection(serverId);
    activeTunnels.removeWhere((t) => t.serverId == serverId);

    final server = servers.where((s) => s.id == serverId).firstOrNull;
    if (server != null) {
      _log(server.name, 'disconnected', reason);
      if (server.autoReconnect) {
        _scheduleReconnect(server, previousTunnel: tunnel);
      }
    } else if (tunnel != null) {
      _log(tunnel.serverName, 'disconnected', reason);
    }

    _notifyTunnelCount();
    notifyListeners();
  }

  /// Clean up SSH client and server socket for a given server ID.
  void _cleanupConnection(String serverId) {
    _serverSockets[serverId]?.close();
    _serverSockets.remove(serverId);
    try {
      _clients[serverId]?.close();
    } catch (_) {}
    _clients.remove(serverId);
  }

  /// Schedule an auto-reconnect attempt with exponential backoff.
  void _scheduleReconnect(ServerConfig server,
      {ActiveTunnel? previousTunnel}) {
    final attempts = _reconnectAttempts[server.id] ?? 0;
    final delaySec = min(pow(2, attempts).toInt(), 30);

    _reconnectTimers[server.id]?.cancel();
    _activeReconnects.add(server.id);

    _log(server.name, 'info',
        'Auto-reconnecting in ${delaySec}s (attempt ${attempts + 1})...');

    _reconnectTimers[server.id] =
        Timer(Duration(seconds: delaySec), () async {
      try {
        await connectTunnel(server);
        // Restore counters from previous tunnel
        final newTunnel = activeTunnels
            .where((t) => t.serverId == server.id)
            .firstOrNull;
        if (newTunnel != null && previousTunnel != null) {
          newTunnel.reconnectCount = previousTunnel.reconnectCount + 1;
          newTunnel.totalUptime =
              previousTunnel.totalUptime + previousTunnel.uptime;
        }
        _reconnectAttempts.remove(server.id);
        _activeReconnects.remove(server.id);
        _log(server.name, 'reconnected',
            'Reconnect #${newTunnel?.reconnectCount ?? 0}');
      } catch (e) {
        _reconnectAttempts[server.id] = attempts + 1;
        _activeReconnects.remove(server.id);
        _log(server.name, 'error', 'Reconnect failed: $e');
        // Schedule next attempt with longer delay
        _scheduleReconnect(server, previousTunnel: previousTunnel);
      }
    });
  }

  /// Handle a single SOCKS5 client connection.
  Future<void> _handleSocksConnection(Socket localSocket, SSHClient client,
      String serverName, ActiveTunnel tunnel) async {
    final greetingCompleter = Completer<Uint8List>();
    final requestCompleter = Completer<Uint8List>();
    SSHForwardChannel? forwardChannel;
    int phase = 0; // 0=greeting, 1=request, 2=forwarding

    final sub = localSocket.listen(
      (Uint8List data) {
        if (phase == 0) {
          phase = 1;
          if (!greetingCompleter.isCompleted) greetingCompleter.complete(data);
        } else if (phase == 1) {
          phase = 2;
          if (!requestCompleter.isCompleted) requestCompleter.complete(data);
        } else {
          // Phase 2: forward data to SSH channel
          try {
            tunnel.bytesOut += data.length;
            forwardChannel?.sink.add(data);
          } catch (_) {}
        }
      },
      onError: (e) {
        if (!greetingCompleter.isCompleted) {
          greetingCompleter.completeError('Socket error: $e');
        }
        if (!requestCompleter.isCompleted) {
          requestCompleter.completeError('Socket error: $e');
        }
        try {
          forwardChannel?.sink.close();
        } catch (_) {}
      },
      onDone: () {
        if (!greetingCompleter.isCompleted) {
          greetingCompleter.completeError('Connection closed');
        }
        if (!requestCompleter.isCompleted) {
          requestCompleter.completeError('Connection closed');
        }
        try {
          forwardChannel?.sink.close();
        } catch (_) {}
      },
    );

    try {
      // ── Phase 0: SOCKS5 greeting ──
      final greeting = await greetingCompleter.future;
      if (greeting.isEmpty || greeting[0] != 0x05) {
        localSocket.destroy();
        return;
      }
      // Respond: version=5, method=0 (no auth)
      localSocket.add([0x05, 0x00]);

      // ── Phase 1: SOCKS5 CONNECT request ──
      final request = await requestCompleter.future;
      if (request.length < 4 || request[0] != 0x05 || request[1] != 0x01) {
        // Not a CONNECT command
        localSocket.add([0x05, 0x07, 0x00, 0x01, 0, 0, 0, 0, 0, 0]);
        localSocket.destroy();
        return;
      }

      String targetHost;
      int targetPort;

      final addrType = request[3];
      if (addrType == 0x01) {
        // IPv4
        if (request.length < 10) {
          localSocket.destroy();
          return;
        }
        targetHost =
            '${request[4]}.${request[5]}.${request[6]}.${request[7]}';
        targetPort = (request[8] << 8) | request[9];
      } else if (addrType == 0x03) {
        // Domain name
        final domainLen = request[4];
        if (request.length < 5 + domainLen + 2) {
          localSocket.destroy();
          return;
        }
        targetHost = String.fromCharCodes(request.sublist(5, 5 + domainLen));
        targetPort =
            (request[5 + domainLen] << 8) | request[6 + domainLen];
      } else if (addrType == 0x04) {
        // IPv6 — 16 bytes
        if (request.length < 22) {
          localSocket.destroy();
          return;
        }
        final bytes = request.sublist(4, 20);
        // Format as proper IPv6 (pairs of bytes as hex groups)
        final groups = <String>[];
        for (int i = 0; i < 16; i += 2) {
          groups.add(
              ((bytes[i] << 8) | bytes[i + 1]).toRadixString(16));
        }
        targetHost = groups.join(':');
        targetPort = (request[20] << 8) | request[21];
      } else {
        // Address type not supported
        localSocket.add([0x05, 0x08, 0x00, 0x01, 0, 0, 0, 0, 0, 0]);
        localSocket.destroy();
        return;
      }

      // ── Open SSH direct-tcpip channel ──
      forwardChannel = await client.forwardLocal(targetHost, targetPort);

      // Send SOCKS5 success: ver=5, rep=0 (succeeded), rsv=0, atyp=1 (IPv4),
      // BND.ADDR=0.0.0.0, BND.PORT=0
      localSocket.add([0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0]);

      // ── Phase 2: bidirectional forwarding ──
      // SSH → local
      forwardChannel.stream.listen(
        (data) {
          try {
            tunnel.bytesIn += data.length;
            localSocket.add(data);
          } catch (_) {}
        },
        onDone: () {
          try {
            localSocket.destroy();
          } catch (_) {}
        },
        onError: (_) {
          try {
            localSocket.destroy();
          } catch (_) {}
        },
      );

      // local → SSH is handled by the subscription's phase==2 branch above
    } catch (e) {
      // Send SOCKS5 general failure
      try {
        localSocket.add([0x05, 0x01, 0x00, 0x01, 0, 0, 0, 0, 0, 0]);
      } catch (_) {}
      try {
        localSocket.destroy();
      } catch (_) {}
    }
  }

  /// Disconnect a tunnel (user-initiated or with specific reason).
  void disconnectTunnel(String serverId, {String reason = 'user disconnect'}) {
    _disconnecting.add(serverId);

    // Cancel any pending reconnect for this server
    _reconnectTimers[serverId]?.cancel();
    _reconnectTimers.remove(serverId);
    _reconnectAttempts.remove(serverId);
    _activeReconnects.remove(serverId);

    _cleanupConnection(serverId);

    final tunnel =
        activeTunnels.where((t) => t.serverId == serverId).firstOrNull;
    activeTunnels.removeWhere((t) => t.serverId == serverId);
    try {
      final s = servers.firstWhere((x) => x.id == serverId);
      // Only mark as disabled for user-initiated disconnects
      if (reason == 'user disconnect') {
        s.isEnabled = false;
        _saveServers();
      }
      _log(s.name, 'disconnected', reason);
    } catch (_) {
      if (tunnel != null) {
        _log(tunnel.serverName, 'disconnected', reason);
      }
    }

    _disconnecting.remove(serverId);
    _notifyTunnelCount();
    notifyListeners();
  }

  // ─── Health check ─────────────────────────────────────────────────

  void _startHealthCheck() {
    _healthCheckTimer =
        Timer.periodic(const Duration(seconds: 30), (_) => _checkHealth());
  }

  Future<void> _checkHealth() async {
    for (final tunnel in List<ActiveTunnel>.from(activeTunnels)) {
      if (tunnel.isExternal) continue;
      final client = _clients[tunnel.serverId];

      if (client == null || client.isClosed) {
        // Safety net: client.done should normally handle this, but just in case
        _handleUnexpectedDisconnect(
            tunnel.serverId, 'Health check: connection lost');
        continue;
      }

      // Connection is alive — update health info
      tunnel.lastKeepaliveAt = DateTime.now();

      // Try to measure latency with a lightweight command
      try {
        final sw = Stopwatch()..start();
        final session = await client
            .execute('true')
            .timeout(const Duration(seconds: 10));
        await session.done.timeout(const Duration(seconds: 5));
        sw.stop();
        tunnel.latencyMs = sw.elapsedMilliseconds;
      } catch (e) {
        // Latency measurement failed — not critical, keepalive handles liveness
        tunnel.latencyMs = null;
        debugPrint('Health check latency probe failed for '
            '${tunnel.serverName}: $e');
      }
    }
    notifyListeners();
  }

  // ─── Network changes (connectivity_plus v6) ──────────────────────

  void _listenNetworkChanges() {
    _connectivitySub = Connectivity()
        .onConnectivityChanged
        .listen((List<ConnectivityResult> results) async {
      if (results.isNotEmpty &&
          !results.contains(ConnectivityResult.none)) {
        _log('System', 'info', 'Network restored, reconnecting...');
        await Future.delayed(const Duration(seconds: 3));
        await _reconnectEnabledTunnels();
      }
    });
  }

  /// Reconnect servers that are either enabled (were active) or marked
  /// for auto-connect on startup.
  Future<void> _reconnectEnabledTunnels() async {
    for (final server
        in servers.where((s) => s.isEnabled || s.connectOnStartup)) {
      if (!_clients.containsKey(server.id)) {
        try {
          await connectTunnel(server);
        } catch (e) {
          _log(server.name, 'error', 'Auto-reconnect failed: $e');
        }
      }
    }
  }

  // ─── Port scanning ────────────────────────────────────────────────

  /// Detect proxy type and auth for a given port.
  /// Sockets are properly closed in finally blocks to prevent resource leaks.
  Future<Map<String, String>> _detectProxyInfo(int port) async {
    final info = <String, String>{};

    // Try SOCKS5 handshake
    Socket? sock;
    try {
      sock = await Socket.connect('127.0.0.1', port,
          timeout: const Duration(milliseconds: 500));
      sock.add([0x05, 0x01, 0x00]);
      await Future.delayed(const Duration(milliseconds: 200));
      final data =
          await sock.first.timeout(const Duration(milliseconds: 300));

      if (data.length >= 2 && data[0] == 0x05) {
        info['type'] = 'SOCKS5';
        info['auth'] = data[1] == 0x00 ? 'no-auth' : 'auth-required';
      } else if (data.length >= 2 && data[0] == 0x04) {
        info['type'] = 'SOCKS4';
        info['auth'] = 'unknown';
      }
    } catch (_) {
    } finally {
      try {
        sock?.destroy();
      } catch (_) {}
    }

    // If not SOCKS, try HTTP proxy
    if (!info.containsKey('type')) {
      Socket? httpSock;
      try {
        httpSock = await Socket.connect('127.0.0.1', port,
            timeout: const Duration(milliseconds: 500));
        httpSock.add(
            'CONNECT test:80 HTTP/1.1\r\nHost: test:80\r\n\r\n'.codeUnits);
        await Future.delayed(const Duration(milliseconds: 200));
        final data =
            await httpSock.first.timeout(const Duration(milliseconds: 300));
        final response = String.fromCharCodes(data);
        if (response.contains('HTTP/')) {
          info['type'] = 'HTTP Proxy';
          info['auth'] = 'unknown';
        }
      } catch (_) {
      } finally {
        try {
          httpSock?.destroy();
        } catch (_) {}
      }
    }

    info['port'] = port.toString();
    return info;
  }

  Future<void> scanAllPorts() async {
    isScanning = true;
    scanProgress = 0.0;
    scannedPorts = 0;
    notifyListeners();
    _log('System', 'info', 'Port scan started (1-65535)');

    final managedPorts = activeTunnels
        .where((t) => !t.isExternal)
        .map((t) => t.socksPort)
        .toSet();
    activeTunnels.removeWhere((t) => t.isExternal);

    const batchSize = 500;
    final openPorts = <int>[];

    for (int start = 1; start <= 65535; start += batchSize) {
      final end = (start + batchSize - 1).clamp(1, 65535);
      final results = await Future.wait(
        List.generate(end - start + 1, (i) => start + i).map((port) async {
          try {
            final sock = await Socket.connect('127.0.0.1', port,
                timeout: const Duration(milliseconds: 150));
            await sock.close();
            return port;
          } catch (_) {
            return null;
          }
        }),
      );
      openPorts.addAll(results.whereType<int>());
      scannedPorts = end;
      scanProgress = scannedPorts / 65535;
      notifyListeners();
    }

    for (final port in openPorts) {
      if (!managedPorts.contains(port)) {
        final proxyInfo = await _detectProxyInfo(port);
        final detectedType = proxyInfo['type'] ?? 'Unknown';
        final detectedAuth = proxyInfo['auth'] ?? 'unknown';

        activeTunnels.add(ActiveTunnel(
          serverId: 'ext_$port',
          serverName: 'External (port $port)',
          socksPort: port,
          startedAt: DateTime.now(),
          isExternal: true,
          proxyType: detectedType,
          authType: detectedAuth,
        ));
      }
    }

    isScanning = false;
    _log('System', 'info',
        'Port scan complete — ${openPorts.length} open ports found');
    notifyListeners();
  }

  // ─── Cleanup ──────────────────────────────────────────────────────

  @override
  void dispose() {
    _healthCheckTimer?.cancel();
    _connectivitySub?.cancel();
    _apiServer?.stop();
    for (final timer in _reconnectTimers.values) {
      timer.cancel();
    }
    _reconnectTimers.clear();
    for (final c in _clients.values) {
      c.close();
    }
    for (final s in _serverSockets.values) {
      s.close();
    }
    super.dispose();
  }
}
