import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../models/chat_message.dart';
import '../models/chat_session.dart';

/// Persistent storage for chat sessions and their messages.
///
/// Each session is stored as two files in the app support directory:
///   .jxcode.jsonl       — message log (JSON Lines)
///   .jxcode.meta.json   — session metadata
///
/// Sessions are grouped by project within a `<appDir>/sessions/` tree.
class SessionRepository {
  final String Function()? basePathOverride;
  static const _uuid = Uuid();

  SessionRepository({this.basePathOverride});

  /// Resolves the root storage directory (app support / sessions).
  Future<Directory> _baseDir() async {
    if (basePathOverride != null) {
      final dir = Directory(basePathOverride!());
      if (!await dir.exists()) await dir.create(recursive: true);
      return dir;
    }
    final appDir = await getApplicationSupportDirectory();
    final dir = Directory(p.join(appDir.path, 'sessions'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// Project-scoped subdirectory for sessions.
  Future<Directory> _projectDir(String projectId) async {
    final base = await _baseDir();
    final dir = Directory(p.join(base.path, _sanitize(projectId)));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// Returns all sessions belonging to [projectId], newest first.
  Future<List<ChatSession>> getSessions(String projectId) async {
    final dir = await _projectDir(projectId);
    final files = dir.listSync().whereType<File>().toList()
      ..sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));

    final sessions = <ChatSession>[];
    for (final file in files) {
      if (!file.path.endsWith('.meta.json')) continue;
      try {
        final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
        sessions.add(_fromMetaJson(json));
      } catch (_) {
        // Corrupt file — skip.
      }
    }
    return sessions;
  }

  /// Same as [getSessions] — convenience alias used by existing Blocs.
  Future<List<ChatSession>> list(String projectId) => getSessions(projectId);

  /// Retrieves a single session by [id].
  Future<ChatSession?> get(String id) async {
    final base = await _baseDir();
    final metaFile = File(p.join(base.path, _sessionDir(id), '.jxcode.meta.json'));
    if (!await metaFile.exists()) return null;
    try {
      final json = jsonDecode(await metaFile.readAsString()) as Map<String, dynamic>;
      return _fromMetaJson(json);
    } catch (_) {
      return null;
    }
  }

  /// Creates a new empty session under [projectId].
  ///
  /// If [name] is omitted, a UUID-based label is used. The returned
  /// [ChatSession] has a stable [id] that matches the on-disk location.
  Future<ChatSession> createSession(
    String projectId, {
    String? name,
    String? modelOverride,
    String? effortOverride,
  }) async {
    final now = DateTime.now();
    final sessionId = _uuid.v4();
    final session = ChatSession(
      id: sessionId,
      projectId: projectId,
      name: name ?? 'Session ${now.millisecondsSinceEpoch}',
      createdAt: now,
      updatedAt: now,
      modelOverride: modelOverride,
      effortOverride: effortOverride,
    );

    await _writeMeta(session);
    return session;
  }

  /// Persists session metadata to disk.
  Future<void> save(ChatSession session) async {
    await _writeMeta(session.copyWith(updatedAt: DateTime.now()));
  }

  /// Alias for [save] used by existing Blocs.
  Future<void> updateSession(ChatSession session) => save(session);

  /// Deletes a session and all its messages from disk.
  Future<void> deleteSession(String id) async {
    final base = await _baseDir();
    final dir = Directory(p.join(base.path, _sessionDir(id)));
    if (await dir.exists()) {
      await dir.delete(recursive: true);
    }
  }

  /// Alias for [deleteSession] used by existing Blocs.
  Future<void> delete(String id) => deleteSession(id);

  /// Toggles the pinned state of a session.
  Future<void> pin(String id, bool pinned) async {
    final session = await get(id);
    if (session == null) return;
    await save(session.copyWith(isPinned: pinned));
  }

  /// Appends a chat message to the session's JSONL message log.
  Future<void> persistMessage(ChatMessage message) async {
    final base = await _baseDir();
    final logFile = File(p.join(
      base.path,
      _sessionDir(message.sessionId),
      '.jxcode.jsonl',
    ));

    if (!await logFile.parent.exists()) {
      await logFile.parent.create(recursive: true);
    }

    final line = jsonEncode({
      'id': message.id,
      'session_id': message.sessionId,
      'role': message.role.name,
      'content': message.content,
      'timestamp': message.timestamp.toIso8601String(),
      'status': message.status.name,
      if (message.toolUseId != null) 'tool_use_id': message.toolUseId,
      if (message.toolName != null) 'tool_name': message.toolName,
      if (message.attachments.isNotEmpty)
        'attachments': message.attachments
            .map((a) => {
              'id': a.id,
              if (a.filePath != null) 'file_path': a.filePath,
              if (a.url != null) 'url': a.url,
              if (a.mimeType != null) 'mime_type': a.mimeType,
              if (a.fileName != null) 'file_name': a.fileName,
            })
            .toList(),
    });

    await logFile.writeAsString('$line\n', mode: FileMode.append);
  }

  /// Reads all messages logged for a session.
  Future<List<ChatMessage>> loadMessages(String sessionId) async {
    final base = await _baseDir();
    final logFile = File(p.join(
      base.path,
      _sessionDir(sessionId),
      '.jxcode.jsonl',
    ));

    if (!await logFile.exists()) return [];

    final messages = <ChatMessage>[];
    final lines = await logFile.readAsLines();
    for (final line in lines) {
      if (line.trim().isEmpty) continue;
      try {
        final json = jsonDecode(line) as Map<String, dynamic>;
        messages.add(_messageFromJson(json));
      } catch (_) {
        // Skip corrupt entries.
      }
    }
    return messages;
  }

  // ---------------------------------------------------------------------------
  // Serialisation helpers
  // ---------------------------------------------------------------------------

  Future<void> _writeMeta(ChatSession s) async {
    final base = await _baseDir();
    final file = File(p.join(base.path, _sessionDir(s.id), '.jxcode.meta.json'));
    if (!await file.parent.exists()) {
      await file.parent.create(recursive: true);
    }
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(_toMetaJson(s)),
    );
  }

  static String _sessionDir(String sessionId) =>
      'sessions/${_sanitize(sessionId)}';

  static String _sanitize(String input) =>
      input.replaceAll(RegExp(r'[^\w\-]'), '_');

  static Map<String, dynamic> _toMetaJson(ChatSession s) => {
    'id': s.id,
    'project_id': s.projectId,
    'name': s.name,
    'created_at': s.createdAt.millisecondsSinceEpoch,
    'updated_at': s.updatedAt.millisecondsSinceEpoch,
    'is_pinned': s.isPinned,
    'message_count': s.messageCount,
    'is_completed': s.isCompleted,
    if (s.modelOverride != null) 'model_override': s.modelOverride,
    if (s.effortOverride != null) 'effort_override': s.effortOverride,
  };

  static ChatSession _fromMetaJson(Map<String, dynamic> json) => ChatSession(
    id: json['id'] as String,
    projectId: json['project_id'] as String,
    name: json['name'] as String?,
    createdAt: DateTime.fromMillisecondsSinceEpoch(
      (json['created_at'] as num).toInt(),
    ),
    updatedAt: DateTime.fromMillisecondsSinceEpoch(
      (json['updated_at'] as num).toInt(),
    ),
    isPinned: json['is_pinned'] as bool? ?? false,
    messageCount: json['message_count'] as int? ?? 0,
    isCompleted: json['is_completed'] as bool? ?? false,
    modelOverride: json['model_override'] as String?,
    effortOverride: json['effort_override'] as String?,
  );

  static ChatMessage _messageFromJson(Map<String, dynamic> json) {
    final attachments = (json['attachments'] as List<dynamic>?)
            ?.map((a) => Attachment(
                  id: a['id'] as String? ?? '',
                  filePath: a['file_path'] as String?,
                  url: a['url'] as String?,
                  mimeType: a['mime_type'] as String?,
                  fileName: a['file_name'] as String?,
                ))
            .toList() ??
        const [];

    return ChatMessage(
      id: json['id'] as String? ?? '',
      sessionId: json['session_id'] as String? ?? '',
      role: MessageRole.values.firstWhere(
        (r) => r.name == json['role'],
        orElse: () => MessageRole.assistant,
      ),
      content: json['content'] as String? ?? '',
      status: MessageStatus.values.firstWhere(
        (s) => s.name == json['status'],
        orElse: () => MessageStatus.complete,
      ),
      timestamp: json['timestamp'] != null
          ? DateTime.parse(json['timestamp'] as String)
          : DateTime.now(),
      attachments: attachments,
      toolUseId: json['tool_use_id'] as String?,
      toolName: json['tool_name'] as String?,
    );
  }
}
