class ActiveTunnel {
  final String serverId;
  final String serverName;
  final int socksPort;
  final DateTime startedAt;
  final bool isExternal;
  bool isConnected;
  int restartCount;
  final String proxyType; // 'SOCKS5', 'SOCKS4', 'HTTP Proxy', 'Unknown'
  final String authType; // 'no-auth', 'auth-required', 'unknown'

  // Bandwidth tracking
  int bytesIn = 0;
  int bytesOut = 0;

  ActiveTunnel({
    required this.serverId,
    required this.serverName,
    required this.socksPort,
    required this.startedAt,
    this.isExternal = false,
    this.isConnected = true,
    this.restartCount = 0,
    this.proxyType = 'SOCKS5',
    this.authType = 'no-auth',
  });

  Duration get uptime => DateTime.now().difference(startedAt);

  String get uptimeString {
    final d = uptime;
    if (d.inHours > 0) return '${d.inHours}h ${d.inMinutes % 60}m';
    if (d.inMinutes > 0) return '${d.inMinutes}m ${d.inSeconds % 60}s';
    return '${d.inSeconds}s';
  }

  String get bandwidthString {
    return '↓${_formatBytes(bytesIn)} ↑${_formatBytes(bytesOut)}';
  }

  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '${bytes}B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)}KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)}MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)}GB';
  }
}
