class PermissionConfig {
  final String defaultPolicy; // 'ask' | 'auto-read' | 'danger-full-access'
  final String sandboxMode; // 'sandboxed' | 'workspace-write' | 'danger-full-access'
  final int maxSteps;
  final bool protectGit;
  final Map<String, String> sessionPolicies;

  PermissionConfig({
    this.defaultPolicy = 'ask',
    this.sandboxMode = 'workspace-write',
    this.maxSteps = 30,
    this.protectGit = true,
    Map<String, String>? sessionPolicies,
  }) : sessionPolicies = sessionPolicies ?? {};

  String getPolicyForSession(String sessionId) {
    if (sessionPolicies.containsKey(sessionId)) {
      return sessionPolicies[sessionId]!;
    }
    return defaultPolicy;
  }

  factory PermissionConfig.fromJson(Map<String, dynamic> json) {
    final rawSessions = json['sessionPolicies'] is Map
        ? Map<String, dynamic>.from(json['sessionPolicies'] as Map)
        : <String, dynamic>{};

    int parseSteps(dynamic v) {
      if (v is int) return v;
      if (v is num) return v.toInt();
      if (v is String) return int.tryParse(v) ?? 30;
      return 30;
    }

    return PermissionConfig(
      defaultPolicy: json['defaultPolicy']?.toString() ?? json['executionPolicy']?.toString() ?? 'ask',
      sandboxMode: json['sandboxMode']?.toString() ?? 'workspace-write',
      maxSteps: parseSteps(json['maxSteps']),
      protectGit: json['protectGit'] == null ? true : (json['protectGit'] == true || json['protectGit'] == 'true'),
      sessionPolicies: rawSessions.map((k, v) => MapEntry(k.toString(), v.toString())),
    );
  }

  Map<String, dynamic> toJson() => {
        'defaultPolicy': defaultPolicy,
        'sandboxMode': sandboxMode,
        'maxSteps': maxSteps,
        'protectGit': protectGit,
        'sessionPolicies': sessionPolicies,
      };

  PermissionConfig copyWith({
    String? defaultPolicy,
    String? sandboxMode,
    int? maxSteps,
    bool? protectGit,
    Map<String, String>? sessionPolicies,
  }) {
    return PermissionConfig(
      defaultPolicy: defaultPolicy ?? this.defaultPolicy,
      sandboxMode: sandboxMode ?? this.sandboxMode,
      maxSteps: maxSteps ?? this.maxSteps,
      protectGit: protectGit ?? this.protectGit,
      sessionPolicies: sessionPolicies ?? Map.from(this.sessionPolicies),
    );
  }
}
