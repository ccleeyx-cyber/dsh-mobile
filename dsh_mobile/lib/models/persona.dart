class AgentPersona {
  final String id;
  final String title;
  final String icon;
  final String description;
  final String prompt;
  final bool isCustom;

  AgentPersona({
    required this.id,
    required this.title,
    required this.icon,
    required this.description,
    required this.prompt,
    this.isCustom = false,
  });

  factory AgentPersona.fromJson(Map<String, dynamic> json) {
    return AgentPersona(
      id: json['id'] ?? '',
      title: json['title'] ?? '',
      icon: json['icon'] ?? 'code',
      description: json['description'] ?? '',
      prompt: json['prompt'] ?? '',
      isCustom: json['isCustom'] ?? false,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'icon': icon,
        'description': description,
        'prompt': prompt,
        'isCustom': isCustom,
      };
}
