import 'dart:convert';

class StreamEvent {
  final String type;
  final Map<String, dynamic> data;

  const StreamEvent({required this.type, required this.data});

  factory StreamEvent.fromJson(Map<String, dynamic> json) {
    return StreamEvent(
      type: json['type'] as String? ?? 'unknown',
      data: Map<String, dynamic>.from(json['data'] as Map? ?? {}),
    );
  }

  factory StreamEvent.fromLine(String line) {
    try {
      final json = jsonDecode(line) as Map<String, dynamic>;
      return StreamEvent.fromJson(json);
    } catch (_) {
      return StreamEvent(type: 'unknown', data: {'raw': line});
    }
  }

  bool get isText => type == 'text_delta' || type == 'text';
  bool get isThinking => type == 'thinking' || type == 'thinking_delta';
  bool get isToolUse => type == 'tool_use' || type == 'tool_start';
  bool get isToolResult => type == 'tool_result';
  bool get isError => type == 'error';
  bool get isDone => type == 'done' || type == 'complete';
  bool get isAskUserQuestion => type == 'ask_user_question';
  bool get isPermissionRequest => type == 'permission_request';

  String? get textContent => data['text'] as String? ?? data['content'] as String?;
  String? get toolName => data['tool_name'] as String? ?? data['name'] as String?;
  String? get toolUseId => data['tool_use_id'] as String? ?? data['id'] as String?;
  Map<String, dynamic>? get toolInput => data['input'] as Map<String, dynamic>?;
  String? get errorMessage => data['error'] as String? ?? data['message'] as String?;

  @override
  String toString() => 'StreamEvent(type: $type)';
}
