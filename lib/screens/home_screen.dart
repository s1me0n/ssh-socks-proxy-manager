import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'servers_tab.dart';
import 'active_tunnels_tab.dart';
import '../services/local_api_server.dart';

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
    _findLocalIP();
  }

  Future<void> _findLocalIP() async {
    final ip = await LocalApiServer.getLocalIp();
    if (mounted) {
      setState(() => _apiAddress = '$ip:7070');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: [
        ServersTab(apiAddress: _apiAddress),
        ActiveTunnelsTab(apiAddress: _apiAddress),
      ][_index],
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.dns), label: 'Servers'),
          NavigationDestination(icon: Icon(Icons.router), label: 'Active'),
        ],
      ),
    );
  }
}
