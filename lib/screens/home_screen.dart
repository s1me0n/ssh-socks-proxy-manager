import 'package:flutter/material.dart';
import 'servers_tab.dart';
import 'active_tunnels_tab.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _index = 0;
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: [const ServersTab(), const ActiveTunnelsTab()][_index],
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
