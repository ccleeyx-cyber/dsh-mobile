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

  String get cleanHost {
    var h = host.trim();
    if (h.startsWith('https://')) {
      h = h.substring(8);
    } else if (h.startsWith('http://')) {
      h = h.substring(7);
    }
    if (h.contains('/')) {
      h = h.split('/')[0];
    }
    if (h.contains(':')) {
      h = h.split(':')[0];
    }
    return h;
  }

  int get cleanPort {
    final h = host.trim();
    if (h.contains(':') && !h.startsWith('http')) {
      final parts = h.split(':');
      final last = parts.last.replaceAll(RegExp(r'[^0-9]'), '');
      final p = int.tryParse(last);
      if (p != null && p > 0) return p;
    }
    return port > 0 ? port : 3088;
  }

  String get httpBaseUrl {
    final scheme = useHttps ? 'https' : 'http';
    return '$scheme://$cleanHost:$cleanPort';
  }

  String get wsUrl {
    final scheme = useHttps ? 'wss' : 'ws';
    return '$scheme://$cleanHost:$cleanPort/mobile-ws?token=$token';
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
