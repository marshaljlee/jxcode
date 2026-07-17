import 'package:equatable/equatable.dart';

enum MessageRole { user, assistant, system, thinking, toolResult }

enum MessageStatus { sending, streaming, complete, error }

class ChatMessage extends Equatable {
  final String id;
  final String sessionId;
  final MessageRole role;
  final String content;
  final MessageStatus status;
  final DateTime timestamp;
  final List<Attachment> attachments;
  final String? toolUseId;
  final String? toolName;

  const ChatMessage({
    required this.id,
    required this.sessionId,
    required this.role,
    required this.content,
    this.status = MessageStatus.complete,
    required this.timestamp,
    this.attachments = const [],
    this.toolUseId,
    this.toolName,
  });

  ChatMessage copyWith({
    String? id,
    String? sessionId,
    MessageRole? role,
    String? content,
    MessageStatus? status,
    DateTime? timestamp,
    List<Attachment>? attachments,
    String? toolUseId,
    String? toolName,
  }) {
    return ChatMessage(
      id: id ?? this.id,
      sessionId: sessionId ?? this.sessionId,
      role: role ?? this.role,
      content: content ?? this.content,
      status: status ?? this.status,
      timestamp: timestamp ?? this.timestamp,
      attachments: attachments ?? this.attachments,
      toolUseId: toolUseId ?? this.toolUseId,
      toolName: toolName ?? this.toolName,
    );
  }

  @override
  List<Object?> get props => [
    id, sessionId, role, content, status, timestamp,
    attachments, toolUseId, toolName,
  ];
}

class Attachment extends Equatable {
  final String id;
  final String? filePath;
  final String? url;
  final String? mimeType;
  final String? fileName;

  const Attachment({
    required this.id,
    this.filePath,
    this.url,
    this.mimeType,
    this.fileName,
  });

  @override
  List<Object?> get props => [id, filePath, url, mimeType, fileName];
}
