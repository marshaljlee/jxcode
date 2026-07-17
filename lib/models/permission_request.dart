import 'package:equatable/equatable.dart';

enum PermissionMode {
  safe,
  moderate,
  high,
  custom,
  interactive,
  approveAll,
  denyAll,
  session,
}

enum PermissionInteractionMode { interactive, approveAll, denyAll, session }

enum PermissionDecision { pending, allowed, denied, allowedOnce, allowedSession }

class PermissionRequest extends Equatable {
  final String id;
  final String command;
  final String toolName;
  final Map<String, dynamic>? toolInput;
  final PermissionMode riskLevel;
  final PermissionDecision decision;
  final DateTime timestamp;
  final String? sessionId;
  final String? updatedInput;

  const PermissionRequest({
    required this.id,
    required this.command,
    required this.toolName,
    this.toolInput,
    this.riskLevel = PermissionMode.moderate,
    this.decision = PermissionDecision.pending,
    required this.timestamp,
    this.sessionId,
    this.updatedInput,
  });

  PermissionRequest copyWith({
    String? id,
    String? command,
    String? toolName,
    Map<String, dynamic>? toolInput,
    PermissionMode? riskLevel,
    PermissionDecision? decision,
    DateTime? timestamp,
    String? sessionId,
    String? updatedInput,
  }) {
    return PermissionRequest(
      id: id ?? this.id,
      command: command ?? this.command,
      toolName: toolName ?? this.toolName,
      toolInput: toolInput ?? this.toolInput,
      riskLevel: riskLevel ?? this.riskLevel,
      decision: decision ?? this.decision,
      timestamp: timestamp ?? this.timestamp,
      sessionId: sessionId ?? this.sessionId,
      updatedInput: updatedInput ?? this.updatedInput,
    );
  }

  @override
  List<Object?> get props => [
    id, command, toolName, toolInput, riskLevel,
    decision, timestamp, sessionId,
  ];
}
