import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import '../models/server_config.dart';
import '../models/active_tunnel.dart';

class ProxyService extends ChangeNotifier {
  List<ServerConfig> servers = [];
  List<ActiveTunnel> activeTunnels = [];
  bool isScanning = false;
  final Map<String, SSHClient> _clients = {};
  final Map<String, ServerSocket> _serverSockets = {};
  Timer? _healthCheckTimer;
  StreamSubscription? _connectivitySub;

  ProxyService() {
    _loadServers();
    _startHealthCheck();
    _listenNetworkChanges();
  }

  Future<void> _loadServers() async {
    final prefs = await SharedPreferences.getInstance();
    final data = prefs.getStringList('servers') ?? [];
    servers = data.map((s) => ServerConfig.fromJson(jsonDecode(s))).toList();
    notifyListeners();
    _reconnectEnabledTunnels();
  }

  Future<void> _saveServers() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
        'servers', servers.map((s) => jsonEncode(s.toJson())).toList());
  }

  void addServer(ServerConfig s) {
    servers.add(s);
    _saveServers();
    notifyListeners();
  }

  void updateServer(ServerConfig s) {
    final i = servers.indexWhere((x) => x.id == s.id);
    if (i >= 0) {
      servers[i] = s;
      _saveServers();
      notifyListeners();
    }
  }

  void deleteServer(String id) {
    disconnectTunnel(id);
    servers.removeWhere((s) => s.id == id);
    _saveServers();
    notifyListeners();
  }

  Future<void> connectTunnel(ServerConfig server) async {
    if (_clients.containsKey(server.id)) return;
    try {
      final socket = await SSHSocket.connect(server.host, server.sshPort,
          timeout: const Duration(seconds: 15));
      final client = SSHClient(socket,
          username: server.username,
          onPasswordRequest: () => server.password);
      await client.authenticated;

      final serverSocket =
          await ServerSocket.bind('127.0.0.1', server.socksPort);
      _serverSockets[server.id] = serverSocket;

      serverSocket.listen((localSocket) async {
        try {
          final forward = await client.forwardLocal('', 0);
          localSocket.pipe(forward.stream as StreamConsumer<List<int>>);
          forward.stream.pipe(localSocket);
        } catch (_) {}
      });

      _clients[server.id] = client;
      server.isEnabled = true;
      await _saveServers();

      activeTunnels.removeWhere((t) => t.serverId == server.id);
      activeTunnels.add(ActiveTunnel(
        serverId: server.id,
        serverName: server.name,
        socksPort: server.socksPort,
        startedAt: DateTime.now(),
      ));
      notifyListeners();
    } catch (e) {
      rethrow;
    }
  }

  void disconnectTunnel(String serverId) {
    _serverSockets[serverId]?.close();
    _serverSockets.remove(serverId);
    _clients[serverId]?.close();
    _clients.remove(serverId);
    activeTunnels.removeWhere((t) => t.serverId == serverId);
    try {
      final s = servers.firstWhere((x) => x.id == serverId);
      s.isEnabled = false;
      _saveServers();
    } catch (_) {}
    notifyListeners();
  }

  void _startHealthCheck() {
    _healthCheckTimer =
        Timer.periodic(const Duration(seconds: 30), (_) => _checkHealth());
  }

  Future<void> _checkHealth() async {
    for (final tunnel in List.from(activeTunnels)) {
      if (tunnel.isExternal) continue;
      final alive = await _isPortOpen(tunnel.socksPort);
      if (!alive) {
        try {
          final server = servers.firstWhere((s) => s.id == tunnel.serverId);
          if (server.isEnabled) {
            disconnectTunnel(server.id);
            await Future.delayed(const Duration(seconds: 2));
            await connectTunnel(server);
            tunnel.restartCount++;
          }
        } catch (_) {}
      }
    }
  }

  void _listenNetworkChanges() {
    _connectivitySub =
        Connectivity().onConnectivityChanged.listen((result) async {
      if (result != ConnectivityResult.none) {
        await Future.delayed(const Duration(seconds: 3));
        await _reconnectEnabledTunnels();
      }
    });
  }

  Future<void> _reconnectEnabledTunnels() async {
    for (final server in servers.where((s) => s.isEnabled)) {
      if (!_clients.containsKey(server.id)) {
        try {
          await connectTunnel(server);
        } catch (_) {}
      }
    }
  }

  Future<void> scanAllPorts() async {
    isScanning = true;
    notifyListeners();

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
    }

    for (final port in openPorts) {
      if (!managedPorts.contains(port)) {
        activeTunnels.add(ActiveTunnel(
          serverId: 'ext_$port',
          serverName: 'External (port $port)',
          socksPort: port,
          startedAt: DateTime.now(),
          isExternal: true,
        ));
      }
    }

    isScanning = false;
    notifyListeners();
  }

  Future<bool> _isPortOpen(int port) async {
    try {
      final s = await Socket.connect('127.0.0.1', port,
          timeout: const Duration(seconds: 3));
      await s.close();
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  void dispose() {
    _healthCheckTimer?.cancel();
    _connectivitySub?.cancel();
    for (final c in _clients.values) {
      c.close();
    }
    for (final s in _serverSockets.values) {
      s.close();
    }
    super.dispose();
  }
}
