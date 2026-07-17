import 'package:flutter/material.dart';

import '../../../models/chat_message.dart';
import '../../../theme/app_theme.dart';

/// Chat input bar with a multi-line text field, send/cancel button,
/// and attachment button.
class InputBar extends StatefulWidget {
  final bool isStreaming;
  final void Function(String text, List<Attachment>? attachments) onSend;
  final VoidCallback onCancel;

  const InputBar({
    super.key,
    required this.isStreaming,
    required this.onSend,
    required this.onCancel,
  });

  @override
  State<InputBar> createState() => _InputBarState();
}

class _InputBarState extends State<InputBar> {
  final TextEditingController _textController = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  final List<Attachment> _attachments = [];
  bool _hasText = false;

  @override
  void initState() {
    super.initState();
    _textController.addListener(() {
      final hasText = _textController.text.trim().isNotEmpty;
      if (hasText != _hasText) {
        setState(() => _hasText = hasText);
      }
    });
  }

  @override
  void dispose() {
    _textController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _handleSend() {
    final text = _textController.text.trim();
    if (text.isEmpty && _attachments.isEmpty) return;

    widget.onSend(text, _attachments.isNotEmpty ? List.from(_attachments) : null);
    _textController.clear();
    setState(() {
      _attachments.clear();
      _hasText = false;
    });
  }

  Future<void> _pickFiles() async {
    // file_picker integration: deferred import pattern
    // In production, use FilePicker.platform.pickFiles()
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text('File picker ready for implementation'),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    );
  }

  void _removeAttachment(String id) {
    setState(() {
      _attachments.removeWhere((a) => a.id == id);
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border(
          top: BorderSide(color: theme.dividerColor.withValues(alpha: 0.5)),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Attachment preview chips
              if (_attachments.isNotEmpty) _buildAttachmentChips(theme),

              // Input row
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  // Attach button
                  IconButton(
                    onPressed: widget.isStreaming ? null : _pickFiles,
                    icon: Icon(
                      Icons.attach_file_rounded,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    tooltip: 'Attach file',
                    visualDensity: VisualDensity.compact,
                  ),

                  // Text field
                  Expanded(
                    child: TextField(
                      controller: _textController,
                      focusNode: _focusNode,
                      textInputAction: TextInputAction.newline,
                      maxLines: 6,
                      minLines: 1,
                      keyboardType: TextInputType.multiline,
                      enabled: !widget.isStreaming,
                      decoration: InputDecoration(
                        hintText: widget.isStreaming
                            ? 'Waiting for response...'
                            : 'Message Claude...',
                        hintStyle: TextStyle(
                          color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
                        ),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide.none,
                        ),
                        filled: true,
                        fillColor: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 10,
                        ),
                        isDense: true,
                      ),
                      onChanged: (_) {}, // Already handled by listener
                    ),
                  ),

                  const SizedBox(width: 4),

                  // Send / Cancel button
                  if (widget.isStreaming)
                    _buildStopButton(theme)
                  else
                    _buildSendButton(theme),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAttachmentChips(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Wrap(
        spacing: 6,
        runSpacing: 4,
        children: _attachments.map((attachment) {
          return Chip(
            label: Text(
              attachment.fileName ?? attachment.filePath ?? 'Unknown',
              style: theme.textTheme.bodySmall,
            ),
            deleteIcon: const Icon(Icons.close_rounded, size: 16),
            onDeleted: widget.isStreaming ? null : () => _removeAttachment(attachment.id),
            visualDensity: VisualDensity.compact,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(6),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildSendButton(ThemeData theme) {
    final canSend = _hasText || _attachments.isNotEmpty;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      decoration: BoxDecoration(
        color: canSend ? JXCODETheme.terracotta : theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: IconButton(
        onPressed: canSend ? _handleSend : null,
        icon: Icon(
          Icons.arrow_upward_rounded,
          color: canSend ? Colors.white : theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
        ),
        visualDensity: VisualDensity.compact,
        tooltip: 'Send',
      ),
    );
  }

  Widget _buildStopButton(ThemeData theme) {
    return Container(
      decoration: BoxDecoration(
        color: JXCODETheme.error.withValues(alpha: 0.9),
        borderRadius: BorderRadius.circular(12),
      ),
      child: IconButton(
        onPressed: widget.onCancel,
        icon: const Icon(Icons.stop_rounded, color: Colors.white),
        visualDensity: VisualDensity.compact,
        tooltip: 'Stop',
      ),
    );
  }
}
