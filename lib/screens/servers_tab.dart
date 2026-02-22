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
                return Card(
                  margin: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 6),
                  child: ListTile(
                    leading: CircleAvatar(
                      backgroundColor:
                          isActive ? Colors.green : Colors.grey.shade700,
                      child: const Icon(Icons.dns, color: Colors.white),
                    ),
                    title: Text(s.name),
                    subtitle: Text(
                        '${s.username}@${s.host}:${s.sshPort}  →  SOCKS :${s.socksPort}'),
                    trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            icon: Icon(
                              isActive ? Icons.stop : Icons.play_arrow,
                              color: isActive ? Colors.red : Colors.green,
                            ),
                            onPressed: () async {
                              if (isActive) {
                                svc.disconnectTunnel(s.id);
                              } else {
                                try {
                                  await svc.connectTunnel(s);
                                } catch (e) {
                                  if (ctx.mounted) {
                                    ScaffoldMessenger.of(ctx).showSnackBar(
                                      SnackBar(
                                          content: Text('Error: $e'),
                                          backgroundColor: Colors.red));
                                  }
                                }
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
