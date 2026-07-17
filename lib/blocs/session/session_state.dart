import '../../models/chat_session.dart';

class SessionState {
  final List<ChatSession> sessions;
  final ChatSession? selectedSession;
  final bool isLoading;

  const SessionState({
    this.sessions = const [],
    this.selectedSession,
    this.isLoading = false,
  });

  SessionState copyWith({
    List<ChatSession>? sessions,
    ChatSession? selectedSession,
    bool? isLoading,
  }) {
    return SessionState(
      sessions: sessions ?? this.sessions,
      selectedSession: selectedSession ?? this.selectedSession,
      isLoading: isLoading ?? this.isLoading,
    );
  }
}
