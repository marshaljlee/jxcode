import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models/chat_message.dart';
import '../models/stream_event.dart';

/// Service that communicates with the Claude LLM.
///
/// **Dual mode:**
/// - **Process mode** (macOS): spawns `jxclaude` as a subprocess and communicates
///   via NDJSON over stdin/stdout.
/// - **API mode** (Android): sends Messages API requests over HTTP/SSE through
///   a local proxy/router (`jxproxy`, default `http://127.0.0.1:5255/v1/messages`).
///
/// Mode is auto-detected from [Platform.isAndroid] at send time.
class ClaudeService {
  // ---------------------------------------------------------------------------
  // Process-mode state (macOS)
  // ---------------------------------------------------------------------------

  Process? _process;
  StreamController<String>? _lineController;
  StreamSubscription<String>? _stdoutSubscription;
  StreamSubscription<String>? _stderrSubscription;
  bool _isRunning = false;
  String _stderrBuffer = '';
  int _processId = 0;

  /// Path to the jxclaude binary — used in process mode (macOS).
  final String claudePath;

  final Duration startTimeout;
  final Duration killGracePeriod;

  // ---------------------------------------------------------------------------
  // API-mode state (Android)
  // ---------------------------------------------------------------------------

  HttpClient? _httpClient;
  bool _apiCancelled = false;

  /// Proxy host for API mode (Android). Defaults to [defaultProxyHost].
  String proxyHost;

  /// Proxy port for API mode (Android). Defaults to [defaultProxyPort].
  int proxyPort;

  /// Default proxy host for Android API mode.
  static const String defaultProxyHost = '127.0.0.1';

  /// Default proxy port for Android API mode — matches the [jxproxy] default.
  static const int defaultProxyPort = 5255;

  // ---------------------------------------------------------------------------
  // Construction
  // ---------------------------------------------------------------------------

  ClaudeService({
    this.claudePath = '/Users/joshua/.local/bin/jx-claude',
    this.startTimeout = const Duration(seconds: 15),
    this.killGracePeriod = const Duration(seconds: 5),
    String? proxyHost,
    int? proxyPort,
  }) : proxyHost = proxyHost ?? defaultProxyHost,
       proxyPort = proxyPort ?? defaultProxyPort;

  // ---------------------------------------------------------------------------
  // Platform helpers
  // ---------------------------------------------------------------------------

  /// True when running on Android — API mode will be used.
  bool get _isAndroid {
    try {
      return Platform.isAndroid;
    } catch (_) {
      return false;
    }
  }

  /// Whether the service is in process mode (macOS, subprocess spawned).
  bool get isRunning => _isRunning;

  /// Captured stderr output from the subprocess (process mode only).
  String get stderrBuffer => _stderrBuffer;

  /// Whether the service will use API mode (no subprocess).
  bool get isApiMode => _isAndroid;
}

// =============================================================================
// Process mode — macOS
// =============================================================================

extension ClaudeServiceProcess on ClaudeService {
  /// Spawns the jxclaude subprocess with stream-json input format.
  ///
  /// On Android this is a no-op — use [send] directly (it will use API mode).
  Future<void> spawn() async {
    if (_isAndroid) return; // API mode — no process to spawn

    if (_isRunning) return;
    _stderrBuffer = '';

    _process = await Process.start(
      claudePath,
      ['--input-format', 'stream-json'],
      runInShell: true,
      environment: {
        'CLAUDE_STREAM_FORMAT': 'ndjson',
        if (Platform.environment.containsKey('ANTHROPIC_BASE_URL'))
          'ANTHROPIC_BASE_URL': Platform.environment['ANTHROPIC_BASE_URL']!,
        if (Platform.environment.containsKey('ANTHROPIC_API_KEY'))
          'ANTHROPIC_API_KEY': Platform.environment['ANTHROPIC_API_KEY']!,
        if (Platform.environment.containsKey('ANTHROPIC_AUTH_TOKEN'))
          'ANTHROPIC_AUTH_TOKEN': Platform.environment['ANTHROPIC_AUTH_TOKEN']!,
      },
    );

    _processId = _process!.pid;
    _isRunning = true;

    _lineController = StreamController<String>.broadcast(
      onCancel: () {},
    );

    _stdoutSubscription = _process!.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          (line) {
            if (line.trim().isEmpty) return;
            _lineController!.add(line);
          },
          onError: (error) {
            _lineController?.addError(error);
          },
        );

