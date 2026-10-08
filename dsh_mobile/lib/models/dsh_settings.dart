class ModelItem {
  final String id;
  final String name;
  final int? contextWindow;
  final int? maxTokens;

  ModelItem({
    required this.id,
    required this.name,
    this.contextWindow,
    this.maxTokens,
  });

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
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'contextWindow': contextWindow,
    'maxTokens': maxTokens,
  };
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
