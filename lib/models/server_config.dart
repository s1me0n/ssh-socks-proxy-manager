class ServerConfig {
  final String id;
  String name;
  String host;
  int sshPort;
  String username;
  String password; // loaded from secure storage
  int socksPort;
  bool isEnabled;
  String authType; // 'password' or 'key'
  String? privateKey; // PEM format, loaded from secure storage
  String? keyPassphrase; // optional passphrase for encrypted keys
  String? keyPath; // path to private key file on device
  bool autoReconnect; // auto-reconnect on unexpected disconnect (default: true)
  bool connectOnStartup; // auto-connect when app starts (default: false)
  bool notificationsEnabled; // per-server disconnect/reconnect notifications
  String? proxyUsername; // SOCKS5 proxy auth username
  String? proxyPassword; // SOCKS5 proxy auth password

  ServerConfig({
    required this.id,
    required this.name,
    required this.host,
    this.sshPort = 22,
    required this.username,
    this.password = '',
    this.socksPort = 1080,
    this.isEnabled = false,
    this.authType = 'password',
    this.privateKey,
    this.keyPassphrase,
    this.keyPath,
    this.autoReconnect = true,
    this.connectOnStartup = false,
    this.notificationsEnabled = true,
    this.proxyUsername,
    this.proxyPassword,
  });

  /// Serialize to JSON — secrets (password, privateKey, keyPassphrase) are NOT included.
  /// They are stored separately in FlutterSecureStorage.
  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'host': host,
        'sshPort': sshPort,
        'username': username,
        'socksPort': socksPort,
        'isEnabled': isEnabled,
        'authType': authType,
        'keyPath': keyPath,
        'autoReconnect': autoReconnect,
        'connectOnStartup': connectOnStartup,
        'notificationsEnabled': notificationsEnabled,
        'proxyUsername': proxyUsername,
        'proxyPassword': proxyPassword,
      };

  factory ServerConfig.fromJson(Map<String, dynamic> j) => ServerConfig(
        id: j['id'],
        name: j['name'],
        host: j['host'],
        sshPort: j['sshPort'] ?? 22,
        username: j['username'],
        password: '', // loaded from secure storage later
        socksPort: j['socksPort'] ?? 1080,
        isEnabled: j['isEnabled'] ?? false,
        authType: j['authType'] ?? 'password',
        keyPath: j['keyPath'],
        autoReconnect: j['autoReconnect'] ?? true,
        connectOnStartup: j['connectOnStartup'] ?? false,
        notificationsEnabled: j['notificationsEnabled'] ?? true,
        proxyUsername: j['proxyUsername'],
        proxyPassword: j['proxyPassword'],
      );
}
