import 'package:equatable/equatable.dart';

import '../../models/chat_session.dart';

sealed class SessionEvent extends Equatable {
  const SessionEvent();

  @override
  List<Object?> get props => [];
}

class LoadSessions extends SessionEvent {
  final String projectId;

  const LoadSessions({required this.projectId});

  @override
  List<Object?> get props => [projectId];
}

class CreateSession extends SessionEvent {
  final String projectId;

  const CreateSession({required this.projectId});

  @override
  List<Object?> get props => [projectId];
}

class SelectSession extends SessionEvent {
  final ChatSession session;

  const SelectSession({required this.session});

  @override
  List<Object?> get props => [session];
}

class DeleteSession extends SessionEvent {
  final ChatSession session;

  const DeleteSession({required this.session});

  @override
  List<Object?> get props => [session];
}

class PinSession extends SessionEvent {
  final ChatSession session;

  const PinSession({required this.session});

  @override
  List<Object?> get props => [session];
}
