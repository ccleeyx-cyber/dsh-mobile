class ServerConfig {
  String host;
  int port;
  String token;
  bool useHttps;

  String npsAddress;
  String authCode;

  ServerConfig({
    required this.host,
    this.port = 3088,
    required this.token,
    this.useHttps = false,
    this.npsAddress = '',
    this.authCode = '',
  });

  String get _normalizedHost {
    var h = host.trim();
    if (h.startsWith('https://')) {
      h = h.substring(8);
    } else if (h.startsWith('http://')) {
      h = h.substring(7);
    }
    if (h.contains('/')) {
      h = h.split('/')[0];
    }
    return h;
  }

  String get cleanHost {
    final h = _normalizedHost;
    if (h.contains(':')) {
      return h.split(':')[0];
    }
    return h.isEmpty ? '127.0.0.1' : h;
  }

  int get cleanPort {
    final h = _normalizedHost;
    if (h.contains(':')) {
      final parts = h.split(':');
      final last = parts.last.replaceAll(RegExp(r'[^0-9]'), '');
      final p = int.tryParse(last);
      if (p != null && p > 0) return p;
    }
    return port > 0 ? port : 3088;
  }

  bool get effectiveUseHttps => useHttps || host.trim().startsWith('https://');

  String get effectiveToken {
    if (token.trim().isNotEmpty) return token.trim();
    if (authCode.trim().isNotEmpty) return authCode.trim();
    return '';
  }

  String get httpBaseUrl {
    final scheme = effectiveUseHttps ? 'https' : 'http';
    return '$scheme://$cleanHost:$cleanPort';
  }

  String get wsUrl {
    final scheme = effectiveUseHttps ? 'wss' : 'ws';
    return '$scheme://$cleanHost:$cleanPort/mobile-ws?token=$effectiveToken';
  }

  Map<String, dynamic> toJson() => {
    'host': host,
    'port': port,
    'token': token,
    'useHttps': useHttps,
    'npsAddress': npsAddress,
    'authCode': authCode,
  };

  factory ServerConfig.fromJson(Map<String, dynamic> json) => ServerConfig(
    host: json['host'] ?? '',
    port: json['port'] ?? 3088,
    token: json['token'] ?? '',
    useHttps: json['useHttps'] ?? false,
    npsAddress: json['npsAddress'] ?? '',
    authCode: json['authCode'] ?? '',
  );
}
