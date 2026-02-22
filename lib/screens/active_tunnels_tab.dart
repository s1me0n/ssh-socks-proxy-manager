import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../services/proxy_service.dart';
import '../models/active_tunnel.dart';

class ActiveTunnelsTab extends StatelessWidget {
  final String apiAddress;
  const ActiveTunnelsTab({super.key, this.apiAddress = 'localhost:7070'});

  @override
  Widget build(BuildContext context) {
    final svc = context.watch<ProxyService>();
    final managed =
        svc.activeTunnels.where((t) => !t.isExternal).toList();
    final external =
        svc.activeTunnels.where((t) => t.isExternal).toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Active Tunnels'),
        actions: [
          IconButton(
            icon: const Icon(Icons.api),
            tooltip: 'API: $apiAddress',
            onPressed: () {
              Clipboard.setData(ClipboardData(text: 'http://$apiAddress'));
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('Copied: http://$apiAddress')),
              );
            },
          ),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Chip(
              label: Text('API $apiAddress',
                  style: const TextStyle(fontSize: 11)),
              avatar: const Icon(Icons.circle, size: 10, color: Colors.green),
            ),
          ),
          svc.isScanning
              ? const Padding(
                  padding: EdgeInsets.all(14),
                  child: SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2)))
              : IconButton(
                  icon: const Icon(Icons.search),
                  tooltip: 'Scan all ports (1-65535)',
                  onPressed: () => svc.scanAllPorts()),
        ],
      ),
      body: Column(children: [
        if (svc.isScanning)
          Column(
            children: [
              LinearProgressIndicator(value: svc.scanProgress),
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'Scanning port ${svc.scannedPorts} / 65535',
                      style: const TextStyle(
                          fontSize: 11, color: Colors.grey),
                    ),
                    Text(
                      '${(svc.scanProgress * 100).toStringAsFixed(1)}%',
                      style: const TextStyle(
                          fontSize: 11, color: Colors.grey),
                    ),
                  ],
                ),
              ),
            ],
          ),
        Expanded(
          child: svc.activeTunnels.isEmpty && !svc.isScanning
              ? const Center(
                  child: Text(
                      'No active tunnels.\nConnect a server or tap 🔍 to scan all ports.',
                      textAlign: TextAlign.center))
              : ListView(children: [
                  if (managed.isNotEmpty) ...[
                    const Padding(
                        padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
                        child: Text('MANAGED',
                            style: TextStyle(
                                fontSize: 12,
                                color: Colors.grey,
                                letterSpacing: 1.2))),
                    ...managed.map((t) => _TunnelCard(
                        tunnel: t,
                        onDisconnect: () =>
                            svc.disconnectTunnel(t.serverId))),
                  ],
                  if (external.isNotEmpty) ...[
                    const Padding(
                        padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
                        child: Text(
                            'EXTERNAL  (Termux / other apps)',
                            style: TextStyle(
                                fontSize: 12,
                                color: Colors.orange,
                                letterSpacing: 1.2))),
                    ...external.map((t) => _TunnelCard(tunnel: t)),
                  ],
                ]),
        ),
      ]),
    );
  }
}

class _TunnelCard extends StatelessWidget {
  final ActiveTunnel tunnel;
  final VoidCallback? onDisconnect;
  const _TunnelCard({required this.tunnel, this.onDisconnect});

  @override
  Widget build(BuildContext context) {
    final hasBandwidth = tunnel.bytesIn > 0 || tunnel.bytesOut > 0;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor:
              tunnel.isExternal ? Colors.orange : Colors.green,
          child: Icon(
              tunnel.isExternal ? Icons.wifi_find : Icons.lock,
              color: Colors.white),
        ),
        title: Text(tunnel.serverName),
        subtitle: Text(
            'SOCKS5  127.0.0.1:${tunnel.socksPort}  •  ${tunnel.uptimeString}'
            '${hasBandwidth ? "\n${tunnel.bandwidthString}" : ""}'
            '${tunnel.isExternal ? "\nType: ${tunnel.proxyType}  •  Auth: ${tunnel.authType}" : ""}'
            '${tunnel.restartCount > 0 ? "  •  restarted ${tunnel.restartCount}x" : ""}'),
        isThreeLine: tunnel.isExternal || hasBandwidth,
        trailing: onDisconnect != null
            ? IconButton(
                icon: const Icon(Icons.stop_circle, color: Colors.red),
                onPressed: onDisconnect)
            : const Tooltip(
                message: 'External — not managed by this app',
                child: Icon(Icons.info_outline, color: Colors.orange)),
      ),
    );
  }
}