    _stderrSubscription = _process!.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          (line) {
            _stderrBuffer += '$line\n';
          },
        );

    _process!.exitCode.then((code) {
      _isRunning = false;
      _process = null;
    });

    final deadline = DateTime.now().add(startTimeout);
    while (DateTime.now().isBefore(deadline)) {
      if (_processId > 0 && _process != null) return;
      await Future.delayed(const Duration(milliseconds: 50));
    }

    if (_process == null) {
      throw ProcessException(
        claudePath,
        ['--input-format', 'stream-json'],
        'Process failed to spawn within ${startTimeout.inSeconds}s',
      );
    }
  }

  /// Process-mode send: writes NDJSON to the subprocess stdin and returns
  /// a [Stream] of parsed [StreamEvent]s.
  Stream<StreamEvent> _sendProcess({
    required String text,
    List<Attachment>? attachments,
    String? sessionId,
    String? model,
    String? effort,
  }) {
    if (!_isRunning || _process == null) {
      throw StateError(
        'ClaudeService is not running. Call spawn() before send().',
      );
    }

    final Map<String, dynamic> input = {
      'text': text,
      if (sessionId != null && sessionId.isNotEmpty) 'session_id': sessionId,
      if (model != null) 'model': model,
      if (effort != null) 'effort': effort,
    };

    if (attachments != null && attachments.isNotEmpty) {
      input['attachments'] = attachments.map((a) => {
        'id': a.id,
        if (a.filePath != null) 'file_path': a.filePath,
        if (a.url != null) 'url': a.url,
        if (a.mimeType != null) 'mime_type': a.mimeType,
        if (a.fileName != null) 'file_name': a.fileName,
      }).toList();
    }

    _process!.stdin.writeln(jsonEncode(input));

    final controller = StreamController<StreamEvent>();
    StreamSubscription<String>? sub;

    sub = _lineController!.stream.listen(
      (line) {
        try {
          final event = StreamEvent.fromLine(line);
          controller.add(event);
          if (event.isDone) {
            unawaited(controller.close());
            sub?.cancel();
          }
        } catch (e) {
          controller.add(StreamEvent(
            type: 'unknown',
            data: {'raw': line, 'parse_error': e.toString()},
          ));
        }
      },
      onError: (Object error) {
        if (!controller.isClosed) {
          controller.addError(error);
        }
      },
      onDone: () {
        if (!controller.isClosed) {
          controller.close();
        }
      },
    );

    return controller.stream;
  }

  /// Cancels the current jxclaude process (process mode only).
  void cancelProcess() {
    _process?.kill(ProcessSignal.sigterm);

    Future.delayed(killGracePeriod, () {
      try {
        _process?.kill(ProcessSignal.sigkill);
      } catch (_) {}
    });

    _cleanup();
  }
}

// =============================================================================
// API mode — Android
// =============================================================================

extension ClaudeServiceApi on ClaudeService {
  /// API-mode send: sends a Messages API request through the proxy at
  /// `http://{proxyHost}:{proxyPort}/v1/messages` and returns parsed SSE
  /// events as a [Stream] of [StreamEvent].
  Stream<StreamEvent> _sendApi({
    required String text,
    List<Attachment>? attachments,
    String? sessionId,
    String? model,
    String? effort,
  }) {
    _apiCancelled = false;
    final controller = StreamController<StreamEvent>();

    _streamApiResponse(
      controller: controller,
      text: text,
      attachments: attachments,
      model: model,
      effort: effort,
    );

    return controller.stream;
  }

