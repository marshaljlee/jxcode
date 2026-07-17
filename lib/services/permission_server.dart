import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models/permission_request.dart';

/// Returned by the [PermissionServer.onRequest] closure to indicate how
/// a given permission request should be resolved.
class PermissionDecision {
  final bool allowed;
  final String? updatedInput;
  final String? reason;

  const PermissionDecision({
    required this.allowed,
    this.updatedInput,
    this.reason,
  });

  static const allow = PermissionDecision(allowed: true);
  static const deny = PermissionDecision(allowed: false);

  Map<String, dynamic> toJson() => {
    'allowed': allowed,
    if (updatedInput != null) 'updated_input': updatedInput,
    if (reason != null) 'reason': reason,
  };
}

/// Local HTTP server that handles incoming permission requests from the
/// Claude CLI's PreToolUse hook.
///
/// Listens on ports 19836-19846 (inclusive) and exposes a POST /permission
/// endpoint. Each request carries tool metadata; the server waits for a
/// [PermissionDecision] via the [onRequest] callback and returns the
/// decision to the CLI.
class PermissionServer {
  HttpServer? _server;
  StreamSubscription<HttpRequest>? _requestSubscription;
  final StreamController<Map<String, dynamic>> _incomingController =
      StreamController<Map<String, dynamic>>.broadcast();
  final StreamController<PermissionRequest> _requestController =
      StreamController<PermissionRequest>.broadcast();

  /// Callback invoked for every incoming permission request.
  ///
  /// Return a [PermissionDecision] to allow or deny. Returning `null`
  /// leaves the request pending (the connection stays open until a
  /// decision is provided via [approve] / [deny]).
  Future<PermissionDecision?> Function(Map<String, dynamic> request)?
      onRequest;

  /// The port the server is actually listening on (set after [start]).
  int? get port => _server?.port;

  /// Stream of raw incoming request payloads (tool_use_id, tool_name,
  /// input, command, etc.).
  Stream<Map<String, dynamic>> get onIncomingRequest => _incomingController.stream;

  /// Stream of parsed [PermissionRequest] objects.
  Stream<PermissionRequest> get onPermissionRequest => _requestController.stream;

  /// Starts the HTTP server. Tries ports 19836-19846 in sequence.
  ///
  /// Returns the port the server bound to, or throws if all ports are
  /// occupied.
  Future<int> start() async {
    HttpServer? bound;
    for (int port = 19836; port <= 19846; port++) {
      try {
        bound = await HttpServer.bind(
          InternetAddress.loopbackIPv4,
          port,
        );
        break;
      } on SocketException {
        continue;
      }
    }

    if (bound == null) {
      throw StateError(
        'PermissionServer could not bind to any port in range 19836-19846',
      );
    }

    _server = bound;

    _requestSubscription = _server!.listen(
      _handleRequest,
      onError: (Object error) {
        _incomingController.addError(error);
      },
    );

    return bound.port;
  }

  /// Approves a pending permission request identified by [requestId].
  ///
  /// Optionally provides [updatedInput] to modify the tool input before
  /// execution.
  Future<void> approve(String requestId, {String? updatedInput}) async {
    await _resolvePending(requestId, PermissionDecision(
      allowed: true,
      updatedInput: updatedInput,
    ));
  }

  /// Denies a pending permission request identified by [requestId].
  Future<void> deny(String requestId) async {
    await _resolvePending(requestId, PermissionDecision.deny);
  }

  /// Approves the request and remembers the decision for the remainder
  /// of the current session.
  Future<void> allowSession(String requestId) async {
    await _resolvePending(requestId, const PermissionDecision(
      allowed: true,
      reason: 'session',
    ));
  }

  /// Directly inject a permission request into the stream (used by the
  /// Bloc for testing or re-routing).
  void submitRequest(PermissionRequest request) {
    _requestController.add(request);
  }

  /// Stops the server and releases all resources.
  void dispose() {
    _requestSubscription?.cancel();
    _requestSubscription = null;
    _server?.close(force: true);
    _server = null;
    _incomingController.close();
    _requestController.close();
  }

  // ---------------------------------------------------------------------------
  // Private
  // ---------------------------------------------------------------------------

  void _handleRequest(HttpRequest request) {
    if (request.method != 'POST' || request.uri.path != '/permission') {
      request.response
        ..statusCode = 404
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({'error': 'Not found'}));
      request.response.close();
      return;
    }

    request
        .cast<List<int>>()
        .transform(utf8.decoder)
        .join()
        .then((String body) {
      Map<String, dynamic> payload;
      try {
        payload = jsonDecode(body) as Map<String, dynamic>;
      } catch (_) {
        request.response
          ..statusCode = 400
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({'error': 'Invalid JSON'}));
        request.response.close();
        return;
      }

      _incomingController.add(payload);

      final permissionRequest = PermissionRequest(
        id: payload['tool_use_id'] as String? ??
            DateTime.now().millisecondsSinceEpoch.toString(),
        command: payload['command'] as String? ?? '',
        toolName: payload['tool_name'] as String? ?? '',
        toolInput: payload['input'] as Map<String, dynamic>?,
        timestamp: DateTime.now(),
        sessionId: payload['session_id'] as String?,
      );
      _requestController.add(permissionRequest);

      final handler = onRequest;
      if (handler != null) {
        handler(payload).then((PermissionDecision? decision) {
          if (decision != null) {
            _sendResponse(request, decision);
          }
          // If decision is null the caller will respond via
          // [approve] / [deny] later.
        });
      }
      // If no handler, the connection stays open — the caller must
      // respond via [approve] / [deny].
    });
  }

  void _sendResponse(HttpRequest request, PermissionDecision decision) {
    request.response
      ..statusCode = 200
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(decision.toJson()));
    request.response.close();
  }

  final Map<String, _PendingRequest> _pending = {};

  Future<void> _resolvePending(
    String requestId,
    PermissionDecision decision,
  ) async {
    final pending = _pending.remove(requestId);
    if (pending != null) {
      _sendResponse(pending.request, decision);
    }
  }

}

class _PendingRequest {
  final HttpRequest request;
  final Completer<void> completer;

  const _PendingRequest({
    required this.request,
    required this.completer,
  });
}
