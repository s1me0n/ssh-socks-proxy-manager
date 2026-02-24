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
          // ─── API Authentication section ──────────────────────
          const Text('API Authentication',
              style: TextStyle(
                  fontSize: 16, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          const Text(
            'Protect the REST API with a Bearer token. '
            '/ping always works without auth.',
            style: TextStyle(fontSize: 13, color: Colors.grey),
          ),
          const SizedBox(height: 12),
          SwitchListTile(
            title: const Text('Enable API Authentication'),
            subtitle: Text(svc.apiAuthEnabled ? 'Enabled' : 'Disabled',
                style: const TextStyle(fontSize: 12)),
            value: svc.apiAuthEnabled,
            onChanged: (v) => svc.setApiAuthEnabled(v),
          ),
          if (svc.apiToken != null) ...[
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('API Token',
                        style: TextStyle(fontWeight: FontWeight.w600)),
                    const SizedBox(height: 8),
                    SelectableText(
                      svc.apiToken!,
                      style: const TextStyle(
                          fontFamily: 'monospace', fontSize: 12),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        OutlinedButton.icon(
                          icon: const Icon(Icons.copy, size: 16),
                          label: const Text('Copy'),
                          onPressed: () {
                            Clipboard.setData(
                                ClipboardData(text: svc.apiToken!));
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                  content: Text('Token copied to clipboard')),
                            );
                          },
                        ),
                        const SizedBox(width: 8),
                        OutlinedButton.icon(
                          icon: const Icon(Icons.refresh, size: 16),
                          label: const Text('Regenerate'),
                          onPressed: () async {
                            await svc.regenerateApiToken();
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                    content: Text('Token regenerated')),
                              );
                            }
                          },
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
          const SizedBox(height: 32),

          // ─── Import / Export section ──────────────────────────
          const Text('Server Import / Export',
              style: TextStyle(
                  fontSize: 16, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          const Text(
            'Export saves server configs. Use "Export with keys" to include '
            'private keys and passwords.\n'
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
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              icon: const Icon(Icons.vpn_key),
              label: const Text('Export with Keys'),
              onPressed: svc.servers.isEmpty
                  ? null
                  : () {
                      final json = jsonEncode({
                        'servers':
                            svc.exportServers(includeKeys: true),
                        'exportedAt':
                            DateTime.now().toIso8601String(),
                        'includesKeys': true,
                      });
                      Clipboard.setData(ClipboardData(text: json));
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                            content: Text(
                                'Exported ${svc.servers.length} server(s) WITH KEYS to clipboard')),
                      );
                    },
            ),
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
                  const Text('SSH SOCKS Proxy Manager v5.0.0'),
                  const SizedBox(height: 8),
                  Text('Servers: ${svc.servers.length}',
                      style: const TextStyle(color: Colors.grey)),
                  Text(
                      'Active tunnels: ${svc.activeTunnels.where((t) => !t.isExternal).length}',
                      style: const TextStyle(color: Colors.grey)),
                  Text('Log entries: ${svc.logs.length}',
                      style: const TextStyle(color: Colors.grey)),
                  Text('Profiles: ${svc.profiles.length}',
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
                  Text('• SOCKS5 proxy authentication'),
                  Text('• SSH password & key authentication'),
                  Text('• Ed25519 & RSA key support'),
                  Text('• SSH keepalive (15s interval)'),
                  Text('• Auto-reconnect with exponential backoff'),
                  Text('• Auto-connect on startup (per server)'),
                  Text('• Connection health monitoring'),
                  Text('• Background foreground service'),
                  Text('• Auto-reconnect on network change'),
                  Text('• Health check every 30s'),
                  Text('• REST API with Bearer token auth'),
                  Text('• WebSocket real-time events'),
                  Text('• Connection stats history (SQLite)'),
                  Text('• Quick-connect profiles'),
                  Text('• Disconnect/reconnect notifications'),
                  Text('• Encrypted secret storage'),
                  Text('• Per-tunnel bandwidth stats'),
                  Text('• Export/import with optional keys'),
                  Text('• Connection logging with reasons'),
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
