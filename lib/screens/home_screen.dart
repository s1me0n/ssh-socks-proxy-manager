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

  @override
  void initState() {
    super.initState();
    _resolveApiAddress();
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
