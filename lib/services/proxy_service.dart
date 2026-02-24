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
import '../models/quick_profile.dart';
import '../utils/id_generator.dart';
import 'local_api_server.dart';
import 'stats_database.dart';
import 'event_broadcaster.dart';

class ProxyService extends ChangeNotifier {
  List<ServerConfig> servers = [];
  List<ActiveTunnel> activeTunnels = [];
  List<QuickProfile> profiles = [];
  bool isScanning = false;
  double scanProgress = 0.0;
  int scannedPorts = 0;

  final List<ConnectionLog> logs = [];

  final Map<String, SSHClient> _clients = {};
  final Map<String, ServerSocket> _serverSockets = {};
  final Set<String> _connecting = {};
  Timer? _healthCheckTimer;
  Timer? _statsCollectionTimer;
  StreamSubscription? _connectivitySub;
  LocalApiServer? _apiServer;
  final FlutterSecureStorage _secureStorage = const FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );
  final StatsDatabase statsDb = StatsDatabase();
  final EventBroadcaster eventBroadcaster = EventBroadcaster();

  // ─── API authentication ──────────────────────────────────────────
  String? _apiToken;
  bool _apiAuthEnabled = false;

  String? get apiToken => _apiToken;
  bool get apiAuthEnabled => _apiAuthEnabled;

  Future<void> setApiAuthEnabled(bool enabled) async {
    _apiAuthEnabled = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('apiAuthEnabled', enabled);
    notifyListeners();
  }

  Future<String> regenerateApiToken() async {
    final prefs = await SharedPreferences.getInstance();
    _apiToken = _generateToken();
    await prefs.setString('apiToken', _apiToken!);
    notifyListeners();
    return _apiToken!;
  }

  String _generateToken() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  Future<void> _loadApiAuth() async {
    final prefs = await SharedPreferences.getInstance();
    _apiToken = prefs.getString('apiToken');
    _apiAuthEnabled = prefs.getBool('apiAuthEnabled') ?? false;
    if (_apiToken == null || _apiToken!.isEmpty) {
      _apiToken = _generateToken();
      await prefs.setString('apiToken', _apiToken!);
    }
  }

  // ─── Auto-reconnect state ────────────────────────────────────────
  final Map<String, Timer> _reconnectTimers = {};
  final Map<String, int> _reconnectAttempts = {};
  final Set<String> _disconnecting = {};
  final Set<String> _activeReconnects = {};
  final Map<String, DateTime> _disconnectTimes = {};

  /// Callback for updating background service notification.
  void Function(int activeTunnelCount)? onTunnelCountChanged;

  /// Callback for updating notification with arbitrary content.
  void Function(String content)? onNotificationUpdate;

  /// Public access to the API server instance.
  LocalApiServer? get apiServer => _apiServer;

  /// Future that completes when the API server is ready.
  Future<void> get apiReady => _apiReadyCompleter.future;
  final Completer<void> _apiReadyCompleter = Completer<void>();

  /// Guards against concurrent _loadServers / _saveServers races.
  Completer<void>? _serversLoaded;

  ProxyService({bool startApi = true}) {
    _startHealthCheck();
    _startStatsCollection();
    _listenNetworkChanges();
    _serversLoaded = Completer<void>();
    _initSequence(startApi);
    _log('System', 'info', 'SSH Proxy Manager started (API: $startApi)');
  }

  Future<void> _initSequence(bool startApi) async {
    await _loadApiAuth();
    await _loadServers();
    await _loadProfiles();
    _serversLoaded!.complete();
    if (startApi) {
      await _initApiServer();
    } else {
      if (!_apiReadyCompleter.isCompleted) {
        _apiReadyCompleter.complete();
      }
    }
  }

  Future<void> _initApiServer() async {
    try {
      _apiServer = LocalApiServer(this);
      _apiServer!.onReady = (port) {
        _log('System', 'info', 'API server ready on port $port');
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
      await _apiServer!.start();
    } catch (e) {
      debugPrint('❌ ProxyService.startApiServer error: $e');
    }
  }

  // ─── Logging ──────────────────────────────────────────────────────

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

  /// Send a notification (via the background service notification callback).
  void _sendNotification(String serverId, String message) {
    final server = servers.where((s) => s.id == serverId).firstOrNull;
    if (server != null && !server.notificationsEnabled) return;
    onNotificationUpdate?.call(message);
  }

  // ─── Server persistence ───────────────────────────────────────────

  Future<void> _loadServers() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final data = prefs.getStringList('servers') ?? [];
      servers = data.map((s) => ServerConfig.fromJson(jsonDecode(s))).toList();

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
        }
      }

      notifyListeners();
      _reconnectEnabledTunnels();
    } catch (e) {
      debugPrint('Failed to load servers: $e');
      _log('System', 'error', 'Failed to load servers: $e');
    }
  }

  /// Public method to reload server list from SharedPreferences.
  /// Used by the UI to pick up changes made by the background-service isolate.
  Future<void> reloadServers() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      final data = prefs.getStringList('servers') ?? [];
      final loaded =
          data.map((s) => ServerConfig.fromJson(jsonDecode(s))).toList();

      // Only update if the server list actually changed (avoid unnecessary rebuilds)
      if (loaded.length != servers.length ||
          data.join() !=
              servers.map((s) => jsonEncode(s.toJson())).join()) {
        // Preserve secrets from current in-memory servers
        for (final s in loaded) {
          final existing = servers.where((x) => x.id == s.id).firstOrNull;
          if (existing != null) {
            s.password = existing.password;
            s.privateKey = existing.privateKey;
            s.keyPassphrase = existing.keyPassphrase;
          } else {
            // New server from API — load secrets
            try {
              s.password =
                  await _secureStorage.read(key: 'password_${s.id}') ?? '';
              s.privateKey =
                  await _secureStorage.read(key: 'privateKey_${s.id}');
              s.keyPassphrase =
                  await _secureStorage.read(key: 'keyPassphrase_${s.id}');
            } catch (_) {}
          }
        }
        servers = loaded;
        notifyListeners();
      }
    } catch (e) {
      debugPrint('reloadServers error: $e');
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
    if (_serversLoaded != null && !_serversLoaded!.isCompleted) {
      await _serversLoaded!.future;
    }
    servers.add(s);
    await _saveServers();
    await _saveSecrets(s);
    _log(s.name, 'info', 'Server added');
    eventBroadcaster.emit('server_added', {'serverId': s.id, 'name': s.name});
    notifyListeners();
  }

  Future<void> updateServer(ServerConfig s) async {
    final i = servers.indexWhere((x) => x.id == s.id);
    if (i >= 0) {
      final oldSocksPort = servers[i].socksPort;
      servers[i] = s;
      await _saveServers();
      await _saveSecrets(s);
      _log(s.name, 'info', 'Server updated');

      // If tunnel is active and socksPort changed → disconnect + reconnect
      if (oldSocksPort != s.socksPort && _clients.containsKey(s.id)) {
        _log(s.name, 'info', 'SOCKS port changed, reconnecting...');
        disconnectTunnel(s.id, reason: 'user_disconnect');
        try {
          await connectTunnel(s);
        } catch (e) {
          _log(s.name, 'error', 'Reconnect after port change failed: $e');
        }
      }

      notifyListeners();
    }
  }

  Future<void> deleteServer(String id) async {
    final name =
        servers.where((s) => s.id == id).map((s) => s.name).firstOrNull ?? id;
    disconnectTunnel(id, reason: 'user_disconnect');
    servers.removeWhere((s) => s.id == id);
    await _saveServers();
    await _deleteSecrets(id);
    _log(name, 'info', 'Server deleted');
    eventBroadcaster.emit('server_deleted', {'serverId': id});
    notifyListeners();
  }

  // ─── Profile persistence ──────────────────────────────────────────

  Future<void> _loadProfiles() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final data = prefs.getStringList('profiles') ?? [];
      profiles =
          data.map((s) => QuickProfile.fromJson(jsonDecode(s))).toList();
    } catch (e) {
      debugPrint('Failed to load profiles: $e');
    }
  }

  Future<void> _saveProfiles() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
        'profiles', profiles.map((p) => jsonEncode(p.toJson())).toList());
  }

  Future<void> addProfile(QuickProfile p) async {
    profiles.add(p);
    await _saveProfiles();
    notifyListeners();
  }

  Future<void> deleteProfile(String id) async {
    profiles.removeWhere((p) => p.id == id);
    await _saveProfiles();
    notifyListeners();
  }

  Future<void> connectProfile(String profileId) async {
    final profile = profiles.where((p) => p.id == profileId).firstOrNull;
    if (profile == null) throw Exception('Profile not found: $profileId');
    final server =
        servers.where((s) => s.id == profile.serverId).firstOrNull;
    if (server == null) {
      throw Exception('Server not found: ${profile.serverId}');
    }
    // Override socksPort from profile
    final originalPort = server.socksPort;
    server.socksPort = profile.socksPort;
    try {
      await connectTunnel(server);
    } finally {
      server.socksPort = originalPort;
    }
  }

  // ─── Private key resolution ───────────────────────────────────────

  Future<String?> _resolvePrivateKey(ServerConfig server) async {
    if (server.privateKey != null && server.privateKey!.isNotEmpty) {
      return server.privateKey;
    }
    if (server.keyPath != null && server.keyPath!.isNotEmpty) {
      try {
        final file = File(server.keyPath!);
        if (await file.exists()) {
          final key = await file.readAsString();
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

  int importServers(List<dynamic> jsonList) {
    int added = 0;
    for (final item in jsonList) {
      final data = item as Map<String, dynamic>;
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
          authType: data['authType'] ??
              (data['privateKey'] != null || data['keyPath'] != null
                  ? 'key'
                  : 'password'),
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

  // ─── Disconnect reason classification ─────────────────────────────

  /// Classify an error into a specific disconnect reason.
  String _classifyDisconnectReason(dynamic error, {String? host}) {
    final msg = error.toString().toLowerCase();
    if (msg.contains('authentication') ||
        msg.contains('auth') && msg.contains('fail') ||
        msg.contains('permission denied') ||
        msg.contains('publickey')) {
      return 'auth_failed';
    }
    if (msg.contains('connection refused') ||
        msg.contains('errno = 111') ||
        msg.contains('connectionrefused')) {
      return 'connection_refused';
    }
    if (msg.contains('could not resolve') ||
        msg.contains('host not found') ||
        msg.contains('dns') ||
        msg.contains('getaddrinfo') ||
        msg.contains('nodename nor servname')) {
      return 'dns_error: ${host ?? 'unknown'}';
    }
    if (msg.contains('timed out') || msg.contains('timeout')) {
      if (msg.contains('keepalive') || msg.contains('keep-alive')) {
        return 'keepalive_timeout';
      }
      return 'socket_timeout';
    }
    if (msg.contains('connection closed') ||
        msg.contains('connection reset') ||
        msg.contains('broken pipe') ||
        msg.contains('eof') ||
        msg.contains('remote closed')) {
      return 'remote_closed';
    }
    if (msg.contains('keepalive') || msg.contains('keep-alive')) {
      return 'keepalive_timeout';
    }
    // Generic SSH error for SSH-related messages, otherwise unknown
    final errorStr = error.toString();
    final truncated = errorStr.length > 100 ? errorStr.substring(0, 100) : errorStr;
    if (msg.contains('ssh') || msg.contains('socket') || msg.contains('channel')) {
      return 'ssh_error: $truncated';
    }
    return 'unknown: $truncated';
  }

  // ─── SOCKS5 Tunnel ───────────────────────────────────────────────

  Future<void> connectTunnel(ServerConfig server) async {
    if (_serversLoaded != null && !_serversLoaded!.isCompleted) {
      await _serversLoaded!.future;
    }
    if (_clients.containsKey(server.id)) return;
    if (_connecting.contains(server.id)) return;
    _connecting.add(server.id);
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

      // Close any lingering server socket before binding
      final existingSocket = _serverSockets.remove(server.id);
      if (existingSocket != null) {
        try {
          await existingSocket.close();
        } catch (_) {}
      }
      // Use shared: true to avoid SocketException when the port is still
      // held by a previous isolate / background-service instance that
      // hasn't released the socket yet (e.g. after hot-restart or update).
      ServerSocket serverSocket;
      try {
        serverSocket = await ServerSocket.bind(
            InternetAddress.anyIPv4, server.socksPort);
      } on SocketException {
        // Port is busy — check if an external proxy is already running
        try {
          final probe = await Socket.connect('127.0.0.1', server.socksPort,
              timeout: const Duration(seconds: 2));
          await probe.close();
          // Port is active — check if it's our own background service tunnel
          final prefs = await SharedPreferences.getInstance();
          await prefs.reload();
          final ownedTunnels = prefs.getStringList('active_tunnels') ?? [];
          final isOwn = ownedTunnels.contains(server.id) ||
              _activeReconnects.contains(server.id);

          client.close();
          // Re-persist ownership if this is our reconnecting tunnel
          if (isOwn) {
            await _markTunnelOwned(server.id, true);
          }
          activeTunnels.removeWhere((t) => t.serverId == server.id);
          activeTunnels.add(ActiveTunnel(
            serverId: server.id,
            serverName: server.name,
            socksPort: server.socksPort,
            startedAt: DateTime.now(),
            isExternal: !isOwn,
            proxyType: 'SOCKS5',
            authType: isOwn ? 'internal' : 'unknown',
          ));
          _log(server.name, 'info',
              isOwn
                  ? 'Port ${server.socksPort} owned by background service — registered as internal tunnel'
                  : 'Port ${server.socksPort} active externally — registered as external tunnel');
          eventBroadcaster.emit('connected', {
            'serverId': server.id,
            'name': server.name,
            'socksPort': server.socksPort,
            'source': 'external',
          });
          _notifyTunnelCount();
          notifyListeners();
          return;
        } catch (_) {
          // Port is busy but nothing is listening — try shared bind
          try {
            serverSocket = await ServerSocket.bind(
                InternetAddress.anyIPv4, server.socksPort, shared: true);
            _log(server.name, 'warning',
                'Port ${server.socksPort} was busy — bound with shared flag');
          } on SocketException {
            client.close();
            _log(server.name, 'error',
                'Port ${server.socksPort} is busy and cannot be bound');
            rethrow;
          }
        }
      }
      _serverSockets[server.id] = serverSocket;

      final hasProxyAuth = server.proxyUsername != null &&
          server.proxyUsername!.isNotEmpty &&
          server.proxyPassword != null &&
          server.proxyPassword!.isNotEmpty;

      final tunnel = ActiveTunnel(
        serverId: server.id,
        serverName: server.name,
        socksPort: server.socksPort,
        startedAt: DateTime.now(),
        proxyType: 'SOCKS5',
        authType: hasProxyAuth ? 'username/password' : 'no-auth',
      );

      serverSocket.listen(
        (Socket localSocket) {
          _handleSocksConnection(localSocket, client, server, tunnel);
        },
        onError: (e) {
          _log(server.name, 'error', 'ServerSocket error: $e');
        },
      );

      _clients[server.id] = client;
      server.isEnabled = true;
      await _saveServers();

      // Track this tunnel in SharedPreferences so other isolates know it's ours
      await _markTunnelOwned(server.id, true);

      activeTunnels.removeWhere((t) => t.serverId == server.id);
      activeTunnels.add(tunnel);
      _log(server.name, 'connected',
          'SOCKS5 proxy listening on 0.0.0.0:${server.socksPort}');

      _listenForDisconnect(server.id, client, server.name);

      // Check if this is a reconnect
      final downTime = _disconnectTimes.remove(server.id);
      if (downTime != null) {
        final downSecs = DateTime.now().difference(downTime).inSeconds;
        _sendNotification(server.id,
            '✅ ${server.name} reconnected (was down ${downSecs}s)');
      }

      _reconnectAttempts.remove(server.id);

      eventBroadcaster.emit('connected', {
        'serverId': server.id,
        'name': server.name,
        'socksPort': server.socksPort,
      });

      _notifyTunnelCount();
      notifyListeners();
    } on SocketException catch (e) {
      _connecting.remove(server.id);
      final reason = _classifyDisconnectReason(e, host: server.host);
      _log(server.name, 'error', 'Connection failed: $reason');
      eventBroadcaster.emit('error', {
        'serverId': server.id,
        'message': reason,
      });
      rethrow;
    } catch (e) {
      _connecting.remove(server.id);
      final reason = _classifyDisconnectReason(e, host: server.host);
      _log(server.name, 'error', 'Connection failed: $reason');
      eventBroadcaster.emit('error', {
        'serverId': server.id,
        'message': reason,
      });
      rethrow;
    } finally {
      _connecting.remove(server.id);
    }
  }

  void _listenForDisconnect(
      String serverId, SSHClient client, String serverName) {
    client.done.then((_) {
      if (!_disconnecting.contains(serverId)) {
        _handleUnexpectedDisconnect(serverId, 'remote_closed');
      }
    }).catchError((e) {
      if (!_disconnecting.contains(serverId)) {
        final server = servers.where((s) => s.id == serverId).firstOrNull;
        final reason = _classifyDisconnectReason(e, host: server?.host);
        _handleUnexpectedDisconnect(serverId, reason);
      }
    });
  }

  void _handleUnexpectedDisconnect(String serverId, String reason) {
    if (_disconnecting.contains(serverId)) return;
    if (_activeReconnects.contains(serverId)) return;

    final tunnel =
        activeTunnels.where((t) => t.serverId == serverId).firstOrNull;
    _cleanupConnection(serverId);
    // Only clear ownership if we won't auto-reconnect; otherwise keep it
    // so TCP probes during the reconnect window don't flag the port as external.
    final server0 = servers.where((s) => s.id == serverId).firstOrNull;
    if (server0 == null || !server0.autoReconnect) {
      _markTunnelOwned(serverId, false);
    }
    activeTunnels.removeWhere((t) => t.serverId == serverId);

    // Record disconnect time for downtime tracking
    _disconnectTimes[serverId] = DateTime.now();

    // Record disconnect in stats
    if (tunnel != null) {
      statsDb.insertDataPoint(
        serverId: serverId,
        uptime: tunnel.uptime.inSeconds,
        bytesIn: tunnel.bytesIn,
        bytesOut: tunnel.bytesOut,
        latencyMs: tunnel.latencyMs,
        reconnectCount: tunnel.reconnectCount,
        disconnectReason: reason,
      );
    }

    final server = servers.where((s) => s.id == serverId).firstOrNull;
    if (server != null) {
      _log(server.name, 'disconnected', reason);
      _sendNotification(serverId,
          '⚠️ ${server.name} disconnected: $reason');

      eventBroadcaster.emit('disconnected', {
        'serverId': serverId,
        'reason': reason,
      });

      if (server.autoReconnect) {
        _scheduleReconnect(server, previousTunnel: tunnel);
      }
    } else if (tunnel != null) {
      _log(tunnel.serverName, 'disconnected', reason);
      eventBroadcaster.emit('disconnected', {
        'serverId': serverId,
        'reason': reason,
      });
    }

    _notifyTunnelCount();
    notifyListeners();
  }

  /// Mark/unmark a tunnel as owned by this app in SharedPreferences.
  Future<void> _markTunnelOwned(String serverId, bool owned) async {
    final prefs = await SharedPreferences.getInstance();
    final tunnels = (prefs.getStringList('active_tunnels') ?? []).toSet();
    if (owned) {
      tunnels.add(serverId);
    } else {
      tunnels.remove(serverId);
    }
    await prefs.setStringList('active_tunnels', tunnels.toList());
  }

  void _cleanupConnection(String serverId) {
    _serverSockets[serverId]?.close();
    _serverSockets.remove(serverId);
    try {
      _clients[serverId]?.close();
    } catch (_) {}
    _clients.remove(serverId);
  }

  void _scheduleReconnect(ServerConfig server,
      {ActiveTunnel? previousTunnel}) {
    final attempts = _reconnectAttempts[server.id] ?? 0;
    final delaySec = min(pow(2, attempts).toInt(), 30);
    final nextRetryMs = delaySec * 1000;

    _reconnectTimers[server.id]?.cancel();
    _activeReconnects.add(server.id);

    _log(server.name, 'info',
        'Auto-reconnecting in ${delaySec}s (attempt ${attempts + 1})...');

    _sendNotification(server.id,
        '🔄 ${server.name} reconnecting (attempt ${attempts + 1})...');

    eventBroadcaster.emit('reconnecting', {
      'serverId': server.id,
      'attempt': attempts + 1,
      'nextRetryMs': nextRetryMs,
    });

    _reconnectTimers[server.id] =
        Timer(Duration(seconds: delaySec), () async {
      try {
        await connectTunnel(server);
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
        _scheduleReconnect(server, previousTunnel: previousTunnel);
      }
    });
  }

  /// Handle a single SOCKS5 client connection with optional proxy auth (#7).
  Future<void> _handleSocksConnection(Socket localSocket, SSHClient client,
      ServerConfig server, ActiveTunnel tunnel) async {
    final greetingCompleter = Completer<Uint8List>();
    final authCompleter = Completer<Uint8List>();
    final requestCompleter = Completer<Uint8List>();
    SSHForwardChannel? forwardChannel;

    final hasProxyAuth = server.proxyUsername != null &&
        server.proxyUsername!.isNotEmpty &&
        server.proxyPassword != null &&
        server.proxyPassword!.isNotEmpty;

    int phase = 0; // 0=greeting, 1=auth(optional), 2=request, 3=forwarding

    final sub = localSocket.listen(
      (Uint8List data) {
        if (phase == 0) {
          phase = hasProxyAuth ? 1 : 2;
          if (!greetingCompleter.isCompleted) greetingCompleter.complete(data);
        } else if (phase == 1) {
          phase = 2;
          if (!authCompleter.isCompleted) authCompleter.complete(data);
        } else if (phase == 2) {
          phase = 3;
          if (!requestCompleter.isCompleted) requestCompleter.complete(data);
        } else {
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
        if (!authCompleter.isCompleted) {
          authCompleter.completeError('Socket error: $e');
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
        if (!authCompleter.isCompleted) {
          authCompleter.completeError('Connection closed');
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

      if (hasProxyAuth) {
        // Respond: version=5, method=2 (username/password)
        localSocket.add([0x05, 0x02]);

        // ── Phase 1: Username/password auth ──
        final authData = await authCompleter.future;
        // RFC 1929: VER(1) ULEN(1) UNAME(ULEN) PLEN(1) PASSWD(PLEN)
        if (authData.length < 3 || authData[0] != 0x01) {
          localSocket.add([0x01, 0x01]); // auth failure
          localSocket.destroy();
          return;
        }
        final ulen = authData[1];
        if (authData.length < 3 + ulen) {
          localSocket.add([0x01, 0x01]);
          localSocket.destroy();
          return;
        }
        final username = String.fromCharCodes(authData.sublist(2, 2 + ulen));
        final plen = authData[2 + ulen];
        if (authData.length < 3 + ulen + plen) {
          localSocket.add([0x01, 0x01]);
          localSocket.destroy();
          return;
        }
        final password = String.fromCharCodes(
            authData.sublist(3 + ulen, 3 + ulen + plen));

        if (username != server.proxyUsername ||
            password != server.proxyPassword) {
          localSocket.add([0x01, 0x01]); // auth failure
          localSocket.destroy();
          return;
        }
        localSocket.add([0x01, 0x00]); // auth success
      } else {
        // Respond: version=5, method=0 (no auth)
        localSocket.add([0x05, 0x00]);
      }

      // ── Phase 2: SOCKS5 CONNECT request ──
      final request = await requestCompleter.future;
      if (request.length < 4 || request[0] != 0x05 || request[1] != 0x01) {
        localSocket.add([0x05, 0x07, 0x00, 0x01, 0, 0, 0, 0, 0, 0]);
        localSocket.destroy();
        return;
      }

      String targetHost;
      int targetPort;

      final addrType = request[3];
      if (addrType == 0x01) {
        if (request.length < 10) {
          localSocket.destroy();
          return;
        }
        targetHost =
            '${request[4]}.${request[5]}.${request[6]}.${request[7]}';
        targetPort = (request[8] << 8) | request[9];
      } else if (addrType == 0x03) {
        final domainLen = request[4];
        if (request.length < 5 + domainLen + 2) {
          localSocket.destroy();
          return;
        }
        targetHost = String.fromCharCodes(request.sublist(5, 5 + domainLen));
        targetPort =
            (request[5 + domainLen] << 8) | request[6 + domainLen];
      } else if (addrType == 0x04) {
        if (request.length < 22) {
          localSocket.destroy();
          return;
        }
        final bytes = request.sublist(4, 20);
        final groups = <String>[];
        for (int i = 0; i < 16; i += 2) {
          groups.add(
              ((bytes[i] << 8) | bytes[i + 1]).toRadixString(16));
        }
        targetHost = groups.join(':');
        targetPort = (request[20] << 8) | request[21];
      } else {
        localSocket.add([0x05, 0x08, 0x00, 0x01, 0, 0, 0, 0, 0, 0]);
        localSocket.destroy();
        return;
      }

      forwardChannel = await client.forwardLocal(targetHost, targetPort);

      localSocket.add([0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0]);

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
    } catch (e) {
      try {
        localSocket.add([0x05, 0x01, 0x00, 0x01, 0, 0, 0, 0, 0, 0]);
      } catch (_) {}
      try {
        localSocket.destroy();
      } catch (_) {}
    }
  }

  /// Disconnect a tunnel (user-initiated or with specific reason).
  void disconnectTunnel(String serverId, {String reason = 'user_disconnect'}) {
    _disconnecting.add(serverId);

    _reconnectTimers[serverId]?.cancel();
    _reconnectTimers.remove(serverId);
    _reconnectAttempts.remove(serverId);
    _activeReconnects.remove(serverId);

    _cleanupConnection(serverId);
    _markTunnelOwned(serverId, false);

    final tunnel =
        activeTunnels.where((t) => t.serverId == serverId).firstOrNull;
    activeTunnels.removeWhere((t) => t.serverId == serverId);
    try {
      final s = servers.firstWhere((x) => x.id == serverId);
      if (reason == 'user_disconnect') {
        s.isEnabled = false;
        _saveServers();
      }
      _log(s.name, 'disconnected', reason);
    } catch (_) {
      if (tunnel != null) {
        _log(tunnel.serverName, 'disconnected', reason);
      }
    }

    eventBroadcaster.emit('disconnected', {
      'serverId': serverId,
      'reason': reason,
    });

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
        _handleUnexpectedDisconnect(
            tunnel.serverId, 'keepalive_timeout');
        continue;
      }

      tunnel.lastKeepaliveAt = DateTime.now();

      try {
        final sw = Stopwatch()..start();
        final session = await client
            .execute('true')
            .timeout(const Duration(seconds: 10));
        await session.done.timeout(const Duration(seconds: 5));
        sw.stop();
        tunnel.latencyMs = sw.elapsedMilliseconds;
      } catch (e) {
        tunnel.latencyMs = null;
        debugPrint('Health check latency probe failed for '
            '${tunnel.serverName}: $e');
      }

      // Broadcast stats event
      eventBroadcaster.emit('stats', {
        'serverId': tunnel.serverId,
        'uptime': tunnel.uptime.inSeconds,
        'bytesIn': tunnel.bytesIn,
        'bytesOut': tunnel.bytesOut,
        'latencyMs': tunnel.latencyMs,
      });
    }
    notifyListeners();
  }

  // ─── Stats collection (every 5 min) ──────────────────────────────

  void _startStatsCollection() {
    _statsCollectionTimer =
        Timer.periodic(const Duration(minutes: 5), (_) => _collectStats());
    // Also schedule cleanup once
    statsDb.cleanup();
  }

  Future<void> _collectStats() async {
    for (final tunnel in activeTunnels) {
      if (tunnel.isExternal) continue;
      await statsDb.insertDataPoint(
        serverId: tunnel.serverId,
        uptime: tunnel.uptime.inSeconds,
        bytesIn: tunnel.bytesIn,
        bytesOut: tunnel.bytesOut,
        latencyMs: tunnel.latencyMs,
        reconnectCount: tunnel.reconnectCount,
      );
    }
    await statsDb.cleanup();
  }

  // ─── Network changes ─────────────────────────────────────────────

  void _listenNetworkChanges() {
    _connectivitySub = Connectivity()
        .onConnectivityChanged
        .listen((List<ConnectivityResult> results) async {
      if (results.isNotEmpty &&
          !results.contains(ConnectivityResult.none)) {
        // Mark currently active tunnels as network_change disconnects
        for (final tunnel in List<ActiveTunnel>.from(activeTunnels)) {
          if (!tunnel.isExternal && _clients.containsKey(tunnel.serverId)) {
            final client = _clients[tunnel.serverId];
            if (client != null && client.isClosed) {
              _handleUnexpectedDisconnect(tunnel.serverId, 'network_change');
            }
          }
        }
        _log('System', 'info', 'Network restored, reconnecting...');
        await Future.delayed(const Duration(seconds: 3));
        await _reconnectEnabledTunnels();
      }
    });
  }

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

  Future<Map<String, String>> _detectProxyInfo(int port) async {
    final info = <String, String>{};

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
    _statsCollectionTimer?.cancel();
    _connectivitySub?.cancel();
    _apiServer?.stop();
    eventBroadcaster.closeAll();
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
