import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';

import '../../models/chat_message.dart';
import '../../models/stream_event.dart';
import '../../services/claude_service.dart';
import '../../services/session_repository.dart';
import '../proxy/proxy_bloc.dart';
import 'chat_event.dart';
import 'chat_state.dart';

class ChatBloc extends Bloc<ChatEvent, ChatState> {
  final ClaudeService _claudeService;
  final SessionRepository _sessionRepo;
  final ProxyBloc? _proxyBloc;
  StreamSubscription<StreamEvent>? _streamSubscription;
  String? _accumulatedContent;

  ChatBloc({
    required this._claudeService,
    required this._sessionRepo,
    this._proxyBloc,
  }) : super(const ChatState()) {
    on<SendMessage>(_onSendMessage);
    on<MessageReceived>(_onMessageReceived);
    on<StreamEventReceived>(_onStreamEventReceived);
    on<ClearSession>(_onClearSession);
    on<CancelStream>(_onCancelStream);
  }

  String _nextId() => DateTime.now().millisecondsSinceEpoch.toString();

  Future<void> _onSendMessage(
    SendMessage event,
    Emitter<ChatState> emit,
  ) async {
    if (state.isStreaming) return;

    final userMessage = ChatMessage(
      id: _nextId(),
      sessionId: state.currentSessionId ?? '',
      role: MessageRole.user,
      content: event.text,
      status: MessageStatus.complete,
      timestamp: DateTime.now(),
      attachments: event.attachments ?? const [],
    );

    final updatedMessages = [...state.messages, userMessage];

    String sessionId = state.currentSessionId ?? '';
    if (sessionId.isEmpty) {
      try {
        final session = await _sessionRepo.createSession(
          '',
          name: event.text.length > 40
              ? '${event.text.substring(0, 40)}...'
              : event.text,
        );
        sessionId = session.id;
      } catch (_) {
        sessionId = _nextId();
      }
    }

    _accumulatedContent = '';

    emit(state.copyWith(
      messages: updatedMessages,
      isStreaming: true,
      currentSessionId: sessionId,
      clearError: true,
    ));

    // Sync proxy config to ClaudeService (used on Android API mode)
    final proxyState = _proxyBloc?.state;
    if (proxyState != null) {
      _claudeService.proxyHost = proxyState.config.customHost.isNotEmpty
          ? Uri.tryParse(proxyState.config.customHost)?.host ?? ClaudeService.defaultProxyHost
          : ClaudeService.defaultProxyHost;
      _claudeService.proxyPort = proxyState.config.port;
    }

    final stream = _claudeService.send(
      text: event.text,
      attachments: event.attachments,
      sessionId: sessionId,
    );

    _streamSubscription = stream.listen(
      (streamEvent) {
        if (!isClosed) {
          add(StreamEventReceived(event: streamEvent));
        }
      },
      onError: (error) {
        if (!isClosed) {
          emit(state.copyWith(
            isStreaming: false,
            error: error.toString(),
          ));
        }
      },
      onDone: () {
        if (!isClosed && _accumulatedContent != null) {
          final assistantMsg = ChatMessage(
            id: _nextId(),
            sessionId: sessionId,
            role: MessageRole.assistant,
            content: _accumulatedContent ?? '',
            status: MessageStatus.complete,
            timestamp: DateTime.now(),
          );
          add(MessageReceived(message: assistantMsg));
        }
      },
    );
  }

  Future<void> _onStreamEventReceived(
    StreamEventReceived event,
    Emitter<ChatState> emit,
  ) async {
    final streamEvent = event.event;

    if (streamEvent.isText && streamEvent.textContent != null) {
      _accumulatedContent = (_accumulatedContent ?? '') + streamEvent.textContent!;

      final messages = [...state.messages];
      final lastMsg = messages.isNotEmpty ? messages.last : null;

      if (lastMsg != null && lastMsg.role == MessageRole.assistant && lastMsg.status == MessageStatus.streaming) {
        messages[messages.length - 1] = lastMsg.copyWith(
          content: _accumulatedContent,
        );
      } else {
        messages.add(ChatMessage(
          id: _nextId(),
          sessionId: state.currentSessionId ?? '',
          role: MessageRole.assistant,
          content: _accumulatedContent ?? '',
          status: MessageStatus.streaming,
          timestamp: DateTime.now(),
        ));
      }

      emit(state.copyWith(messages: messages));
    } else if (streamEvent.isToolUse) {
      final toolMessage = ChatMessage(
        id: _nextId(),
        sessionId: state.currentSessionId ?? '',
        role: MessageRole.toolResult,
        content: 'Tool: ${streamEvent.toolName ?? "unknown"}',
        status: MessageStatus.complete,
        timestamp: DateTime.now(),
        toolUseId: streamEvent.toolUseId,
        toolName: streamEvent.toolName,
      );

      emit(state.copyWith(messages: [...state.messages, toolMessage]));
    } else if (streamEvent.isError) {
      emit(state.copyWith(
        error: streamEvent.errorMessage ?? 'Unknown error',
      ));
    }
  }

  Future<void> _onMessageReceived(
    MessageReceived event,
    Emitter<ChatState> emit,
  ) async {
    final messages = [...state.messages];
    final receivedMsg = event.message;

    final lastIdx = messages.length - 1;
    if (lastIdx >= 0 &&
        messages[lastIdx].role == MessageRole.assistant &&
        messages[lastIdx].status == MessageStatus.streaming) {
      messages[lastIdx] = messages[lastIdx].copyWith(
        content: receivedMsg.content,
        status: MessageStatus.complete,
      );
    } else {
      messages.add(receivedMsg);
    }

    _accumulatedContent = null;

    emit(state.copyWith(
      messages: messages,
      isStreaming: false,
    ));

    try {
      await _sessionRepo.persistMessage(receivedMsg);
    } catch (_) {
      // Non-critical: message persistence is best-effort
    }
  }

  void _onClearSession(ClearSession event, Emitter<ChatState> emit) {
    _streamSubscription?.cancel();
    _accumulatedContent = null;
    emit(const ChatState());
  }

  void _onCancelStream(CancelStream event, Emitter<ChatState> emit) {
    _streamSubscription?.cancel();
    _accumulatedContent = null;
    _claudeService.cancel();
    emit(state.copyWith(isStreaming: false));
  }

  @override
  Future<void> close() {
    _streamSubscription?.cancel();
    return super.close();
  }
}
