import 'package:equatable/equatable.dart';

class ChatSession extends Equatable {
  final String id;
  final String projectId;
  final String? name;
  final DateTime createdAt;
  final DateTime updatedAt;
  final bool isPinned;
  final int messageCount;
  final String? modelOverride;
  final String? effortOverride;
  final bool isCompleted;

  const ChatSession({
    required this.id,
    required this.projectId,
    this.name,
    required this.createdAt,
    required this.updatedAt,
    this.isPinned = false,
    this.messageCount = 0,
    this.modelOverride,
    this.effortOverride,
    this.isCompleted = false,
  });

  ChatSession copyWith({
    String? id,
    String? projectId,
    String? name,
    DateTime? createdAt,
    DateTime? updatedAt,
    bool? isPinned,
    int? messageCount,
    String? modelOverride,
    String? effortOverride,
    bool? isCompleted,
  }) {
    return ChatSession(
      id: id ?? this.id,
      projectId: projectId ?? this.projectId,
      name: name ?? this.name,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      isPinned: isPinned ?? this.isPinned,
      messageCount: messageCount ?? this.messageCount,
      modelOverride: modelOverride ?? this.modelOverride,
      effortOverride: effortOverride ?? this.effortOverride,
      isCompleted: isCompleted ?? this.isCompleted,
    );
  }

  @override
  List<Object?> get props => [
    id, projectId, name, createdAt, updatedAt,
    isPinned, messageCount, modelOverride, effortOverride, isCompleted,
  ];
}