  /// Performs the HTTP request and feeds SSE events into [controller].
  void _streamApiResponse({
    required StreamController<StreamEvent> controller,
    required String text,
    List<Attachment>? attachments,
    String? model,
    String? effort,
  }) async {
    try {
      final client = _httpClient ??= HttpClient();
      final url = Uri.parse('http://$proxyHost:$proxyPort/v1/messages');

      final payload = <String, dynamic>{
        'model': model ?? 'claude-sonnet-4-6',
        'max_tokens': 4096,
        'stream': true,
        'messages': [
          {'role': 'user', 'content': _buildContent(text, attachments)},
        ],
      };

      if (effort != null) {
        payload['thinking'] = {
          'type': 'enabled',
          'budget_tokens': int.tryParse(effort) ?? 16000,
        };
      }

      final request = await client.postUrl(url);
      request.headers.contentType = ContentType.json;
      request.headers.set('Accept', 'text/event-stream');
      request.write(jsonEncode(payload));

      final response = await request.close();

      if (response.statusCode != 200) {
        final body = await response.transform(utf8.decoder).join();
        controller.addError(
          HttpException('API returned ${response.statusCode}: $body', uri: url),
        );
        unawaited(controller.close());
        return;
      }

      // SSE parser with line buffer
      final parser = SseParser(controller, () => _apiCancelled);
      await for (final chunk in response.transform(utf8.decoder)) {
        if (_apiCancelled || controller.isClosed) break;
        parser.feed(chunk);
      }
      parser.flush();
    } catch (e) {
      if (!controller.isClosed) {
        controller.addError(e);
        unawaited(controller.close());
      }
    }
  }

  /// Builds the `content` field for the Messages API from text and optional
  /// attachments.
  dynamic _buildContent(String text, List<Attachment>? attachments) {
    if (attachments == null || attachments.isEmpty) return text;

    final blocks = <Map<String, dynamic>>[
      {'type': 'text', 'text': text},
    ];
    for (final a in attachments) {
      if (a.filePath != null) {
        blocks.add({
          'type': 'file',
          'source': {
            'type': 'base64',
            'media_type': a.mimeType ?? 'application/octet-stream',
            'data': '', // file content loaded by the caller on Android
          },
        });
      }
    }
    return blocks;
  }

  /// Cancels the current API request (API mode only).
  void cancelApi() {
    _apiCancelled = true;
  }
}

// =============================================================================
// SSE parser
// =============================================================================

/// Streaming SSE (Server-Sent Events) parser.
///
/// Accumulates partial lines across chunks, buffers one complete event at a
/// time, and emits [StreamEvent]s to the controller when a full event is
/// assembled (event type + data lines).
class SseParser {
  final StreamController<StreamEvent> controller;
  final bool Function() isCancelled;

  String _buffer = '';
  String? _currentEvent;
  String _currentData = '';

  SseParser(this.controller, this.isCancelled);

  /// Feed a chunk of text into the parser.
  void feed(String chunk) {
    _buffer += chunk;
    _processBuffer();
  }

  /// Flush any remaining buffered event data.
  void flush() {
    if (_currentData.isNotEmpty) {
      _emitEvent();
    }
  }

  void _processBuffer() {
    while (true) {
      final idx = _buffer.indexOf('\n');
      if (idx < 0) break; // wait for more data

      final line = _buffer.substring(0, idx);
      _buffer = _buffer.substring(idx + 1);
      _processLine(line);
    }
  }

  void _processLine(String line) {
    final trimmed = line.trimRight();

    if (trimmed.isEmpty) {
      // Blank line signals the end of an event
      if (_currentData.isNotEmpty || _currentEvent != null) {
        _emitEvent();
      }
      return;
    }

    if (trimmed.startsWith('event:')) {
      _currentEvent = trimmed.substring(6).trim();
    } else if (trimmed.startsWith('data:')) {
      final dataPart = trimmed.substring(5).trim();
      if (_currentData.isNotEmpty) _currentData += '\n';
      _currentData += dataPart;
    } else if (trimmed.startsWith(':')) {
      // SSE comment line — ignored
    }
    // Other fields (id, retry) silently ignored
  }

