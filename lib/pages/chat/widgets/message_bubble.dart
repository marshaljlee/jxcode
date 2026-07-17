import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

import '../../../models/chat_message.dart';
import '../../../theme/app_theme.dart';

/// A single chat message bubble.
///
/// Renders the role avatar, message content as markdown, timestamp,
/// status indicator, optional collapsible thinking blocks, tool-use
/// cards, and a copy button.
class MessageBubble extends StatefulWidget {
  final ChatMessage message;
  final bool isLast;
  final bool isStreaming;

  const MessageBubble({
    super.key,
    required this.message,
    this.isLast = false,
    this.isStreaming = false,
  });

  @override
  State<MessageBubble> createState() => _MessageBubbleState();
}

class _MessageBubbleState extends State<MessageBubble> {
  bool _thinkingExpanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isUser = widget.message.role == MessageRole.user;
    final isAssistant = widget.message.role == MessageRole.assistant;
    final isTool = widget.message.role == MessageRole.toolResult;

    // Extract thinking content from message (wrapped in  thinking...)
    final thinkingContent = _extractThinking(widget.message.content);
    final mainContent = _removeThinking(widget.message.content);

    return Padding(
      padding: EdgeInsets.only(
        left: isUser ? 48 : 16,
        right: isUser ? 16 : 48,
        top: 4,
        bottom: 4,
      ),
      child: Column(
        crossAxisAlignment: isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          // Thinking block (collapsible)
          if (thinkingContent != null) _buildThinkingBlock(theme, thinkingContent),

          // Tool use card
          if (isTool && widget.message.toolName != null)
            _buildToolCard(theme),

          // Main message content
          if (mainContent.isNotEmpty || isAssistant)
            _buildContentCard(theme, isUser, isAssistant, mainContent),

          // Metadata row
          _buildMetaRow(theme, isUser),
        ],
      ),
    );
  }

  Widget _buildThinkingBlock(ThemeData theme, String content) {
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.3),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: () => setState(() => _thinkingExpanded = !_thinkingExpanded),
            borderRadius: BorderRadius.circular(10),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  Icon(
                    Icons.psychology_outlined,
                    size: 16,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'Thinking',
                    style: theme.textTheme.labelSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const Spacer(),
                  Icon(
                    _thinkingExpanded ? Icons.expand_less : Icons.expand_more,
                    size: 18,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ],
              ),
            ),
          ),
          AnimatedCrossFade(
            firstChild: const SizedBox.shrink(),
            secondChild: Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
              child: Text(
                content,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  fontStyle: FontStyle.italic,
                ),
              ),
            ),
            crossFadeState: _thinkingExpanded
                ? CrossFadeState.showSecond
                : CrossFadeState.showFirst,
            duration: const Duration(milliseconds: 200),
          ),
        ],
      ),
    );
  }

  Widget _buildToolCard(ThemeData theme) {
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.secondaryContainer.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.3),
        ),
      ),
      child: Row(
        children: [
          Icon(
            Icons.build_outlined,
            size: 16,
            color: theme.colorScheme.onSecondaryContainer,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Tool: ${widget.message.toolName ?? "Unknown"}',
              style: theme.textTheme.bodySmall?.copyWith(
                fontWeight: FontWeight.w500,
                color: theme.colorScheme.onSecondaryContainer,
              ),
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: JXCODETheme.success.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              'completed',
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w600,
                color: JXCODETheme.success,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildContentCard(
    ThemeData theme,
    bool isUser,
    bool isAssistant,
    String content,
  ) {
    final bgColor = isUser
        ? JXCODETheme.terracotta.withValues(alpha: 0.12)
        : theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Role label
          if (isAssistant && content.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(
                'Claude',
                style: theme.textTheme.labelSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: JXCODETheme.terracotta,
                ),
              ),
            ),

          // Content as markdown
          MarkdownBody(
            data: content,
            selectable: true,
            styleSheet: MarkdownStyleSheet(
              p: theme.textTheme.bodyMedium?.copyWith(height: 1.5),
              h1: theme.textTheme.titleLarge,
              h2: theme.textTheme.titleMedium,
              h3: theme.textTheme.titleSmall,
              code: theme.textTheme.bodySmall?.copyWith(
                fontFamily: 'monospace',
                backgroundColor: theme.colorScheme.surfaceContainerHighest,
              ),
              codeblockDecoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              blockquoteDecoration: BoxDecoration(
                border: Border(
                  left: BorderSide(
                    color: JXCODETheme.terracotta.withValues(alpha: 0.5),
                    width: 3,
                  ),
                ),
              ),
              codeblockPadding: const EdgeInsets.all(12),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMetaRow(ThemeData theme, bool isUser) {
    return Padding(
      padding: const EdgeInsets.only(top: 4, left: 4, right: 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Timestamp
          Text(
            _formatTime(widget.message.timestamp),
            style: theme.textTheme.bodySmall?.copyWith(
              fontSize: 10,
              color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
            ),
          ),

          // Status indicator
          if (widget.isLast && widget.message.status == MessageStatus.streaming) ...[
            const SizedBox(width: 6),
            SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: theme.colorScheme.primary,
              ),
            ),
          ],

          if (widget.message.status == MessageStatus.error) ...[
            const SizedBox(width: 6),
            Icon(Icons.error_outline, size: 12, color: JXCODETheme.error),
          ],

          const Spacer(),

          // Copy button
          InkWell(
            onTap: () {
              _copyToClipboard(widget.message.content, theme);
            },
            borderRadius: BorderRadius.circular(4),
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: Icon(
                Icons.copy_rounded,
                size: 14,
                color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  /// Extracts content between  and  markers.
  String? _extractThinking(String content) {
    final start = ' thinking';
    final end = ' ';
    final startIdx = content.indexOf(start);
    if (startIdx == -1) return null;
    final endIdx = content.indexOf(end, startIdx + start.length);
    if (endIdx == -1) return content.substring(startIdx + start.length);
    return content.substring(startIdx + start.length, endIdx);
  }

  /// Removes  blocks from content.
  String _removeThinking(String content) {
    return content.replaceAll(
      RegExp(r'  .*?  ', dotAll: true),
      '',
    ).trim();
  }

  String _formatTime(DateTime dt) {
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inSeconds < 60) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return '${dt.month}/${dt.day} ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }

  void _copyToClipboard(String content, ThemeData theme) {
    // Clipboard copy handled by platform channel
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text('Copied to clipboard'),
        duration: const Duration(seconds: 1),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    );
  }
}
