class ServerConfig {
  final String id;
  final String name;
  final String host;
  final int sshPort;
  final String username;
  final String password;
  final int socksPort;
  bool isEnabled;

  ServerConfig({
    required this.id,
    required this.name,
    required this.host,
    this.sshPort = 22,
    required this.username,
    required this.password,
    this.socksPort = 1080,
    this.isEnabled = false,
  });

  Map<String, dynamic> toJson() => {
    'id': id, 'name': name, 'host': host, 'sshPort': sshPort,
    'username': username, 'password': password, 'socksPort': socksPort,
    'isEnabled': isEnabled,
  };

  factory ServerConfig.fromJson(Map<String, dynamic> j) => ServerConfig(
    id: j['id'], name: j['name'], host: j['host'],
    sshPort: j['sshPort'] ?? 22,
    username: j['username'], password: j['password'],
    socksPort: j['socksPort'] ?? 1080,
    isEnabled: j['isEnabled'] ?? false,
  );
}
