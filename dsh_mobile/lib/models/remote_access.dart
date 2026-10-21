/// 「远程接入」的统一状态（[refactor 2026-10-21]）。
///
/// ## 为什么需要这个模型
///
/// NPS 与 cloudflared 解决的是**同一件事**（让手机从公网到达本机），只是出口
/// 不同，所以它们是同一个能力的两种 `provider`，**严格互斥**。
///
/// 之前 App 把两者当成两个功能：NPS 的地址在服务端配置里、cloudflared 的开关在
/// 手机页面上。结果是用户既不知道两者是二选一，也不知道"该填哪个地址"，而且
/// 隧道没开时手机根本连不上、点不到那个开关（死循环）。
///
/// 现在客户端只读这份状态：走哪条路、公网地址是什么、就绪了吗、为什么没就绪。
/// 进程怎么起是服务端的事。
class RemoteAccessState {
  /// `none` / `nps` / `cloudflared`。
  final String provider;

  /// 谁在管理出口：`none` / `external`（用户自己的反代）/ `gateway`（网关起的隧道）。
  final String managed;

  /// 公网地址；`none` 或隧道没起时是 null。
  final String? publicUrl;

  /// 局域网地址（永远有值，除非网关自己不知道）。
  final String localUrl;

  /// 是否可用。注意 `nps` 的 ready 只代表"配置完整"——网关没有能力验证一个
  /// 外部反代到底通不通；cloudflared 则必须等到边缘注册成功。
  final bool ready;

  /// 没就绪（或有风险）的原因。空串表示没有问题。
  final String reason;

  final int tlsPort;
  final String? certFingerprint;

  const RemoteAccessState({
    required this.provider,
    required this.managed,
    required this.publicUrl,
    required this.localUrl,
    required this.ready,
    required this.reason,
    required this.tlsPort,
    required this.certFingerprint,
  });

  factory RemoteAccessState.fromJson(Map<String, dynamic> json) {
    final url = json['publicUrl']?.toString() ?? '';
    return RemoteAccessState(
      provider: json['provider']?.toString() ?? 'none',
      managed: json['managed']?.toString() ?? 'none',
      publicUrl: url.isEmpty ? null : url,
      localUrl: json['localUrl']?.toString() ?? '',
      ready: json['ready'] == true,
      reason: json['reason']?.toString() ?? '',
      tlsPort: json['tlsPort'] is num ? (json['tlsPort'] as num).toInt() : 0,
      certFingerprint: (json['certFingerprint']?.toString() ?? '').isEmpty
          ? null
          : json['certFingerprint'].toString(),
    );
  }

  /// 供 UI 直接显示的中文名。
  String get providerLabel => switch (provider) {
        'nps' => '自建反向代理（NPS）',
        'cloudflared' => '临时隧道（cloudflared）',
        _ => '未开启（仅局域网）',
      };

  /// 通道由谁决定 —— 界面上必须说清，否则用户会在手机上找开关。
  String get managedLabel => switch (managed) {
        'external' => '由你的反向代理提供',
        'gateway' => '由网关自动建立',
        _ => '未配置',
      };
}
