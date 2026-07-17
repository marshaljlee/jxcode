import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../blocs/permission/permission_bloc.dart';
import '../../blocs/permission/permission_event.dart';
import '../../models/permission_request.dart';
import '../../theme/app_theme.dart';
import '../../widgets/status_indicators.dart';

/// Full-screen permission approval overlay shown when the Claude CLI
/// requests tool execution approval.
///
/// Displays the tool name, command string, risk level indicator, and
/// action buttons (Allow, Deny, Allow Once, Allow Session, Edit Input).
class PermissionModalOverlay extends StatelessWidget {
  final PermissionRequest request;

  const PermissionModalOverlay({super.key, required this.request});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final riskColor = _riskColor(request.riskLevel);
    final riskLabel = _riskLabel(request.riskLevel);

    return Material(
      color: Colors.black54,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Material(
            color: theme.colorScheme.surface,
            borderRadius: BorderRadius.circular(16),
            elevation: 8,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 500),
              child: SingleChildScrollView(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // Header
                      _buildHeader(context, theme, riskColor, riskLabel),

                      const SizedBox(height: 20),

                      // Tool info
                      _buildToolInfo(context, theme),

                      const SizedBox(height: 16),

                      // Command string
                      _buildCommandBlock(theme),

                      const SizedBox(height: 20),

                      // Action buttons
                      _buildActions(context, theme),

                      // Edit input
                      _buildEditInput(context, theme),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context, ThemeData theme, Color riskColor, String riskLabel) {
    return Row(
      children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: riskColor.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(Icons.shield_outlined, color: riskColor, size: 22),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Permission Request',
                style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 2),
              Row(
                children: [
                  PermissionBadge(label: riskLabel),
                  const SizedBox(width: 8),
                  Text(
                    request.toolName,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      fontFamily: 'monospace',
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        IconButton(
          icon: const Icon(Icons.close_rounded),
          onPressed: () {
            context.read<PermissionBloc>().add(DenyPermission(requestId: request.id));
          },
          visualDensity: VisualDensity.compact,
        ),
      ],
    );
  }

  Widget _buildToolInfo(BuildContext context, ThemeData theme) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _infoRow(context, theme, 'Tool', request.toolName),
          const SizedBox(height: 6),
          if (request.sessionId != null) ...[
            _infoRow(context, theme, 'Session', request.sessionId!.length > 12
                ? '${request.sessionId!.substring(0, 12)}...'
                : request.sessionId!),
            const SizedBox(height: 6),
          ],
          _infoRow(context, theme, 'Risk Level', _riskLabel(request.riskLevel)),
        ],
      ),
    );
  }

  Widget _infoRow(BuildContext context, ThemeData theme, String label, String value) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 80,
          child: Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: theme.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w500),
          ),
        ),
      ],
    );
  }

  Widget _buildCommandBlock(ThemeData theme) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.3),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.terminal_rounded, size: 14, color: theme.colorScheme.onSurfaceVariant),
              const SizedBox(width: 6),
              Text(
                'Command',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            request.command.isNotEmpty ? request.command : '(no command)',
            style: theme.textTheme.bodySmall?.copyWith(
              fontFamily: 'monospace',
              fontSize: 12,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActions(BuildContext context, ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Primary actions row
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: () {
                  context.read<PermissionBloc>().add(DenyPermission(requestId: request.id));
                },
                style: OutlinedButton.styleFrom(
                  foregroundColor: JXCODETheme.error,
                  side: BorderSide(color: JXCODETheme.error.withValues(alpha: 0.5)),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
                child: const Text('Deny'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: FilledButton(
                onPressed: () {
                  context.read<PermissionBloc>().add(ApprovePermission(requestId: request.id));
                },
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
                child: const Text('Allow'),
              ),
            ),
          ],
        ),

        const SizedBox(height: 8),

        // Secondary actions
        Row(
          children: [
            Expanded(
              child: TextButton(
                onPressed: () {
                  context.read<PermissionBloc>().add(SessionAllow(requestId: request.id));
                },
                child: const Text('Allow Session'),
              ),
            ),
            Expanded(
              child: TextButton(
                onPressed: () {
                  // Edit input would open an inline editor
                },
                child: const Text('Edit Input'),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildEditInput(BuildContext context, ThemeData theme) {
    return const SizedBox.shrink();
  }

  Color _riskColor(PermissionMode mode) {
    switch (mode) {
      case PermissionMode.safe:
      case PermissionMode.approveAll:
        return JXCODETheme.success;
      case PermissionMode.moderate:
      case PermissionMode.high:
      case PermissionMode.custom:
      case PermissionMode.session:
        return JXCODETheme.warning;
      case PermissionMode.interactive:
        return JXCODETheme.info;
      case PermissionMode.denyAll:
        return JXCODETheme.error;
    }
  }

  String _riskLabel(PermissionMode mode) {
    switch (mode) {
      case PermissionMode.safe:
        return 'Safe';
      case PermissionMode.moderate:
        return 'Moderate';
      case PermissionMode.high:
      case PermissionMode.custom:
      case PermissionMode.session:
        return 'High';
      case PermissionMode.interactive:
        return 'Review';
      case PermissionMode.approveAll:
        return 'Auto-Allow';
      case PermissionMode.denyAll:
        return 'Auto-Deny';
    }
  }
}
