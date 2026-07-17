import 'package:equatable/equatable.dart';

import '../../models/permission_request.dart';

class PermissionState extends Equatable {
  final List<PermissionRequest> pendingRequests;
  final PermissionMode currentMode;
  final PermissionDecision? lastDecision;

  const PermissionState({
    this.pendingRequests = const [],
    this.currentMode = PermissionMode.interactive,
    this.lastDecision,
  });

  PermissionState copyWith({
    List<PermissionRequest>? pendingRequests,
    PermissionMode? currentMode,
    PermissionDecision? lastDecision,
    bool clearLastDecision = false,
  }) {
    return PermissionState(
      pendingRequests: pendingRequests ?? this.pendingRequests,
      currentMode: currentMode ?? this.currentMode,
      lastDecision: clearLastDecision ? null : (lastDecision ?? this.lastDecision),
    );
  }

  @override
  List<Object?> get props => [pendingRequests, currentMode, lastDecision];
}
