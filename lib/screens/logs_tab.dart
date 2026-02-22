import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/proxy_service.dart';
import '../models/connection_log.dart';

class LogsTab extends StatelessWidget {
  const LogsTab({super.key});

  @override
  Widget build(BuildContext context) {
    final svc = context.watch<ProxyService>();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Connection Logs'),
        actions: [
          if (svc.logs.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.delete_sweep),
              tooltip: 'Clear logs',
              onPressed: () {
                svc.logs.clear();
                svc.notifyListeners();
              },
            ),
        ],
      ),
      body: svc.logs.isEmpty
          ? const Center(
              child: Text('No logs yet.',
                  style: TextStyle(color: Colors.grey)))
          : ListView.builder(
              itemCount: svc.logs.length,
              itemBuilder: (ctx, i) {
                final log = svc.logs[i];
                return _LogTile(log: log);
              },
            ),
    );
  }
}

class _LogTile extends StatelessWidget {
  final ConnectionLog log;
  const _LogTile({required this.log});

  IconData _icon() {
    switch (log.event) {
      case 'connected':
        return Icons.check_circle;
      case 'disconnected':
        return Icons.cancel;
      case 'error':
        return Icons.error;
      case 'reconnected':
        return Icons.refresh;
      case 'info':
      default:
        return Icons.info;
    }
  }

  Color _color() {
    switch (log.event) {
      case 'connected':
        return Colors.green;
      case 'disconnected':
        return Colors.orange;
      case 'error':
        return Colors.red;
      case 'reconnected':
        return Colors.blue;
      case 'info':
      default:
        return Colors.grey;
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListTile(
      dense: true,
      leading: Icon(_icon(), color: _color(), size: 20),
      title: Text(
        '${log.timeString}  ${log.serverName}',
        style: const TextStyle(fontSize: 13, fontFamily: 'monospace'),
      ),
      subtitle: log.details != null
          ? Text(log.details!,
              style: const TextStyle(fontSize: 12),
              maxLines: 2,
              overflow: TextOverflow.ellipsis)
          : null,
      trailing: Text(log.event,
          style: TextStyle(
              fontSize: 11,
              color: _color(),
              fontWeight: FontWeight.w600)),
    );
  }
}
