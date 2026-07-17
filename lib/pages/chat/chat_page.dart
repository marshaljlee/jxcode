import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../blocs/chat/chat_bloc.dart';
import '../../blocs/chat/chat_event.dart';
import '../../blocs/chat/chat_state.dart';
import '../../blocs/permission/permission_bloc.dart';
import '../../blocs/permission/permission_state.dart';
import '../../blocs/project/project_bloc.dart';
import '../../blocs/project/project_state.dart';
import '../../blocs/settings/settings_bloc.dart';
import '../../theme/app_theme.dart';
import '../../widgets/status_indicators.dart';
import 'widgets/input_bar.dart';
import 'widgets/message_list.dart';

/// Full-screen chat interface for a single session.
///
/// Accepts an optional [sessionId] to restore an existing conversation.
class ChatPage extends StatefulWidget {
  final String? sessionId;

  const ChatPage({super.key, this.sessionId});

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    if (widget.sessionId != null) {
      _loadExistingSession(widget.sessionId!);
    }
  }

  void _loadExistingSession(String sessionId) {
    // Session restoration logic would load messages from repo.
    // For now, the ChatBloc handles session lifecycle.
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<ProjectBloc, ProjectState>(
      builder: (context, projectState) {
        return BlocBuilder<ChatBloc, ChatState>(
          builder: (context, chatState) {
            return Scaffold(
              appBar: _buildAppBar(context, chatState, projectState),
              body: Column(
                children: [
                  // Permission mode indicator bar
                  _buildPermissionBar(context),

                  // Message area
                  Expanded(
                    child: _buildMessageArea(context, chatState),
                  ),

                  // Input bar
                  InputBar(
                    isStreaming: chatState.isStreaming,
                    onSend: (text, attachments) {
                      context.read<ChatBloc>().add(
                            SendMessage(text: text, attachments: attachments),
                          );
                    },
                    onCancel: () {
                      context.read<ChatBloc>().add(const CancelStream());
                    },
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  PreferredSizeWidget _buildAppBar(
    BuildContext context,
    ChatState chatState,
    ProjectState projectState,
  ) {
    final theme = Theme.of(context);
    final sessionName = chatState.currentSessionId != null
        ? 'Session ${chatState.currentSessionId!.length > 8 ? chatState.currentSessionId!.substring(0, 8) : chatState.currentSessionId!}'
        : 'New Chat';

    return AppBar(
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            projectState.selectedProject?.name ?? sessionName,
            style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
          ),
          Row(
            children: [
              if (projectState.selectedProject != null)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: Text(
                    projectState.selectedProject!.path.split('/').last,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              if (chatState.isStreaming) ...[
                const SizedBox(width: 6),
                const StreamingIndicator(),
              ],
            ],
          ),
        ],
      ),
      actions: [
        // Model chip
        BlocBuilder<SettingsBloc, SettingsState>(
          builder: (context, settingsState) {
            return Padding(
              padding: const EdgeInsets.only(right: 4),
              child: ModelChip(model: settingsState.defaultModel),
            );
          },
        ),
        // Permission mode
        BlocBuilder<PermissionBloc, PermissionState>(
          builder: (context, permState) {
            return Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ModeLabel(mode: permState.currentMode.name),
            );
          },
        ),
        // Clear session
        IconButton(
          icon: const Icon(Icons.delete_outline_rounded, size: 20),
          onPressed: chatState.messages.isNotEmpty
              ? () {
                  context.read<ChatBloc>().add(const ClearSession());
                }
              : null,
          tooltip: 'Clear session',
        ),
      ],
    );
  }

  Widget _buildPermissionBar(BuildContext context) {
    return BlocBuilder<PermissionBloc, PermissionState>(
      builder: (context, state) {
        if (state.pendingRequests.isEmpty) {
          return const SizedBox.shrink();
        }

        final count = state.pendingRequests.length;
        final theme = Theme.of(context);
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          color: JXCODETheme.warning.withValues(alpha: 0.1),
          child: Row(
            children: [
              Icon(Icons.shield_outlined, size: 16, color: JXCODETheme.warning),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '$count permission request${count > 1 ? 's' : ''} pending',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: JXCODETheme.warning,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              TextButton(
                onPressed: () {
                  // The overlay from HomePage will show the modal.
                },
                child: const Text('Review', style: TextStyle(fontSize: 12)),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildMessageArea(BuildContext context, ChatState chatState) {
    if (chatState.error != null) {
      return _buildErrorState(context, chatState.error!);
    }

    if (chatState.messages.isEmpty && !chatState.isStreaming) {
      return _buildEmptyState(context);
    }

    return MessageList(
      messages: chatState.messages,
      isStreaming: chatState.isStreaming,
      scrollController: _scrollController,
      onClear: () {
        context.read<ChatBloc>().add(const ClearSession());
      },
    );
  }

  Widget _buildEmptyState(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.chat_bubble_outline_rounded,
              size: 64,
              color: theme.colorScheme.primary.withValues(alpha: 0.3),
            ),
            const SizedBox(height: 20),
            Text(
              'Start a conversation',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Send a message to begin chatting with Claude.\nUse /help to see available commands.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildErrorState(BuildContext context, String error) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline_rounded, size: 48, color: JXCODETheme.error),
            const SizedBox(height: 16),
            Text(
              'Something went wrong',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              error,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            FilledButton.tonal(
              onPressed: () {
                context.read<ChatBloc>().add(const ClearSession());
              },
              child: const Text('Start fresh'),
            ),
          ],
        ),
      ),
    );
  }
}
