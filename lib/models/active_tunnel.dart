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
}
