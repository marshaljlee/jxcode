import 'package:flutter/material.dart';

import '../../../models/chat_message.dart';
import 'message_bubble.dart';

/// Reverse-order scrollable list of chat messages.
///
/// Auto-scrolls to the bottom on new messages. Shows a loading indicator
/// at the top when the user pulls to refresh. Delegates rendering to
/// [MessageBubble] per item.
class MessageList extends StatefulWidget {
  final List<ChatMessage> messages;
  final bool isStreaming;
  final ScrollController? scrollController;
  final VoidCallback? onClear;

  const MessageList({
    super.key,
    required this.messages,
    this.isStreaming = false,
    this.scrollController,
    this.onClear,
  });

  @override
  State<MessageList> createState() => _MessageListState();
}

class _MessageListState extends State<MessageList> {
  late final ScrollController _scrollController;
  bool _autoScrollEnabled = true;
  bool _isAtBottom = true;

  @override
  void initState() {
    super.initState();
    _scrollController =
        widget.scrollController ?? ScrollController();
    _scrollController.addListener(_onScroll);
  }

  @override
  void didUpdateWidget(MessageList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.messages.length > oldWidget.messages.length ||
        (widget.isStreaming && _autoScrollEnabled)) {
      _scrollToBottom();
    }
  }

  @override
  void dispose() {
    if (widget.scrollController == null) {
      _scrollController.dispose();
    }
    super.dispose();
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final maxScroll = _scrollController.position.maxScrollExtent;
    final currentScroll = _scrollController.offset;
    final atBottom = (maxScroll - currentScroll) < 80;
    if (atBottom != _isAtBottom) {
      setState(() => _isAtBottom = atBottom);
    }
    if (atBottom && !_autoScrollEnabled) {
      setState(() => _autoScrollEnabled = true);
    }
    if (!atBottom && _autoScrollEnabled) {
      setState(() => _autoScrollEnabled = false);
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients && _autoScrollEnabled) {
        _scrollController.animateTo(
          _scrollController.position.minScrollExtent,
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _onRefresh() async {
    // Pull-to-refresh would reload messages from repository.
    await Future.delayed(const Duration(milliseconds: 500));
  }

  @override
  Widget build(BuildContext context) {
    if (widget.messages.isEmpty) {
      return const SizedBox.shrink();
    }

    return Stack(
      children: [
        // Scroll-to-bottom FAB
        if (!_isAtBottom && widget.messages.length > 3)
          Positioned(
            right: 16,
            bottom: 16,
            child: FloatingActionButton.small(
              heroTag: 'scrollToBottom',
              onPressed: () {
                setState(() => _autoScrollEnabled = true);
                _scrollToBottom();
              },
              child: const Icon(Icons.arrow_downward_rounded, size: 18),
            ),
          ),

        // Message list (reversed)
        RefreshIndicator(
          onRefresh: _onRefresh,
          child: ListView.builder(
            controller: _scrollController,
            reverse: true,
            padding: const EdgeInsets.symmetric(vertical: 8),
            itemCount: widget.messages.length,
            itemBuilder: (context, index) {
              final reversedIdx = widget.messages.length - 1 - index;
              final message = widget.messages[reversedIdx];
              final isLast = reversedIdx == widget.messages.length - 1;

              return MessageBubble(
                message: message,
                isLast: isLast,
                isStreaming: widget.isStreaming && isLast,
              );
            },
          ),
        ),
      ],
    );
  }
}
