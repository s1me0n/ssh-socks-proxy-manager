class ServerConfig {
  final String id;
  final String name;
  final String host;
  final int sshPort;
  final String username;
  String password; // loaded from secure storage
  final int socksPort;
  bool isEnabled;
  final String authType; // 'password' or 'key'
  String? privateKey; // PEM format, loaded from secure storage
  String? keyPassphrase; // optional passphrase for encrypted keys

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
      );
}
