import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../models/chat_session.dart';
import '../models/project.dart';
import '../theme/app_theme.dart';
import 'status_indicators.dart';

/// Contents for the drawer sidebar.
///
/// Renders the current project card, a short list of recent sessions,
/// navigation entries for agents and MCP servers, and a proxy status
/// indicator at the bottom.
class AppDrawerContent extends StatelessWidget {
  final Project? currentProject;
  final List<ChatSession> recentSessions;
  final String proxyStatus;
  final double proxyLatency;

  const AppDrawerContent({
    super.key,
    this.currentProject,
    this.recentSessions = const [],
    this.proxyStatus = 'stopped',
    this.proxyLatency = 0,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildHeader(context, theme),
        const Divider(height: 1),
        Expanded(child: _buildBody(context, theme)),
        _buildProxyTile(context, theme),
      ],
    );
  }

  Widget _buildHeader(BuildContext context, ThemeData theme) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
      child: Row(
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: JXCODETheme.terracotta,
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Center(
              child: Text(
                'JX',
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                  fontSize: 13,
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'JXCODE',
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
                letterSpacing: 0.5,
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close_rounded, size: 20),
            onPressed: () => Navigator.of(context).pop(),
            visualDensity: VisualDensity.compact,
            tooltip: 'Close drawer',
          ),
        ],
      ),
    );
  }

  Widget _buildBody(BuildContext context, ThemeData theme) {
    return ListView(
      padding: EdgeInsets.zero,
      children: [
        // ── Current project ──
        _SectionHeader(title: 'Project'),
        if (currentProject != null) _ProjectTile(project: currentProject!),
        if (currentProject == null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text(
              'No project selected',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        const Divider(indent: 16, endIndent: 16),

        // ── Recent sessions ──
        _SectionHeader(title: 'Recent Sessions'),
        if (recentSessions.isNotEmpty)
          ...recentSessions.map((s) => _SessionTile(session: s))
        else
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text(
              'No recent sessions',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        const Divider(indent: 16, endIndent: 16),

        // ── Navigation ──
        _SectionHeader(title: 'Navigation'),
        _NavTile(
          icon: Icons.people_outline_rounded,
          label: 'Agents',
          onTap: () {
            Navigator.of(context).pop();
            context.go('/settings');
          },
        ),
        _NavTile(
          icon: Icons.dns_outlined,
          label: 'MCP Servers',
          onTap: () {
            Navigator.of(context).pop();
            context.go('/settings');
          },
        ),
        _NavTile(
          icon: Icons.description_outlined,
          label: 'Settings',
          onTap: () {
            Navigator.of(context).pop();
            context.go('/settings');
          },
        ),
      ],
    );
  }

  Widget _buildProxyTile(BuildContext context, ThemeData theme) {
    final bool isRunning = proxyStatus == 'running';
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
        border: Border(
          top: BorderSide(color: theme.dividerColor.withValues(alpha: 0.5)),
        ),
      ),
      child: ListTile(
        dense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        leading: ConnectionDot(
          isActive: isRunning,
          latency: proxyLatency,
        ),
        title: Text(
          'Proxy ${isRunning ? 'Running' : 'Stopped'}',
          style: theme.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w500),
        ),
        subtitle: isRunning
            ? Text(
                '${proxyLatency.toStringAsFixed(0)} ms',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              )
            : null,
        trailing: IconButton(
          icon: Icon(
            isRunning ? Icons.stop_rounded : Icons.play_arrow_rounded,
            size: 18,
          ),
          onPressed: () {
            // Proxy start/stop dispatched from Settings page
          },
          visualDensity: VisualDensity.compact,
          tooltip: isRunning ? 'Stop proxy' : 'Start proxy',
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Sub-widgets
// ---------------------------------------------------------------------------

class _SectionHeader extends StatelessWidget {
  final String title;
  const _SectionHeader({required this.title});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Text(
        title.toUpperCase(),
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
          fontWeight: FontWeight.w600,
          letterSpacing: 0.8,
        ),
      ),
    );
  }
}

class _ProjectTile extends StatelessWidget {
  final Project project;
  const _ProjectTile({required this.project});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16),
      leading: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: JXCODETheme.terracotta.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(8),
        ),
        child: const Icon(Icons.folder_rounded, size: 18, color: JXCODETheme.terracotta),
      ),
      title: Text(
        project.name,
        style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        project.path.split('/').last,
        style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        overflow: TextOverflow.ellipsis,
      ),
      onTap: () {
        Navigator.of(context).pop();
        context.go('/projects/${project.id}');
      },
    );
  }
}

class _SessionTile extends StatelessWidget {
  final ChatSession session;
  const _SessionTile({required this.session});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final timeStr = _formatTimestamp(session.updatedAt);

    return ListTile(
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16),
      leading: Icon(
        Icons.chat_bubble_outline_rounded,
        size: 18,
        color: theme.colorScheme.onSurfaceVariant,
      ),
      title: Text(
        session.name ?? 'Untitled',
        style: theme.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w500),
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Text(
        timeStr,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
          fontSize: 10,
        ),
      ),
      onTap: () {
        Navigator.of(context).pop();
        context.go('/chat/${session.id}');
      },
    );
  }

  String _formatTimestamp(DateTime dt) {
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inMinutes < 1) return 'now';
    if (diff.inHours < 1) return '${diff.inMinutes}m';
    if (diff.inDays < 1) return '${diff.inHours}h';
    return '${diff.inDays}d';
  }
}

class _NavTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _NavTile({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16),
      leading: Icon(icon, size: 20, color: theme.colorScheme.onSurfaceVariant),
      title: Text(label, style: theme.textTheme.bodyMedium),
      onTap: onTap,
    );
  }
}
