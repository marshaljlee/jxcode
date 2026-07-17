import 'package:flutter_bloc/flutter_bloc.dart';

import '../../services/session_repository.dart';
import 'session_event.dart';
import 'session_state.dart';

class SessionBloc extends Bloc<SessionEvent, SessionState> {
  final SessionRepository _repository;

  SessionBloc({required this._repository})
      : super(const SessionState()) {
    on<LoadSessions>(_onLoadSessions);
    on<CreateSession>(_onCreateSession);
    on<SelectSession>(_onSelectSession);
    on<DeleteSession>(_onDeleteSession);
    on<PinSession>(_onPinSession);
  }

  Future<void> _onLoadSessions(
    LoadSessions event,
    Emitter<SessionState> emit,
  ) async {
    emit(state.copyWith(isLoading: true));
    try {
      final sessions = await _repository.getSessions(event.projectId);
      emit(state.copyWith(sessions: sessions, isLoading: false));
    } catch (_) {
      emit(state.copyWith(isLoading: false));
    }
  }

  Future<void> _onCreateSession(
    CreateSession event,
    Emitter<SessionState> emit,
  ) async {
    try {
      final session =
          await _repository.createSession(event.projectId);
      final sessions = [...state.sessions, session];
      emit(state.copyWith(
        sessions: sessions,
        selectedSession: session,
      ));
    } catch (_) {
      // Silently fail; session creation is non-critical
    }
  }

  void _onSelectSession(
    SelectSession event,
    Emitter<SessionState> emit,
  ) {
    emit(state.copyWith(selectedSession: event.session));
  }

  Future<void> _onDeleteSession(
    DeleteSession event,
    Emitter<SessionState> emit,
  ) async {
    try {
      await _repository.deleteSession(event.session.id);
      final sessions = state.sessions
          .where((s) => s.id != event.session.id)
          .toList();
      final selected = state.selectedSession?.id == event.session.id
          ? null
          : state.selectedSession;
      emit(state.copyWith(
        sessions: sessions,
        selectedSession: selected,
      ));
    } catch (_) {
      // Silently fail
    }
  }

  Future<void> _onPinSession(
    PinSession event,
    Emitter<SessionState> emit,
  ) async {
    try {
      final updated = event.session.copyWith(
        isPinned: !event.session.isPinned,
      );
      await _repository.updateSession(updated);
      final sessions = state.sessions.map((s) {
        return s.id == updated.id ? updated : s;
      }).toList();
      emit(state.copyWith(
        sessions: sessions,
        selectedSession: updated,
      ));
    } catch (_) {
      // Silently fail
    }
  }
}
