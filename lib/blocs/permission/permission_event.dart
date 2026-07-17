import 'package:equatable/equatable.dart';

import '../../models/permission_request.dart';

sealed class PermissionEvent extends Equatable {
  const PermissionEvent();

  @override
  List<Object?> get props => [];
}

class RequestPermission extends PermissionEvent {
  final PermissionRequest request;

  const RequestPermission({required this.request});

  @override
  List<Object?> get props => [request];
}

class ApprovePermission extends PermissionEvent {
  final String requestId;
  final String? updatedInput;

  const ApprovePermission({required this.requestId, this.updatedInput});

  @override
  List<Object?> get props => [requestId, updatedInput];
}

class DenyPermission extends PermissionEvent {
  final String requestId;

  const DenyPermission({required this.requestId});

  @override
  List<Object?> get props => [requestId];
}

class SessionAllow extends PermissionEvent {
  final String requestId;

  const SessionAllow({required this.requestId});

  @override
  List<Object?> get props => [requestId];
}

class SetPermissionMode extends PermissionEvent {
  final PermissionMode mode;

  const SetPermissionMode({required this.mode});

  @override
  List<Object?> get props => [mode];
}
