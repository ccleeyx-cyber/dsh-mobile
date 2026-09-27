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

  factory ModelItem.fromJson(Map<String, dynamic> json) {
    return ModelItem(
      id: json['id'] ?? '',
      name: json['name'] ?? json['id'] ?? '',
      contextWindow: json['contextWindow'],
      maxTokens: json['maxTokens'],
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
      currentModel: json['currentModel'] ?? 'cn:deepseek-v4.1-flash',
      currentProvider: json['currentProvider'] ?? 'wb',
      availableModels: rawList.map((m) => ModelItem.fromJson(m as Map<String, dynamic>)).toList(),
      dshHost: json['dshHost'] ?? '127.0.0.1:3080',
      bridgePort: json['bridgePort'] ?? 3088,
    );
  }
}
