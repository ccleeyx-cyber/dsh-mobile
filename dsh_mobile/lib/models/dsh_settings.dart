/// 一条可选的大模型。
///
/// ## 为什么带 provider
///
/// [feat 2026-10-22] 用户原话：「模型设置没有分组，需要按不同的供应商分组显示」。
/// 网关原先把 `cordis.patch.yml` 里 `providers` 的**每个供应商**的模型拍平成一个
/// 数组，供应商身份在拍平那一刻就丢了 —— 手机端再聪明也分不出来。
///
/// 所以服务端现在给每条模型带 `provider` / `providerLabel`，这里如实接住：
///   * `provider` = 配置里的 key（`wb` / `qwen` / …），是分组的**依据**；
///   * `providerLabel` = 配置里的 `displayName`（没配就同 key），是给人看的标题。
///
/// 老网关（1.15.0 之前）没有这两个字段 —— 那种情况下退回"从模型 id 的 `xxx:`
/// 前缀猜"（`cn:deepseek-v4-pro` → `cn`）。猜出来的分组仍然比一个 60 条的平铺
/// 列表有用，且**不冒充**服务端的判断：[providerIsInferred] 会让界面说"按 id 前缀"。
class ModelItem {
  final String id;
  final String name;
  final int? contextWindow;
  final int? maxTokens;

  /// 供应商 id（配置里的 providers key）。老网关回空串。
  final String provider;

  /// 供应商显示名。老网关回空串。
  final String providerLabel;

  ModelItem({
    required this.id,
    required this.name,
    this.contextWindow,
    this.maxTokens,
    this.provider = '',
    this.providerLabel = '',
  });

  /// 分组用的供应商 key：服务端给的优先，否则取 id 前缀，都没有才归「未分组」。
  String get providerKey {
    if (provider.trim().isNotEmpty) return provider.trim();
    final prefix = _idPrefix;
    return prefix.isNotEmpty ? prefix : '未分组';
  }

  /// 分组标题：`providerLabel` 优先，否则用 key。
  String get providerTitle {
    final label = providerLabel.trim();
    if (label.isNotEmpty) return label;
    return providerKey;
  }

  /// 这个分组是不是**推出来的**（老网关没给 provider）。
  bool get providerIsInferred => provider.trim().isEmpty;

  /// `cn:deepseek-v4-pro` → `cn`；没有冒号就是空串（不瞎猜）。
  String get _idPrefix {
    final idx = id.indexOf(':');
    if (idx <= 0) return '';
    return id.substring(0, idx);
  }

  static int? _parseInt(dynamic v) {
    if (v == null) return null;
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v.toString());
  }

  factory ModelItem.fromJson(Map<String, dynamic> json) {
    return ModelItem(
      id: json['id']?.toString() ?? '',
      name: json['name']?.toString() ?? json['id']?.toString() ?? '',
      contextWindow: _parseInt(json['contextWindow']),
      maxTokens: _parseInt(json['maxTokens']),
      provider: json['provider']?.toString() ?? '',
      providerLabel: json['providerLabel']?.toString() ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'contextWindow': contextWindow,
    'maxTokens': maxTokens,
    'provider': provider,
    'providerLabel': providerLabel,
  };
}

/// 按供应商分组后的一组模型（界面层的视图模型，不从 JSON 解析）。
class ModelGroup {
  final String key;
  final String title;
  final bool inferred;
  final List<ModelItem> models;

  const ModelGroup({
    required this.key,
    required this.title,
    required this.inferred,
    required this.models,
  });
}

/// 把一条平铺的模型列表折成「按供应商分组」，保持服务端给的顺序。
///
/// 顺序是有意义的：`providers` 在配置里的先后就是用户心里的先后，重新按字母
/// 排序会把最常用的那一组挤到后面。组内顺序同样原样保留。
List<ModelGroup> groupModelsByProvider(List<ModelItem> models) {
  final order = <String>[];
  final buckets = <String, List<ModelItem>>{};
  final titles = <String, String>{};
  final inferred = <String, bool>{};

  for (final m in models) {
    final key = m.providerKey;
    if (!buckets.containsKey(key)) {
      buckets[key] = <ModelItem>[];
      order.add(key);
      titles[key] = m.providerTitle;
      inferred[key] = m.providerIsInferred;
    }
    buckets[key]!.add(m);
  }

  return order
      .map((key) => ModelGroup(
            key: key,
            title: titles[key] ?? key,
            inferred: inferred[key] ?? false,
            models: buckets[key]!,
          ))
      .toList();
}

class DshSettings {
  final String currentModel;
  final String currentProvider;
  final List<ModelItem> availableModels;
  final String dshHost;
  final int bridgePort;

  DshSettings({
    required this.currentModel,
    required this.currentProvider,
    required this.availableModels,
    required this.dshHost,
    required this.bridgePort,
  });

  /// 当前模型所属的供应商（用于把"使用中"那一组排在最前、以及标题提示）。
  String get currentModelProvider {
    for (final m in availableModels) {
      if (m.id == currentModel) return m.providerKey;
    }
    return currentProvider;
  }

  factory DshSettings.fromJson(Map<String, dynamic> json) {
    final rawList = json['availableModels'] as List<dynamic>? ?? [];
    return DshSettings(
      currentModel: json['currentModel']?.toString() ?? 'cn:deepseek-v4.1-flash',
      currentProvider: json['currentProvider']?.toString() ?? 'wb',
      availableModels: rawList
          .whereType<Map>()
          .map((m) => ModelItem.fromJson(Map<String, dynamic>.from(m)))
          .toList(),
      dshHost: json['dshHost']?.toString() ?? '127.0.0.1:3080',
      bridgePort: ModelItem._parseInt(json['bridgePort']) ?? 3088,
    );
  }
}