  void _emitEvent() {
    if (isCancelled()) return;

    final dataStr = _currentData;
    _currentData = '';
    final eventType = _currentEvent;
    _currentEvent = null;

    if (dataStr == '[DONE]') {
      controller.add(StreamEvent(type: 'done', data: {}));
      return;
    }

    Map<String, dynamic> data;
    try {
      data = jsonDecode(dataStr) as Map<String, dynamic>;
    } catch (_) {
      return; // skip unparseable data
    }

    final mapped = _mapSseToStreamEvent(eventType, data);
    if (mapped != null) {
      controller.add(mapped);
      if (mapped.isDone) {
        // Allow trailing events
      }
    }
  }

  /// Maps an SSE event to a [StreamEvent].
  ///
  /// Returns `null` for events that should be silently ignored (e.g.
  /// `message_start`, `ping`).
  StreamEvent? _mapSseToStreamEvent(String? eventType, Map<String, dynamic> data) {
    final type = data['type'] as String? ?? eventType ?? '';

    switch (type) {
      case 'message_start':
        return null;

      case 'content_block_start':
        final block = data['content_block'] as Map<String, dynamic>?;
        final blockType = block?['type'] as String?;
        if (blockType == 'tool_use') {
          return StreamEvent(
            type: 'tool_use',
            data: {
              'tool_name': block?['name'] ?? '',
              'name': block?['name'] ?? '',
              'input': block?['input'] ?? {},
              'tool_use_id': block?['id'] ?? '',
              'id': block?['id'] ?? '',
            },
          );
        }
        return null;

      case 'content_block_delta':
        final delta = data['delta'] as Map<String, dynamic>?;
        final deltaType = delta?['type'] as String?;
        if (deltaType == 'text_delta') {
          return StreamEvent(
            type: 'text_delta',
            data: {'text': delta?['text'] ?? ''},
          );
        }
        if (deltaType == 'input_json_delta') {
          return StreamEvent(
            type: 'tool_result',
            data: {'text': delta?['partial_json'] ?? ''},
          );
        }
        return null;

      case 'message_delta':
        final msgDelta = data['delta'] as Map<String, dynamic>?;
        final stopReason = msgDelta?['stop_reason'] as String?;
        return StreamEvent(
          type: 'done',
          data: {'stop_reason': stopReason ?? ''},
        );

      case 'message_stop':
        return StreamEvent(type: 'complete', data: {});

      case 'content_block_stop':
        return null; // internal bookkeeping

      case 'ping':
        return null;

      case 'error':
        return StreamEvent(
          type: 'error',
          data: {'error': data['error']?.toString() ?? 'API error'},
        );

      default:
        return StreamEvent(type: 'unknown', data: data);
    }
  }
}

// =============================================================================
// Unified interface
// =============================================================================

extension ClaudeServiceSend on ClaudeService {
  /// Sends a user message and returns a [Stream] of parsed [StreamEvent]s.
  ///
  /// **macOS**: writes NDJSON to the jxclaude subprocess stdin.
  /// **Android**: sends Messages API request through jxproxy at
  /// `http://{proxyHost}:{proxyPort}/v1/messages`.
  Stream<StreamEvent> send({
    required String text,
    List<Attachment>? attachments,
    String? sessionId,
    String? model,
    String? effort,
  }) {
    if (_isAndroid) {
      return _sendApi(
        text: text,
        attachments: attachments,
        sessionId: sessionId,
        model: model,
        effort: effort,
      );
    }
    return _sendProcess(
      text: text,
      attachments: attachments,
      sessionId: sessionId,
      model: model,
      effort: effort,
    );
  }

  /// Cancels the current operation — process or API request depending on mode.
  void cancel() {
    if (_isAndroid) {
      cancelApi();
    } else {
      cancelProcess();
    }
  }
}

// =============================================================================
// Lifecycle
// =============================================================================

extension ClaudeServiceLifecycle on ClaudeService {
  /// Releases all resources.
  void dispose() {
    try {
      _process?.kill(ProcessSignal.sigkill);
    } catch (_) {}
    _cleanup();
    _httpClient?.close(force: true);
    _httpClient = null;
  }

  void _cleanup() {
    _stdoutSubscription?.cancel();
    _stdoutSubscription = null;
    _stderrSubscription?.cancel();
    _stderrSubscription = null;
    _lineController?.close();
    _lineController = null;
    _isRunning = false;
    _process = null;
  }
}
