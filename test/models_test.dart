import 'package:flutter_test/flutter_test.dart';

import 'package:jxcode/models/project.dart';
import 'package:jxcode/models/chat_message.dart';
import 'package:jxcode/models/chat_session.dart';
import 'package:jxcode/models/permission_request.dart';

void main() {
  group('Project', () {
    test('equatable works', () {
      final a = Project(
        id: 'p1',
        name: 'Test',
        path: '/tmp/test',
        createdAt: DateTime(2026),
        lastOpenedAt: DateTime(2026),
      );
      final b = Project(
        id: 'p1',
        name: 'Test',
        path: '/tmp/test',
        createdAt: DateTime(2026),
        lastOpenedAt: DateTime(2026),
      );
      expect(a, equals(b));
    });

    test('copyWith updates fields', () {
      final a = Project(
        id: 'p1', name: 'Test', path: '/tmp/test',
        createdAt: DateTime(2026), lastOpenedAt: DateTime(2026),
      );
      final b = a.copyWith(name: 'Updated');
      expect(b.name, 'Updated');
      expect(b.id, 'p1');
    });
  });

  group('ChatMessage', () {
    test('creates with defaults', () {
      final msg = ChatMessage(
        id: 'm1', sessionId: 's1',
        role: MessageRole.user, content: 'hello',
        timestamp: DateTime(2026),
      );
      expect(msg.role, MessageRole.user);
      expect(msg.content, 'hello');
      expect(msg.status, MessageStatus.complete);
    });

    test('copyWith updates role', () {
      final msg = ChatMessage(
        id: 'm1', sessionId: 's1',
        role: MessageRole.user, content: 'hello',
        timestamp: DateTime(2026),
      );
      final updated = msg.copyWith(role: MessageRole.assistant, content: 'reply');
      expect(updated.role, MessageRole.assistant);
      expect(updated.content, 'reply');
      expect(updated.id, 'm1');
    });
  });

  group('ChatSession', () {
    test('isPinned defaults to false', () {
      final s = ChatSession(
        id: 's1', projectId: 'p1',
        createdAt: DateTime(2026), updatedAt: DateTime(2026),
      );
      expect(s.isPinned, false);
      expect(s.isCompleted, false);
    });
  });

  group('PermissionRequest', () {
    test('riskLevel defaults to moderate', () {
      final r = PermissionRequest(
        id: 'r1', command: 'ls', toolName: 'Bash',
        timestamp: DateTime(2026),
      );
      expect(r.riskLevel, PermissionMode.moderate);
      expect(r.decision, PermissionDecision.pending);
    });

    test('copyWith updates decision', () {
      final r = PermissionRequest(
        id: 'r1', command: 'ls', toolName: 'Bash',
        timestamp: DateTime(2026),
      );
      final approved = r.copyWith(decision: PermissionDecision.allowed);
      expect(approved.decision, PermissionDecision.allowed);
    });
  });
}
