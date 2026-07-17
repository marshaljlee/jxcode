import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';

import '../../models/permission_request.dart';
import '../../services/permission_server.dart' hide PermissionDecision;
import 'permission_event.dart';
import 'permission_state.dart';

class PermissionBloc extends Bloc<PermissionEvent, PermissionState> {
  final PermissionServer _permissionServer;
  StreamSubscription<PermissionRequest>? _requestSubscription;

  PermissionBloc({required this._permissionServer})
      : super(const PermissionState()) {
    on<RequestPermission>(_onRequestPermission);
    on<ApprovePermission>(_onApprovePermission);
    on<DenyPermission>(_onDenyPermission);
    on<SessionAllow>(_onSessionAllow);
    on<SetPermissionMode>(_onSetPermissionMode);

    _requestSubscription = _permissionServer.onPermissionRequest.listen(
      (request) {
        if (!isClosed) {
          add(RequestPermission(request: request));
        }
      },
    );
  }

  void _onRequestPermission(
    RequestPermission event,
    Emitter<PermissionState> emit,
  ) {
    final pending = [...state.pendingRequests, event.request];

    PermissionDecision? autoDecision;
    switch (state.currentMode) {
      case PermissionMode.approveAll:
      case PermissionMode.safe:
        autoDecision = PermissionDecision.allowed;
      case PermissionMode.denyAll:
        autoDecision = PermissionDecision.denied;
      case PermissionMode.interactive:
      case PermissionMode.custom:
      case PermissionMode.moderate:
      case PermissionMode.high:
      case PermissionMode.session:
        autoDecision = null;
    }

    if (autoDecision != null) {
      emit(state.copyWith(lastDecision: autoDecision));
    } else {
      emit(state.copyWith(pendingRequests: pending));
    }
  }

  Future<void> _onApprovePermission(
    ApprovePermission event,
    Emitter<PermissionState> emit,
  ) async {
    await _permissionServer.approve(
      event.requestId,
      updatedInput: event.updatedInput,
    );
    _removeRequest(event.requestId, emit);
    emit(state.copyWith(lastDecision: PermissionDecision.allowed));
  }

  Future<void> _onDenyPermission(
    DenyPermission event,
    Emitter<PermissionState> emit,
  ) async {
    await _permissionServer.deny(event.requestId);
    _removeRequest(event.requestId, emit);
    emit(state.copyWith(lastDecision: PermissionDecision.denied));
  }

  Future<void> _onSessionAllow(
    SessionAllow event,
    Emitter<PermissionState> emit,
  ) async {
    await _permissionServer.allowSession(event.requestId);
    _removeRequest(event.requestId, emit);
    emit(state.copyWith(lastDecision: PermissionDecision.allowedOnce));
  }

  void _onSetPermissionMode(
    SetPermissionMode event,
    Emitter<PermissionState> emit,
  ) {
    emit(state.copyWith(currentMode: event.mode));
  }

  void _removeRequest(
    String requestId,
    Emitter<PermissionState> emit,
  ) {
    final remaining = state.pendingRequests
        .where((r) => r.id != requestId)
        .toList();
    emit(state.copyWith(pendingRequests: remaining));
  }

  @override
  Future<void> close() {
    _requestSubscription?.cancel();
    return super.close();
  }
}
