/// 审批与权限配置。
///
/// ## 为什么只有执行策略
///
/// 网关的 payload 里还有 `sandboxMode` / `maxSteps` / `protectGit` 三个字段，
/// 它们**只在网关侧被校验、存储、回显，全链路没有任何消费者**：引擎不认识它们，
/// 网关也不拿它们做任何判断（真正驱动行为的是 `defaultPolicy`，见网关审批路径里
/// 的 `effectivePolicy`）。此前 App 把这三个渲染成「沙箱提权」「敏感目录防护」
/// 「单轮步数上限」三个控件，等于让用户改一个不影响任何东西的开关 —— 尤其
/// 「敏感目录防护」的文案还承诺拦截 `.git`/`.dsh` 的写入，而实现并不存在。
///
/// 现在不再建模、也不再生效（toJson 不发这三个字段）。网关为了兼容已安装的旧版
/// App 仍然接收并保存它们，属于遗留数据，不是可配置项。
class PermissionConfig {
  final String defaultPolicy; // 'ask' | 'auto-read' | 'danger-full-access'
  final Map<String, String> sessionPolicies;

  PermissionConfig({
    this.defaultPolicy = 'ask',
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

    return PermissionConfig(
      // `executionPolicy` 是网关 payload 里的同义字段，历史上两者都出现过。
      defaultPolicy: json['defaultPolicy']?.toString() ?? json['executionPolicy']?.toString() ?? 'ask',
      sessionPolicies: rawSessions.map((k, v) => MapEntry(k.toString(), v.toString())),
    );
  }

  Map<String, dynamic> toJson() => {
        'defaultPolicy': defaultPolicy,
        'sessionPolicies': sessionPolicies,
      };

  PermissionConfig copyWith({
    String? defaultPolicy,
    Map<String, String>? sessionPolicies,
  }) {
    return PermissionConfig(
      defaultPolicy: defaultPolicy ?? this.defaultPolicy,
      sessionPolicies: sessionPolicies ?? Map.from(this.sessionPolicies),
    );
  }
}
