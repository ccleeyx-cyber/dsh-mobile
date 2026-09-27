class ServerConfig {
  String host;
  int port;
  String token;
  bool useHttps;

  ServerConfig({
    required this.host,
    this.port = 3088,
    required this.token,
    this.useHttps = false,
  });

  String get httpBaseUrl {
    final scheme = useHttps ? 'https' : 'http';
    return '$scheme://$host:$port';
  }

  String get wsUrl {
    final scheme = useHttps ? 'wss' : 'ws';
    return '$scheme://$host:$port/mobile-ws?token=$token';
  }

  Map<String, dynamic> toJson() => {
    'host': host,
    'port': port,
    'token': token,
    'useHttps': useHttps,
  };

  factory ServerConfig.fromJson(Map<String, dynamic> json) => ServerConfig(
    host: json['host'] ?? '',
    port: json['port'] ?? 3088,
    token: json['token'] ?? '',
    useHttps: json['useHttps'] ?? false,
  );
}
