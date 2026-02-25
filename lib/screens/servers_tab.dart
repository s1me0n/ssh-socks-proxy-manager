import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../services/proxy_service.dart';
import '../models/server_config.dart';
import 'server_form_screen.dart';

class ServersTab extends StatelessWidget {
  final String apiAddress;
  const ServersTab({super.key, this.apiAddress = 'localhost:7070'});

  @override
  Widget build(BuildContext context) {
    final svc = context.watch<ProxyService>();
    return Scaffold(
      appBar: AppBar(
        title: const Text('SSH Servers'),
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
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => Navigator.push(context,
            MaterialPageRoute(builder: (_) => const ServerFormScreen())),
        child: const Icon(Icons.add),
      ),
      body: svc.servers.isEmpty
          ? const Center(
              child: Text('No servers yet.\nTap + to add one.',
                  textAlign: TextAlign.center))
          : ListView.builder(
              itemCount: svc.servers.length,
              itemBuilder: (ctx, i) {
                final s = svc.servers[i];
                final isActive = svc.activeTunnels
                    .any((t) => t.serverId == s.id && !t.isExternal);
                final isExternal = svc.activeTunnels
                    .any((t) => t.serverId == s.id && t.isExternal);
                final statusColor = isActive
                    ? Colors.green
                    : isExternal
                        ? Colors.orange
                        : Colors.grey.shade700;
                final reverseText = isActive && s.reverseProxy
                    ? '  ↑ Exposed :${s.reverseProxyPort}'
                    : '';
                final statusText = isExternal
                    ? '  ⚡ Active (external)'
                    : reverseText;
                return Card(
                  margin: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 6),
                  child: ListTile(
                    leading: CircleAvatar(
                      backgroundColor: statusColor,
                      child: Icon(
                          isExternal
                              ? Icons.wifi_find
                              : s.authType == 'key'
                                  ? Icons.vpn_key
                                  : Icons.dns,
                          color: Colors.white),
                    ),
                    title: Text(s.name),
                    subtitle: Text(
                        '${s.username}@${s.host}:${s.sshPort}  →  SOCKS :${s.socksPort}'
                        '  (${s.authType == 'key' ? 'key' : 'pass'})$statusText'),
                    trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (isExternal)
                            IconButton(
                              icon: const Icon(Icons.content_copy,
                                  color: Colors.orange),
                              tooltip: 'Copy kill command',
                              onPressed: () {
                                final killCmd =
                                    'kill \$(lsof -ti :${s.socksPort})';
                                Clipboard.setData(
                                    ClipboardData(text: killCmd));
                                ScaffoldMessenger.of(ctx).showSnackBar(
                                  SnackBar(
                                      content: Text(
                                          'Copied: $killCmd\nRun in Termux to stop the proxy')),
                                );
                              },
                            )
                          else
                            IconButton(
                              icon: Icon(
                                isActive ? Icons.stop : Icons.play_arrow,
                                color: isActive ? Colors.red : Colors.green,
                              ),
                              onPressed: () async {
                                final base = 'http://$apiAddress';
                                final client = HttpClient();
                                try {
                                  final uri = isActive
                                      ? Uri.parse('$base/disconnect/${s.id}')
                                      : Uri.parse('$base/connect/${s.id}');
                                  final req = await client.postUrl(uri);
                                  req.headers.contentLength = 0;
                                  final resp = await req.close();
                                  await resp.drain<void>();
                                } catch (e) {
                                  if (ctx.mounted) {
                                    ScaffoldMessenger.of(ctx).showSnackBar(
                                      SnackBar(
                                          content: Text('Error: $e'),
                                          backgroundColor: Colors.red));
                                  }
                                } finally {
                                  client.close();
                                }
                              },
                            ),
                          PopupMenuButton(
                            itemBuilder: (_) => [
                              const PopupMenuItem(
                                  value: 'edit', child: Text('Edit')),
                              const PopupMenuItem(
                                  value: 'delete', child: Text('Delete')),
                            ],
                            onSelected: (v) {
                              if (v == 'edit') {
                                Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                        builder: (_) =>
                                            ServerFormScreen(server: s)));
                              }
                              if (v == 'delete') {
                                showDialog(
                                  context: context,
                                  builder: (_) => AlertDialog(
                                    title: const Text('Delete server?'),
                                    content: Text('Delete "${s.name}"?'),
                                    actions: [
                                      TextButton(
                                          onPressed: () =>
                                              Navigator.pop(context),
                                          child: const Text('Cancel')),
                                      TextButton(
                                          onPressed: () {
                                            svc.deleteServer(s.id);
                                            Navigator.pop(context);
                                          },
                                          child: const Text('Delete',
                                              style: TextStyle(
                                                  color: Colors.red))),
                                    ],
                                  ),
                                );
                              }
                            },
                          ),
                        ]),
                  ),
                );
              },
            ),
    );
  }
}
