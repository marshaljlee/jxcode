import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../blocs/project/project_bloc.dart';
import '../../blocs/session/session_bloc.dart';
import '../../blocs/session/session_event.dart';
import '../../blocs/session/session_state.dart';
import '../../models/project.dart';
import '../../theme/app_theme.dart';

/// Displays a single project's session history, file tree, and info card.
class ProjectDetailPage extends StatefulWidget {
  final String projectId;

  const ProjectDetailPage({super.key, required this.projectId});

  @override
  State<ProjectDetailPage> createState() => _ProjectDetailPageState();
}

class _ProjectDetailPageState extends State<ProjectDetailPage> {
  Project? _project;

  @override
  void initState() {
    super.initState();
    _loadProject();
  }

  void _loadProject() {
    final state = context.read<ProjectBloc>().state;
    _project = state.projects.where((p) => p.id == widget.projectId).firstOrNull;

    if (_project != null) {
      context.read<SessionBloc>().add(LoadSessions(projectId: widget.projectId));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_project == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Project')),
        body: const Center(child: Text('Project not found')),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(_project!.name),
        actions: [
          IconButton(
            icon: const Icon(Icons.chat_bubble_outline_rounded),
            onPressed: () => _startNewSession(context),
            tooltip: 'New session',
          ),
        ],
      ),
      body: BlocBuilder<SessionBloc, SessionState>(
        builder: (context, sessionState) {
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              // Project info card
              _buildInfoCard(context, sessionState),

              const SizedBox(height: 16),

              // Sessions
              _buildSessionsSection(context, sessionState),
            ],
          );
        },
      ),
    );
  }

  Widget _buildInfoCard(BuildContext context, SessionState sessionState) {
    final theme = Theme.of(context);
    final project = _project!;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: JXCODETheme.terracotta.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(Icons.folder_rounded, color: JXCODETheme.terracotta, size: 20),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        project.name,
                        style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
                      ),
                      Text(
                        project.path,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const Divider(height: 24),
            _infoRow(theme, 'Sessions', '${sessionState.sessions.length}'),
            _infoRow(theme, 'Created', _formatDate(project.createdAt)),
            _infoRow(theme, 'Last opened', _formatDate(project.lastOpenedAt)),
            if (project.claudeMdPath != null)
              _infoRow(theme, 'CLAUDE.md', project.claudeMdPath!),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => _startNewSession(context),
                    icon: const Icon(Icons.chat_bubble_outline_rounded, size: 16),
                    label: const Text('New Session'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton.tonalIcon(
                    onPressed: () {
                      // File tree toggle would open a modal or expand
                    },
                    icon: const Icon(Icons.folder_open_rounded, size: 16),
                    label: const Text('Browse Files'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _infoRow(ThemeData theme, String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          Text(
            value,
            style: theme.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w500),
          ),
        ],
      ),
    );
  }

  Widget _buildSessionsSection(BuildContext context, SessionState sessionState) {
    final theme = Theme.of(context);

    if (sessionState.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    // Pinned sessions first
    final pinned = sessionState.sessions.where((s) => s.isPinned).toList();
    final recent = sessionState.sessions.where((s) => !s.isPinned).toList();

    if (pinned.isEmpty && recent.isEmpty) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            children: [
              Icon(Icons.history_rounded, size: 48, color: theme.colorScheme.primary.withValues(alpha: 0.3)),
              const SizedBox(height: 12),
              Text(
                'No sessions yet',
                style: theme.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w500),
              ),
              const SizedBox(height: 4),
              Text(
                'Start a new chat session to begin working.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Sessions',
          style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),

        // Pinned sessions
        if (pinned.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 4),
            child: Text(
              'PINNED',
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
                letterSpacing: 0.8,
              ),
            ),
          ),
          ...pinned.map((s) => _SessionCard(session: s)),
          const SizedBox(height: 8),
        ],

        // Recent sessions
        if (recent.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 4),
            child: Text(
              'RECENT',
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
                letterSpacing: 0.8,
              ),
            ),
          ),
          ...recent.map((s) => _SessionCard(session: s)),
        ],
      ],
    );
  }

  String _formatDate(DateTime dt) {
    return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
  }

  void _startNewSession(BuildContext context) {
    context.read<SessionBloc>().add(CreateSession(projectId: widget.projectId));
    context.go('/chat');
  }
}

/// A single session card in the list.
class _SessionCard extends StatelessWidget {
  final dynamic session;

  const _SessionCard({required this.session});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // We cast from the generic import — the session is ChatSession but we
    // access via dynamic to keep the import barrier clean in scaffolding.
    final name = session.name as String? ?? 'Untitled';
    final messageCount = session.messageCount as int? ?? 0;
    final updatedAt = session.updatedAt as DateTime;
    final isPinned = session.isPinned as bool? ?? false;
    final timeStr = _formatTimeAgo(updatedAt);

    return Card(
      margin: const EdgeInsets.only(bottom: 6),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => context.go('/chat/${session.id}'),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: isPinned
                      ? JXCODETheme.warning.withValues(alpha: 0.15)
                      : theme.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(
                  isPinned ? Icons.push_pin_rounded : Icons.chat_bubble_outline_rounded,
                  size: 16,
                  color: isPinned ? JXCODETheme.warning : theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w500),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      '$messageCount messages · $timeStr',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.chevron_right_rounded,
                color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _formatTimeAgo(DateTime dt) {
    final diff = DateTime.now().difference(dt);
    if (diff.inMinutes < 1) return 'now';
    if (diff.inHours < 1) return '${diff.inMinutes}m ago';
    if (diff.inDays < 1) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }
}
