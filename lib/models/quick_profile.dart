class QuickProfile {
  final String id;
  final String serverId;
  final String name;
  final int socksPort;

  QuickProfile({
    required this.id,
    required this.serverId,
    required this.name,
    required this.socksPort,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'serverId': serverId,
        'name': name,
        'socksPort': socksPort,
      };

  factory QuickProfile.fromJson(Map<String, dynamic> j) => QuickProfile(
        id: j['id'],
        serverId: j['serverId'],
        name: j['name'],
        socksPort: j['socksPort'] ?? 1080,
      );
}
