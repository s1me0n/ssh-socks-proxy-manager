import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'servers_tab.dart';
import 'active_tunnels_tab.dart';
import 'logs_tab.dart';
import 'settings_tab.dart';
import '../services/local_api_server.dart';
import '../services/proxy_service.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _index = 0;
  String _apiAddress = 'localhost:7070';
  Timer? _refreshTimer;
  StreamSubscription? _wsSubscription;

  @override
  void initState() {
    super.initState();
    _resolveApiAddress();
    _startRefreshAfterInit();
    _connectWebSocket();
  }

  /// Wait for ProxyService init (including _restoreOwnedTunnels) to complete
  /// before starting the periodic refresh timer. This prevents the race
  /// condition where reloadServers() runs before owned tunnels are restored,
  /// causing them to appear as "Active (external)".
  Future<void> _startRefreshAfterInit() async {
    final svc = Provider.of<ProxyService>(context, listen: false);
    try {
      await svc.initComplete.timeout(const Duration(seconds: 30));
    } catch (_) {}
    if (!mounted) return;
    // Periodically reload servers from storage so that changes made by
    // the background-service isolate (e.g. via Termux API) are reflected.
    _refreshTimer = Timer.periodic(
      const Duration(seconds: 3),
      (_) {
        if (mounted) {
          final svc = Provider.of<ProxyService>(context, listen: false);
          svc.reloadServers();
        }
      },
    );
  }

  /// Connect to WebSocket for real-time UI updates (Task 3).
  void _connectWebSocket() {
    final svc = Provider.of<ProxyService>(context, listen: false);
    final port = svc.apiServer?.activePort ?? 7070;
    final wsUrl = 'ws://127.0.0.1:$port/ws/events';
    WebSocket.connect(wsUrl).then((ws) {
      _wsSubscription = ws.listen(
        (data) {
          try {
            final event = jsonDecode(data);
            final type = event['event'] ?? event['type'];
            if (type == 'refresh' ||
                type == 'connected' ||
                type == 'disconnected' ||
                type == 'tunnel_connected' ||
                type == 'tunnel_disconnected') {
              if (mounted) {
                final svc = Provider.of<ProxyService>(context, listen: false);
                svc.reloadServers();
              }
            }
          } catch (_) {}
        },
        onDone: () {
          // Reconnect after a delay
          if (mounted) {
            Future.delayed(const Duration(seconds: 3), () {
              if (mounted) _connectWebSocket();
            });
          }
        },
        onError: (_) {
          if (mounted) {
            Future.delayed(const Duration(seconds: 3), () {
              if (mounted) _connectWebSocket();
            });
          }
        },
      );
    }).catchError((_) {
      // WebSocket not available yet, retry
      if (mounted) {
        Future.delayed(const Duration(seconds: 3), () {
          if (mounted) _connectWebSocket();
        });
      }
    });
  }

  Future<void> _resolveApiAddress() async {
    try {
      final proxyService = Provider.of<ProxyService>(context, listen: false);
      // API server runs in the background service isolate — do NOT start
      // a second one here.  Just wait for the background one to be ready
      // so we can read its port for the UI badge.
      await proxyService.apiReady.timeout(
        const Duration(seconds: 15),
        onTimeout: () {
          debugPrint('⚠️ HomeScreen: API ready timeout — using defaults');
        },
      );
      final ip = await LocalApiServer.getLocalIp();
      final port = proxyService.apiServer?.activePort ?? LocalApiServer.port;
      if (mounted) {
        setState(() => _apiAddress = '$ip:$port');
      }
    } catch (e) {
      debugPrint('❌ HomeScreen: API address resolve error: $e');
    }
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    _wsSubscription?.cancel();
    // API server lifecycle is owned by ProxyService, NOT HomeScreen.
    // Do NOT stop it here — it must survive widget rebuilds.
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: [
        ServersTab(apiAddress: _apiAddress),
        ActiveTunnelsTab(apiAddress: _apiAddress),
        const LogsTab(),
        const SettingsTab(),
      ][_index],
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.dns), label: 'Servers'),
          NavigationDestination(icon: Icon(Icons.router), label: 'Active'),
          NavigationDestination(
              icon: Icon(Icons.article), label: 'Logs'),
          NavigationDestination(
              icon: Icon(Icons.settings), label: 'Settings'),
        ],
      ),
    );
  }
}
