import 'dart:io';
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
                        onDisconnect: () async {
                          final client = HttpClient();
                          try {
                            final req = await client.postUrl(
                                Uri.parse('http://$apiAddress/disconnect/${t.serverId}'));
                            req.headers.contentLength = 0;
                            final resp = await req.close();
                            await resp.drain<void>();
                          } catch (_) {
                          } finally {
                            client.close();
                          }
                        })),
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
                    ...external.map((t) => _ExternalTunnelCard(tunnel: t)),
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
    final hasLatency = tunnel.latencyMs != null;
    final hasReconnects = tunnel.reconnectCount > 0;

    // Build subtitle parts
    final lines = <String>[
      'SOCKS5  127.0.0.1:${tunnel.socksPort}  •  ${tunnel.uptimeString}',
    ];

    // Health info line
    final healthParts = <String>[];
    if (hasLatency) healthParts.add('${tunnel.latencyMs}ms');
    if (hasBandwidth) healthParts.add(tunnel.bandwidthString);
    if (hasReconnects) healthParts.add('↻${tunnel.reconnectCount}');
    if (healthParts.isNotEmpty) lines.add(healthParts.join('  •  '));

    if (tunnel.isExternal) {
      lines.add('Type: ${tunnel.proxyType}  •  Auth: ${tunnel.authType}');
    }

    if (tunnel.reconnectCount > 0) {
      lines.add('Total uptime: ${tunnel.totalUptimeString}');
    }

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
        subtitle: Text(lines.join('\n')),
        isThreeLine: lines.length > 1,
        trailing: onDisconnect != null
            ? IconButton(
                icon: const Icon(Icons.stop_circle, color: Colors.red),
                onPressed: onDisconnect)
            : null,
      ),
    );
  }
}

class _ExternalTunnelCard extends StatelessWidget {
  final ActiveTunnel tunnel;
  const _ExternalTunnelCard({required this.tunnel});

  @override
  Widget build(BuildContext context) {
    final pid = tunnel.serverId; // external tunnels store PID-like info
    final killCmd = 'kill \$(lsof -ti :${tunnel.socksPort})';

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: ListTile(
        leading: const CircleAvatar(
          backgroundColor: Colors.orange,
          child: Icon(Icons.wifi_find, color: Colors.white),
        ),
        title: Text(tunnel.serverName),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'SOCKS5  127.0.0.1:${tunnel.socksPort}  •  ${tunnel.uptimeString}\n'
              'Type: ${tunnel.proxyType}  •  Auth: ${tunnel.authType}',
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                const Icon(Icons.info_outline,
                    size: 14, color: Colors.orange),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    'Stop via Termux: $killCmd',
                    style: const TextStyle(
                        fontSize: 11, color: Colors.orange),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.copy, size: 16),
                  tooltip: 'Copy kill command',
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: killCmd));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                          content: Text('Kill command copied!')),
                    );
                  },
                ),
              ],
            ),
          ],
        ),
        isThreeLine: true,
      ),
    );
  }
}
