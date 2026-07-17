import 'package:equatable/equatable.dart';

import '../../models/chat_message.dart';

class ChatState extends Equatable {
  final List<ChatMessage> messages;
  final bool isStreaming;
  final String? currentSessionId;
  final String? error;

  const ChatState({
    this.messages = const [],
    this.isStreaming = false,
    this.currentSessionId,
    this.error,
  });

  ChatState copyWith({
    List<ChatMessage>? messages,
    bool? isStreaming,
    String? currentSessionId,
    String? error,
    bool clearError = false,
  }) {
    return ChatState(
      messages: messages ?? this.messages,
      isStreaming: isStreaming ?? this.isStreaming,
      currentSessionId: currentSessionId ?? this.currentSessionId,
      error: clearError ? null : (error ?? this.error),
    );
  }

  @override
  List<Object?> get props => [messages, isStreaming, currentSessionId, error];
}
