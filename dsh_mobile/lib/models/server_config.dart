class ServerConfig {
  /// Stable identity used by the saved-gateway list.
  ///
  /// Empty for a config written before multi-gateway support existed;
  /// `StorageService` assigns one when it loads or saves, so callers never have
  /// to invent an id themselves.
  String id;

  /// User-visible label in the gateway switcher. May be empty — see
  /// [displayName] for the fallback.
  String name;

  String host;
  int port;
  String token;
  bool useHttps;

  String npsAddress;
  String authCode;

  /// 配对时网关分配的设备 id（dev_xxxxxxxx）。
  ///
  /// [feat 2026-10-12] 电脑端撤销设备会向**所有**在线客户端广播
  /// {type:'device_revoked', deviceId}；只有本机 id 命中时才清凭据断连，
  /// 否则多台手机会互相误伤。
  String deviceId;

  ServerConfig({
    this.id = '',
    this.name = '',
    required this.host,
    this.port = 3088,
    required this.token,
    this.useHttps = false,
    this.npsAddress = '',
    this.authCode = '',
    this.deviceId = '',
  });

  /// What the switcher shows. Falls back to the host so an unnamed gateway is
  /// still distinguishable, and to a literal only when there is nothing at all.
  String get displayName {
    final n = name.trim();
    if (n.isNotEmpty) return n;
    final h = host.trim();
    return h.isEmpty ? '未命名网关' : h;
  }

  /// An independent copy. Pass [id]: '' to force a fresh identity, which is how
  /// "save as new gateway" avoids overwriting the one being edited.
  ServerConfig clone({String? id, String? name}) => ServerConfig(
        id: id ?? this.id,
        name: name ?? this.name,
        host: host,
        port: port,
        token: token,
        useHttps: useHttps,
        npsAddress: npsAddress,
        authCode: authCode,
        deviceId: deviceId,
      );

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
    // Token deliberately NOT in the query string anymore: URLs end up in proxy
    // access logs, analytics and OS-level network diagnostics. The gateway
    // accepts the same headers as HTTP (Authorization / x-dsh-token), and
    // WebSocketChannel.connect passes them through. The query fallback remains
    // only for gateways predating header auth — they ignored headers, so a
    // 401 there triggers the client's auth-failure path cleanly.
    return '$scheme://$cleanHost:$cleanPort/mobile-ws';
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'host': host,
    'port': port,
    'token': token,
    'useHttps': useHttps,
    'npsAddress': npsAddress,
    'authCode': authCode,
    'deviceId': deviceId,
  };

  // Tolerant readers. A config written by an older build has no id/name at all,
  // and SharedPreferences gives back whatever JSON produced, so a numeric port
  // or a non-string field must not throw the whole load away — the previous
  // `json['host'] ?? ''` form did exactly that.
  static String _str(dynamic v) => v == null ? '' : v.toString();

  static int _int(dynamic v, int fallback) {
    if (v == null) return fallback;
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v.toString().trim()) ?? fallback;
  }

  factory ServerConfig.fromJson(Map<String, dynamic> json) => ServerConfig(
    id: _str(json['id']),
    name: _str(json['name']),
    host: _str(json['host']),
    port: _int(json['port'], 3088),
    token: _str(json['token']),
    useHttps: json['useHttps'] == true || json['useHttps'] == 'true',
    npsAddress: _str(json['npsAddress']),
    authCode: _str(json['authCode']),
    deviceId: _str(json['deviceId']),
  );
}
