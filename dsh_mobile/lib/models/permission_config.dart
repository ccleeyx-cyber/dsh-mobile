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
    final rawSessions = json['sessionPolicies'] as Map<String, dynamic>? ?? {};
    return PermissionConfig(
      defaultPolicy: json['defaultPolicy'] ?? 'ask',
      sandboxMode: json['sandboxMode'] ?? 'workspace-write',
      maxSteps: json['maxSteps'] is int ? json['maxSteps'] : 30,
      protectGit: json['protectGit'] ?? true,
      sessionPolicies: rawSessions.map((k, v) => MapEntry(k, v.toString())),
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
