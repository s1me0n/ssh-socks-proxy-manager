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
  LocalApiServer? _apiServer;

  @override
  void initState() {
    super.initState();
    _startApiServer();
  }

  Future<void> _startApiServer() async {
    final proxyService = Provider.of<ProxyService>(context, listen: false);
    _apiServer = LocalApiServer(proxyService);
    await _apiServer!.start();
    final ip = await LocalApiServer.getLocalIp();
    final port = _apiServer!.activePort ?? LocalApiServer.port;
    if (mounted) {
      setState(() => _apiAddress = '$ip:$port');
    }
  }

  @override
  void dispose() {
    _apiServer?.stop();
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
