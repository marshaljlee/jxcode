import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:jxcode/models/stream_event.dart';
import 'package:jxcode/services/claude_service.dart';

/// Tests the SSE → StreamEvent mapping used in API mode (Android).
///
/// Verifies that raw SSE events received from jxproxy's `/v1/messages`
/// endpoint are correctly parsed into [StreamEvent]s consumed by ChatBloc.
void main() {
  group('SseParser — single events', () {
    /// Feed one complete SSE event and return the parsed events.
    List<StreamEvent> parse(String eventType, Map<String, dynamic> data) {
      final events = <StreamEvent>[];
      final ctrl = StreamController<StreamEvent>.broadcast(sync: true);
      ctrl.stream.listen(events.add);
      final parser = SseParser(ctrl, () => false);
      parser.feed('event: $eventType\ndata: ${jsonEncode(data)}\n\n');
      parser.flush();
      ctrl.close();
      return events;
    }

    test('text_delta', () {
      final events = parse('content_block_delta', {
        'type': 'content_block_delta',
        'index': 0,
        'delta': {'type': 'text_delta', 'text': 'Hello!'},
      });
      expect(events, hasLength(1));
      expect(events[0].type, 'text_delta');
      expect(events[0].textContent, 'Hello!');
    });

    test('tool_use', () {
      final events = parse('content_block_start', {
        'type': 'content_block_start',
        'index': 0,
        'content_block': {
          'type': 'tool_use',
          'id': 'toolu_abc',
          'name': 'bash',
          'input': {'cmd': 'ls'},
        },
      });
      expect(events, hasLength(1));
      expect(events[0].type, 'tool_use');
      expect(events[0].toolName, 'bash');
      expect(events[0].toolUseId, 'toolu_abc');
    });

    test('input_json_delta → tool_result', () {
      final events = parse('content_block_delta', {
        'type': 'content_block_delta',
        'index': 1,
        'delta': {'type': 'input_json_delta', 'partial_json': '{"x":1}'},
      });
      expect(events, hasLength(1));
      expect(events[0].type, 'tool_result');
    });

    test('message_delta → done', () {
      final events = parse('message_delta', {
        'type': 'message_delta',
        'delta': {'stop_reason': 'end_turn', 'stop_sequence': null},
      });
      expect(events, hasLength(1));
      expect(events[0].type, 'done');
    });

    test('message_stop → complete', () {
      final events = parse('message_stop', {'type': 'message_stop'});
      expect(events, hasLength(1));
      expect(events[0].type, 'complete');
    });

    test('message_start ignored', () {
      final events = parse('message_start', {
        'type': 'message_start',
        'message': {'id': 'msg_1'},
      });
      expect(events, isEmpty);
    });

    test('content_block_stop ignored', () {
      final events = parse('content_block_stop', {
        'type': 'content_block_stop',
        'index': 0,
      });
      expect(events, isEmpty);
    });

    test('ping ignored', () {
      final events = parse('ping', {'type': 'ping'});
      expect(events, isEmpty);
    });

    test('error', () {
      final events = parse('error', {
        'type': 'error',
        'error': {'message': 'overloaded'},
      });
      expect(events, hasLength(1));
      expect(events[0].type, 'error');
    });
  });

  group('SseParser — multi-event stream', () {
    test('full turn: text + done + complete', () {
      final events = <StreamEvent>[];
      final ctrl = StreamController<StreamEvent>.broadcast(sync: true);
      ctrl.stream.listen(events.add);
      final parser = SseParser(ctrl, () => false);

      parser.feed(
        'event: content_block_delta\n'
        'data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hi"}}\n'
        '\n'
        'event: content_block_delta\n'
        'data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":" there"}}\n'
        '\n'
        'event: message_delta\n'
        'data: {"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null}}\n'
        '\n'
        'event: message_stop\n'
        'data: {"type":"message_stop"}\n'
        '\n',
      );
      parser.flush();
      ctrl.close();

      expect(events, hasLength(4));
      expect(events[0].type, 'text_delta');
      expect(events[0].textContent, 'Hi');
      expect(events[1].type, 'text_delta');
      expect(events[1].textContent, ' there');
      expect(events[2].type, 'done');
      expect(events[3].type, 'complete');
    });
  });

  group('SseParser — chunk boundaries', () {
    test('partial line across chunks', () {
      final events = <StreamEvent>[];
      final ctrl = StreamController<StreamEvent>.broadcast(sync: true);
      ctrl.stream.listen(events.add);
      final parser = SseParser(ctrl, () => false);

      // First chunk: incomplete event
      parser.feed(
        'event: content_block_delta\n'
        'data: {"type":"content_block_delta",',
      );
      expect(events, isEmpty);

      // Second chunk: continuation + empty line
      parser.feed(
        '"index":0,"delta":{"type":"text_delta","text":"ok"}}\n'
        '\n',
      );
      parser.flush();
      ctrl.close();

      expect(events, hasLength(1));
      expect(events[0].type, 'text_delta');
      expect(events[0].textContent, 'ok');
    });
  });

  group('SseParser — cancellation', () {
    test('cancelled parser skips emit', () {
      final events = <StreamEvent>[];
      final ctrl = StreamController<StreamEvent>.broadcast(sync: true);
      ctrl.stream.listen(events.add);
      var cancelled = true;
      final parser = SseParser(ctrl, () => cancelled);

      parser.feed(
        'event: message_stop\n'
        'data: {"type":"message_stop"}\n'
        '\n',
      );
      parser.flush();
      ctrl.close();

      expect(events, isEmpty);
    });
  });
}
