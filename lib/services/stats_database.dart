import 'dart:async';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;

class StatsDatabase {
  Database? _db;

  Future<Database> get database async {
    if (_db != null) return _db!;
    final dbPath = await getDatabasesPath();
    _db = await openDatabase(
      p.join(dbPath, 'stats.db'),
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE stats (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            serverId TEXT NOT NULL,
            timestamp INTEGER NOT NULL,
            uptime INTEGER NOT NULL DEFAULT 0,
            bytesIn INTEGER NOT NULL DEFAULT 0,
            bytesOut INTEGER NOT NULL DEFAULT 0,
            latencyMs INTEGER,
            reconnectCount INTEGER NOT NULL DEFAULT 0,
            disconnectReason TEXT
          )
        ''');
        await db.execute(
            'CREATE INDEX idx_stats_server_time ON stats(serverId, timestamp)');
      },
    );
    return _db!;
  }

  Future<void> insertDataPoint({
    required String serverId,
    required int uptime,
    required int bytesIn,
    required int bytesOut,
    int? latencyMs,
    int reconnectCount = 0,
    String? disconnectReason,
  }) async {
    final db = await database;
    await db.insert('stats', {
      'serverId': serverId,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
      'uptime': uptime,
      'bytesIn': bytesIn,
      'bytesOut': bytesOut,
      'latencyMs': latencyMs,
      'reconnectCount': reconnectCount,
      'disconnectReason': disconnectReason,
    });
  }

  Future<void> cleanup() async {
    final db = await database;
    final cutoff =
        DateTime.now().subtract(const Duration(days: 7)).millisecondsSinceEpoch;
    await db.delete('stats', where: 'timestamp < ?', whereArgs: [cutoff]);
  }

  Future<Map<String, dynamic>> getStats(String serverId, String period) async {
    final db = await database;
    final now = DateTime.now().millisecondsSinceEpoch;
    int since;
    switch (period) {
      case '1h':
        since = now - 3600000;
        break;
      case '24h':
        since = now - 86400000;
        break;
      case '7d':
        since = now - 604800000;
        break;
      default:
        since = now - 86400000;
    }

    final rows = await db.query(
      'stats',
      where: 'serverId = ? AND timestamp >= ?',
      whereArgs: [serverId, since],
      orderBy: 'timestamp ASC',
    );

    if (rows.isEmpty) {
      return {
        'totalUptime': 0,
        'uptimePercent': 0.0,
        'avgLatencyMs': 0,
        'reconnectCount': 0,
        'disconnectReasons': <String, int>{},
        'dataPoints': <Map<String, dynamic>>[],
      };
    }

    int totalUptime = 0;
    int latencySum = 0;
    int latencyCount = 0;
    int maxReconnect = 0;
    final reasons = <String, int>{};

    for (final row in rows) {
      totalUptime += (row['uptime'] as int?) ?? 0;
      final lat = row['latencyMs'] as int?;
      if (lat != null) {
        latencySum += lat;
        latencyCount++;
      }
      final rc = (row['reconnectCount'] as int?) ?? 0;
      if (rc > maxReconnect) maxReconnect = rc;
      final reason = row['disconnectReason'] as String?;
      if (reason != null && reason.isNotEmpty) {
        reasons[reason] = (reasons[reason] ?? 0) + 1;
      }
    }

    final periodMs = now - since;
    final uptimePercent =
        periodMs > 0 ? (totalUptime * 1000 / periodMs * 100).clamp(0, 100) : 0;

    return {
      'totalUptime': totalUptime,
      'uptimePercent': uptimePercent is double
          ? double.parse(uptimePercent.toStringAsFixed(2))
          : uptimePercent,
      'avgLatencyMs': latencyCount > 0 ? (latencySum / latencyCount).round() : 0,
      'reconnectCount': maxReconnect,
      'disconnectReasons': reasons,
      'dataPoints': rows
          .map((r) => {
                'timestamp': r['timestamp'],
                'uptime': r['uptime'],
                'bytesIn': r['bytesIn'],
                'bytesOut': r['bytesOut'],
                'latencyMs': r['latencyMs'],
                'reconnectCount': r['reconnectCount'],
              })
          .toList(),
    };
  }

  Future<void> close() async {
    await _db?.close();
    _db = null;
  }
}
