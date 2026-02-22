import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../services/proxy_service.dart';

class SettingsTab extends StatelessWidget {
  const SettingsTab({super.key});

  @override
  Widget build(BuildContext context) {
    final svc = context.watch<ProxyService>();
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // ─── Import / Export section ──────────────────────────
          const Text('Server Import / Export',
              style: TextStyle(
                  fontSize: 16, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          const Text(
            'Export saves server configs (without passwords or keys).\n'
            'Import merges servers — duplicates (same host+user+port) are skipped.',
            style: TextStyle(fontSize: 13, color: Colors.grey),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  icon: const Icon(Icons.upload),
                  label: const Text('Export'),
                  onPressed: svc.servers.isEmpty
                      ? null
                      : () {
                          final json = jsonEncode({
                            'servers': svc.exportServers(),
                            'exportedAt':
                                DateTime.now().toIso8601String(),
                          });
                          Clipboard.setData(ClipboardData(text: json));
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                                content: Text(
                                    'Exported ${svc.servers.length} server(s) to clipboard')),
                          );
                        },
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.download),
                  label: const Text('Import'),
                  onPressed: () => _showImportDialog(context, svc),
                ),
              ),
            ],
          ),
          const SizedBox(height: 32),

          // ─── Info section ────────────────────────────────────
          const Text('About',
              style: TextStyle(
                  fontSize: 16, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('SSH SOCKS Proxy Manager v2.0.0'),
                  const SizedBox(height: 8),
                  Text('Servers: ${svc.servers.length}',
                      style: const TextStyle(color: Colors.grey)),
                  Text(
                      'Active tunnels: ${svc.activeTunnels.where((t) => !t.isExternal).length}',
                      style: const TextStyle(color: Colors.grey)),
                  Text('Log entries: ${svc.logs.length}',
                      style: const TextStyle(color: Colors.grey)),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: const [
                  Text('Features',
                      style: TextStyle(fontWeight: FontWeight.w600)),
                  SizedBox(height: 8),
                  Text('• Full SOCKS5 proxy (IPv4, IPv6, domain)'),
                  Text('• SSH password & key authentication'),
                  Text('• Ed25519 & RSA key support'),
                  Text('• Background foreground service'),
                  Text('• Auto-reconnect on network change'),
                  Text('• Health check every 30s'),
                  Text('• REST API on port 7070'),
                  Text('• Encrypted secret storage'),
                  Text('• Per-tunnel bandwidth stats'),
                  Text('• Connection logging'),
                  Text('• Server import/export'),
                  Text('• Boot auto-start'),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _showImportDialog(BuildContext context, ProxyService svc) {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Import Servers'),
        content: SizedBox(
          width: double.maxFinite,
          child: TextField(
            controller: controller,
            maxLines: 10,
            style: const TextStyle(
                fontFamily: 'monospace', fontSize: 12),
            decoration: const InputDecoration(
              hintText: 'Paste exported JSON here...',
              border: OutlineInputBorder(),
            ),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel')),
          FilledButton(
            onPressed: () {
              try {
                final data = jsonDecode(controller.text);
                List<dynamic> serverList;
                if (data is Map && data.containsKey('servers')) {
                  serverList = data['servers'] as List<dynamic>;
                } else if (data is List) {
                  serverList = data;
                } else {
                  throw FormatException('Invalid format');
                }
                final added = svc.importServers(serverList);
                Navigator.pop(ctx);
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                      content: Text(
                          'Imported $added new server(s), ${serverList.length - added} skipped (duplicates)')),
                );
              } catch (e) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                      content: Text('Import error: $e'),
                      backgroundColor: Colors.red),
                );
              }
            },
            child: const Text('Import'),
          ),
        ],
      ),
    );
  }
}
