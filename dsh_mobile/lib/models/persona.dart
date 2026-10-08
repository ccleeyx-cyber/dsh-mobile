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
      id: json['id']?.toString() ?? '',
      title: json['title']?.toString() ?? '',
      icon: json['icon']?.toString() ?? 'code',
      description: json['description']?.toString() ?? '',
      prompt: json['prompt']?.toString() ?? '',
      isCustom: json['isCustom'] == true || json['isCustom'] == 'true',
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
