import 'package:equatable/equatable.dart';

import '../../models/chat_message.dart';
import '../../models/stream_event.dart';

sealed class ChatEvent extends Equatable {
  const ChatEvent();

  @override
  List<Object?> get props => [];
}

class SendMessage extends ChatEvent {
  final String text;
  final List<Attachment>? attachments;

  const SendMessage({required this.text, this.attachments});

  @override
  List<Object?> get props => [text, attachments];
}

class MessageReceived extends ChatEvent {
  final ChatMessage message;

  const MessageReceived({required this.message});

  @override
  List<Object?> get props => [message];
}

class StreamEventReceived extends ChatEvent {
  final StreamEvent event;

  const StreamEventReceived({required this.event});

  @override
  List<Object?> get props => [event];
}

class ClearSession extends ChatEvent {
  const ClearSession();
}

class CancelStream extends ChatEvent {
  const CancelStream();
}
